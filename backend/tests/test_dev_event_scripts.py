from __future__ import annotations

import os
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

from sqlalchemy.orm import Session, sessionmaker

from app.models.dev_event import DevEvent
from scripts import collect_dev_context, collect_git_snapshot, record_command_result, run_dev_checks


def test_collect_git_snapshot_saves_changed_files_diff_stat_and_commits(
    db: Session,
    tmp_path: Path,
    monkeypatch,
) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test User")
    (repo / "README.md").write_text("hello\n", encoding="utf-8")
    _git(repo, "add", "README.md")
    _git(repo, "commit", "-m", "initial commit")
    (repo / "README.md").write_text("hello\nupdated\n", encoding="utf-8")

    _patch_script_session(monkeypatch, collect_git_snapshot, db)

    exit_code = collect_git_snapshot.collect_git_snapshot(str(repo))

    event = db.query(DevEvent).one()
    assert exit_code == 0
    assert event.event_type == "git_snapshot"
    assert event.details_json["changed_files"] == ["README.md"]
    assert "README.md" in event.details_json["diff_stat"]
    assert event.details_json["recent_commits"]


def test_collect_git_snapshot_handles_non_git_path(tmp_path: Path) -> None:
    exit_code = collect_git_snapshot.collect_git_snapshot(str(tmp_path))

    assert exit_code == 1


def test_record_command_result_saves_masked_summary_and_details(
    db: Session,
    monkeypatch,
) -> None:
    _patch_script_session(monkeypatch, record_command_result, db)

    exit_code = record_command_result.record_command_result(
        command="uv run pytest token=abc123",
        status="success",
        summary="pytest 통과: token=abc123",
        event_type="test_result",
        exit_code=0,
        duration_seconds=1.5,
    )

    event = db.query(DevEvent).one()
    assert exit_code == 0
    assert event.event_type == "test_result"
    assert event.status == "success"
    assert "abc123" not in event.summary
    assert "abc123" not in event.command
    assert event.details_json["exit_code"] == 0
    assert event.details_json["duration_seconds"] == 1.5


def test_collect_git_snapshot_script_runs_without_pythonpath(tmp_path: Path) -> None:
    result = _run_script_without_pythonpath(
        "scripts/collect_git_snapshot.py",
        "--repo-path",
        str(tmp_path),
    )

    assert result.returncode == 1
    assert "Git 저장소가 아닙니다" in result.stdout


def test_record_command_result_script_imports_without_pythonpath() -> None:
    result = _run_script_without_pythonpath("scripts/record_command_result.py", "--help")

    assert result.returncode == 0
    assert "Record a command result as DevEvent." in result.stdout


def test_run_dev_checks_saves_success_results(db: Session, monkeypatch, tmp_path: Path) -> None:
    _patch_script_session(monkeypatch, run_dev_checks, db)
    monkeypatch.setattr(run_dev_checks, "_run_command", _fake_command_runner([0, 0, 0, 0]))

    exit_code = run_dev_checks.run_dev_checks(repo_path=str(tmp_path))

    events = db.query(DevEvent).order_by(DevEvent.id).all()
    assert exit_code == 0
    assert len(events) == 4
    assert {event.status for event in events} == {"success"}
    assert [event.command for event in events] == [
        "uv run ruff check .",
        "uv run pytest",
        "uv run alembic check",
        "git diff --check",
    ]
    assert all(event.details_json["exit_code"] == 0 for event in events)
    assert all("duration_seconds" in event.details_json for event in events)


def test_run_dev_checks_continues_after_failure_and_returns_one(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    _patch_script_session(monkeypatch, run_dev_checks, db)
    monkeypatch.setattr(run_dev_checks, "_run_command", _fake_command_runner([0, 1, 0, 0]))

    exit_code = run_dev_checks.run_dev_checks(repo_path=str(tmp_path))

    events = db.query(DevEvent).order_by(DevEvent.id).all()
    assert exit_code == 1
    assert len(events) == 4
    assert [event.status for event in events] == ["success", "failed", "success", "success"]
    assert events[1].command == "uv run pytest"


def test_run_dev_checks_masks_sensitive_output_excerpt(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    _patch_script_session(monkeypatch, run_dev_checks, db)
    monkeypatch.setattr(
        run_dev_checks,
        "_run_command",
        _fake_command_runner([0, 0, 0, 0], stdout="token=abc123 password=hunter2"),
    )

    run_dev_checks.run_dev_checks(repo_path=str(tmp_path))

    event = db.query(DevEvent).first()
    assert "abc123" not in event.details_json["output_excerpt"]
    assert "hunter2" not in event.details_json["output_excerpt"]


def test_run_dev_checks_compresses_pytest_success_output(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    _patch_script_session(monkeypatch, run_dev_checks, db)
    output = "\n".join(
        [
            "tests/test_ai_components.py ................................",
            "tests/test_api_flows.py ................................",
            "============================= 123 passed in 3.33s ==============================",
        ]
    )
    monkeypatch.setattr(
        run_dev_checks,
        "_run_command",
        _fake_command_runner([0, 0, 0, 0], outputs=["", output, "", ""]),
    )

    run_dev_checks.run_dev_checks(repo_path=str(tmp_path))

    event = db.query(DevEvent).filter(DevEvent.command == "uv run ruff check .").one()
    pytest_event = db.query(DevEvent).filter(DevEvent.command == "uv run pytest").one()
    assert event.details_json["output_excerpt"] == ""
    assert pytest_event.details_json["output_excerpt"] == "123 passed in 3.33s"
    assert "tests/test_api_flows.py" not in pytest_event.details_json["output_excerpt"]


def test_run_dev_checks_compresses_alembic_and_ruff_output(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    _patch_script_session(monkeypatch, run_dev_checks, db)
    alembic_output = "\n".join(
        [
            "INFO  [alembic.runtime.plugins] setting up autogenerate plugin "
            "alembic.autogenerate.schemas",
            "INFO  [alembic.runtime.plugins] setting up autogenerate plugin "
            "alembic.autogenerate.tables",
            "No new upgrade operations detected.",
        ]
    )
    monkeypatch.setattr(
        run_dev_checks,
        "_run_command",
        _fake_command_runner(
            [0, 0, 0, 0],
            outputs=["All checks passed!", "pytest ok", alembic_output, ""],
        ),
    )

    run_dev_checks.run_dev_checks(repo_path=str(tmp_path))

    ruff_event = db.query(DevEvent).filter(DevEvent.command == "uv run ruff check .").one()
    alembic_event = db.query(DevEvent).filter(DevEvent.command == "uv run alembic check").one()
    git_event = db.query(DevEvent).filter(DevEvent.command == "git diff --check").one()
    assert ruff_event.details_json["output_excerpt"] == "All checks passed!"
    assert alembic_event.details_json["output_excerpt"] == "No new upgrade operations detected."
    assert "setting up autogenerate plugin" not in alembic_event.details_json["output_excerpt"]
    assert git_event.details_json["output_excerpt"] == "No whitespace errors"


def test_run_dev_checks_limits_failed_output_excerpt(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    _patch_script_session(monkeypatch, run_dev_checks, db)
    long_failure = "\n".join(["FAILED tests/test_example.py::test_case"] + ["x" * 200] * 20)
    monkeypatch.setattr(
        run_dev_checks,
        "_run_command",
        _fake_command_runner([0, 1, 0, 0], outputs=["", long_failure, "", ""]),
    )

    run_dev_checks.run_dev_checks(repo_path=str(tmp_path))

    event = db.query(DevEvent).filter(DevEvent.command == "uv run pytest").one()
    assert event.status == "failed"
    assert "FAILED tests/test_example.py::test_case" in event.details_json["output_excerpt"]
    assert len(event.details_json["output_excerpt"]) <= run_dev_checks.OUTPUT_EXCERPT_LIMIT


def test_run_dev_checks_script_imports_without_pythonpath() -> None:
    result = _run_script_without_pythonpath("scripts/run_dev_checks.py", "--help")

    assert result.returncode == 0
    assert "Run development checks and record DevEvents." in result.stdout


def test_collect_dev_context_runs_git_snapshot_and_dev_checks(
    monkeypatch,
    tmp_path: Path,
) -> None:
    calls: list[tuple[str, str, bool]] = []

    def fake_collect_git_snapshot(repo_path: str, *, session_current: bool = False) -> int:
        calls.append(("git", repo_path, session_current))
        return 0

    def fake_run_dev_checks(repo_path: str | None = None, *, session_current: bool = False) -> int:
        calls.append(("checks", repo_path or "", session_current))
        return 0

    monkeypatch.setattr(collect_dev_context, "collect_git_snapshot", fake_collect_git_snapshot)
    monkeypatch.setattr(collect_dev_context, "run_dev_checks", fake_run_dev_checks)

    exit_code = collect_dev_context.collect_dev_context(
        repo_path=str(tmp_path),
        session_current=True,
    )

    assert exit_code == 0
    assert calls == [
        ("git", str(tmp_path.resolve()), True),
        ("checks", str(tmp_path.resolve()), True),
    ]


def test_collect_dev_context_returns_one_when_checks_fail(
    monkeypatch,
    tmp_path: Path,
) -> None:
    calls: list[str] = []

    def fake_collect_git_snapshot(repo_path: str, *, session_current: bool = False) -> int:
        calls.append("git")
        return 0

    def fake_run_dev_checks(repo_path: str | None = None, *, session_current: bool = False) -> int:
        calls.append("checks")
        return 1

    monkeypatch.setattr(collect_dev_context, "collect_git_snapshot", fake_collect_git_snapshot)
    monkeypatch.setattr(collect_dev_context, "run_dev_checks", fake_run_dev_checks)

    exit_code = collect_dev_context.collect_dev_context(repo_path=str(tmp_path))

    assert exit_code == 1
    assert calls == ["git", "checks"]


def test_collect_dev_context_script_imports_without_pythonpath() -> None:
    result = _run_script_without_pythonpath("scripts/collect_dev_context.py", "--help")

    assert result.returncode == 0
    assert "Collect Git and development check context." in result.stdout


def _patch_script_session(monkeypatch, module, db: Session) -> None:
    testing_session_local = sessionmaker(bind=db.get_bind())
    monkeypatch.setattr(module, "SessionLocal", testing_session_local)


def _git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def _run_script_without_pythonpath(*args: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.pop("PYTHONPATH", None)
    return subprocess.run(
        [sys.executable, *args],
        check=False,
        capture_output=True,
        text=True,
        cwd=Path(__file__).resolve().parents[1],
        env=env,
    )


def _fake_command_runner(
    exit_codes: list[int],
    *,
    stdout: str = "ok",
    outputs: list[str] | None = None,
) -> Callable:
    remaining_codes = list(exit_codes)
    remaining_outputs = list(outputs) if outputs is not None else None

    def run(command: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
        command_output = (
            remaining_outputs.pop(0) if remaining_outputs is not None else stdout
        )
        return subprocess.CompletedProcess(
            args=command,
            returncode=remaining_codes.pop(0),
            stdout=command_output,
            stderr="",
        )

    return run

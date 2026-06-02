from __future__ import annotations

import os
import subprocess
import sys
from collections.abc import Callable
from pathlib import Path

from sqlalchemy.orm import Session, sessionmaker

from app.models.dev_event import DevEvent
from scripts import collect_git_snapshot, record_command_result, run_dev_checks


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


def test_run_dev_checks_script_imports_without_pythonpath() -> None:
    result = _run_script_without_pythonpath("scripts/run_dev_checks.py", "--help")

    assert result.returncode == 0
    assert "Run development checks and record DevEvents." in result.stdout


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
) -> Callable:
    remaining_codes = list(exit_codes)

    def run(command: list[str], *, cwd: Path) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(
            args=command,
            returncode=remaining_codes.pop(0),
            stdout=stdout,
            stderr="",
        )

    return run

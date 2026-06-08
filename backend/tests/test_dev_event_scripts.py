from __future__ import annotations

import os
import subprocess
import sys
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path

from sqlalchemy.orm import Session, sessionmaker

from app.models.dev_event import DevEvent
from scripts import (
    collect_dev_context,
    collect_git_snapshot,
    dev_check_output,
    dev_event_helpers,
    dev_tracking,
    install_command_tracking_hook,
    record_command_result,
    run_dev_checks,
    uninstall_command_tracking_hook,
    watch_dev_context,
)


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


def test_record_command_result_records_terminal_metadata_and_git_context(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _clean_git_repo(tmp_path)
    _patch_script_session(monkeypatch, record_command_result, db)

    exit_code = record_command_result.record_command_result(
        command="uv run pytest --token=abc123",
        exit_code=1,
        duration_ms=12345,
        cwd=str(repo),
        started_at="2026-06-08T01:00:00+00:00",
        ended_at="2026-06-08T01:00:12+00:00",
        shell="zsh",
        source="terminal",
        session_current=True,
    )

    event = db.query(DevEvent).one()
    assert exit_code == 0
    assert event.event_type == "command_result"
    assert event.source == "terminal"
    assert event.status == "failed"
    assert event.repo_path == str(repo)
    assert event.branch in {"master", "main"}
    assert "abc123" not in event.command
    assert event.details_json["duration_ms"] == 12345
    assert event.details_json["cwd"] == str(repo)
    assert event.details_json["tracking_mode"] == "command_hook"
    assert event.details_json["shell"] == "zsh"


def test_record_command_result_saves_successful_short_pytest_command(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _clean_git_repo(tmp_path)
    _patch_script_session(monkeypatch, record_command_result, db)

    exit_code = record_command_result.record_command_result(
        command="uv run pytest tests/test_health.py",
        exit_code=0,
        duration_ms=5,
        cwd=str(repo),
        source="terminal",
    )

    event = db.query(DevEvent).one()
    assert exit_code == 0
    assert event.status == "success"
    assert event.command == "uv run pytest tests/test_health.py"
    assert event.details_json["duration_ms"] == 5


def test_record_command_result_skips_simple_and_env_read_commands(
    db: Session,
    monkeypatch,
) -> None:
    _patch_script_session(monkeypatch, record_command_result, db)

    assert record_command_result.record_command_result(command="pwd", source="terminal") == 0
    assert record_command_result.record_command_result(
        command="cat .env",
        source="terminal",
    ) == 0

    assert db.query(DevEvent).count() == 0


def test_record_command_result_handles_non_git_cwd(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    _patch_script_session(monkeypatch, record_command_result, db)

    record_command_result.record_command_result(
        command="python script.py",
        exit_code=0,
        cwd=str(tmp_path),
        source="terminal",
    )

    event = db.query(DevEvent).one()
    assert event.repo_path is None
    assert event.branch is None
    assert event.details_json["cwd"] == str(tmp_path)


def test_record_command_result_truncates_long_command(
    db: Session,
    monkeypatch,
) -> None:
    _patch_script_session(monkeypatch, record_command_result, db)
    long_command = "python " + ("x" * 700)

    record_command_result.record_command_result(command=long_command, source="terminal")

    event = db.query(DevEvent).one()
    assert len(event.command) <= record_command_result.MAX_COMMAND_CHARS
    assert event.command.endswith("...")


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


def test_zsh_tracking_hook_file_contains_required_hooks() -> None:
    hook_path = Path("scripts/mwoham_zsh_tracking.zsh")
    content = hook_path.read_text(encoding="utf-8")

    assert "add-zsh-hook preexec _mwoham_command_tracking_preexec" in content
    assert "add-zsh-hook precmd _mwoham_command_tracking_precmd" in content
    assert "scripts/record_command_result.py" in content
    assert "--source \"terminal\"" in content
    assert "_mwoham_is_dev_validation_command" in content
    assert "uv\\ run\\ pytest*" in content


def test_install_command_tracking_hook_is_idempotent(tmp_path: Path) -> None:
    zshrc = tmp_path / ".zshrc"
    hook_path = tmp_path / "mwoham_zsh_tracking.zsh"
    hook_path.write_text("# hook\n", encoding="utf-8")

    first = install_command_tracking_hook.install_hook(
        zshrc_path=zshrc,
        hook_path=hook_path,
    )
    second = install_command_tracking_hook.install_hook(
        zshrc_path=zshrc,
        hook_path=hook_path,
    )

    content = zshrc.read_text(encoding="utf-8")
    assert first is True
    assert second is False
    assert content.count("source ") == 1
    assert str(hook_path) in content


def test_uninstall_command_tracking_hook_removes_source_line(tmp_path: Path) -> None:
    zshrc = tmp_path / ".zshrc"
    hook_path = tmp_path / "mwoham_zsh_tracking.zsh"
    install_command_tracking_hook.install_hook(zshrc_path=zshrc, hook_path=hook_path)

    removed = uninstall_command_tracking_hook.uninstall_hook(
        zshrc_path=zshrc,
        hook_path=hook_path,
    )

    assert removed is True
    assert "mwoham_zsh_tracking.zsh" not in zshrc.read_text(encoding="utf-8")


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


def test_run_dev_checks_no_record_does_not_save_events(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    _patch_script_session(monkeypatch, run_dev_checks, db)
    monkeypatch.setattr(run_dev_checks, "_run_command", _fake_command_runner([0, 0, 0, 0]))

    exit_code = run_dev_checks.run_dev_checks(repo_path=str(tmp_path), no_record=True)

    assert exit_code == 0
    assert db.query(DevEvent).count() == 0


def test_run_dev_checks_no_record_returns_one_on_failure(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    _patch_script_session(monkeypatch, run_dev_checks, db)
    monkeypatch.setattr(run_dev_checks, "_run_command", _fake_command_runner([0, 1, 0, 0]))

    exit_code = run_dev_checks.run_dev_checks(repo_path=str(tmp_path), no_record=True)

    assert exit_code == 1
    assert db.query(DevEvent).count() == 0


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
    assert len(event.details_json["output_excerpt"]) <= dev_check_output.OUTPUT_EXCERPT_LIMIT


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


def test_dev_context_tracker_saves_dirty_snapshot_once(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _dirty_git_repo(tmp_path)
    _patch_script_session(monkeypatch, dev_tracking, db)
    tracker = _dev_context_tracker(tmp_path)

    first = tracker.check_once(str(repo))
    second = tracker.check_once(str(repo))

    events = db.query(DevEvent).all()
    assert first.status == "saved"
    assert second.status == "unchanged"
    assert len(events) == 1
    assert events[0].event_type == "git_snapshot"
    assert events[0].summary.startswith("Git 변경 감지: 1 file changed on ")
    assert events[0].details_json["tracking_mode"] == "watch"
    assert events[0].details_json["changed_files"] == ["README.md"]
    assert "diff" not in events[0].details_json


def test_dev_context_tracker_uses_persistent_state_after_restart(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _dirty_git_repo(tmp_path)
    state_path = tmp_path / "dev_tracking_state.json"
    _patch_script_session(monkeypatch, dev_tracking, db)

    first = dev_tracking.DevContextTracker(state_path=state_path).check_once(str(repo))
    second = dev_tracking.DevContextTracker(state_path=state_path).check_once(str(repo))

    assert first.status == "saved"
    assert second.status == "unchanged"
    assert db.query(DevEvent).count() == 1
    state_text = state_path.read_text(encoding="utf-8")
    assert "README.md" not in state_text
    assert "hello" not in state_text


def test_dev_context_tracker_allows_same_signature_after_ttl(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _dirty_git_repo(tmp_path)
    state_path = tmp_path / "dev_tracking_state.json"
    now = _FakeClock(datetime(2026, 6, 1, 0, 0, tzinfo=UTC))
    _patch_script_session(monkeypatch, dev_tracking, db)

    first = dev_tracking.DevContextTracker(
        state_path=state_path,
        dedupe_ttl_seconds=21600,
        now=now,
    ).check_once(str(repo))
    now.advance(seconds=21601)
    second = dev_tracking.DevContextTracker(
        state_path=state_path,
        dedupe_ttl_seconds=21600,
        now=now,
    ).check_once(str(repo))

    events = db.query(DevEvent).all()
    state_entry = dev_tracking.DevTrackingStateStore(state_path).get_entry(
        dev_tracking.build_repo_state_key(repo)
    )
    assert first.status == "saved"
    assert second.status == "saved"
    assert len(events) == 2
    assert state_entry is not None
    assert state_entry.updated_at == now()


def test_dev_context_tracker_saves_when_signature_changes(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _dirty_git_repo(tmp_path)
    _patch_script_session(monkeypatch, dev_tracking, db)
    tracker = _dev_context_tracker(tmp_path)

    first = tracker.check_once(str(repo))
    (repo / "app.py").write_text("print('hello')\n", encoding="utf-8")
    second = tracker.check_once(str(repo))

    events = db.query(DevEvent).order_by(DevEvent.id).all()
    assert first.status == "saved"
    assert second.status == "saved"
    assert len(events) == 2
    assert events[1].details_json["changed_files"] == ["README.md", "app.py"]
    assert events[0].details_json["tracking_signature"] != events[1].details_json[
        "tracking_signature"
    ]


def test_dev_context_tracker_persistent_state_saves_changed_signature(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _dirty_git_repo(tmp_path)
    state_path = tmp_path / "dev_tracking_state.json"
    _patch_script_session(monkeypatch, dev_tracking, db)

    first = dev_tracking.DevContextTracker(state_path=state_path).check_once(str(repo))
    (repo / "app.py").write_text("print('hello')\n", encoding="utf-8")
    second = dev_tracking.DevContextTracker(state_path=state_path).check_once(str(repo))

    events = db.query(DevEvent).order_by(DevEvent.id).all()
    assert first.status == "saved"
    assert second.status == "saved"
    assert len(events) == 2
    assert events[1].details_json["changed_files"] == ["README.md", "app.py"]


def test_dev_context_tracker_debounces_until_signature_is_stable(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _dirty_git_repo(tmp_path)
    now = _FakeClock(datetime(2026, 6, 1, 0, 0, tzinfo=UTC))
    _patch_script_session(monkeypatch, dev_tracking, db)
    tracker = _dev_context_tracker(tmp_path, debounce_seconds=20, now=now)

    first = tracker.check_once(str(repo))
    now.advance(seconds=19)
    second = tracker.check_once(str(repo))
    now.advance(seconds=2)
    third = tracker.check_once(str(repo))

    assert first.status == "pending"
    assert second.status == "pending"
    assert third.status == "saved"
    assert db.query(DevEvent).count() == 1


def test_dev_context_tracker_resets_debounce_when_signature_changes(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _dirty_git_repo(tmp_path)
    now = _FakeClock(datetime(2026, 6, 1, 0, 0, tzinfo=UTC))
    _patch_script_session(monkeypatch, dev_tracking, db)
    tracker = _dev_context_tracker(tmp_path, debounce_seconds=20, now=now)

    first = tracker.check_once(str(repo))
    now.advance(seconds=10)
    (repo / "app.py").write_text("print('hello')\n", encoding="utf-8")
    second = tracker.check_once(str(repo))
    now.advance(seconds=10)
    third = tracker.check_once(str(repo))
    now.advance(seconds=11)
    fourth = tracker.check_once(str(repo))

    events = db.query(DevEvent).all()
    assert first.status == "pending"
    assert second.status == "pending"
    assert third.status == "pending"
    assert fourth.status == "saved"
    assert len(events) == 1
    assert events[0].details_json["changed_files"] == ["README.md", "app.py"]


def test_dev_context_tracker_does_not_save_clean_initial_snapshot(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _clean_git_repo(tmp_path)
    _patch_script_session(monkeypatch, dev_tracking, db)
    tracker = _dev_context_tracker(tmp_path)

    result = tracker.check_once(str(repo))

    assert result.status == "clean"
    assert db.query(DevEvent).count() == 0


def test_dev_context_tracker_persists_clean_baseline(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _clean_git_repo(tmp_path)
    state_path = tmp_path / "dev_tracking_state.json"
    _patch_script_session(monkeypatch, dev_tracking, db)

    first = dev_tracking.DevContextTracker(state_path=state_path).check_once(str(repo))
    second = dev_tracking.DevContextTracker(state_path=state_path).check_once(str(repo))

    assert first.status == "clean"
    assert second.status == "unchanged"
    assert db.query(DevEvent).count() == 0


def test_dev_tracking_state_path_uses_environment_override(
    monkeypatch,
    tmp_path: Path,
) -> None:
    state_path = tmp_path / "custom_state.json"
    monkeypatch.setenv("MWOHAM_DEV_TRACKING_STATE_PATH", str(state_path))

    assert dev_tracking.get_default_state_path() == state_path


def test_dev_tracking_state_path_uses_temp_directory(monkeypatch, tmp_path: Path) -> None:
    monkeypatch.delenv("MWOHAM_DEV_TRACKING_STATE_PATH", raising=False)
    monkeypatch.setattr(dev_tracking.tempfile, "gettempdir", lambda: str(tmp_path))

    assert dev_tracking.get_default_state_path() == (
        tmp_path / "mwoham-dev-tracking-state.json"
    )


def test_dev_context_tracker_ignores_vim_swap_only(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _clean_git_repo(tmp_path)
    (repo / ".README.md.swp").write_text("swap\n", encoding="utf-8")
    _patch_script_session(monkeypatch, dev_tracking, db)

    result = _dev_context_tracker(tmp_path).check_once(str(repo))

    assert result.status == "clean"
    assert db.query(DevEvent).count() == 0


def test_dev_context_tracker_saves_real_change_with_vim_swap(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _dirty_git_repo(tmp_path)
    (repo / ".README.md.swp").write_text("swap\n", encoding="utf-8")
    _patch_script_session(monkeypatch, dev_tracking, db)

    result = _dev_context_tracker(tmp_path).check_once(str(repo))

    event = db.query(DevEvent).one()
    assert result.status == "saved"
    assert event.details_json["changed_files"] == ["README.md"]
    assert event.details_json["git_status_short"] == [" M README.md"]
    assert event.details_json["diff_summary"] == [
        {
            "file": "README.md",
            "insertions": 1,
            "deletions": 0,
            "status": "unstaged",
        }
    ]


def test_dev_context_tracker_ignores_swap_signature_changes(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _dirty_git_repo(tmp_path)
    _patch_script_session(monkeypatch, dev_tracking, db)
    tracker = _dev_context_tracker(tmp_path)

    first = tracker.check_once(str(repo))
    (repo / ".README.md.swp").write_text("swap\n", encoding="utf-8")
    second = tracker.check_once(str(repo))
    (repo / ".README.md.swp").unlink()
    third = tracker.check_once(str(repo))

    assert first.status == "saved"
    assert second.status == "unchanged"
    assert third.status == "unchanged"
    assert db.query(DevEvent).count() == 1


def test_dev_tracking_diff_summary_marks_untracked_without_reading_contents(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _clean_git_repo(tmp_path)
    (repo / "new_secret.py").write_text("api_key='secret-value'\n", encoding="utf-8")
    _patch_script_session(monkeypatch, dev_tracking, db)

    result = _dev_context_tracker(tmp_path).check_once(str(repo))

    event = db.query(DevEvent).one()
    assert result.status == "saved"
    assert event.details_json["diff_summary"] == [
        {
            "file": "new_secret.py",
            "status": "untracked",
            "untracked": True,
        }
    ]
    assert "secret-value" not in str(event.details_json)


def test_dev_tracking_diff_summary_marks_binary_files(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _clean_git_repo(tmp_path)
    (repo / "asset.bin").write_bytes(b"\x00\x01\x02")
    _git(repo, "add", "asset.bin")
    _git(repo, "commit", "-m", "add binary")
    (repo / "asset.bin").write_bytes(b"\x00\x01\x02\x03")
    _patch_script_session(monkeypatch, dev_tracking, db)

    result = _dev_context_tracker(tmp_path).check_once(str(repo))

    event = db.query(DevEvent).one()
    assert result.status == "saved"
    assert event.details_json["diff_summary"] == [
        {
            "file": "asset.bin",
            "binary": True,
            "status": "unstaged",
        }
    ]


def test_dev_context_tracker_passes_session_current(monkeypatch, tmp_path: Path) -> None:
    repo = _dirty_git_repo(tmp_path)
    calls: list[bool] = []

    def fake_save_dev_event(request, *, session_current: bool = False):
        calls.append(session_current)
        return type("SavedEvent", (), {"id": 1, "summary": request.summary})()

    monkeypatch.setattr(dev_tracking, "save_dev_event", fake_save_dev_event)

    result = _dev_context_tracker(tmp_path).check_once(str(repo), session_current=True)

    assert result.status == "saved"
    assert calls == [True]


def test_watch_dev_context_once_runs_single_check(monkeypatch, tmp_path: Path) -> None:
    calls: list[bool] = []

    class FakeTracker:
        def check_once(self, repo_path: str, *, session_current: bool = False):
            calls.append(session_current)
            return dev_tracking.DevTrackingResult(
                status="saved",
                summary="Git 변경 감지: 1 file changed on main",
            )

    exit_code = watch_dev_context.watch_dev_context(
        repo_path=str(tmp_path),
        interval=1,
        session_current=True,
        once=True,
        tracker=FakeTracker(),
    )

    assert exit_code == 0
    assert calls == [True]


def test_watch_dev_context_once_uses_zero_debounce_by_default(
    db: Session,
    monkeypatch,
    tmp_path: Path,
) -> None:
    repo = _dirty_git_repo(tmp_path)
    _patch_script_session(monkeypatch, dev_tracking, db)

    exit_code = watch_dev_context.watch_dev_context(
        repo_path=str(repo),
        interval=60,
        once=True,
        state_path=str(tmp_path / "state.json"),
    )

    assert exit_code == 0
    assert db.query(DevEvent).count() == 1


def test_watch_dev_context_script_imports_without_pythonpath() -> None:
    result = _run_script_without_pythonpath("scripts/watch_dev_context.py", "--help")

    assert result.returncode == 0
    assert "Watch Git changes and record DevEvents." in result.stdout


def _patch_script_session(monkeypatch, _module, db: Session) -> None:
    testing_session_local = sessionmaker(bind=db.get_bind())
    monkeypatch.setattr(dev_event_helpers, "SessionLocal", testing_session_local)


def _dev_context_tracker(
    tmp_path: Path,
    *,
    debounce_seconds: int = 0,
    now: Callable[[], datetime] | None = None,
) -> dev_tracking.DevContextTracker:
    return dev_tracking.DevContextTracker(
        state_path=tmp_path / "dev-tracking-state.json",
        debounce_seconds=debounce_seconds,
        now=now,
    )


def _clean_git_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init")
    _git(repo, "config", "user.email", "test@example.com")
    _git(repo, "config", "user.name", "Test User")
    (repo / "README.md").write_text("hello\n", encoding="utf-8")
    _git(repo, "add", "README.md")
    _git(repo, "commit", "-m", "initial commit")
    return repo


def _dirty_git_repo(tmp_path: Path) -> Path:
    repo = _clean_git_repo(tmp_path)
    (repo / "README.md").write_text("hello\nupdated\n", encoding="utf-8")
    return repo


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


class _FakeClock:
    def __init__(self, current: datetime) -> None:
        self.current = current

    def __call__(self) -> datetime:
        return self.current

    def advance(self, *, seconds: int) -> None:
        self.current += timedelta(seconds=seconds)


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

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from sqlalchemy.orm import Session, sessionmaker

from app.models.dev_event import DevEvent
from scripts import collect_git_snapshot, record_command_result


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

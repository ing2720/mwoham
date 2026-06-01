from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

from app.core.timezone import now_utc
from app.db.session import SessionLocal
from app.schemas.dev_event import DevEventCreate
from app.services.dev_event_service import get_dev_event_service


def collect_git_snapshot(repo_path: str, *, session_current: bool = False) -> int:
    repo = Path(repo_path).expanduser().resolve()
    if not _is_git_repo(repo):
        print(f"Git 저장소가 아닙니다: {repo}")
        return 1

    branch = _run_git(repo, "branch", "--show-current").strip() or "detached"
    status_short = _run_git(repo, "status", "--short").splitlines()
    changed_files = _changed_files(status_short)
    diff_stat = _run_git(repo, "diff", "--stat").strip()
    recent_commits = _run_git(repo, "log", "-5", "--oneline").splitlines()

    summary = _build_summary(changed_files, branch=branch)
    request = DevEventCreate(
        event_type="git_snapshot",
        source="script",
        repo_path=_compact_path(repo),
        branch=branch,
        status="unknown",
        summary=summary,
        details_json={
            "changed_files": changed_files,
            "git_status_short": status_short[:80],
            "diff_stat": diff_stat,
            "recent_commits": recent_commits[:5],
        },
        occurred_at=now_utc(),
    )

    with SessionLocal() as db:
        service = get_dev_event_service()
        event = (
            service.create_for_current_session(db, request)
            if session_current
            else service.create(db, request)
        )
    print(f"DevEvent 저장됨: id={event.id} summary={event.summary}")
    return 0


def _is_git_repo(repo: Path) -> bool:
    result = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--is-inside-work-tree"],
        check=False,
        capture_output=True,
        text=True,
    )
    return result.returncode == 0 and result.stdout.strip() == "true"


def _run_git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return ""
    return result.stdout


def _changed_files(status_short: list[str]) -> list[str]:
    files: list[str] = []
    for line in status_short:
        if not line.strip():
            continue
        file_path = line[3:].strip()
        if " -> " in file_path:
            file_path = file_path.split(" -> ", 1)[1].strip()
        files.append(file_path)
    return files


def _build_summary(changed_files: list[str], *, branch: str) -> str:
    if not changed_files:
        return f"Git 변경 없음: {branch}"
    file_text = ", ".join(changed_files[:5])
    extra_count = len(changed_files) - 5
    suffix = f" 외 {extra_count}개" if extra_count > 0 else ""
    return f"Git 변경 파일 확인: {file_text}{suffix}"


def _compact_path(path: Path) -> str:
    home = Path.home()
    try:
        return "~/" + str(path.relative_to(home))
    except ValueError:
        return str(path)


def main() -> int:
    parser = argparse.ArgumentParser(description="Collect a structured Git snapshot as DevEvent.")
    parser.add_argument("--repo-path", required=True)
    parser.add_argument("--session-current", action="store_true")
    args = parser.parse_args()
    return collect_git_snapshot(args.repo_path, session_current=args.session_current)


if __name__ == "__main__":
    raise SystemExit(main())

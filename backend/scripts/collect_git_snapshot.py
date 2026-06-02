from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

try:
    from scripts._bootstrap import add_backend_root_to_path
except ModuleNotFoundError:
    from _bootstrap import add_backend_root_to_path

add_backend_root_to_path()

try:
    from scripts.dev_event_helpers import (
        build_dev_event_request,
        compact_path,
        print_saved_event,
        save_dev_event,
    )
except ModuleNotFoundError:
    from dev_event_helpers import (
        build_dev_event_request,
        compact_path,
        print_saved_event,
        save_dev_event,
    )


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
    request = build_dev_event_request(
        event_type="git_snapshot",
        source="script",
        repo_path=compact_path(repo),
        branch=branch,
        status="unknown",
        summary=summary,
        details_json={
            "changed_files": changed_files,
            "git_status_short": status_short[:80],
            "diff_stat": diff_stat,
            "recent_commits": recent_commits[:5],
        },
    )

    print_saved_event(save_dev_event(request, session_current=session_current))
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


def main() -> int:
    parser = argparse.ArgumentParser(description="Collect a structured Git snapshot as DevEvent.")
    parser.add_argument("--repo-path", required=True)
    parser.add_argument("--session-current", action="store_true")
    args = parser.parse_args()
    return collect_git_snapshot(args.repo_path, session_current=args.session_current)


if __name__ == "__main__":
    raise SystemExit(main())

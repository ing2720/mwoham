from __future__ import annotations

import argparse

try:
    from scripts._bootstrap import add_backend_root_to_path
except ModuleNotFoundError:
    from _bootstrap import add_backend_root_to_path

add_backend_root_to_path()

try:
    from scripts.collect_git_snapshot import collect_git_snapshot
    from scripts.dev_event_helpers import resolve_project_root
    from scripts.run_dev_checks import run_dev_checks
except ModuleNotFoundError:
    from collect_git_snapshot import collect_git_snapshot
    from dev_event_helpers import resolve_project_root
    from run_dev_checks import run_dev_checks


def collect_dev_context(
    *,
    repo_path: str | None = None,
    session_current: bool = False,
) -> int:
    project_root = resolve_project_root(repo_path)

    print("Git snapshot 수집 시작")
    git_exit_code = collect_git_snapshot(str(project_root), session_current=session_current)

    print("개발 검증 명령 실행 시작")
    checks_exit_code = run_dev_checks(
        repo_path=str(project_root),
        session_current=session_current,
    )

    if git_exit_code == 0 and checks_exit_code == 0:
        print("작업 마감 DevEvent 수집 완료: 전체 성공")
        return 0

    failed_parts = []
    if git_exit_code != 0:
        failed_parts.append("Git snapshot")
    if checks_exit_code != 0:
        failed_parts.append("개발 검증")
    print(f"작업 마감 DevEvent 수집 완료: 실패 항목 {', '.join(failed_parts)}")
    return 1


def main() -> int:
    parser = argparse.ArgumentParser(description="Collect Git and development check context.")
    parser.add_argument("--repo-path")
    parser.add_argument("--session-current", action="store_true")
    args = parser.parse_args()
    return collect_dev_context(repo_path=args.repo_path, session_current=args.session_current)


if __name__ == "__main__":
    raise SystemExit(main())

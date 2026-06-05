from __future__ import annotations

import argparse
import time

try:
    from scripts._bootstrap import add_backend_root_to_path
except ModuleNotFoundError:
    from _bootstrap import add_backend_root_to_path

add_backend_root_to_path()

try:
    from scripts.dev_event_helpers import resolve_project_root
    from scripts.dev_tracking import DevContextTracker
except ModuleNotFoundError:
    from dev_event_helpers import resolve_project_root
    from dev_tracking import DevContextTracker


def watch_dev_context(
    *,
    repo_path: str | None = None,
    interval: int = 60,
    session_current: bool = False,
    once: bool = False,
    tracker: DevContextTracker | None = None,
) -> int:
    project_root = resolve_project_root(repo_path)
    tracker = tracker or DevContextTracker()
    print(f"Dev tracking 감시 시작: repo={project_root} interval={interval}s")

    try:
        while True:
            result = tracker.check_once(str(project_root), session_current=session_current)
            print(_format_result(result.status, summary=result.summary))
            if once:
                print("Dev tracking 1회 확인 완료")
                return 0 if result.status != "not_git_repo" else 1
            time.sleep(interval)
    except KeyboardInterrupt:
        print("Dev tracking 감시 종료")
        return 0


def _format_result(status: str, *, summary: str | None = None) -> str:
    if status == "saved":
        return f"변경 감지, DevEvent 저장됨: {summary}"
    if status == "unchanged":
        return "변경 없음"
    if status == "clean":
        return "변경 없음: clean baseline 설정"
    if status == "not_git_repo":
        return "Git 저장소가 아닙니다"
    return f"상태 확인: {status}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Watch Git changes and record DevEvents.")
    parser.add_argument("--repo-path")
    parser.add_argument("--interval", type=int, default=60)
    parser.add_argument("--session-current", action="store_true")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    return watch_dev_context(
        repo_path=args.repo_path,
        interval=args.interval,
        session_current=args.session_current,
        once=args.once,
    )


if __name__ == "__main__":
    raise SystemExit(main())

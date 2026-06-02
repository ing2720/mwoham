from __future__ import annotations

import argparse

try:
    from scripts._bootstrap import add_backend_root_to_path
except ModuleNotFoundError:
    from _bootstrap import add_backend_root_to_path

add_backend_root_to_path()

from app.core.timezone import now_utc  # noqa: E402
from app.db.session import SessionLocal  # noqa: E402
from app.schemas.dev_event import DevEventCreate  # noqa: E402
from app.services.dev_event_service import get_dev_event_service  # noqa: E402


def record_command_result(
    *,
    command: str,
    status: str,
    summary: str,
    event_type: str = "command_result",
    exit_code: int | None = None,
    duration_seconds: float | None = None,
    repo_path: str | None = None,
    session_current: bool = False,
) -> int:
    request = DevEventCreate(
        event_type=event_type,
        source="script",
        repo_path=repo_path,
        command=command,
        status=status,
        summary=summary,
        details_json={
            key: value
            for key, value in {
                "exit_code": exit_code,
                "duration_seconds": duration_seconds,
            }.items()
            if value is not None
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


def main() -> int:
    parser = argparse.ArgumentParser(description="Record a command result as DevEvent.")
    parser.add_argument("--command", required=True)
    parser.add_argument("--status", choices=["success", "failed", "unknown"], required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument(
        "--event-type",
        choices=["command_result", "test_result", "build_result", "note"],
        default="command_result",
    )
    parser.add_argument("--exit-code", type=int)
    parser.add_argument("--duration-seconds", type=float)
    parser.add_argument("--repo-path")
    parser.add_argument("--session-current", action="store_true")
    args = parser.parse_args()
    return record_command_result(
        command=args.command,
        status=args.status,
        summary=args.summary,
        event_type=args.event_type,
        exit_code=args.exit_code,
        duration_seconds=args.duration_seconds,
        repo_path=args.repo_path,
        session_current=args.session_current,
    )


if __name__ == "__main__":
    raise SystemExit(main())

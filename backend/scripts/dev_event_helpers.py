from __future__ import annotations

from pathlib import Path

from app.core.timezone import now_utc
from app.db.session import SessionLocal
from app.schemas.dev_event import DevEventCreate, DevEventRead
from app.services.dev_event_service import get_dev_event_service


def resolve_backend_root() -> Path:
    return Path(__file__).resolve().parents[1]


def resolve_project_root(repo_path: str | None = None) -> Path:
    backend_root = resolve_backend_root()
    return Path(repo_path).expanduser().resolve() if repo_path else backend_root.parent


def compact_path(path: Path) -> str:
    home = Path.home()
    try:
        return "~/" + str(path.resolve().relative_to(home))
    except ValueError:
        return str(path.resolve())


def build_dev_event_request(
    *,
    event_type: str,
    source: str = "script",
    session_id: int | None = None,
    repo_path: str | None = None,
    branch: str | None = None,
    command: str | None = None,
    status: str | None = None,
    summary: str,
    details_json: dict | None = None,
) -> DevEventCreate:
    return DevEventCreate(
        session_id=session_id,
        event_type=event_type,
        source=source,
        repo_path=repo_path,
        branch=branch,
        command=command,
        status=status,
        summary=summary,
        details_json=details_json,
        occurred_at=now_utc(),
    )


def save_dev_event(request: DevEventCreate, *, session_current: bool = False) -> DevEventRead:
    with SessionLocal() as db:
        service = get_dev_event_service()
        return (
            service.create_for_current_session(db, request)
            if session_current
            else service.create(db, request)
        )


def print_saved_event(event: DevEventRead) -> None:
    print(f"DevEvent 저장됨: id={event.id} summary={event.summary}")

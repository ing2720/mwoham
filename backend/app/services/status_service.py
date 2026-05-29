from datetime import UTC, datetime

from sqlalchemy.orm import Session

from app.models.work_session import WorkSession
from app.repositories.work_event_repository import WorkEventRepository
from app.repositories.work_session_repository import WorkSessionRepository
from app.schemas.status import StatusResponse


class StatusService:
    def __init__(
        self,
        session_repository: WorkSessionRepository,
        event_repository: WorkEventRepository,
    ) -> None:
        self.session_repository = session_repository
        self.event_repository = event_repository

    def get_status(self, db: Session) -> StatusResponse:
        session = self.session_repository.get_current(db)
        latest_event = self.event_repository.get_latest(db)

        return StatusResponse(
            status=session.status if session is not None else "stopped",
            current_app=latest_event.app_name if latest_event is not None else None,
            current_window=latest_event.window_title if latest_event is not None else None,
            meeting_mode=False,
            last_event_at=latest_event.timestamp if latest_event is not None else None,
            report_status="idle",
            session_id=session.id if session is not None else None,
            session_started_at=session.started_at if session is not None else None,
            elapsed_seconds=self._elapsed_seconds(session),
        )

    def _elapsed_seconds(self, session: WorkSession | None) -> int | None:
        if session is None:
            return None

        started_at = session.started_at
        if started_at.tzinfo is None:
            started_at = started_at.replace(tzinfo=UTC)

        return max(0, int((datetime.now(UTC) - started_at.astimezone(UTC)).total_seconds()))


def get_status_service() -> StatusService:
    return StatusService(
        session_repository=WorkSessionRepository(),
        event_repository=WorkEventRepository(),
    )

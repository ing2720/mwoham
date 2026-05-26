from sqlalchemy.orm import Session

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
        )


def get_status_service() -> StatusService:
    return StatusService(
        session_repository=WorkSessionRepository(),
        event_repository=WorkEventRepository(),
    )

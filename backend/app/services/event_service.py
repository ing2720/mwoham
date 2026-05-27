from datetime import date

from sqlalchemy.orm import Session

from app.core.exceptions import ResourceNotFoundError
from app.models.work_session import WorkSession
from app.repositories.work_event_repository import WorkEventRepository
from app.repositories.work_session_repository import WorkSessionRepository
from app.schemas.work_event import WorkEventCreate, WorkEventCreateResponse, WorkEventListResponse
from app.services.setting_service import SettingService, get_setting_service


class EventService:
    def __init__(
        self,
        event_repository: WorkEventRepository,
        session_repository: WorkSessionRepository,
        setting_service: SettingService,
    ) -> None:
        self.event_repository = event_repository
        self.session_repository = session_repository
        self.setting_service = setting_service

    def create(self, db: Session, request: WorkEventCreate) -> WorkEventCreateResponse:
        session = self._resolve_session(db, request.session_id)
        if self.setting_service.is_private_app(db, request.app_name):
            request = WorkEventCreate(
                session_id=request.session_id,
                timestamp=request.timestamp,
                source=request.source,
                app_name=request.app_name,
                window_title=None,
                content="비공개 앱 사용 중",
                project_name=request.project_name,
                metadata_json=None,
                confidence=request.confidence,
            )
        event = self.event_repository.create(db, event_in=request, session_id=session.id)
        return WorkEventCreateResponse(id=event.id)

    def list(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
        source: str | None = None,
        limit: int = 100,
    ) -> WorkEventListResponse:
        items = self.event_repository.list(
            db,
            session_id=session_id,
            target_date=target_date,
            source=source,
            limit=limit,
        )
        total = self.event_repository.count(
            db,
            session_id=session_id,
            target_date=target_date,
            source=source,
        )
        return WorkEventListResponse(items=items, total=total)

    def _resolve_session(self, db: Session, session_id: int | None) -> WorkSession:
        if session_id is not None:
            session = self.session_repository.get_by_id(db, session_id)
        else:
            session = self.session_repository.get_current_by_status(db, "active")

        if session is None:
            raise ResourceNotFoundError("Active recording session not found.")
        return session


def get_event_service() -> EventService:
    return EventService(
        event_repository=WorkEventRepository(),
        session_repository=WorkSessionRepository(),
        setting_service=get_setting_service(),
    )

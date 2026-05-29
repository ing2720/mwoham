from datetime import date

from sqlalchemy.orm import Session

from app.core.exceptions import ResourceNotFoundError
from app.models.work_session import WorkSession
from app.repositories.activity_segment_repository import ActivitySegmentRepository
from app.repositories.work_session_repository import WorkSessionRepository
from app.schemas.activity_segment import (
    ActivitySegmentCreate,
    ActivitySegmentListResponse,
    ActivitySegmentResponse,
    ActivitySegmentUpdate,
)
from app.services.setting_service import SettingService, get_setting_service


class ActivitySegmentService:
    def __init__(
        self,
        segment_repository: ActivitySegmentRepository,
        session_repository: WorkSessionRepository,
        setting_service: SettingService,
    ) -> None:
        self.segment_repository = segment_repository
        self.session_repository = session_repository
        self.setting_service = setting_service

    def create(self, db: Session, request: ActivitySegmentCreate) -> ActivitySegmentResponse:
        session = self._resolve_session(db, request.session_id)
        if self.setting_service.is_private_app(db, request.app_name):
            request = ActivitySegmentCreate(
                session_id=request.session_id,
                app_name=request.app_name,
                window_title=None,
                source=request.source,
                started_at=request.started_at,
                last_seen_at=request.last_seen_at,
            )
        segment = self.segment_repository.create(db, segment_in=request, session_id=session.id)
        return ActivitySegmentResponse.model_validate(segment)

    def update(
        self,
        db: Session,
        segment_id: int,
        request: ActivitySegmentUpdate,
    ) -> ActivitySegmentResponse:
        segment = self.segment_repository.get_by_id(db, segment_id)
        if segment is None:
            raise ResourceNotFoundError("Activity segment not found.")

        session = self.session_repository.get_by_id(db, segment.session_id)
        if session is None or session.status != "active":
            raise ResourceNotFoundError("Active recording session not found.")

        segment = self.segment_repository.update_seen_at(
            db,
            segment=segment,
            last_seen_at=request.last_seen_at,
        )
        return ActivitySegmentResponse.model_validate(segment)

    def list(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
        source: str | None = None,
        limit: int = 100,
    ) -> ActivitySegmentListResponse:
        items = self.segment_repository.list(
            db,
            session_id=session_id,
            target_date=target_date,
            source=source,
            limit=limit,
        )
        total = self.segment_repository.count(
            db,
            session_id=session_id,
            target_date=target_date,
            source=source,
        )
        return ActivitySegmentListResponse(items=items, total=total)

    def _resolve_session(self, db: Session, session_id: int | None) -> WorkSession:
        if session_id is not None:
            session = self.session_repository.get_by_id(db, session_id)
        else:
            session = self.session_repository.get_current_by_status(db, "active")

        if session is None:
            raise ResourceNotFoundError("Active recording session not found.")
        return session


def get_activity_segment_service() -> ActivitySegmentService:
    return ActivitySegmentService(
        segment_repository=ActivitySegmentRepository(),
        session_repository=WorkSessionRepository(),
        setting_service=get_setting_service(),
    )

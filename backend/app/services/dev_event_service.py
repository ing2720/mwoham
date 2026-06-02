from datetime import date
from typing import Any

from sqlalchemy.orm import Session

from app.core.timezone import now_utc, parse_date_or_today_kst
from app.repositories.dev_event_repository import DevEventRepository
from app.repositories.work_session_repository import WorkSessionRepository
from app.schemas.dev_event import DevEventCreate, DevEventListResponse, DevEventRead
from app.services.privacy_filter import PrivacyFilter, get_privacy_filter


class DevEventService:
    def __init__(
        self,
        repository: DevEventRepository,
        session_repository: WorkSessionRepository,
        privacy_filter: PrivacyFilter,
    ) -> None:
        self.repository = repository
        self.session_repository = session_repository
        self.privacy_filter = privacy_filter

    def create(self, db: Session, request: DevEventCreate) -> DevEventRead:
        sanitized = self._sanitize_request(request)
        event = self.repository.create(db, event_in=sanitized)
        return DevEventRead.model_validate(event)

    def create_for_current_session(self, db: Session, request: DevEventCreate) -> DevEventRead:
        session = self.session_repository.get_current(db)
        session_id = session.id if session is not None else None
        return self.create(db, request.model_copy(update={"session_id": session_id}))

    def list(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
        event_type: str | None = None,
        limit: int = 100,
    ) -> DevEventListResponse:
        items = self.repository.list(
            db,
            session_id=session_id,
            target_date=target_date,
            event_type=event_type,
            limit=limit,
        )
        total = self.repository.count(
            db,
            session_id=session_id,
            target_date=target_date,
            event_type=event_type,
        )
        return DevEventListResponse(items=items, total=total)

    def list_today(
        self,
        db: Session,
        *,
        event_type: str | None = None,
        limit: int = 100,
    ) -> DevEventListResponse:
        return self.list(
            db,
            target_date=parse_date_or_today_kst(),
            event_type=event_type,
            limit=limit,
        )

    def _sanitize_request(self, request: DevEventCreate) -> DevEventCreate:
        return DevEventCreate(
            session_id=request.session_id,
            event_type=request.event_type,
            source=request.source,
            repo_path=self._mask_optional(request.repo_path),
            branch=self._mask_optional(request.branch),
            command=self._mask_optional(request.command),
            status=request.status,
            summary=self.privacy_filter.mask(request.summary),
            details_json=self._sanitize_details(request.details_json),
            occurred_at=request.occurred_at or now_utc(),
        )

    def _sanitize_details(self, value: Any) -> Any:
        if isinstance(value, dict):
            return {key: self._sanitize_details(item) for key, item in value.items()}
        if isinstance(value, list):
            return [self._sanitize_details(item) for item in value]
        if isinstance(value, str):
            return self.privacy_filter.mask(value)
        return value

    def _mask_optional(self, value: str | None) -> str | None:
        return self.privacy_filter.mask(value) if value else value


def get_dev_event_service() -> DevEventService:
    return DevEventService(
        repository=DevEventRepository(),
        session_repository=WorkSessionRepository(),
        privacy_filter=get_privacy_filter(),
    )

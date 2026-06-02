from datetime import date

from sqlalchemy import Select, func, select
from sqlalchemy.orm import Session

from app.core.timezone import get_kst_day_range_as_utc
from app.models.dev_event import DevEvent
from app.schemas.dev_event import DevEventCreate


class DevEventRepository:
    def create(self, db: Session, *, event_in: DevEventCreate) -> DevEvent:
        event = DevEvent(
            session_id=event_in.session_id,
            event_type=event_in.event_type,
            source=event_in.source,
            repo_path=event_in.repo_path,
            branch=event_in.branch,
            command=event_in.command,
            status=event_in.status,
            summary=event_in.summary,
            details_json=event_in.details_json,
            occurred_at=event_in.occurred_at,
        )
        db.add(event)
        db.commit()
        db.refresh(event)
        return event

    def list(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
        event_type: str | None = None,
        limit: int = 100,
    ) -> list[DevEvent]:
        statement = self._filtered_select(
            session_id=session_id,
            target_date=target_date,
            event_type=event_type,
        )
        statement = statement.order_by(DevEvent.occurred_at.desc(), DevEvent.id.desc()).limit(limit)
        return list(db.scalars(statement))

    def count(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
        event_type: str | None = None,
    ) -> int:
        filtered = self._filtered_select(
            session_id=session_id,
            target_date=target_date,
            event_type=event_type,
        ).subquery()
        return db.scalar(select(func.count()).select_from(filtered)) or 0

    def _filtered_select(
        self,
        *,
        session_id: int | None,
        target_date: date | None,
        event_type: str | None,
    ) -> Select[tuple[DevEvent]]:
        statement = select(DevEvent)
        if session_id is not None:
            statement = statement.where(DevEvent.session_id == session_id)
        if target_date is not None:
            start, end = get_kst_day_range_as_utc(target_date)
            statement = statement.where(DevEvent.occurred_at >= start, DevEvent.occurred_at < end)
        if event_type is not None:
            statement = statement.where(DevEvent.event_type == event_type)
        return statement

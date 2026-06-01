from datetime import date

from sqlalchemy import Select, func, select
from sqlalchemy.orm import Session

from app.core.timezone import utc_range_for_kst_date
from app.models.work_event import WorkEvent
from app.schemas.work_event import WorkEventCreate


class WorkEventRepository:
    def create(self, db: Session, *, event_in: WorkEventCreate, session_id: int) -> WorkEvent:
        event = WorkEvent(
            session_id=session_id,
            timestamp=event_in.timestamp,
            source=event_in.source,
            app_name=event_in.app_name,
            window_title=event_in.window_title,
            content=event_in.content,
            project_name=event_in.project_name,
            metadata_json=event_in.metadata_json,
            confidence=event_in.confidence,
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
        source: str | None = None,
        limit: int = 100,
    ) -> list[WorkEvent]:
        statement = self._filtered_select(
            session_id=session_id,
            target_date=target_date,
            source=source,
        )
        statement = statement.order_by(
            WorkEvent.timestamp.desc(),
            WorkEvent.id.desc(),
        ).limit(limit)
        return list(db.scalars(statement))

    def count(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
        source: str | None = None,
    ) -> int:
        filtered = self._filtered_select(
            session_id=session_id,
            target_date=target_date,
            source=source,
        ).subquery()
        return db.scalar(select(func.count()).select_from(filtered)) or 0

    def get_latest(self, db: Session) -> WorkEvent | None:
        return db.scalar(
            select(WorkEvent)
            .order_by(
                WorkEvent.timestamp.desc(),
                WorkEvent.id.desc(),
            )
            .limit(1)
        )

    def _filtered_select(
        self,
        *,
        session_id: int | None,
        target_date: date | None,
        source: str | None,
    ) -> Select[tuple[WorkEvent]]:
        statement = select(WorkEvent)
        if session_id is not None:
            statement = statement.where(WorkEvent.session_id == session_id)
        if target_date is not None:
            start, end = utc_range_for_kst_date(target_date)
            statement = statement.where(WorkEvent.timestamp >= start, WorkEvent.timestamp <= end)
        if source is not None:
            statement = statement.where(WorkEvent.source == source)
        return statement

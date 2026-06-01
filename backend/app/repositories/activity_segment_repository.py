from datetime import UTC, date, datetime

from sqlalchemy import Select, func, select
from sqlalchemy.orm import Session

from app.core.timezone import utc_range_for_kst_date
from app.models.activity_segment import ActivitySegment
from app.schemas.activity_segment import ActivitySegmentCreate


class ActivitySegmentRepository:
    def create(
        self,
        db: Session,
        *,
        segment_in: ActivitySegmentCreate,
        session_id: int,
    ) -> ActivitySegment:
        segment = ActivitySegment(
            session_id=session_id,
            app_name=segment_in.app_name,
            window_title=segment_in.window_title,
            source=segment_in.source,
            started_at=segment_in.started_at,
            ended_at=segment_in.last_seen_at,
            last_seen_at=segment_in.last_seen_at,
            duration_seconds=self._duration_seconds(segment_in.started_at, segment_in.last_seen_at),
            sample_count=1,
        )
        db.add(segment)
        db.commit()
        db.refresh(segment)
        return segment

    def get_by_id(self, db: Session, segment_id: int) -> ActivitySegment | None:
        return db.get(ActivitySegment, segment_id)

    def update_seen_at(
        self,
        db: Session,
        *,
        segment: ActivitySegment,
        last_seen_at: datetime,
    ) -> ActivitySegment:
        segment.last_seen_at = last_seen_at
        segment.ended_at = last_seen_at
        segment.duration_seconds = self._duration_seconds(segment.started_at, last_seen_at)
        segment.sample_count += 1
        db.add(segment)
        db.commit()
        db.refresh(segment)
        return segment

    def list(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
        source: str | None = None,
        limit: int = 100,
    ) -> list[ActivitySegment]:
        statement = self._filtered_select(
            session_id=session_id,
            target_date=target_date,
            source=source,
        )
        statement = statement.order_by(
            ActivitySegment.started_at.desc(),
            ActivitySegment.id.desc(),
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

    def get_latest(self, db: Session) -> ActivitySegment | None:
        return db.scalar(
            select(ActivitySegment)
            .order_by(
                ActivitySegment.last_seen_at.desc(),
                ActivitySegment.id.desc(),
            )
            .limit(1)
        )

    def _filtered_select(
        self,
        *,
        session_id: int | None,
        target_date: date | None,
        source: str | None,
    ) -> Select[tuple[ActivitySegment]]:
        statement = select(ActivitySegment)
        if session_id is not None:
            statement = statement.where(ActivitySegment.session_id == session_id)
        if target_date is not None:
            start, end = utc_range_for_kst_date(target_date)
            statement = statement.where(
                ActivitySegment.started_at <= end,
                ActivitySegment.ended_at >= start,
            )
        if source is not None:
            statement = statement.where(ActivitySegment.source == source)
        return statement

    def _duration_seconds(self, started_at: datetime, ended_at: datetime) -> int:
        if started_at.tzinfo is None:
            started_at = started_at.replace(tzinfo=UTC)
        if ended_at.tzinfo is None:
            ended_at = ended_at.replace(tzinfo=UTC)
        return max(0, int((ended_at.astimezone(UTC) - started_at.astimezone(UTC)).total_seconds()))

from datetime import UTC, date, datetime, time

from sqlalchemy import Select, func, select
from sqlalchemy.orm import Session

from app.models.screen_observation import ScreenObservation
from app.schemas.screen_observation import ScreenObservationCreate


class ScreenObservationRepository:
    def create(
        self,
        db: Session,
        *,
        observation_in: ScreenObservationCreate,
        session_id: int,
    ) -> ScreenObservation:
        observation = ScreenObservation(
            session_id=session_id,
            timestamp=observation_in.timestamp,
            app_name=observation_in.app_name,
            window_title=observation_in.window_title,
            ocr_text=observation_in.ocr_text,
            detected_keywords=observation_in.detected_keywords,
            ai_inference=observation_in.ai_inference,
            frame_hash=observation_in.frame_hash,
        )
        db.add(observation)
        db.commit()
        db.refresh(observation)
        return observation

    def get_recent_by_frame_hash(
        self,
        db: Session,
        *,
        session_id: int,
        frame_hash: str,
    ) -> ScreenObservation | None:
        return db.scalar(
            select(ScreenObservation)
            .where(
                ScreenObservation.session_id == session_id,
                ScreenObservation.frame_hash == frame_hash,
            )
            .order_by(ScreenObservation.timestamp.desc(), ScreenObservation.id.desc())
            .limit(1)
        )

    def list(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
        limit: int = 100,
    ) -> list[ScreenObservation]:
        statement = self._filtered_select(session_id=session_id, target_date=target_date)
        statement = statement.order_by(
            ScreenObservation.timestamp.desc(),
            ScreenObservation.id.desc(),
        ).limit(limit)
        return list(db.scalars(statement))

    def count(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
    ) -> int:
        filtered = self._filtered_select(session_id=session_id, target_date=target_date).subquery()
        return db.scalar(select(func.count()).select_from(filtered)) or 0

    def _filtered_select(
        self,
        *,
        session_id: int | None,
        target_date: date | None,
    ) -> Select[tuple[ScreenObservation]]:
        statement = select(ScreenObservation)
        if session_id is not None:
            statement = statement.where(ScreenObservation.session_id == session_id)
        if target_date is not None:
            start = datetime.combine(target_date, time.min, tzinfo=UTC)
            end = datetime.combine(target_date, time.max, tzinfo=UTC)
            statement = statement.where(
                ScreenObservation.timestamp >= start,
                ScreenObservation.timestamp <= end,
            )
        return statement

from datetime import UTC, date, datetime, time

from sqlalchemy import Select, func, select
from sqlalchemy.orm import Session

from app.models.manual_memo import ManualMemo
from app.schemas.memo import MemoCreate


class MemoRepository:
    def create(self, db: Session, *, memo_in: MemoCreate, session_id: int | None) -> ManualMemo:
        memo = ManualMemo(
            session_id=session_id,
            timestamp=memo_in.timestamp or datetime.now(UTC),
            content=memo_in.content,
            linked_type=memo_in.linked_type,
            linked_id=memo_in.linked_id,
        )
        db.add(memo)
        db.commit()
        db.refresh(memo)
        return memo

    def list(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
        limit: int = 100,
    ) -> list[ManualMemo]:
        statement = self._filtered_select(session_id=session_id, target_date=target_date)
        statement = statement.order_by(
            ManualMemo.timestamp.desc(),
            ManualMemo.id.desc(),
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
    ) -> Select[tuple[ManualMemo]]:
        statement = select(ManualMemo)
        if session_id is not None:
            statement = statement.where(ManualMemo.session_id == session_id)
        if target_date is not None:
            start = datetime.combine(target_date, time.min, tzinfo=UTC)
            end = datetime.combine(target_date, time.max, tzinfo=UTC)
            statement = statement.where(ManualMemo.timestamp >= start, ManualMemo.timestamp <= end)
        return statement

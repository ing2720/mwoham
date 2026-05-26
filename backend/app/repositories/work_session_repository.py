from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.work_session import WorkSession


class WorkSessionRepository:
    def create(
        self,
        db: Session,
        *,
        project_id: int | None,
        title: str | None,
        started_at: datetime,
    ) -> WorkSession:
        session = WorkSession(
            project_id=project_id,
            title=title,
            started_at=started_at,
            status="active",
        )
        db.add(session)
        db.commit()
        db.refresh(session)
        return session

    def get_by_id(self, db: Session, session_id: int) -> WorkSession | None:
        return db.get(WorkSession, session_id)

    def get_current(self, db: Session) -> WorkSession | None:
        return db.scalar(
            select(WorkSession)
            .where(WorkSession.status.in_(("active", "paused")))
            .order_by(WorkSession.started_at.desc(), WorkSession.id.desc())
            .limit(1)
        )

    def get_current_by_status(self, db: Session, status: str) -> WorkSession | None:
        return db.scalar(
            select(WorkSession)
            .where(WorkSession.status == status)
            .order_by(WorkSession.started_at.desc(), WorkSession.id.desc())
            .limit(1)
        )

    def update_status(
        self,
        db: Session,
        session: WorkSession,
        *,
        status: str,
        ended_at: datetime | None = None,
    ) -> WorkSession:
        session.status = status
        if ended_at is not None:
            session.ended_at = ended_at
        db.add(session)
        db.commit()
        db.refresh(session)
        return session

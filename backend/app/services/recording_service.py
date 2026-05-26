from datetime import UTC, datetime

from sqlalchemy.orm import Session

from app.core.exceptions import InvalidStateTransitionError, ResourceNotFoundError
from app.models.work_session import WorkSession
from app.repositories.work_session_repository import WorkSessionRepository
from app.schemas.recording import (
    RecordingResponse,
    RecordingSessionRequest,
    RecordingStartRequest,
    RecordingStopRequest,
)


class RecordingService:
    def __init__(self, repository: WorkSessionRepository) -> None:
        self.repository = repository

    def start(self, db: Session, request: RecordingStartRequest) -> RecordingResponse:
        current = self.repository.get_current(db)
        if current is not None:
            raise InvalidStateTransitionError("Recording is already active or paused.")

        session = self.repository.create(
            db,
            project_id=request.project_id,
            title=request.title,
            started_at=request.started_at or datetime.now(UTC),
        )
        return self._to_response(session)

    def pause(self, db: Session, request: RecordingSessionRequest) -> RecordingResponse:
        session = self._resolve_session(db, request.session_id, fallback_status="active")
        if session.status != "active":
            raise InvalidStateTransitionError("Only active recording sessions can be paused.")

        session = self.repository.update_status(db, session, status="paused")
        return self._to_response(session)

    def resume(self, db: Session, request: RecordingSessionRequest) -> RecordingResponse:
        session = self._resolve_session(db, request.session_id, fallback_status="paused")
        if session.status != "paused":
            raise InvalidStateTransitionError("Only paused recording sessions can be resumed.")

        session = self.repository.update_status(db, session, status="active")
        return self._to_response(session)

    def stop(self, db: Session, request: RecordingStopRequest) -> RecordingResponse:
        session = self._resolve_session(db, request.session_id)
        if session.status not in {"active", "paused"}:
            raise InvalidStateTransitionError(
                "Only active or paused recording sessions can be stopped."
            )

        session = self.repository.update_status(
            db,
            session,
            status="stopped",
            ended_at=request.ended_at or datetime.now(UTC),
        )
        return self._to_response(session)

    def _resolve_session(
        self,
        db: Session,
        session_id: int | None,
        *,
        fallback_status: str | None = None,
    ) -> WorkSession:
        if session_id is not None:
            session = self.repository.get_by_id(db, session_id)
        elif fallback_status is not None:
            session = self.repository.get_current_by_status(db, fallback_status)
        else:
            session = self.repository.get_current(db)

        if session is None:
            raise ResourceNotFoundError("Recording session not found.")
        return session

    def _to_response(self, session: WorkSession) -> RecordingResponse:
        return RecordingResponse(
            session_id=session.id,
            status=session.status,
            started_at=session.started_at,
            ended_at=session.ended_at,
        )


def get_recording_service() -> RecordingService:
    return RecordingService(repository=WorkSessionRepository())

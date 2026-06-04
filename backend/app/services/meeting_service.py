from datetime import date

from sqlalchemy.orm import Session

from app.core.exceptions import InvalidStateTransitionError, ResourceNotFoundError
from app.core.timezone import now_utc
from app.models.work_session import WorkSession
from app.repositories.meeting_repository import MeetingRepository
from app.repositories.work_session_repository import WorkSessionRepository
from app.schemas.meeting import (
    MeetingEndRequest,
    MeetingListResponse,
    MeetingResponse,
    MeetingStartRequest,
)


class MeetingService:
    def __init__(
        self,
        meeting_repository: MeetingRepository,
        session_repository: WorkSessionRepository,
    ) -> None:
        self.meeting_repository = meeting_repository
        self.session_repository = session_repository

    def start_meeting(self, db: Session, request: MeetingStartRequest) -> MeetingResponse:
        if self.meeting_repository.get_current_active_meeting(db) is not None:
            raise InvalidStateTransitionError("Active meeting already exists.")

        session = self._resolve_session(db, request.session_id)
        meeting = self.meeting_repository.create_meeting(
            db,
            request=request,
            session_id=session.id,
            started_at=request.started_at or now_utc(),
        )
        return MeetingResponse.model_validate(meeting)

    def end_meeting(
        self,
        db: Session,
        *,
        meeting_id: int,
        request: MeetingEndRequest,
    ) -> MeetingResponse:
        meeting = self.meeting_repository.get_meeting(db, meeting_id)
        if meeting is None:
            raise ResourceNotFoundError("Meeting not found.")
        if meeting.ended_at is not None:
            raise InvalidStateTransitionError("Meeting already ended.")

        meeting.ended_at = request.ended_at or now_utc()
        if request.summary is not None:
            meeting.summary = request.summary
        return MeetingResponse.model_validate(self.meeting_repository.update_meeting(db, meeting))

    def get_current_meeting(self, db: Session) -> MeetingResponse | None:
        meeting = self.meeting_repository.get_current_active_meeting(db)
        if meeting is None:
            return None
        return MeetingResponse.model_validate(meeting)

    def list_meetings(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
        limit: int = 100,
    ) -> MeetingListResponse:
        items = self.meeting_repository.list_meetings(
            db,
            session_id=session_id,
            target_date=target_date,
            limit=limit,
        )
        total = self.meeting_repository.count_meetings(
            db,
            session_id=session_id,
            target_date=target_date,
        )
        return MeetingListResponse(items=items, total=total)

    def _resolve_session(self, db: Session, session_id: int | None) -> WorkSession:
        if session_id is not None:
            session = self.session_repository.get_by_id(db, session_id)
        else:
            session = self.session_repository.get_current_by_status(db, "active")

        if session is None:
            raise ResourceNotFoundError("Active recording session not found.")
        return session


def get_meeting_service() -> MeetingService:
    return MeetingService(
        meeting_repository=MeetingRepository(),
        session_repository=WorkSessionRepository(),
    )

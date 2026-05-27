from datetime import UTC, date, datetime

from sqlalchemy.orm import Session

from app.core.exceptions import ResourceNotFoundError
from app.models.work_session import WorkSession
from app.repositories.meeting_repository import MeetingRepository
from app.repositories.work_session_repository import WorkSessionRepository
from app.schemas.meeting import (
    MeetingEndRequest,
    MeetingListResponse,
    MeetingResponse,
    MeetingStartRequest,
)
from app.schemas.transcript import TranscriptCreate, TranscriptListResponse, TranscriptResponse


class MeetingService:
    def __init__(
        self,
        meeting_repository: MeetingRepository,
        session_repository: WorkSessionRepository,
    ) -> None:
        self.meeting_repository = meeting_repository
        self.session_repository = session_repository

    def start_meeting(self, db: Session, request: MeetingStartRequest) -> MeetingResponse:
        session = self._resolve_session(db, request.session_id)
        meeting = self.meeting_repository.create_meeting(
            db,
            request=request,
            session_id=session.id,
            started_at=request.started_at or datetime.now(UTC),
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
        meeting.ended_at = request.ended_at or datetime.now(UTC)
        if request.summary is not None:
            meeting.summary = request.summary
        return MeetingResponse.model_validate(self.meeting_repository.update_meeting(db, meeting))

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

    def create_transcript(self, db: Session, request: TranscriptCreate) -> TranscriptResponse:
        meeting = self.meeting_repository.get_meeting(db, request.meeting_id)
        if meeting is None:
            raise ResourceNotFoundError("Meeting not found.")
        transcript = self.meeting_repository.create_transcript(
            db,
            request=request,
            timestamp=request.timestamp or datetime.now(UTC),
        )
        return TranscriptResponse.model_validate(transcript)

    def list_transcripts(
        self,
        db: Session,
        *,
        meeting_id: int,
        limit: int = 100,
    ) -> TranscriptListResponse:
        meeting = self.meeting_repository.get_meeting(db, meeting_id)
        if meeting is None:
            raise ResourceNotFoundError("Meeting not found.")
        items = self.meeting_repository.list_transcripts(
            db,
            meeting_id=meeting_id,
            limit=limit,
        )
        total = self.meeting_repository.count_transcripts(db, meeting_id=meeting_id)
        return TranscriptListResponse(items=items, total=total)

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

from datetime import date

from sqlalchemy.orm import Session

from app.core.exceptions import InvalidStateTransitionError, ResourceNotFoundError
from app.core.timezone import now_kst, now_utc
from app.models.work_session import WorkSession
from app.repositories.meeting_repository import MeetingRepository
from app.repositories.work_session_repository import WorkSessionRepository
from app.schemas.meeting import (
    MeetingEndRequest,
    MeetingListResponse,
    MeetingResponse,
    MeetingStartRequest,
)
from app.schemas.transcript import (
    MeetingTranscriptCreate,
    MeetingTranscriptListResponse,
    MeetingTranscriptResponse,
    TranscriptCreate,
    TranscriptListResponse,
    TranscriptResponse,
)
from app.services.privacy_filter import PrivacyFilter, get_privacy_filter


class MeetingService:
    max_transcript_text_length = 4000

    def __init__(
        self,
        meeting_repository: MeetingRepository,
        session_repository: WorkSessionRepository,
        privacy_filter: PrivacyFilter,
    ) -> None:
        self.meeting_repository = meeting_repository
        self.session_repository = session_repository
        self.privacy_filter = privacy_filter

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

    def create_transcript(self, db: Session, request: TranscriptCreate) -> TranscriptResponse:
        meeting = self.meeting_repository.get_meeting(db, request.meeting_id)
        if meeting is None:
            raise ResourceNotFoundError("Meeting not found.")
        text = self._sanitize_transcript_text(request.text)
        transcript = self.meeting_repository.create_transcript(
            db,
            request=request.model_copy(update={"text": text}),
            timestamp=request.timestamp or now_utc(),
        )
        return TranscriptResponse.model_validate(transcript)

    def create_meeting_transcript(
        self,
        db: Session,
        request: MeetingTranscriptCreate,
    ) -> MeetingTranscriptResponse:
        meeting_session_id = request.meeting_session_id
        if meeting_session_id is not None:
            meeting = self.meeting_repository.get_meeting(db, meeting_session_id)
            if meeting is None:
                raise ResourceNotFoundError("Meeting not found.")
        else:
            active_meeting = self.meeting_repository.get_current_active_meeting(db)
            meeting_session_id = active_meeting.id if active_meeting is not None else None

        text = self._sanitize_transcript_text(request.text)
        timestamp = request.started_at or now_utc()
        transcript = self.meeting_repository.create_meeting_transcript(
            db,
            request=request,
            meeting_session_id=meeting_session_id,
            timestamp=timestamp,
            text=text,
        )
        return MeetingTranscriptResponse.model_validate(transcript)

    def list_today_meeting_transcripts(
        self,
        db: Session,
        *,
        limit: int = 100,
    ) -> MeetingTranscriptListResponse:
        items = self.meeting_repository.list_transcripts(
            db,
            target_date=now_kst().date(),
            limit=limit,
        )
        return MeetingTranscriptListResponse(
            items=[MeetingTranscriptResponse.model_validate(item) for item in items],
            total=len(items),
        )

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

    def _sanitize_transcript_text(self, text: str) -> str:
        normalized = " ".join(text.split())
        if not normalized:
            raise ValueError("Transcript text must not be empty.")
        if len(normalized) > self.max_transcript_text_length:
            normalized = normalized[: self.max_transcript_text_length].rstrip()
        return self.privacy_filter.mask(normalized)

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
        privacy_filter=get_privacy_filter(),
    )

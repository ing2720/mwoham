from sqlalchemy.orm import Session

from app.core.exceptions import ResourceNotFoundError
from app.core.timezone import now_kst, now_utc
from app.repositories.meeting_repository import MeetingRepository
from app.schemas.transcript import (
    MeetingTranscriptCreate,
    MeetingTranscriptListResponse,
    MeetingTranscriptResponse,
    TranscriptCreate,
    TranscriptListResponse,
    TranscriptResponse,
)
from app.services.privacy_filter import PrivacyFilter, get_privacy_filter
from app.services.transcript_quality import TranscriptQualityPolicy, get_transcript_quality_policy


class MeetingTranscriptService:
    max_transcript_text_length = 4000

    def __init__(
        self,
        meeting_repository: MeetingRepository,
        privacy_filter: PrivacyFilter,
        transcript_quality_policy: TranscriptQualityPolicy,
    ) -> None:
        self.meeting_repository = meeting_repository
        self.privacy_filter = privacy_filter
        self.transcript_quality_policy = transcript_quality_policy

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
        latest = self.meeting_repository.get_latest_transcript(
            db,
            meeting_id=meeting_session_id,
            source=request.source,
        )
        if latest is not None and self.transcript_quality_policy.is_near_duplicate(
            latest.text,
            text,
        ):
            if self.transcript_quality_policy.should_replace_duplicate(latest.text, text):
                latest = self.meeting_repository.update_transcript_text(
                    db,
                    latest,
                    text=text,
                    timestamp=timestamp,
                )
            return MeetingTranscriptResponse.model_validate(latest)

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
        normalized = self.transcript_quality_policy.normalize(text)
        if not normalized:
            raise ValueError("Transcript text must not be empty.")
        if self.transcript_quality_policy.is_too_short_for_storage(normalized):
            raise ValueError("Transcript text is too short.")
        if len(normalized) > self.max_transcript_text_length:
            normalized = normalized[: self.max_transcript_text_length].rstrip()
        return self.privacy_filter.mask(normalized)


def get_meeting_transcript_service() -> MeetingTranscriptService:
    return MeetingTranscriptService(
        meeting_repository=MeetingRepository(),
        privacy_filter=get_privacy_filter(),
        transcript_quality_policy=get_transcript_quality_policy(),
    )

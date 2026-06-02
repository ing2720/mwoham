from datetime import date, datetime

from sqlalchemy import Select, func, select
from sqlalchemy.orm import Session

from app.core.timezone import get_kst_day_range_as_utc
from app.models.meeting_session import MeetingSession
from app.models.voice_transcript import VoiceTranscript
from app.schemas.meeting import MeetingStartRequest
from app.schemas.transcript import TranscriptCreate


class MeetingRepository:
    def create_meeting(
        self,
        db: Session,
        *,
        request: MeetingStartRequest,
        session_id: int,
        started_at: datetime,
    ) -> MeetingSession:
        meeting = MeetingSession(
            session_id=session_id,
            started_at=started_at,
            meeting_app=request.meeting_app,
            title=request.title,
            transcript_enabled=request.transcript_enabled,
        )
        db.add(meeting)
        db.commit()
        db.refresh(meeting)
        return meeting

    def get_meeting(self, db: Session, meeting_id: int) -> MeetingSession | None:
        return db.get(MeetingSession, meeting_id)

    def get_current_active_meeting(self, db: Session) -> MeetingSession | None:
        return db.scalar(
            select(MeetingSession)
            .where(MeetingSession.ended_at.is_(None))
            .order_by(MeetingSession.started_at.desc(), MeetingSession.id.desc())
            .limit(1)
        )

    def update_meeting(self, db: Session, meeting: MeetingSession) -> MeetingSession:
        db.add(meeting)
        db.commit()
        db.refresh(meeting)
        return meeting

    def list_meetings(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
        limit: int = 100,
    ) -> list[MeetingSession]:
        statement = self._meeting_select(session_id=session_id, target_date=target_date)
        statement = statement.order_by(
            MeetingSession.started_at.desc(), MeetingSession.id.desc()
        ).limit(limit)
        return list(db.scalars(statement))

    def count_meetings(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
    ) -> int:
        filtered = self._meeting_select(session_id=session_id, target_date=target_date).subquery()
        return db.scalar(select(func.count()).select_from(filtered)) or 0

    def create_transcript(
        self,
        db: Session,
        *,
        request: TranscriptCreate,
        timestamp: datetime,
    ) -> VoiceTranscript:
        transcript = VoiceTranscript(
            meeting_id=request.meeting_id,
            timestamp=timestamp,
            text=request.text,
            speaker=request.speaker,
            confidence=request.confidence,
        )
        db.add(transcript)
        db.commit()
        db.refresh(transcript)
        return transcript

    def list_transcripts(
        self,
        db: Session,
        *,
        meeting_id: int | None = None,
        target_date: date | None = None,
        limit: int = 100,
    ) -> list[VoiceTranscript]:
        statement = self._transcript_select(meeting_id=meeting_id, target_date=target_date)
        statement = statement.order_by(
            VoiceTranscript.timestamp.asc(),
            VoiceTranscript.id.asc(),
        ).limit(limit)
        return list(db.scalars(statement))

    def count_transcripts(self, db: Session, *, meeting_id: int) -> int:
        filtered = self._transcript_select(meeting_id=meeting_id, target_date=None).subquery()
        return db.scalar(select(func.count()).select_from(filtered)) or 0

    def _meeting_select(
        self,
        *,
        session_id: int | None,
        target_date: date | None,
    ) -> Select[tuple[MeetingSession]]:
        statement = select(MeetingSession)
        if session_id is not None:
            statement = statement.where(MeetingSession.session_id == session_id)
        if target_date is not None:
            start, end = get_kst_day_range_as_utc(target_date)
            statement = statement.where(
                MeetingSession.started_at >= start,
                MeetingSession.started_at < end,
            )
        return statement

    def _transcript_select(
        self,
        *,
        meeting_id: int | None,
        target_date: date | None,
    ) -> Select[tuple[VoiceTranscript]]:
        statement = select(VoiceTranscript)
        if meeting_id is not None:
            statement = statement.where(VoiceTranscript.meeting_id == meeting_id)
        if target_date is not None:
            start, end = get_kst_day_range_as_utc(target_date)
            statement = statement.where(
                VoiceTranscript.timestamp >= start,
                VoiceTranscript.timestamp < end,
            )
        return statement

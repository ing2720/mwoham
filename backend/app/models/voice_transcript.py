from datetime import datetime
from typing import TYPE_CHECKING

from sqlalchemy import DateTime, Float, ForeignKey, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base

if TYPE_CHECKING:
    from app.models.meeting_session import MeetingSession


class VoiceTranscript(Base):
    __tablename__ = "voice_transcripts"

    id: Mapped[int] = mapped_column(primary_key=True, index=True)
    meeting_id: Mapped[int | None] = mapped_column(
        ForeignKey("meeting_sessions.id", ondelete="CASCADE"),
        nullable=True,
        index=True,
    )
    timestamp: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, index=True)
    text: Mapped[str] = mapped_column(Text, nullable=False)
    source: Mapped[str] = mapped_column(
        String(50),
        nullable=False,
        default="apple_speech",
        server_default="apple_speech",
    )
    started_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
        index=True,
    )
    ended_at: Mapped[datetime | None] = mapped_column(
        DateTime(timezone=True),
        nullable=True,
        index=True,
    )
    speaker: Mapped[str | None] = mapped_column(String(100), nullable=True)
    confidence: Mapped[float | None] = mapped_column(Float, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    meeting: Mapped["MeetingSession | None"] = relationship(back_populates="transcripts")

    @property
    def meeting_session_id(self) -> int | None:
        return self.meeting_id

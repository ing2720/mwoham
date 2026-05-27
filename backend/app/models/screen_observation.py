from datetime import datetime
from typing import TYPE_CHECKING, Any

from sqlalchemy import JSON, DateTime, ForeignKey, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base

if TYPE_CHECKING:
    from app.models.work_session import WorkSession


class ScreenObservation(Base):
    __tablename__ = "screen_observations"

    id: Mapped[int] = mapped_column(primary_key=True, index=True)
    session_id: Mapped[int] = mapped_column(
        ForeignKey("work_sessions.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )
    timestamp: Mapped[datetime] = mapped_column(DateTime(timezone=True), nullable=False, index=True)
    app_name: Mapped[str | None] = mapped_column(String(100), nullable=True, index=True)
    window_title: Mapped[str | None] = mapped_column(String(255), nullable=True)
    ocr_text: Mapped[str | None] = mapped_column(Text, nullable=True)
    detected_keywords: Mapped[list[str] | dict[str, Any] | None] = mapped_column(
        JSON, nullable=True
    )
    ai_inference: Mapped[str | None] = mapped_column(Text, nullable=True)
    frame_hash: Mapped[str | None] = mapped_column(String(128), nullable=True, index=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    session: Mapped["WorkSession"] = relationship(back_populates="screen_observations")

from datetime import datetime
from typing import TYPE_CHECKING, Any

from sqlalchemy import JSON, DateTime, ForeignKey, String, Text, func
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.db.base import Base

if TYPE_CHECKING:
    from app.models.work_session import WorkSession


class DevEvent(Base):
    __tablename__ = "dev_events"

    id: Mapped[int] = mapped_column(primary_key=True, index=True)
    session_id: Mapped[int | None] = mapped_column(
        ForeignKey("work_sessions.id", ondelete="SET NULL"),
        nullable=True,
        index=True,
    )
    event_type: Mapped[str] = mapped_column(String(30), nullable=False, index=True)
    source: Mapped[str] = mapped_column(String(30), nullable=False, index=True)
    repo_path: Mapped[str | None] = mapped_column(String(500), nullable=True)
    branch: Mapped[str | None] = mapped_column(String(200), nullable=True)
    command: Mapped[str | None] = mapped_column(Text, nullable=True)
    status: Mapped[str | None] = mapped_column(String(30), nullable=True, index=True)
    summary: Mapped[str] = mapped_column(Text, nullable=False)
    details_json: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    occurred_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        index=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

    session: Mapped["WorkSession | None"] = relationship(back_populates="dev_events")

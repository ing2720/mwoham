from datetime import datetime

from sqlalchemy import Boolean, DateTime, String, func
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base


class PrivateApp(Base):
    __tablename__ = "private_apps"

    id: Mapped[int] = mapped_column(primary_key=True, index=True)
    app_name: Mapped[str] = mapped_column(String(100), nullable=False, unique=True, index=True)
    match_type: Mapped[str] = mapped_column(
        String(20),
        nullable=False,
        default="exact",
        server_default="exact",
        index=True,
    )
    is_enabled: Mapped[bool] = mapped_column(
        Boolean,
        nullable=False,
        default=True,
        server_default="1",
        index=True,
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )

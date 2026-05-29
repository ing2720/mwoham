from __future__ import annotations

from datetime import date as DateType
from datetime import datetime as DateTimeType
from typing import Any

from app.schemas.common import ApiSchema


class TimelineItem(ApiSchema):
    type: str
    id: int
    timestamp: DateTimeType
    content: str
    source: str | None = None
    app_name: str | None = None
    window_title: str | None = None
    detected_keywords: list[str] | dict[str, Any] | None = None
    ai_inference: str | None = None
    frame_hash: str | None = None
    meeting_id: int | None = None
    speaker: str | None = None
    confidence: float | None = None
    session_id: int | None = None
    linked_type: str | None = None
    linked_id: int | None = None
    ended_at: DateTimeType | None = None
    duration_seconds: int | None = None
    sample_count: int | None = None


class TimelineResponse(ApiSchema):
    date: DateType
    items: list[TimelineItem]
    total: int

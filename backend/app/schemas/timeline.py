from __future__ import annotations

from datetime import date as DateType
from datetime import datetime as DateTimeType

from app.schemas.common import ApiSchema


class TimelineItem(ApiSchema):
    type: str
    id: int
    timestamp: DateTimeType
    content: str
    source: str | None = None
    app_name: str | None = None
    window_title: str | None = None
    session_id: int | None = None
    linked_type: str | None = None
    linked_id: int | None = None


class TimelineResponse(ApiSchema):
    date: DateType
    items: list[TimelineItem]
    total: int

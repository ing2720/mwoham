from datetime import datetime

from pydantic import Field

from app.schemas.common import ApiSchema


class ActivitySegmentCreate(ApiSchema):
    session_id: int | None = None
    app_name: str | None = Field(default=None, max_length=100)
    window_title: str | None = Field(default=None, max_length=255)
    source: str = Field(min_length=1, max_length=30)
    started_at: datetime
    last_seen_at: datetime


class ActivitySegmentUpdate(ApiSchema):
    last_seen_at: datetime


class ActivitySegmentResponse(ApiSchema):
    id: int
    session_id: int
    app_name: str | None = None
    window_title: str | None = None
    source: str
    started_at: datetime
    ended_at: datetime
    last_seen_at: datetime
    duration_seconds: int
    sample_count: int
    created_at: datetime


class ActivitySegmentListResponse(ApiSchema):
    items: list[ActivitySegmentResponse]
    total: int

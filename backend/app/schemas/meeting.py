from datetime import datetime

from pydantic import Field

from app.schemas.common import ApiSchema


class MeetingStartRequest(ApiSchema):
    session_id: int | None = None
    started_at: datetime | None = None
    meeting_app: str | None = Field(default=None, max_length=100)
    title: str | None = Field(default=None, max_length=200)
    transcript_enabled: bool = False


class MeetingEndRequest(ApiSchema):
    ended_at: datetime | None = None
    summary: str | None = None


class MeetingResponse(ApiSchema):
    id: int
    session_id: int
    started_at: datetime
    ended_at: datetime | None = None
    status: str
    meeting_app: str | None = None
    title: str | None = None
    transcript_enabled: bool
    summary: str | None = None
    created_at: datetime


class MeetingListResponse(ApiSchema):
    items: list[MeetingResponse]
    total: int

from datetime import datetime

from pydantic import Field

from app.schemas.common import ApiSchema


class TranscriptCreate(ApiSchema):
    meeting_id: int
    timestamp: datetime | None = None
    text: str = Field(min_length=1)
    speaker: str | None = Field(default=None, max_length=100)
    confidence: float | None = Field(default=None, ge=0, le=1)


class TranscriptResponse(ApiSchema):
    id: int
    meeting_id: int
    timestamp: datetime
    text: str
    speaker: str | None = None
    confidence: float | None = None
    created_at: datetime


class TranscriptListResponse(ApiSchema):
    items: list[TranscriptResponse]
    total: int

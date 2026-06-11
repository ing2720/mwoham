from datetime import datetime
from typing import Literal

from pydantic import Field

from app.schemas.common import ApiSchema

TranscriptSource = Literal[
    "apple_speech",
    "apple_speech_microphone",
    "apple_speech_system_audio",
    "apple_speech_full_meeting",
    "local_whisper_full_meeting",
    "manual",
]


class TranscriptCreate(ApiSchema):
    meeting_id: int
    timestamp: datetime | None = None
    text: str = Field(min_length=1)
    speaker: str | None = Field(default=None, max_length=100)
    confidence: float | None = Field(default=None, ge=0, le=1)


class MeetingTranscriptCreate(ApiSchema):
    meeting_session_id: int | None = None
    text: str = Field(min_length=1, max_length=4000)
    source: TranscriptSource = "apple_speech"
    started_at: datetime | None = None
    ended_at: datetime | None = None
    speaker: str | None = Field(default=None, max_length=100)
    confidence: float | None = Field(default=None, ge=0, le=1)


class TranscriptResponse(ApiSchema):
    id: int
    meeting_id: int | None
    timestamp: datetime
    text: str
    source: str = "apple_speech"
    started_at: datetime | None = None
    ended_at: datetime | None = None
    speaker: str | None = None
    confidence: float | None = None
    created_at: datetime


class MeetingTranscriptResponse(ApiSchema):
    id: int
    meeting_session_id: int | None = None
    text: str
    source: str
    started_at: datetime | None = None
    ended_at: datetime | None = None
    created_at: datetime


class TranscriptListResponse(ApiSchema):
    items: list[TranscriptResponse]
    total: int


class MeetingTranscriptListResponse(ApiSchema):
    items: list[MeetingTranscriptResponse]
    total: int

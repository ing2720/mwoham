from datetime import datetime
from typing import Any

from pydantic import Field

from app.schemas.common import ApiSchema


class ScreenObservationCreate(ApiSchema):
    session_id: int | None = None
    timestamp: datetime
    app_name: str | None = Field(default=None, max_length=100)
    window_title: str | None = Field(default=None, max_length=255)
    ocr_text: str | None = None
    detected_keywords: list[str] | dict[str, Any] | None = None
    ai_inference: str | None = None
    frame_hash: str | None = Field(default=None, max_length=128)


class ScreenObservationResponse(ApiSchema):
    id: int
    session_id: int
    timestamp: datetime
    app_name: str | None = None
    window_title: str | None = None
    ocr_text: str | None = None
    detected_keywords: list[str] | dict[str, Any] | None = None
    ai_inference: str | None = None
    frame_hash: str | None = None
    created_at: datetime


class ScreenObservationCreateResponse(ApiSchema):
    id: int
    saved: bool = True
    duplicate: bool = False


class ScreenObservationListResponse(ApiSchema):
    items: list[ScreenObservationResponse]
    total: int

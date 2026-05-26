from datetime import datetime
from typing import Any

from pydantic import Field

from app.schemas.common import ApiSchema


class WorkEventCreate(ApiSchema):
    session_id: int | None = None
    timestamp: datetime
    source: str = Field(min_length=1, max_length=30)
    app_name: str | None = Field(default=None, max_length=100)
    window_title: str | None = Field(default=None, max_length=255)
    content: str = Field(min_length=1)
    project_name: str | None = Field(default=None, max_length=100)
    metadata_json: dict[str, Any] | None = None
    confidence: float | None = Field(default=None, ge=0, le=1)


class WorkEventResponse(ApiSchema):
    id: int
    session_id: int
    timestamp: datetime
    source: str
    app_name: str | None = None
    window_title: str | None = None
    content: str
    project_name: str | None = None
    metadata_json: dict[str, Any] | None = None
    confidence: float | None = None
    created_at: datetime


class WorkEventCreateResponse(ApiSchema):
    id: int
    saved: bool = True
    duplicate: bool = False


class WorkEventListResponse(ApiSchema):
    items: list[WorkEventResponse]
    total: int

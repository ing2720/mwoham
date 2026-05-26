from datetime import datetime

from pydantic import Field

from app.schemas.common import ApiSchema


class MemoCreate(ApiSchema):
    session_id: int | None = None
    timestamp: datetime | None = None
    content: str = Field(min_length=1)
    linked_type: str | None = Field(default=None, max_length=50)
    linked_id: int | None = None


class MemoResponse(ApiSchema):
    id: int
    session_id: int | None = None
    timestamp: datetime
    content: str
    linked_type: str | None = None
    linked_id: int | None = None
    created_at: datetime


class MemoListResponse(ApiSchema):
    items: list[MemoResponse]
    total: int

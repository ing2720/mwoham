from datetime import datetime
from typing import Any, Literal

from pydantic import Field

from app.schemas.common import ApiSchema

DevEventType = Literal[
    "git_snapshot",
    "command_result",
    "test_result",
    "build_result",
    "note",
]
DevEventSource = Literal["script", "api", "manual"]
DevEventStatus = Literal["success", "failed", "unknown"]


class DevEventCreate(ApiSchema):
    session_id: int | None = None
    event_type: DevEventType
    source: DevEventSource = "api"
    repo_path: str | None = Field(default=None, max_length=500)
    branch: str | None = Field(default=None, max_length=200)
    command: str | None = None
    status: DevEventStatus | None = None
    summary: str = Field(min_length=1)
    details_json: dict[str, Any] | None = None
    occurred_at: datetime | None = None


class DevEventRead(ApiSchema):
    id: int
    session_id: int | None = None
    event_type: str
    source: str
    repo_path: str | None = None
    branch: str | None = None
    command: str | None = None
    status: str | None = None
    summary: str
    details_json: dict[str, Any] | None = None
    occurred_at: datetime
    created_at: datetime


class DevEventListResponse(ApiSchema):
    items: list[DevEventRead]
    total: int

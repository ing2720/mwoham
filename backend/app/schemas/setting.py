from datetime import datetime
from typing import Literal

from pydantic import Field

from app.schemas.common import ApiSchema

SettingValueType = Literal["string", "number", "boolean", "json"]
PrivateAppMatchType = Literal["exact", "contains", "regex"]


class AppSettingResponse(ApiSchema):
    key: str
    value: str | None = None
    value_type: str
    updated_at: datetime


class SettingsResponse(ApiSchema):
    items: list[AppSettingResponse]
    total: int


class SettingsPatchRequest(ApiSchema):
    settings: dict[str, str | int | float | bool | dict | list | None]


class PrivateAppCreate(ApiSchema):
    app_name: str = Field(min_length=1, max_length=100)
    match_type: PrivateAppMatchType = "exact"
    is_enabled: bool = True


class PrivateAppResponse(ApiSchema):
    id: int
    app_name: str
    match_type: str
    is_enabled: bool
    created_at: datetime


class PrivateAppListResponse(ApiSchema):
    items: list[PrivateAppResponse]
    total: int


class DeletePrivateAppResponse(ApiSchema):
    app_name: str
    deleted: bool

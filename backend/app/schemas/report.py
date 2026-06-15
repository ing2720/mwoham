from __future__ import annotations

from datetime import date as DateType
from datetime import datetime as DateTimeType
from typing import Literal

from pydantic import Field

from app.schemas.common import ApiSchema

ReportExportFormat = Literal["markdown", "pdf"]


class DailyReportCreate(ApiSchema):
    date: DateType | None = None
    project_id: int | None = None
    mode: Literal["detailed", "simple"] = "detailed"


class ReportUpdate(ApiSchema):
    title: str | None = Field(default=None, max_length=200)
    content: str | None = Field(default=None, min_length=1)


class ReportResponse(ApiSchema):
    id: int
    project_id: int | None = None
    date: DateType | None = None
    mode: str
    title: str | None = None
    content: str
    source_range_start: DateTimeType | None = None
    source_range_end: DateTimeType | None = None
    created_by: str
    created_at: DateTimeType
    updated_at: DateTimeType


class ReportListResponse(ApiSchema):
    items: list[ReportResponse]
    total: int


class ReportExportRequest(ApiSchema):
    export_format: ReportExportFormat


class ReportExportResponse(ApiSchema):
    file_path: str
    format: ReportExportFormat
    created_at: DateTimeType
    download_url: str

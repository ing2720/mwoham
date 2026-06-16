from datetime import date, datetime
from typing import Annotated, Literal
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import FileResponse, Response
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from app.core.exceptions import ResourceNotFoundError
from app.core.security import require_local_api_token
from app.db.session import get_db
from app.report.display import format_created_by, format_report_mode
from app.report.export_service import ReportExportService, get_report_export_service
from app.schemas.report import (
    DailyReportCreate,
    ReportExportFormat,
    ReportExportRequest,
    ReportExportResponse,
    ReportListResponse,
    ReportResponse,
    ReportUpdate,
)
from app.services.report_service import ReportService, get_report_service

router = APIRouter(prefix="/reports", tags=["reports"])
templates = Jinja2Templates(directory="app/web/templates")
templates.env.filters["created_by_label"] = format_created_by
templates.env.filters["report_mode_label"] = format_report_mode
KST = ZoneInfo("Asia/Seoul")


@router.post("/daily", response_model=ReportResponse, status_code=status.HTTP_201_CREATED)
def create_daily_report(
    request: DailyReportCreate | None = None,
    mode: Literal["detailed", "simple"] | None = None,
    _: None = Depends(require_local_api_token),
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
) -> ReportResponse:
    report_request = request or DailyReportCreate()
    if mode is not None:
        report_request = report_request.model_copy(update={"mode": mode})
    return service.create_daily_report(db, report_request)


@router.get("/today", response_model=ReportListResponse)
def list_today_reports(
    target_date: Annotated[date | None, Query(alias="date")] = None,
    mode: str | None = None,
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
) -> ReportListResponse:
    return service.list_today_reports(db, target_date=target_date, mode=mode)


@router.get("", response_model=None)
def list_reports(
    request: Request,
    target_date: Annotated[date | None, Query(alias="date")] = None,
    mode: str | None = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 100,
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
) -> ReportListResponse | Response:
    report_list = service.list_reports(db, target_date=target_date, mode=mode, limit=limit)
    if "text/html" in request.headers.get("accept", ""):
        report_payloads = [
            report.model_dump(mode="json")
            for report in report_list.items
        ]
        today_text = datetime.now(KST).strftime("%Y-%m-%d")
        return templates.TemplateResponse(
            request,
            "reports.html",
            {
                "active_page": "reports",
                "reports": report_list.items,
                "report_payloads": report_payloads,
                "report_groups": _group_reports_by_date(
                    report_payloads,
                    today_text=today_text,
                ),
                "latest_report_id": report_payloads[0]["id"] if report_payloads else None,
                "total": report_list.total,
            },
        )
    return report_list


@router.get("/{report_id}", response_model=ReportResponse)
def get_report(
    report_id: int,
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
) -> ReportResponse:
    try:
        return service.get_report(db, report_id)
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc


@router.patch("/{report_id}", response_model=ReportResponse)
def update_report(
    report_id: int,
    request: ReportUpdate,
    _: None = Depends(require_local_api_token),
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
) -> ReportResponse:
    try:
        return service.update_report(db, report_id, request)
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc


@router.post("/{report_id}/export", response_model=ReportExportResponse)
def export_report(
    report_id: int,
    request: ReportExportRequest | None = None,
    export_format: ReportExportFormat | None = None,
    _: None = Depends(require_local_api_token),
    db: Session = Depends(get_db),
    service: ReportExportService = Depends(get_report_export_service),
) -> ReportExportResponse:
    selected_format = request.export_format if request is not None else export_format
    if selected_format is None:
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="export_format is required.",
        )

    try:
        return service.export_report(db, report_id=report_id, export_format=selected_format)
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc


@router.get("/{report_id}/download", response_class=FileResponse)
def download_report(
    report_id: int,
    export_format: Annotated[ReportExportFormat, Query(alias="format")],
    db: Session = Depends(get_db),
    service: ReportExportService = Depends(get_report_export_service),
) -> FileResponse:
    try:
        exported = service.export_report(db, report_id=report_id, export_format=export_format)
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc

    media_type = "application/pdf" if export_format == "pdf" else "text/markdown; charset=utf-8"
    filename = exported.file_path.rsplit("/", maxsplit=1)[-1]
    return FileResponse(
        exported.file_path,
        media_type=media_type,
        filename=filename,
        content_disposition_type="attachment",
    )


def _group_reports_by_date(
    reports: list[dict],
    *,
    today_text: str,
) -> list[dict]:
    grouped: dict[str, list[dict]] = {}
    for report in reports:
        report_item = {
            **report,
            "created_at_label": _format_iso_datetime(report.get("created_at")),
            "updated_at_label": _format_iso_datetime(report.get("updated_at")),
        }
        report_date = report_item.get("date") or str(report_item.get("created_at", ""))[:10]
        grouped.setdefault(report_date, []).append(report_item)

    groups = []
    for report_date in sorted(grouped, reverse=True):
        items = sorted(
            grouped[report_date],
            key=lambda report: (report.get("updated_at") or "", report.get("id") or 0),
            reverse=True,
        )
        is_today = report_date == today_text
        groups.append(
            {
                "date": report_date,
                "title": f"오늘 · {report_date}" if is_today else report_date,
                "is_today": is_today,
                "items": items,
            }
        )
    return groups


def _format_iso_datetime(value: str | None) -> str:
    if not value:
        return "-"
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.astimezone(KST).strftime("%Y-%m-%d %H:%M")

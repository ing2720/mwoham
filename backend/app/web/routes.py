from datetime import UTC, date, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import RedirectResponse
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from app.core.exceptions import InvalidStateTransitionError, ResourceNotFoundError
from app.db.session import get_db
from app.report.display import format_created_by, format_report_mode
from app.schemas.memo import MemoCreate
from app.schemas.recording import (
    RecordingSessionRequest,
    RecordingStartRequest,
    RecordingStopRequest,
)
from app.schemas.report import DailyReportCreate
from app.schemas.setting import PrivateAppCreate
from app.schemas.work_event import WorkEventCreate
from app.services.event_service import EventService, get_event_service
from app.services.memo_service import MemoService, get_memo_service
from app.services.recording_service import RecordingService, get_recording_service
from app.services.report_service import ReportService, get_report_service
from app.services.setting_service import SettingService, get_setting_service
from app.services.web_dashboard_service import WebDashboardService, get_web_dashboard_service

router = APIRouter(tags=["web"])
templates = Jinja2Templates(directory="app/web/templates")
templates.env.filters["created_by_label"] = format_created_by
templates.env.filters["report_mode_label"] = format_report_mode


@router.get("/dashboard")
def dashboard(
    request: Request,
    db: Session = Depends(get_db),
    service: WebDashboardService = Depends(get_web_dashboard_service),
):
    context = service.get_dashboard_context(db)
    return templates.TemplateResponse(
        request,
        "dashboard.html",
        {"active_page": "dashboard", **context},
    )


@router.get("/timeline")
def timeline(
    request: Request,
    target_date: Annotated[date | None, Query(alias="date")] = None,
    db: Session = Depends(get_db),
    service: WebDashboardService = Depends(get_web_dashboard_service),
):
    context = service.get_timeline_context(db, target_date=target_date)
    return templates.TemplateResponse(
        request,
        "timeline.html",
        {"active_page": "timeline", **context},
    )


@router.get("/reports")
def reports(
    request: Request,
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
):
    report_list = service.list_reports(db, limit=100)
    return templates.TemplateResponse(
        request,
        "reports.html",
        {"active_page": "reports", "reports": report_list.items, "total": report_list.total},
    )


@router.get("/reports/{report_id}/view")
def report_detail(
    report_id: int,
    request: Request,
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
):
    report = service.get_report(db, report_id)
    return templates.TemplateResponse(
        request,
        "report_detail.html",
        {"active_page": "reports", "report": report},
    )


@router.post("/dashboard/recording/start")
async def start_recording_from_dashboard(
    request: Request,
    db: Session = Depends(get_db),
    service: RecordingService = Depends(get_recording_service),
) -> RedirectResponse:
    form = await request.form()
    title = str(form.get("title") or "").strip() or None
    try:
        service.start(db, RecordingStartRequest(title=title))
    except InvalidStateTransitionError:
        pass
    return RedirectResponse("/dashboard", status_code=303)


@router.post("/dashboard/recording/pause")
def pause_recording_from_dashboard(
    db: Session = Depends(get_db),
    service: RecordingService = Depends(get_recording_service),
) -> RedirectResponse:
    try:
        service.pause(db, RecordingSessionRequest())
    except (InvalidStateTransitionError, ResourceNotFoundError):
        pass
    return RedirectResponse("/dashboard", status_code=303)


@router.post("/dashboard/recording/resume")
def resume_recording_from_dashboard(
    db: Session = Depends(get_db),
    service: RecordingService = Depends(get_recording_service),
) -> RedirectResponse:
    try:
        service.resume(db, RecordingSessionRequest())
    except (InvalidStateTransitionError, ResourceNotFoundError):
        pass
    return RedirectResponse("/dashboard", status_code=303)


@router.post("/dashboard/recording/stop")
def stop_recording_from_dashboard(
    db: Session = Depends(get_db),
    service: RecordingService = Depends(get_recording_service),
) -> RedirectResponse:
    try:
        service.stop(db, RecordingStopRequest())
    except (InvalidStateTransitionError, ResourceNotFoundError):
        pass
    return RedirectResponse("/dashboard", status_code=303)


@router.post("/dashboard/events")
async def create_event_from_dashboard(
    request: Request,
    db: Session = Depends(get_db),
    service: EventService = Depends(get_event_service),
) -> RedirectResponse:
    form = await request.form()
    try:
        service.create(
            db,
            WorkEventCreate(
                timestamp=datetime.now(UTC),
                source=str(form.get("source") or "web"),
                app_name=str(form.get("app_name") or "").strip() or None,
                window_title=str(form.get("window_title") or "").strip() or None,
                content=str(form.get("content") or "").strip(),
            ),
        )
    except (ResourceNotFoundError, ValueError):
        pass
    return RedirectResponse("/dashboard", status_code=303)


@router.post("/dashboard/memos")
async def create_memo_from_dashboard(
    request: Request,
    db: Session = Depends(get_db),
    service: MemoService = Depends(get_memo_service),
) -> RedirectResponse:
    form = await request.form()
    content = str(form.get("content") or "").strip()
    if content:
        service.create(db, MemoCreate(timestamp=datetime.now(UTC), content=content))
    return RedirectResponse("/dashboard", status_code=303)


@router.post("/reports/daily/create")
def create_daily_report_from_web(
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
) -> RedirectResponse:
    report = service.create_daily_report(db, DailyReportCreate())
    return RedirectResponse(f"/reports/{report.id}/view", status_code=303)


@router.post("/settings/private-apps/add")
async def add_private_app_from_settings(
    request: Request,
    db: Session = Depends(get_db),
    service: SettingService = Depends(get_setting_service),
) -> RedirectResponse:
    form = await request.form()
    app_name = str(form.get("app_name") or "").strip()
    if app_name:
        service.create_private_app(
            db,
            PrivateAppCreate(
                app_name=app_name,
                match_type=str(form.get("match_type") or "exact"),
                is_enabled=form.get("is_enabled") == "on",
            ),
        )
    return RedirectResponse("/settings", status_code=303)


@router.post("/settings/private-apps/delete")
async def delete_private_app_from_settings(
    request: Request,
    db: Session = Depends(get_db),
    service: SettingService = Depends(get_setting_service),
) -> RedirectResponse:
    form = await request.form()
    app_name = str(form.get("app_name") or "").strip()
    if app_name:
        service.delete_private_app(db, app_name)
    return RedirectResponse("/settings", status_code=303)

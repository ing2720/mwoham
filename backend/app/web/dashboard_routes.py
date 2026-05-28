from datetime import UTC, date, datetime
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request
from fastapi.responses import RedirectResponse
from sqlalchemy.orm import Session

from app.core.exceptions import InvalidStateTransitionError, ResourceNotFoundError
from app.db.session import get_db
from app.schemas.memo import MemoCreate
from app.schemas.recording import (
    RecordingSessionRequest,
    RecordingStartRequest,
    RecordingStopRequest,
)
from app.schemas.work_event import WorkEventCreate
from app.services.event_service import EventService, get_event_service
from app.services.memo_service import MemoService, get_memo_service
from app.services.recording_service import RecordingService, get_recording_service
from app.services.web_dashboard_service import WebDashboardService, get_web_dashboard_service
from app.web.templating import templates

router = APIRouter(tags=["web"])


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

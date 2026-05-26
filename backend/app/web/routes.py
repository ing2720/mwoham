from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.services.web_dashboard_service import WebDashboardService, get_web_dashboard_service

router = APIRouter(tags=["web"])
templates = Jinja2Templates(directory="app/web/templates")


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
def reports(request: Request):
    return templates.TemplateResponse(
        request,
        "reports.html",
        {"active_page": "reports"},
    )


@router.get("/settings")
def settings(request: Request):
    return templates.TemplateResponse(
        request,
        "settings.html",
        {"active_page": "settings"},
    )

from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status
from fastapi.responses import Response
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from app.core.exceptions import ResourceNotFoundError
from app.db.session import get_db
from app.schemas.report import DailyReportCreate, ReportListResponse, ReportResponse, ReportUpdate
from app.services.report_service import ReportService, get_report_service

router = APIRouter(prefix="/reports", tags=["reports"])
templates = Jinja2Templates(directory="app/web/templates")


@router.post("/daily", response_model=ReportResponse, status_code=status.HTTP_201_CREATED)
def create_daily_report(
    request: DailyReportCreate | None = None,
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
) -> ReportResponse:
    return service.create_daily_report(db, request or DailyReportCreate())


@router.get("/today", response_model=ReportListResponse)
def list_today_reports(
    target_date: Annotated[date | None, Query(alias="date")] = None,
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
) -> ReportListResponse:
    return service.list_today_reports(db, target_date=target_date)


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
        return templates.TemplateResponse(
            request,
            "reports.html",
            {
                "active_page": "reports",
                "reports": report_list.items,
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
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
) -> ReportResponse:
    try:
        return service.update_report(db, report_id, request)
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc

from datetime import datetime
from typing import Literal

from fastapi import APIRouter, Depends, Request
from fastapi.responses import RedirectResponse
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.report.display import KST, group_reports_by_date
from app.schemas.report import DailyReportCreate
from app.services.report_service import ReportService, get_report_service
from app.web.templating import templates

router = APIRouter(tags=["web"])


@router.get("/reports")
def reports(
    request: Request,
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
):
    report_list = service.list_reports(db, limit=100)
    report_payloads = [report.model_dump(mode="json") for report in report_list.items]
    today_text = datetime.now(KST).strftime("%Y-%m-%d")
    grouped_reports = group_reports_by_date(report_payloads, today_text=today_text)
    latest_report_id = report_payloads[0]["id"] if report_payloads else None
    return templates.TemplateResponse(
        request,
        "reports.html",
        {
            "active_page": "reports",
            "reports": report_list.items,
            "report_payloads": report_payloads,
            "report_groups": grouped_reports,
            "latest_report_id": latest_report_id,
            "total": report_list.total,
        },
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


@router.post("/reports/daily/create")
def create_daily_report_from_web(
    mode: Literal["detailed", "simple"] = "detailed",
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
) -> RedirectResponse:
    report = service.create_daily_report(db, DailyReportCreate(mode=mode))
    return RedirectResponse(f"/reports/{report.id}/view", status_code=303)

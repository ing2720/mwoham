from datetime import datetime
from typing import Literal
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, Request
from fastapi.responses import RedirectResponse
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.schemas.report import DailyReportCreate
from app.services.report_service import ReportService, get_report_service
from app.web.templating import templates

router = APIRouter(tags=["web"])
KST = ZoneInfo("Asia/Seoul")


@router.get("/reports")
def reports(
    request: Request,
    db: Session = Depends(get_db),
    service: ReportService = Depends(get_report_service),
):
    report_list = service.list_reports(db, limit=100)
    report_payloads = [
        report.model_dump(mode="json")
        for report in report_list.items
    ]
    today_text = datetime.now(KST).strftime("%Y-%m-%d")
    grouped_reports = _group_reports_by_date(report_payloads, today_text=today_text)
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

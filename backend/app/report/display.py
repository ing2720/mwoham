from datetime import datetime
from zoneinfo import ZoneInfo

CREATED_BY_LABELS = {
    "ai": "AI",
    "system": "시스템",
    "user": "사용자",
}

REPORT_MODE_LABELS = {
    "detailed": "상세 리포트",
    "simple": "간단 리포트",
}

KST = ZoneInfo("Asia/Seoul")


def format_created_by(value: str) -> str:
    return CREATED_BY_LABELS.get(value, value)


def format_report_mode(value: str) -> str:
    return REPORT_MODE_LABELS.get(value, value)


def group_reports_by_date(
    reports: list[dict],
    *,
    today_text: str,
) -> list[dict]:
    grouped: dict[str, list[dict]] = {}
    for report in reports:
        report_item = {
            **report,
            "created_at_label": format_report_datetime(report.get("created_at")),
            "updated_at_label": format_report_datetime(report.get("updated_at")),
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


def format_report_datetime(value: str | None) -> str:
    if not value:
        return "-"
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    return parsed.astimezone(KST).strftime("%Y-%m-%d %H:%M")

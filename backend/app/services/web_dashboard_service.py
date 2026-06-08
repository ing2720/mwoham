from datetime import date
from typing import Any

from sqlalchemy.orm import Session

from app.models.report import Report
from app.repositories.report_repository import ReportRepository
from app.schemas.timeline import TimelineItem, TimelineResponse
from app.services.status_service import StatusService, get_status_service
from app.services.timeline_builder import TimelineBuilder, get_timeline_builder

TIMELINE_FILTER_OPTIONS = [
    {"value": "all", "label": "전체"},
    {"value": "dev", "label": "개발 이벤트"},
    {"value": "git", "label": "자동 Git 변경"},
    {"value": "command", "label": "터미널 명령"},
    {"value": "command_failed", "label": "실패 명령"},
    {"value": "meeting", "label": "회의 전사"},
    {"value": "memo", "label": "수동 메모"},
    {"value": "report", "label": "리포트"},
]
TIMELINE_FILTER_VALUES = {option["value"] for option in TIMELINE_FILTER_OPTIONS}


class WebDashboardService:
    def __init__(
        self,
        status_service: StatusService,
        timeline_builder: TimelineBuilder,
        report_repository: ReportRepository,
    ) -> None:
        self.status_service = status_service
        self.timeline_builder = timeline_builder
        self.report_repository = report_repository

    def get_dashboard_context(self, db: Session) -> dict[str, Any]:
        timeline = self.timeline_builder.build_for_date(db)
        return {
            "status": self.status_service.get_status(db),
            "timeline": timeline,
            "recent_items": timeline.items[-8:],
        }

    def get_timeline_context(
        self,
        db: Session,
        target_date: date | None = None,
        timeline_filter: str | None = None,
    ) -> dict[str, Any]:
        timeline = self.timeline_builder.build_for_date(db, target_date=target_date)
        return {
            "timeline": self._prepare_web_timeline(
                db,
                timeline=timeline,
                timeline_filter=timeline_filter,
            ),
            "is_detail": False,
            **self._filter_context(timeline_filter),
        }

    def get_detail_timeline_context(
        self,
        db: Session,
        target_date: date | None = None,
        timeline_filter: str | None = None,
    ) -> dict[str, Any]:
        timeline = self.timeline_builder.build_detail_for_date(
            db,
            target_date=target_date,
        )
        return {
            "timeline": self._prepare_web_timeline(
                db,
                timeline=timeline,
                timeline_filter=timeline_filter,
            ),
            "is_detail": True,
            **self._filter_context(timeline_filter),
        }

    def _prepare_web_timeline(
        self,
        db: Session,
        *,
        timeline: TimelineResponse,
        timeline_filter: str | None,
    ) -> TimelineResponse:
        selected_filter = self._normalize_filter(timeline_filter)
        items = [
            *timeline.items,
            *[
                self._report_to_item(report)
                for report in self.report_repository.list(
                    db,
                    target_date=timeline.date,
                    limit=1000,
                )
            ],
        ]
        filtered_items = [
            item for item in items if self._matches_timeline_filter(item, selected_filter)
        ]
        filtered_items.sort(key=lambda item: item.timestamp, reverse=True)
        return TimelineResponse(
            date=timeline.date,
            items=filtered_items,
            total=len(filtered_items),
        )

    def _filter_context(self, timeline_filter: str | None) -> dict[str, Any]:
        selected_filter = self._normalize_filter(timeline_filter)
        selected_label = next(
            option["label"]
            for option in TIMELINE_FILTER_OPTIONS
            if option["value"] == selected_filter
        )
        return {
            "timeline_filter": selected_filter,
            "timeline_filter_label": selected_label,
            "timeline_filter_options": TIMELINE_FILTER_OPTIONS,
        }

    def _normalize_filter(self, timeline_filter: str | None) -> str:
        if timeline_filter in TIMELINE_FILTER_VALUES:
            return timeline_filter
        return "all"

    def _matches_timeline_filter(self, item: TimelineItem, timeline_filter: str) -> bool:
        if timeline_filter == "all":
            return True
        if timeline_filter == "dev":
            return item.type == "dev_event"
        if timeline_filter == "git":
            return (
                item.type == "dev_event"
                and item.event_type == "git_snapshot"
                and (
                    item.source == "watch"
                    or item.display_label == "자동 Git 변경 감지"
                    or (item.details_json or {}).get("tracking_mode") == "watch"
                )
            )
        if timeline_filter == "command":
            return (
                item.type == "dev_event"
                and item.event_type == "command_result"
                and item.source == "terminal"
            )
        if timeline_filter == "command_failed":
            return (
                item.type == "dev_event"
                and item.event_type == "command_result"
                and item.source == "terminal"
                and item.status == "failed"
            )
        if timeline_filter == "meeting":
            return item.type == "transcript"
        if timeline_filter == "memo":
            return item.type == "memo"
        if timeline_filter == "report":
            return item.type == "report"
        return True

    def _report_to_item(self, report: Report) -> TimelineItem:
        return TimelineItem(
            type="report",
            id=report.id,
            timestamp=report.created_at,
            content=report.title or f"{report.date.isoformat() if report.date else ''} 리포트",
            display_label="리포트",
            source=report.created_by,
            event_type=report.mode,
        )


def get_web_dashboard_service() -> WebDashboardService:
    return WebDashboardService(
        status_service=get_status_service(),
        timeline_builder=get_timeline_builder(),
        report_repository=ReportRepository(),
    )

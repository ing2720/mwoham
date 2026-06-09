from datetime import date
from typing import Any

from sqlalchemy.orm import Session

from app.core.timezone import parse_date_or_today_kst
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
        review_context = self._get_daily_review_context(db, target_date=timeline.date)
        return {
            "status": self.status_service.get_status(db),
            "timeline": timeline,
            "recent_items": self._dashboard_recent_items(timeline.items),
            **review_context,
        }

    def _get_daily_review_context(
        self,
        db: Session,
        target_date: date | None = None,
    ) -> dict[str, Any]:
        review_date = parse_date_or_today_kst(target_date)
        timeline = self.timeline_builder.build_detail_for_date(db, target_date=review_date)
        reports = self.report_repository.list(db, target_date=review_date, limit=5)
        latest_report = reports[0] if reports else None
        return {
            "review_date": review_date,
            "latest_report": latest_report,
            "report_excerpt": self._report_excerpt(latest_report),
            "validation_commands": self._validation_commands(timeline.items),
            "command_flows": self._command_flows(timeline.items),
            "recent_dev_events": self._recent_dev_events(timeline.items),
            "meeting_memo_items": self._meeting_memo_items(timeline.items),
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

    def _report_excerpt(self, report: Report | None) -> str:
        if report is None:
            return ""
        compacted = " ".join(report.content.split())
        return self._truncate(compacted, 320)

    def _validation_commands(self, items: list[TimelineItem]) -> list[dict[str, Any]]:
        commands = [
            {
                "timestamp": item.timestamp,
                "command": item.command or item.content,
                "status": item.status or "unknown",
                "label": "성공" if item.status == "success" else "실패",
            }
            for item in items
            if self._is_terminal_command(item) and self._is_validation_command(item.command)
        ]
        return list(reversed(commands[-8:]))

    def _command_flows(self, items: list[TimelineItem]) -> list[dict[str, Any]]:
        commands = [
            item
            for item in items
            if self._is_terminal_command(item)
            and not self._is_inspection_or_cleanup_command(item.command)
        ]
        flows: list[dict[str, Any]] = []
        for index, item in enumerate(commands):
            if item.status != "failed":
                continue
            next_success = next(
                (
                    candidate
                    for candidate in commands[index + 1 :]
                    if candidate.status == "success"
                    and self._command_family(candidate.command)
                    == self._command_family(item.command)
                ),
                None,
            )
            flows.append(
                {
                    "timestamp": item.timestamp,
                    "failed_command": item.command or item.content,
                    "success_command": next_success.command if next_success else None,
                    "is_qa_failure": self._is_intentional_qa_failure(item.command),
                }
            )
        return list(reversed(flows[-5:]))

    def _recent_dev_events(self, items: list[TimelineItem]) -> list[TimelineItem]:
        dev_events = [
            item
            for item in items
            if item.type == "dev_event"
            and not (
                item.event_type == "command_result"
                and self._is_inspection_or_cleanup_command(item.command)
            )
        ]
        return list(reversed(dev_events[-8:]))

    def _meeting_memo_items(self, items: list[TimelineItem]) -> list[TimelineItem]:
        meeting_memo_items = [
            item
            for item in items
            if item.type in {"meeting", "transcript", "memo"}
            and item.content.strip()
        ]
        return list(reversed(meeting_memo_items[-8:]))

    def _dashboard_recent_items(self, items: list[TimelineItem]) -> list[TimelineItem]:
        visible_items = [
            item
            for item in items
            if not (
                self._is_terminal_command(item)
                and self._is_inspection_or_cleanup_command(item.command)
            )
        ]
        return visible_items[-8:]

    def _is_terminal_command(self, item: TimelineItem) -> bool:
        return (
            item.type == "dev_event"
            and item.event_type == "command_result"
            and item.source == "terminal"
        )

    def _is_validation_command(self, command: str | None) -> bool:
        normalized = self._normalize_command(command)
        return normalized.startswith(
            (
                "uv run pytest",
                "uv run python scripts/run_dev_checks.py",
                "uv run alembic check",
                "git diff --check",
                "ruff",
                "xcodebuild",
                "bash -n",
                "zsh -n",
            )
        )

    def _is_inspection_or_cleanup_command(self, command: str | None) -> bool:
        normalized = self._normalize_command(command)
        return normalized.startswith(
            (
                "echo",
                "sqlite3",
                "curl",
                "source ",
                "mwoham_command_tracking_status",
                "mwoham_command_tracking_disable",
                "git switch",
                "git pull",
                "rm -rf",
            )
        ) or self._is_git_tag_inspection_command(normalized)

    def _is_git_tag_inspection_command(self, normalized_command: str) -> bool:
        return (
            normalized_command == "git tag"
            or normalized_command.startswith("git tag |")
            or normalized_command.startswith("git tag --list")
            or normalized_command.startswith("git tag -l")
        )

    def _is_intentional_qa_failure(self, command: str | None) -> bool:
        normalized = self._normalize_command(command)
        return "tests/not_exists.py" in normalized

    def _command_family(self, command: str | None) -> str:
        normalized = self._normalize_command(command)
        parts = normalized.split()
        if len(parts) >= 3 and parts[:3] == ["uv", "run", "pytest"]:
            return "uv run pytest"
        if len(parts) >= 3 and parts[:3] == ["uv", "run", "python"]:
            return "uv run python"
        return " ".join(parts[:2]) if parts else ""

    def _normalize_command(self, command: str | None) -> str:
        return " ".join((command or "").split())

    def _truncate(self, text: str, limit: int) -> str:
        if len(text) <= limit:
            return text
        return text[:limit].rstrip() + "..."

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

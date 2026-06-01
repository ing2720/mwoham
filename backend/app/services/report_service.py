import logging
import re
from datetime import date, datetime

from sqlalchemy.orm import Session

from app.ai.gemini_client import GeminiClient
from app.ai.prompt_builder import get_prompt_builder
from app.ai.report_content_cleaner import ReportContentCleaner, get_report_content_cleaner
from app.ai.summarizer import GeminiSummarizer
from app.core.config import settings
from app.core.exceptions import ResourceNotFoundError
from app.core.timezone import KST, as_kst, now_kst, utc_range_for_kst_date
from app.models.report import Report
from app.repositories.report_repository import ReportRepository
from app.schemas.report import DailyReportCreate, ReportListResponse, ReportResponse, ReportUpdate
from app.schemas.timeline import TimelineResponse
from app.services.timeline_builder import TimelineBuilder, get_timeline_builder

logger = logging.getLogger(__name__)


class ReportService:
    KST = KST

    def __init__(
        self,
        repository: ReportRepository,
        timeline_builder: TimelineBuilder,
        summarizer: GeminiSummarizer,
        content_cleaner: ReportContentCleaner | None = None,
    ) -> None:
        self.repository = repository
        self.timeline_builder = timeline_builder
        self.summarizer = summarizer
        self.content_cleaner = content_cleaner or get_report_content_cleaner()

    def create_daily_report(self, db: Session, request: DailyReportCreate) -> ReportResponse:
        target_date = request.date or now_kst().date()
        timeline = self.timeline_builder.build_detail_for_kst_date(db, target_date=target_date)
        generated_content = self.summarizer.summarize_daily_report(timeline)
        cleaned_content = (
            self.content_cleaner.clean(generated_content) if generated_content else None
        )
        if cleaned_content is None:
            logger.warning(
                "Daily report is falling back to placeholder: date=%s reason=%s "
                "finish_reason=%s was_truncated=%s",
                target_date.isoformat(),
                getattr(self.summarizer, "last_error_reason", None),
                getattr(self.summarizer, "last_finish_reason", None),
                getattr(self.summarizer, "last_was_truncated", False),
            )
        source_range_start, source_range_end = self._source_range_for_kst_date(target_date)
        report = Report(
            project_id=request.project_id,
            date=target_date,
            mode=request.mode,
            title=f"{target_date.isoformat()} 일일 작업 리포트",
            content=cleaned_content or self._build_placeholder_content(timeline),
            source_range_start=source_range_start,
            source_range_end=source_range_end,
            created_by="ai" if cleaned_content else "system",
        )
        return ReportResponse.model_validate(self.repository.create(db, report))

    def list_reports(
        self,
        db: Session,
        *,
        target_date: date | None = None,
        mode: str | None = None,
        limit: int = 100,
    ) -> ReportListResponse:
        items = self.repository.list(db, target_date=target_date, mode=mode, limit=limit)
        total = self.repository.count(db, target_date=target_date, mode=mode)
        return ReportListResponse(items=items, total=total)

    def list_today_reports(
        self, db: Session, target_date: date | None = None
    ) -> ReportListResponse:
        report_date = target_date or now_kst().date()
        return self.list_reports(db, target_date=report_date, mode=None, limit=100)

    def get_report(self, db: Session, report_id: int) -> ReportResponse:
        report = self.repository.get_by_id(db, report_id)
        if report is None:
            raise ResourceNotFoundError("Report not found.")
        return ReportResponse.model_validate(report)

    def update_report(self, db: Session, report_id: int, request: ReportUpdate) -> ReportResponse:
        report = self.repository.get_by_id(db, report_id)
        if report is None:
            raise ResourceNotFoundError("Report not found.")
        if request.title is not None:
            report.title = request.title
        if request.content is not None:
            report.content = request.content
        report.created_by = "user"
        return ReportResponse.model_validate(self.repository.update(db, report))

    def _build_placeholder_content(self, timeline: TimelineResponse) -> str:
        memos = [item for item in timeline.items if item.type == "memo"]
        screen_observations = [
            item
            for item in timeline.items
            if item.type == "screen_ocr" and not self._is_self_service_screen_item(item)
        ]
        activity_segments = [item for item in timeline.items if item.type == "activity_segment"]
        events = [item for item in timeline.items if item.type == "event"]
        work_candidates = self._build_work_candidates(memos, screen_observations, events)
        lines = [
            f"# {timeline.date.isoformat()} 일일 작업 리포트",
            "",
            "## 요약",
            f"- 오늘 수집된 타임라인 항목은 총 {timeline.total}개입니다.",
            "- Gemini 응답을 사용할 수 없어 핵심 항목만 간단히 정리했습니다.",
            "",
            "## 작업 후보",
        ]
        if work_candidates:
            lines.extend(f"- {candidate}" for candidate in work_candidates[:8])
        else:
            lines.append("- 확인된 작업 단서가 부족합니다.")

        lines.extend(
            [
                "",
                "## 주요 메모",
            ]
        )
        if not timeline.items:
            lines.append("- 기록된 이벤트나 메모가 없습니다.")
            return "\n".join(lines)

        lines.extend(self._format_placeholder_items(memos, empty_text="주요 메모가 없습니다."))
        lines.extend(["", "## 주요 화면 관찰"])
        lines.extend(
            self._format_placeholder_items(
                screen_observations,
                empty_text="주요 화면 관찰이 없습니다.",
                formatter=self._format_screen_observation_placeholder,
            )
        )
        lines.extend(["", "## 주요 작업 환경"])
        lines.extend(
            self._format_environment_placeholder_items(
                activity_segments,
                events,
                empty_text="주요 작업 환경 정보가 없습니다.",
            )
        )
        return "\n".join(lines)

    def _format_placeholder_items(
        self,
        items,
        *,
        empty_text: str,
        limit: int = 5,
        formatter=None,
    ) -> list[str]:
        if not items:
            return [f"- {empty_text}"]
        item_formatter = formatter or self._format_default_placeholder_item
        return [item_formatter(item) for item in items[:limit]]

    def _format_default_placeholder_item(self, item) -> str:
        return f"- {self._format_kst_clock(item.timestamp)} {item.content}"

    def _format_screen_observation_placeholder(self, item) -> str:
        content = item.ai_inference or self._build_ocr_evidence_snippet(
            item.ocr_text or item.content
        )
        if not content:
            content = "화면 텍스트 수집됨"
        return f"- {self._format_kst_clock(item.timestamp)} {content}"

    def _format_environment_placeholder_items(
        self,
        activity_segments,
        events,
        *,
        empty_text: str,
        limit: int = 5,
    ) -> list[str]:
        environment_counts: dict[str, int] = {}
        for item in activity_segments:
            app_name = item.app_name or "알 수 없는 앱"
            environment_counts[app_name] = environment_counts.get(app_name, 0) + (
                item.duration_seconds or 0
            )
        if environment_counts:
            return [
                f"- {app_name}: {duration_seconds}초"
                for app_name, duration_seconds in sorted(
                    environment_counts.items(),
                    key=lambda entry: entry[1],
                    reverse=True,
                )[:limit]
            ]

        return self._format_placeholder_items(events, empty_text=empty_text, limit=limit)

    def _build_work_candidates(self, memos, screen_observations, events) -> list[str]:
        candidates: list[str] = []
        for item in memos:
            candidates.append(f"{self._format_kst_clock(item.timestamp)} 메모: {item.content}")
        for item in screen_observations:
            evidence = item.ai_inference or self._build_ocr_evidence_snippet(
                item.ocr_text or item.content
            )
            if evidence:
                candidates.append(
                    f"{self._format_kst_clock(item.timestamp)} 화면 단서: {evidence}"
                )
        for item in events:
            if item.source == "mac_active_window":
                continue
            if self._extract_work_keywords(item.content) or len(item.content.strip()) >= 12:
                candidates.append(
                    f"{self._format_kst_clock(item.timestamp)} 이벤트: {item.content}"
                )

        deduplicated: list[str] = []
        seen: set[str] = set()
        for candidate in candidates:
            key = candidate.lower()
            if key in seen:
                continue
            seen.add(key)
            deduplicated.append(candidate)
        return deduplicated

    def _build_ocr_evidence_snippet(self, text: str | None, *, limit: int = 160) -> str:
        if not text:
            return ""
        lines: list[str] = []
        seen: set[str] = set()
        for raw_line in text.splitlines():
            line = re.sub(r"\s+", " ", raw_line).strip(" -|·•\t")
            if not line or self._is_self_service_text(line) or self._is_noise_line(line):
                continue
            key = line.lower()
            if key in seen:
                continue
            seen.add(key)
            lines.append(line)
        return self._truncate(" / ".join(lines[:4]), limit) if lines else ""

    def _is_noise_line(self, text: str) -> bool:
        lowered = text.lower()
        if len(text) <= 2:
            return True
        if any(
            marker in lowered
            for marker in [
                "chatgpt can make mistakes",
                "chatgpt는 실수를 할 수",
                "nw_path_necp_check",
                "nsdebugdescription",
                "userinfo={",
                "connection invalid",
                "무엇이든 물어보세요",
                "공유된 ",
                "tb 사용",
                "order by",
            ]
        ):
            return True
        alpha_numeric_count = sum(char.isalnum() for char in text)
        return alpha_numeric_count / max(len(text), 1) < 0.35

    def _is_self_service_screen_item(self, item) -> bool:
        values = [item.app_name, item.window_title, item.content, item.ocr_text, item.ai_inference]
        combined_text = "\n".join(value for value in values if value)
        return self._is_self_service_text(combined_text)

    def _is_self_service_text(self, text: str) -> bool:
        lowered = text.lower()
        return any(
            marker in lowered
            for marker in [
                "127.0.0.1:8765",
                "localhost:8765",
                "대시보드 - 뭐함",
                "타임라인 - 뭐함",
                "리포트 - 뭐함",
                "설정 - 뭐함",
                "작업 기록 자동화 서비스",
            ]
        )

    def _extract_work_keywords(self, text: str | None) -> list[str]:
        if not text:
            return []
        lowered = text.lower()
        return [
            keyword
            for keyword in [
                "pytest",
                "ruff",
                "alembic",
                "xcodebuild",
                "quota",
                "gemini",
                "ocr",
                "timeline",
                "report",
                "pdf",
                "release",
                "package",
                "fastapi",
                "swift",
                "api",
                "migration",
            ]
            if keyword in lowered
        ]

    def _truncate(self, text: str, limit: int) -> str:
        if len(text) <= limit:
            return text
        return text[:limit].rstrip() + "..."

    def _format_kst_clock(self, value: datetime) -> str:
        return as_kst(value).strftime("%H:%M")

    def _source_range_for_kst_date(self, target_date: date) -> tuple[datetime, datetime]:
        return utc_range_for_kst_date(target_date)


def get_report_service() -> ReportService:
    return ReportService(
        repository=ReportRepository(),
        timeline_builder=get_timeline_builder(),
        summarizer=GeminiSummarizer(
            client=GeminiClient(
                api_key=settings.gemini_api_key,
                model=settings.gemini_model,
                max_output_tokens=settings.gemini_max_output_tokens,
            ),
            prompt_builder=get_prompt_builder(),
        ),
        content_cleaner=get_report_content_cleaner(),
    )

import logging
from datetime import UTC, date, datetime, time

from sqlalchemy.orm import Session

from app.ai.gemini_client import GeminiClient
from app.ai.prompt_builder import get_prompt_builder
from app.ai.report_content_cleaner import ReportContentCleaner, get_report_content_cleaner
from app.ai.summarizer import GeminiSummarizer
from app.core.config import settings
from app.core.exceptions import ResourceNotFoundError
from app.models.report import Report
from app.repositories.report_repository import ReportRepository
from app.schemas.report import DailyReportCreate, ReportListResponse, ReportResponse, ReportUpdate
from app.schemas.timeline import TimelineResponse
from app.services.timeline_builder import TimelineBuilder, get_timeline_builder

logger = logging.getLogger(__name__)


class ReportService:
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
        target_date = request.date or datetime.now(UTC).date()
        timeline = self.timeline_builder.build_for_date(db, target_date=target_date)
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
        report = Report(
            project_id=request.project_id,
            date=target_date,
            mode=request.mode,
            title=f"{target_date.isoformat()} 일일 작업 리포트",
            content=cleaned_content or self._build_placeholder_content(timeline),
            source_range_start=datetime.combine(target_date, time.min, tzinfo=UTC),
            source_range_end=datetime.combine(target_date, time.max, tzinfo=UTC),
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
        report_date = target_date or datetime.now(UTC).date()
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
        screen_observations = [item for item in timeline.items if item.type == "screen_ocr"]
        activity_segments = [item for item in timeline.items if item.type == "activity_segment"]
        events = [item for item in timeline.items if item.type == "event"]
        lines = [
            f"# {timeline.date.isoformat()} 일일 작업 리포트",
            "",
            "## 요약",
            f"- 오늘 수집된 타임라인 항목은 총 {timeline.total}개입니다.",
            "- Gemini 응답을 사용할 수 없어 핵심 항목만 간단히 정리했습니다.",
            "",
            "## 주요 메모",
        ]
        if not timeline.items:
            lines.append("- 기록된 이벤트나 메모가 없습니다.")
            return "\n".join(lines)

        lines.extend(self._format_placeholder_items(memos, empty_text="주요 메모가 없습니다."))
        lines.extend(["", "## 주요 화면 관찰"])
        lines.extend(
            self._format_placeholder_items(
                screen_observations,
                empty_text="주요 화면 관찰이 없습니다.",
            )
        )
        lines.extend(["", "## 주요 작업 환경"])
        environment_items = activity_segments or events
        lines.extend(
            self._format_placeholder_items(
                environment_items,
                empty_text="주요 작업 환경 정보가 없습니다.",
            )
        )
        return "\n".join(lines)

    def _format_placeholder_items(self, items, *, empty_text: str, limit: int = 5) -> list[str]:
        if not items:
            return [f"- {empty_text}"]
        return [f"- {item.timestamp.strftime('%H:%M')} {item.content}" for item in items[:limit]]


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

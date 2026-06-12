import logging
from datetime import UTC, date, datetime

from sqlalchemy.orm import Session

from app.ai.gemini_client import GeminiClient
from app.ai.prompt_builder import get_prompt_builder
from app.ai.report_content_cleaner import ReportContentCleaner, get_report_content_cleaner
from app.ai.summarizer import GeminiSummarizer
from app.core.config import settings
from app.core.exceptions import ResourceNotFoundError
from app.core.timezone import get_kst_day_range_as_utc, parse_date_or_today_kst
from app.models.report import Report
from app.repositories.report_repository import ReportRepository
from app.schemas.report import DailyReportCreate, ReportListResponse, ReportResponse, ReportUpdate
from app.services.report_fallback_builder import (
    ReportFallbackBuilder,
    get_report_fallback_builder,
)
from app.services.timeline_builder import TimelineBuilder, get_timeline_builder

logger = logging.getLogger(__name__)


class ReportService:
    def __init__(
        self,
        repository: ReportRepository,
        timeline_builder: TimelineBuilder,
        summarizer: GeminiSummarizer,
        content_cleaner: ReportContentCleaner | None = None,
        fallback_builder: ReportFallbackBuilder | None = None,
    ) -> None:
        self.repository = repository
        self.timeline_builder = timeline_builder
        self.summarizer = summarizer
        self.content_cleaner = content_cleaner or get_report_content_cleaner()
        self.fallback_builder = fallback_builder or get_report_fallback_builder()

    def create_daily_report(self, db: Session, request: DailyReportCreate) -> ReportResponse:
        target_date = parse_date_or_today_kst(request.date)
        timeline = self.timeline_builder.build_detail_for_kst_date(db, target_date=target_date)
        generated_content = self.summarizer.summarize_daily_report(timeline, mode=request.mode)
        cleaned_content = (
            self.content_cleaner.clean(generated_content, mode=request.mode)
            if generated_content
            else None
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
        content = cleaned_content or self.fallback_builder.build(timeline, mode=request.mode)
        created_by = "ai" if cleaned_content else "system"
        title = self._daily_report_title(target_date, mode=request.mode)
        existing_report = self.repository.get_latest_by_identity(
            db,
            target_date=target_date,
            mode=request.mode,
            project_id=request.project_id,
        )
        if existing_report is not None:
            existing_report.title = title
            existing_report.content = content
            existing_report.source_range_start = source_range_start
            existing_report.source_range_end = source_range_end
            existing_report.created_by = created_by
            existing_report.updated_at = datetime.now(UTC)
            return ReportResponse.model_validate(self.repository.update(db, existing_report))

        report = Report(
            project_id=request.project_id,
            date=target_date,
            mode=request.mode,
            title=title,
            content=content,
            source_range_start=source_range_start,
            source_range_end=source_range_end,
            created_by=created_by,
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
        self, db: Session, target_date: date | None = None, mode: str | None = None
    ) -> ReportListResponse:
        report_date = parse_date_or_today_kst(target_date)
        reports = self.repository.list(db, target_date=report_date, mode=mode, limit=1)
        return ReportListResponse(items=reports, total=len(reports))

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

    def _source_range_for_kst_date(self, target_date: date) -> tuple[datetime, datetime]:
        return get_kst_day_range_as_utc(target_date)

    def _daily_report_title(self, target_date: date, *, mode: str) -> str:
        if mode == "simple":
            return f"{target_date.isoformat()} 간단 작업 리포트"
        return f"{target_date.isoformat()} 일일 작업 리포트"


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
        fallback_builder=get_report_fallback_builder(),
    )

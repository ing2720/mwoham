import logging
from datetime import UTC, date, datetime
from time import perf_counter

from sqlalchemy.orm import Session

from app.ai.gemini_client import GeminiClient
from app.ai.openai_client import OpenAIClient
from app.ai.prompt_builder import get_prompt_builder
from app.ai.provider import AIProvider, resolve_ai_provider_config
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
        started_at = perf_counter()
        generated_content = self.summarizer.summarize_daily_report(timeline, mode=request.mode)
        ai_latency_ms = getattr(self.summarizer, "last_latency_ms", None)
        cleaned_content = (
            self.content_cleaner.clean(generated_content, mode=request.mode)
            if generated_content
            else None
        )
        fallback_reason = self._fallback_reason(cleaned_content)
        if cleaned_content is None:
            logger.warning(
                "Daily report is falling back: date=%s reason=%s finish_reason=%s "
                "was_truncated=%s ai_latency_ms=%s",
                target_date.isoformat(),
                fallback_reason,
                getattr(self.summarizer, "last_finish_reason", None),
                getattr(self.summarizer, "last_was_truncated", False),
                ai_latency_ms,
            )
        source_range_start, source_range_end = self._source_range_for_kst_date(target_date)
        content = cleaned_content or self.fallback_builder.build(timeline, mode=request.mode)
        created_by = "ai" if cleaned_content else "fallback"
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
            saved = self.repository.update(db, existing_report)
            response = self._report_response(saved, fallback_reason=fallback_reason)
            logger.info(
                "Daily report generated: date=%s mode=%s created_by=%s total_latency_ms=%s "
                "ai_latency_ms=%s fallback_reason=%s updated_existing=true",
                target_date.isoformat(),
                request.mode,
                response.created_by,
                int((perf_counter() - started_at) * 1000),
                ai_latency_ms,
                response.fallback_reason,
            )
            return response

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
        saved = self.repository.create(db, report)
        response = self._report_response(saved, fallback_reason=fallback_reason)
        logger.info(
            "Daily report generated: date=%s mode=%s created_by=%s total_latency_ms=%s "
            "ai_latency_ms=%s fallback_reason=%s updated_existing=false",
            target_date.isoformat(),
            request.mode,
            response.created_by,
            int((perf_counter() - started_at) * 1000),
            ai_latency_ms,
            response.fallback_reason,
        )
        return response

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

    def _fallback_reason(self, cleaned_content: str | None) -> str | None:
        if cleaned_content:
            return None
        reason = getattr(self.summarizer, "last_error_reason", None)
        if reason:
            return reason
        if getattr(self.summarizer, "last_was_truncated", False):
            return "truncated_response"
        if getattr(self.summarizer, "last_finish_reason", None):
            return "invalid_response"
        return "ai_unavailable"

    def _report_response(
        self,
        report: Report,
        *,
        fallback_reason: str | None = None,
    ) -> ReportResponse:
        response = ReportResponse.model_validate(report)
        if response.created_by == "fallback" and fallback_reason:
            return response.model_copy(update={"fallback_reason": fallback_reason})
        return response


def get_report_service() -> ReportService:
    provider_config = resolve_ai_provider_config(settings)
    if provider_config.provider == AIProvider.OPENAI:
        client = OpenAIClient(
            api_key=provider_config.api_key,
            model=provider_config.model,
            max_output_tokens=settings.gemini_max_output_tokens,
            timeout_seconds=settings.ai_report_timeout_seconds,
        )
    else:
        client = GeminiClient(
            api_key=provider_config.api_key,
            model=provider_config.model,
            max_output_tokens=settings.gemini_max_output_tokens,
            timeout_seconds=settings.ai_report_timeout_seconds,
        )
    return ReportService(
        repository=ReportRepository(),
        timeline_builder=get_timeline_builder(),
        summarizer=GeminiSummarizer(
            client=client,
            prompt_builder=get_prompt_builder(),
        ),
        content_cleaner=get_report_content_cleaner(),
        fallback_builder=get_report_fallback_builder(),
    )

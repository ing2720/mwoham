import logging
from time import perf_counter

from app.ai.prompt_builder import PromptBuilder
from app.schemas.timeline import TimelineResponse

logger = logging.getLogger(__name__)


class GeminiSummarizer:
    def __init__(self, client, prompt_builder: PromptBuilder) -> None:
        self.client = client
        self.prompt_builder = prompt_builder
        self.last_finish_reason: str | None = None
        self.last_was_truncated = False
        self.last_error_reason: str | None = None
        self.last_latency_ms: int | None = None

    def summarize_daily_report(
        self, timeline: TimelineResponse, *, mode: str = "detailed"
    ) -> str | None:
        self.last_finish_reason = None
        self.last_was_truncated = False
        self.last_error_reason = None
        self.last_latency_ms = None
        if not self.client.is_configured:
            self.last_error_reason = "api_key_missing"
            return None
        if mode == "simple":
            prompt = self.prompt_builder.build_simple_daily_report_prompt(timeline)
        else:
            prompt = self.prompt_builder.build_daily_report_prompt(timeline)
        started_at = perf_counter()
        result = self.client.generate_text_result(prompt)
        self.last_latency_ms = int((perf_counter() - started_at) * 1000)
        self.last_finish_reason = result.finish_reason
        self.last_was_truncated = result.was_truncated
        self.last_error_reason = result.error_reason
        logger.info(
            "AI report generation finished: client=%s model=%s mode=%s latency_ms=%s "
            "success=%s reason=%s finish_reason=%s truncated=%s prompt_chars=%s",
            self.client.__class__.__name__,
            getattr(self.client, "model", "-"),
            mode,
            self.last_latency_ms,
            result.text is not None,
            result.error_reason,
            result.finish_reason,
            result.was_truncated,
            len(prompt),
        )
        return result.text

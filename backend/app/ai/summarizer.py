from app.ai.gemini_client import GeminiClient
from app.ai.prompt_builder import PromptBuilder
from app.schemas.timeline import TimelineResponse


class GeminiSummarizer:
    def __init__(self, client: GeminiClient, prompt_builder: PromptBuilder) -> None:
        self.client = client
        self.prompt_builder = prompt_builder
        self.last_finish_reason: str | None = None
        self.last_was_truncated = False

    def summarize_daily_report(self, timeline: TimelineResponse) -> str | None:
        self.last_finish_reason = None
        self.last_was_truncated = False
        if not self.client.is_configured:
            return None
        prompt = self.prompt_builder.build_daily_report_prompt(timeline)
        result = self.client.generate_text_result(prompt)
        self.last_finish_reason = result.finish_reason
        self.last_was_truncated = result.was_truncated
        return result.text

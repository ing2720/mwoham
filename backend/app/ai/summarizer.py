from app.ai.gemini_client import GeminiClient
from app.ai.prompt_builder import PromptBuilder
from app.schemas.timeline import TimelineResponse


class GeminiSummarizer:
    def __init__(self, client: GeminiClient, prompt_builder: PromptBuilder) -> None:
        self.client = client
        self.prompt_builder = prompt_builder

    def summarize_daily_report(self, timeline: TimelineResponse) -> str | None:
        if not self.client.is_configured:
            return None
        prompt = self.prompt_builder.build_daily_report_prompt(timeline)
        return self.client.generate_text(prompt)

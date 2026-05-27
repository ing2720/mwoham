from datetime import UTC, date, datetime

from app.ai.gemini_client import GeminiClient
from app.ai.prompt_builder import PromptBuilder
from app.ai.summarizer import GeminiSummarizer
from app.schemas.timeline import TimelineItem, TimelineResponse
from app.services.privacy_filter import PrivacyFilter


def test_privacy_filter_masks_secret_patterns() -> None:
    text = "api_key=abc123 token: xyz password='pw123' Bearer ey.secret"

    masked = PrivacyFilter().mask(text)

    assert "abc123" not in masked
    assert "xyz" not in masked
    assert "pw123" not in masked
    assert "ey.secret" not in masked
    assert "[MASKED]" in masked


def test_prompt_builder_uses_only_compressed_masked_timeline() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="event",
                id=1,
                timestamp=datetime(2026, 5, 26, 9, 0, tzinfo=UTC),
                source="terminal",
                app_name="Terminal",
                content="deploy token=secret-token",
                session_id=1,
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "원본 화면, 음성, 스크린샷, 오디오 파일은 포함하지 않았습니다." in prompt
    assert "secret-token" not in prompt
    assert "[MASKED]" in prompt
    assert "deploy" in prompt


def test_prompt_builder_includes_screen_ocr_text_and_keywords() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="screen_ocr",
                id=1,
                timestamp=datetime(2026, 5, 26, 10, 0, tzinfo=UTC),
                app_name="Chrome",
                content="401 Unauthorized api_key=secret",
                detected_keywords=["401", "Authorization"],
                ai_inference="인증 설정 문제 가능성",
                session_id=1,
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "type=screen_ocr" in prompt
    assert "401 Unauthorized" in prompt
    assert "Authorization" in prompt
    assert "인증 설정 문제 가능성" in prompt
    assert "api_key=secret" not in prompt


def test_gemini_client_returns_none_without_api_key() -> None:
    client = GeminiClient(api_key=None, model="gemini-2.5-flash")

    assert client.generate_text("hello") is None


def test_summarizer_does_not_call_unconfigured_client() -> None:
    class UnconfiguredClient:
        is_configured = False

        def generate_text(self, prompt: str) -> str:
            raise AssertionError("Gemini should not be called")

    timeline = TimelineResponse(date=date(2026, 5, 26), total=0, items=[])
    summarizer = GeminiSummarizer(
        client=UnconfiguredClient(),
        prompt_builder=PromptBuilder(privacy_filter=PrivacyFilter()),
    )

    assert summarizer.summarize_daily_report(timeline) is None

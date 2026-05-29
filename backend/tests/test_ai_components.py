from datetime import UTC, date, datetime

from app.ai.gemini_client import GeminiClient
from app.ai.prompt_builder import PromptBuilder
from app.ai.report_content_cleaner import ReportContentCleaner
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
    assert "## 오늘 한 일 요약" in prompt
    assert "## 시간대별 작업 흐름" in prompt
    assert "앱 이름은 작업 도구나 환경 정보로만 참고하세요." in prompt
    assert "'Codex 앱에서', 'Chrome 앱에서', 'VSCode 앱에서'" in prompt
    assert "secret-token" not in prompt
    assert "[MASKED]" in prompt
    assert "deploy" in prompt
    assert "EVENT |" in prompt


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

    assert "SCREEN_OCR |" in prompt
    assert "ocr_text=401 Unauthorized" in prompt
    assert "401 Unauthorized" in prompt
    assert "Authorization" in prompt
    assert "인증 설정 문제 가능성" in prompt
    assert "api_key=secret" not in prompt


def test_prompt_builder_includes_activity_segment_duration() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="activity_segment",
                id=1,
                timestamp=datetime(2026, 5, 26, 10, 0, tzinfo=UTC),
                ended_at=datetime(2026, 5, 26, 10, 15, tzinfo=UTC),
                app_name="Chrome",
                window_title="PR 작성",
                source="mac_active_window",
                content="Chrome / PR 작성",
                duration_seconds=900,
                sample_count=30,
                session_id=1,
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "ACTIVITY_SEGMENT |" in prompt
    assert "duration_seconds=900" in prompt
    assert "window=PR 작성" in prompt


def test_prompt_builder_includes_meeting_transcripts() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="transcript",
                id=1,
                timestamp=datetime(2026, 5, 26, 11, 0, tzinfo=UTC),
                content="배포 전 리포트 생성을 확인합니다.",
                meeting_id=7,
                speaker="mentor",
                confidence=0.9,
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "TRANSCRIPT |" in prompt
    assert "speaker=mentor" in prompt
    assert "meeting_id=7" in prompt
    assert "배포 전 리포트 생성을 확인합니다." in prompt


def test_prompt_builder_handles_empty_timeline_concisely() -> None:
    timeline = TimelineResponse(date=date(2026, 5, 26), total=0, items=[])

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "EMPTY: 기록된 작업이 없습니다." in prompt
    assert "빈 타임라인이면 '기록된 작업이 없습니다.' 한 문장만 반환하세요." in prompt


def test_prompt_builder_distinguishes_event_memo_meeting_types() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=3,
        items=[
            TimelineItem(
                type="event",
                id=1,
                timestamp=datetime(2026, 5, 26, 9, 0, tzinfo=UTC),
                source="window",
                app_name="Cursor",
                window_title="backend",
                content="프롬프트 개선",
            ),
            TimelineItem(
                type="memo",
                id=2,
                timestamp=datetime(2026, 5, 26, 10, 0, tzinfo=UTC),
                content="결정사항은 별도 섹션으로 정리",
                linked_type="report",
                linked_id=1,
            ),
            TimelineItem(
                type="meeting",
                id=3,
                timestamp=datetime(2026, 5, 26, 11, 0, tzinfo=UTC),
                content="회의 시작: 리포트 품질 개선",
                meeting_id=3,
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "EVENT |" in prompt
    assert "MEMO |" in prompt
    assert "MEETING |" in prompt
    assert "회의/메모에서 나온 결정사항" in prompt


def test_gemini_client_returns_none_without_api_key() -> None:
    client = GeminiClient(api_key=None, model="gemini-2.5-flash")

    assert client.generate_text("hello") is None


def test_gemini_client_parses_finish_reason() -> None:
    payload = {
        "candidates": [
            {
                "finishReason": "MAX_TOKENS",
                "content": {"parts": [{"text": "잘린 리포트"}]},
            }
        ]
    }

    result = GeminiClient(api_key="token", model="gemini-2.5-flash")._extract_result(payload)

    assert result.text == "잘린 리포트"
    assert result.finish_reason == "MAX_TOKENS"
    assert result.was_truncated is True


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


def test_report_content_cleaner_removes_standalone_bullets() -> None:
    content = "## 시간대별 작업 흐름\n- 테스트 실패\n*\n-\n•\n"

    cleaned = ReportContentCleaner().clean(content)

    assert "\n*\n" not in cleaned
    assert "\n-\n" not in cleaned
    assert "\n•\n" not in cleaned
    assert "- 테스트 실패" in cleaned


def test_report_content_cleaner_fills_missing_sections() -> None:
    content = "## 오늘 한 일 요약\n테스트를 진행했습니다."

    cleaned = ReportContentCleaner().clean(content)

    assert "## 오늘 한 일 요약\n테스트를 진행했습니다." in cleaned
    assert "## 시간대별 작업 흐름\n확인된 내용 없음." in cleaned
    assert "## 주요 트러블슈팅\n확인된 내용 없음." in cleaned
    assert "## 회의/메모에서 나온 결정사항\n확인된 내용 없음." in cleaned
    assert "## 다음 작업 후보\n확인된 내용 없음." in cleaned


def test_report_content_cleaner_preserves_normal_markdown() -> None:
    content = "\n\n".join(
        [
            "## 오늘 한 일 요약\n- API 구현",
            "## 시간대별 작업 흐름\n- 오전: 구현",
            "## 주요 트러블슈팅\n- 확인된 내용 없음.",
            "## 회의/메모에서 나온 결정사항\n- 결정사항 없음.",
            "## 다음 작업 후보\n- Swift 연동",
        ]
    )

    cleaned = ReportContentCleaner().clean(content)

    assert cleaned == content

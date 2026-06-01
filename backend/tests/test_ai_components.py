from datetime import UTC, date, datetime

import httpx
import pytest

from app.ai.gemini_client import GeminiClient
from app.ai.prompt_builder import PromptBuilder
from app.ai.report_content_cleaner import ReportContentCleaner
from app.ai.summarizer import GeminiSummarizer
from app.schemas.timeline import TimelineItem, TimelineResponse
from app.services.privacy_filter import PrivacyFilter
from app.services.screen_observation_summarizer import (
    SAFE_UNCLEAR_INFERENCE,
    ScreenObservationSummarizer,
)


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
    assert "앱 이름을 작업 내용으로 착각하지 마세요." in prompt


def test_prompt_builder_prioritizes_screen_ocr_inference_and_keywords() -> None:
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
                ai_inference="사용자는 인증 설정 문제를 확인하고 있습니다.",
                session_id=1,
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "SCREEN_OCR |" in prompt
    assert "inference=사용자는 인증 설정 문제를 확인하고 있습니다." in prompt
    assert "ocr_excerpt=401 Unauthorized" in prompt
    assert "401 Unauthorized" in prompt
    assert "Authorization" in prompt
    assert "사용자는 인증 설정 문제를 확인하고 있습니다." in prompt
    assert "api_key=secret" not in prompt


def test_prompt_builder_summarizes_activity_segments_as_auxiliary_context() -> None:
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

    assert "ACTIVITY_SEGMENT |" not in prompt
    assert "ACTIVITY_ENVIRONMENT_SUMMARY |" in prompt
    assert "보조 작업 컨텍스트" in prompt
    assert "Chrome / PR 작성 900초" in prompt


def test_prompt_builder_groups_concrete_work_evidence_by_time() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=3,
        items=[
            TimelineItem(
                type="memo",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 31, tzinfo=UTC),
                content="Gemini quota 절약 정책 적용",
            ),
            TimelineItem(
                type="screen_ocr",
                id=2,
                timestamp=datetime(2026, 5, 26, 1, 35, tzinfo=UTC),
                app_name="PyCharm",
                content="화면 텍스트 수집됨",
                ocr_text="\n".join(
                    [
                        "ENABLE_SCREEN_OBSERVATION_AI_INFERENCE=false",
                        "SCREEN_AI_MIN_INTERVAL_SECONDS=300",
                        "pytest tests/test_report_api.py",
                        "ChatGPT can make mistakes. Check important info.",
                    ]
                ),
                detected_keywords=["pytest", "Gemini", "quota"],
            ),
            TimelineItem(
                type="event",
                id=3,
                timestamp=datetime(2026, 5, 26, 2, 3, tzinfo=UTC),
                source="terminal",
                content="xcodebuild Release package tester bundle",
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "PRIORITY_MEMOS:" in prompt
    assert "WORK_EVIDENCE_BY_TIME:" in prompt
    assert "WORK_BLOCK | time_range=01:30~02:00" in prompt
    assert "Gemini quota 절약 정책 적용" in prompt
    assert "ENABLE_SCREEN_OBSERVATION_AI_INFERENCE=false" in prompt
    assert "pytest tests/test_report_api.py" in prompt
    assert "ChatGPT can make mistakes" not in prompt
    assert "xcodebuild Release package tester bundle" in prompt


def test_prompt_builder_excludes_self_service_screen_ocr() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="screen_ocr",
                id=1,
                timestamp=datetime(2026, 5, 26, 10, 0, tzinfo=UTC),
                app_name="Google Chrome",
                window_title="대시보드 - 뭐함",
                content="화면 텍스트 수집됨",
                ocr_text="127.0.0.1:8765 작업 기록 자동화 서비스",
                session_id=1,
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "SCREEN_OCR |" not in prompt
    assert "127.0.0.1:8765" not in prompt


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
    assert client.generate_text_result("hello").error_reason == "api_key_missing"


def test_gemini_client_generate_text_keeps_existing_text_interface(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_post(*args, **kwargs):
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {"parts": [{"text": "정상 응답입니다."}]},
                    }
                ]
            },
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)

    client = GeminiClient(api_key="test-api-key", model="gemini-2.5-flash")

    assert client.generate_text("hello") == "정상 응답입니다."


def test_gemini_client_handles_http_error_response(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_post(*args, **kwargs):
        return httpx.Response(
            400,
            json={"error": {"status": "INVALID_ARGUMENT", "message": "bad model"}},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)

    result = GeminiClient(api_key="test-api-key", model="bad-model").generate_text_result("hello")

    assert result.text is None
    assert result.error_reason == "http_status_error"
    assert result.status_code == 400
    assert "INVALID_ARGUMENT" in (result.raw_error or "")


def test_gemini_client_classifies_quota_exceeded_response(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_post(*args, **kwargs):
        return httpx.Response(
            429,
            json={"error": {"status": "RESOURCE_EXHAUSTED", "message": "quota exceeded"}},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)

    result = GeminiClient(api_key="test-api-key", model="gemini-2.5-flash").generate_text_result(
        "hello"
    )

    assert result.text is None
    assert result.error_reason == "quota_exceeded"
    assert result.status_code == 429


def test_gemini_client_handles_json_parse_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_post(*args, **kwargs):
        return httpx.Response(
            200,
            text="not-json",
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)

    result = GeminiClient(api_key="test-api-key", model="gemini-2.5-flash").generate_text_result(
        "hello"
    )

    assert result.text is None
    assert result.error_reason == "json_parse_error"
    assert result.status_code == 200


def test_gemini_client_handles_missing_candidates() -> None:
    result = GeminiClient(api_key="token", model="gemini-2.5-flash")._extract_result({})

    assert result.text is None
    assert result.error_reason == "candidates_missing"


def test_gemini_client_handles_missing_parts() -> None:
    payload = {"candidates": [{"finishReason": "STOP", "content": {}}]}

    result = GeminiClient(api_key="token", model="gemini-2.5-flash")._extract_result(payload)

    assert result.text is None
    assert result.error_reason == "parts_missing"


def test_gemini_client_handles_missing_text() -> None:
    payload = {"candidates": [{"finishReason": "STOP", "content": {"parts": [{}]}}]}

    result = GeminiClient(api_key="token", model="gemini-2.5-flash")._extract_result(payload)

    assert result.text is None
    assert result.error_reason == "text_missing"


def test_gemini_client_handles_safety_block() -> None:
    payload = {"promptFeedback": {"blockReason": "SAFETY"}}

    result = GeminiClient(api_key="token", model="gemini-2.5-flash")._extract_result(payload)

    assert result.text is None
    assert result.error_reason == "safety_block"
    assert "SAFETY" in (result.raw_error or "")


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
    assert result.error_reason == "non_stop_finish_reason"
    assert result.was_truncated is True


def test_screen_observation_summarizer_generates_ai_inference_from_ocr_text() -> None:
    class ConfiguredClient:
        is_configured = True

        def __init__(self) -> None:
            self.prompt = ""

        def generate_text(self, prompt: str) -> str:
            self.prompt = prompt
            return "FastAPI 인증 오류를 확인하며 API 요청 헤더 문제를 디버깅하고 있습니다."

    client = ConfiguredClient()
    summarizer = ScreenObservationSummarizer(client=client, privacy_filter=PrivacyFilter())

    inference = summarizer.summarize(
        ocr_text="401 Unauthorized error while calling FastAPI endpoint",
        app_name="Chrome",
        window_title="Swagger UI",
    )

    assert inference == "FastAPI 인증 오류를 확인하며 API 요청 헤더 문제를 디버깅하고 있습니다."
    assert "401 Unauthorized error" in client.prompt
    assert "app_name: Chrome" in client.prompt
    assert "window_title: Swagger UI" in client.prompt


def test_screen_observation_summarizer_falls_back_when_gemini_fails() -> None:
    class FailingClient:
        is_configured = True

        def generate_text(self, prompt: str) -> None:
            return None

    summarizer = ScreenObservationSummarizer(client=FailingClient(), privacy_filter=PrivacyFilter())

    inference = summarizer.summarize(
        ocr_text="pytest failure exception traceback in backend tests",
        app_name="PyCharm",
        window_title="test_api_flows.py",
    )

    assert inference is not None
    assert inference == "사용자는 PyCharm에서 프로젝트 코드 변경 내용을 확인하고 있습니다."
    assert "pytest failure exception" not in inference


def test_screen_observation_summarizer_handles_short_ocr_text_safely() -> None:
    class ConfiguredClient:
        is_configured = True

        def generate_text(self, prompt: str) -> str:
            raise AssertionError("Gemini should not be called for short OCR text.")

    summarizer = ScreenObservationSummarizer(
        client=ConfiguredClient(),
        privacy_filter=PrivacyFilter(),
    )

    assert (
        summarizer.summarize(ocr_text="OK", app_name="Chrome", window_title=None)
        == SAFE_UNCLEAR_INFERENCE
    )


def test_screen_observation_summarizer_falls_back_for_truncated_gemini_response() -> None:
    class TruncatedClient:
        is_configured = True

        def generate_text(self, prompt: str) -> str:
            return "사용자는 Google Chrome 브라우저에서 `127.0.0.1"

    summarizer = ScreenObservationSummarizer(
        client=TruncatedClient(),
        privacy_filter=PrivacyFilter(),
    )

    inference = summarizer.summarize(
        ocr_text="Mwoham dashboard recording status screen observation timeline report",
        app_name="Google Chrome",
        window_title="127.0.0.1:8765/dashboard",
    )

    assert (
        inference
        == "사용자는 Google Chrome에서 작업 기록 자동화 서비스 화면을 확인하고 있습니다."
    )
    assert "127.0.0.1" not in inference
    assert inference.endswith("있습니다.")


def test_screen_observation_summarizer_falls_back_for_open_quote_response() -> None:
    class OpenQuoteClient:
        is_configured = True

        def generate_text(self, prompt: str) -> str:
            return "사용자는 Google Chrome 브라우저에서 'OZ코딩스쿨 초격차 17기"

    summarizer = ScreenObservationSummarizer(
        client=OpenQuoteClient(),
        privacy_filter=PrivacyFilter(),
    )

    inference = summarizer.summarize(
        ocr_text="course page lesson curriculum assignment browser tab progress status",
        app_name="Google Chrome",
        window_title="OZ코딩스쿨 초격차 17기",
    )

    assert inference == "사용자는 Google Chrome에서 웹 화면의 작업 내용을 확인하고 있습니다."
    assert "OZ코딩스쿨 초격차 17기" not in inference
    assert inference.endswith("있습니다.")


def test_screen_observation_summarizer_keeps_normal_complete_gemini_response() -> None:
    class CompleteClient:
        is_configured = True

        def generate_text(self, prompt: str) -> str:
            return "사용자는 PyCharm에서 FastAPI 테스트 실패 원인을 확인하고 있습니다."

    summarizer = ScreenObservationSummarizer(
        client=CompleteClient(),
        privacy_filter=PrivacyFilter(),
    )

    inference = summarizer.summarize(
        ocr_text="pytest failed assertion error FastAPI endpoint response mismatch",
        app_name="PyCharm",
        window_title="test_api_flows.py",
    )

    assert inference == "사용자는 PyCharm에서 FastAPI 테스트 실패 원인을 확인하고 있습니다."


def test_screen_observation_summarizer_handles_noisy_mixed_ocr_safely() -> None:
    class ConfiguredClient:
        is_configured = True

        def generate_text(self, prompt: str) -> str:
            raise AssertionError("Gemini should not be called for noisy mixed OCR text.")

    summarizer = ScreenObservationSummarizer(
        client=ConfiguredClient(),
        privacy_filter=PrivacyFilter(),
    )

    inference = summarizer.summarize(
        ocr_text="\n".join(
            [
                "ChatGPT can make mistakes. Check important info.",
                "nw_path_necp_check failed",
                "UserInfo={NSDebugDescription=Connection invalid}",
                "Google Chrome Slack Xcode PyCharm Finder Terminal",
                "Message ChatGPT",
            ]
        ),
        app_name="Google Chrome",
        window_title="ChatGPT",
    )

    assert inference == "사용자는 Google Chrome에서 웹 화면의 작업 내용을 확인하고 있습니다."


def test_prompt_builder_replaces_truncated_screen_inference() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="screen_ocr",
                id=1,
                timestamp=datetime(2026, 5, 26, 10, 0, tzinfo=UTC),
                app_name="Chrome",
                content="사용자는 Google Chrome 브라우저에서 `127.0.0.1",
                ocr_text="127.0.0.1 dashboard status recording",
                ai_inference="사용자는 Google Chrome 브라우저에서 `127.0.0.1",
                session_id=1,
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "inference=화면 내용만으로는 구체적인 작업을 판단하기 어렵습니다." in prompt
    assert "inference=사용자는 Google Chrome 브라우저에서 `127.0.0.1" not in prompt


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

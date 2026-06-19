import subprocess
from datetime import UTC, date, datetime
from pathlib import Path

import httpx
import pytest

from app.ai.gemini_client import GeminiClient
from app.ai.git_diff_context import GitDiffContext, GitDiffContextBuilder
from app.ai.openai_client import OpenAIClient
from app.ai.prompt_builder import PromptBuilder
from app.ai.provider import AIProvider, resolve_ai_provider_config
from app.ai.report_content_cleaner import ReportContentCleaner
from app.ai.summarizer import GeminiSummarizer
from app.core.config import Settings, settings
from app.schemas.timeline import TimelineItem, TimelineResponse
from app.services.privacy_filter import PrivacyFilter
from app.services.report_service import get_report_service
from app.services.screen_observation_summarizer import (
    SAFE_UNCLEAR_INFERENCE,
    ScreenObservationSummarizer,
)


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repo),
            "-c",
            "user.email=test@example.com",
            "-c",
            "user.name=Test User",
            *args,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout


def _init_git_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init")
    return repo


def _timeline_with_repo(repo: Path) -> TimelineResponse:
    return TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                repo_path=str(repo),
                branch="main",
                content="Git 변경 감지",
                details_json={
                    "changed_files": ["backend/app/service.py"],
                    "diff_summary": [
                        {
                            "file": "backend/app/service.py",
                            "insertions": 1,
                            "deletions": 0,
                        }
                    ],
                },
            )
        ],
    )


def _prompt_section(prompt: str, header: str, next_header: str) -> str:
    start = prompt.index(header)
    end = prompt.index(next_header, start)
    return prompt[start:end]


class _StaticGitDiffContextBuilder:
    def __init__(self, context: GitDiffContext | None) -> None:
        self.context = context

    def build_for_timeline(self, timeline: TimelineResponse) -> GitDiffContext | None:
        return self.context


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

    builder = PromptBuilder(privacy_filter=PrivacyFilter())
    prompt = builder.build_daily_report_prompt(timeline)

    assert "원본 화면, 음성, 스크린샷, 오디오 파일은 포함하지 않았습니다." in prompt
    assert "## 오늘 한 일 요약" in prompt
    assert "## 시간대별 작업 흐름" in prompt
    assert "앱 이름은 작업 도구나 환경 정보로만 참고하세요." in prompt
    assert "앱 이름은 업무 주체가 아니라 작업 환경 보조 정보로만 다루고" in prompt
    assert "secret-token" not in prompt
    assert "[MASKED]" in prompt
    assert "deploy" in prompt
    assert "EVENT |" in prompt
    assert "실제 작업 내용, 결정사항, 문제 해결 과정을 중심으로 요약하세요." in prompt


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

    builder = PromptBuilder(privacy_filter=PrivacyFilter())
    prompt = builder.build_daily_report_prompt(timeline)

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

    builder = PromptBuilder(privacy_filter=PrivacyFilter())
    prompt = builder.build_daily_report_prompt(timeline)

    assert "ACTIVITY_SEGMENT |" not in prompt
    assert "ACTIVITY_ENVIRONMENT_SUMMARY |" in prompt
    assert "보조 정보" in prompt
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
    assert "WORK_BLOCK | time_range=10:30~11:00" in prompt
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
                content="회의 전사 수집됨: 배포 전 리포트 생성을 확인합니다.",
                meeting_id=7,
                speaker="mentor",
                confidence=0.9,
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "MEETING_MEMO_CONTEXT:" in prompt
    assert "MEETING_TRANSCRIPT | meeting_id=7" in prompt
    assert "category=discussion" in prompt
    assert "PRIORITY_MEETING_TRANSCRIPTS:" in prompt
    assert "TRANSCRIPT_GROUP |" in prompt
    assert "speaker=mentor" in prompt
    assert "meeting_id=7" in prompt
    assert "배포 전 리포트 생성을 확인합니다." in prompt
    assert "text=회의 전사 수집됨" not in prompt
    assert "회의 전사는 결정사항, 논의사항, 후속작업 후보로 나눠 반영" in prompt
    assert "근거 없이 결정사항을 만들지 마세요." in prompt
    assert "source 값은 근거로만 참고하고 최종 리포트에 과하게 나열하지 마세요." in prompt


def test_prompt_builder_groups_meeting_transcripts_and_skips_short_fragments() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=3,
        items=[
            TimelineItem(
                type="transcript",
                id=1,
                timestamp=datetime(2026, 5, 26, 11, 0, tzinfo=UTC),
                content="회의 전사 수집됨: 테스트",
                meeting_id=7,
            ),
            TimelineItem(
                type="transcript",
                id=2,
                timestamp=datetime(2026, 5, 26, 11, 1, tzinfo=UTC),
                content="회의 전사 수집됨: Apple Speech 회의 전사 저장 품질을 점검했습니다.",
                meeting_id=7,
            ),
            TimelineItem(
                type="transcript",
                id=3,
                timestamp=datetime(2026, 5, 26, 11, 2, tzinfo=UTC),
                content="회의 전사 수집됨: 다음 작업은 시스템 오디오 캡처 가능성 검토입니다.",
                meeting_id=7,
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert prompt.count("TRANSCRIPT_GROUP | meeting_id=7") == 1
    assert prompt.count("MEETING_TRANSCRIPT | meeting_id=7") == 2
    assert "Apple Speech 회의 전사 저장 품질을 점검했습니다." in prompt
    assert "다음 작업은 시스템 오디오 캡처 가능성 검토입니다." in prompt
    assert "text=테스트" not in prompt
    assert "TRANSCRIPT_NOISE_SUMMARY" in prompt
    assert "short=1" in prompt


def test_prompt_builder_adds_meeting_memo_context_and_prioritizes_manual_memo() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=3,
        items=[
            TimelineItem(
                type="memo",
                id=1,
                timestamp=datetime(2026, 5, 26, 10, 0, tzinfo=UTC),
                content="결정: 회의 전사 품질 개선은 detailed report 중심으로 진행",
            ),
            TimelineItem(
                type="transcript",
                id=2,
                timestamp=datetime(2026, 5, 26, 10, 2, tzinfo=UTC),
                content="회의 전사 수집됨: 회의 전사 품질 개선 방향을 논의했습니다.",
                meeting_id=3,
                source="apple_speech_microphone",
            ),
            TimelineItem(
                type="transcript",
                id=3,
                timestamp=datetime(2026, 5, 26, 10, 3, tzinfo=UTC),
                content="회의 전사 수집됨: 다음 작업은 memo context 검증입니다.",
                meeting_id=3,
                source="apple_speech_full_meeting",
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)
    context = _prompt_section(prompt, "MEETING_MEMO_CONTEXT:", "PRIORITY_MEMOS:")

    assert "source_policy=manual_memo_is_user_direct_evidence" in context
    assert "MANUAL_MEMO |" in context
    assert "confidence=user_direct" in context
    assert "category=decision" in context
    assert "결정: 회의 전사 품질 개선은 detailed report 중심으로 진행" in context
    assert "MEETING_TRANSCRIPT | meeting_id=3" in context
    assert "category=discussion" in context
    assert "category=follow_up_candidate" in context
    assert "MEETING_MEMO_CONTEXT는 회의/메모 근거입니다." in prompt
    assert "manual memo는 사용자 직접 입력으로 전사보다 우선하세요." in prompt
    assert "WORK_EVIDENCE_BY_TIME:" not in prompt


def test_prompt_builder_deduplicates_multi_source_transcripts_in_meeting_context() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=3,
        items=[
            TimelineItem(
                type="transcript",
                id=1,
                timestamp=datetime(2026, 5, 26, 10, 0, tzinfo=UTC),
                content="회의 전사 수집됨: 리포트 입력에서 회의와 메모 근거를 분리하기로 했습니다.",
                meeting_id=5,
                source="apple_speech_microphone",
            ),
            TimelineItem(
                type="transcript",
                id=2,
                timestamp=datetime(2026, 5, 26, 10, 1, tzinfo=UTC),
                content="회의 전사 수집됨: 리포트 입력에서 회의와 메모 근거를 분리하기로 했습니다.",
                meeting_id=5,
                source="apple_speech_system_audio",
            ),
            TimelineItem(
                type="transcript",
                id=3,
                timestamp=datetime(2026, 5, 26, 10, 2, tzinfo=UTC),
                content="회의 전사 수집됨: 네 네 네 네",
                meeting_id=5,
                source="apple_speech_full_meeting",
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)
    context = _prompt_section(prompt, "MEETING_MEMO_CONTEXT:", "PRIORITY_MEETING_TRANSCRIPTS:")

    assert context.count("리포트 입력에서 회의와 메모 근거를 분리하기로 했습니다.") == 1
    assert "TRANSCRIPT_NOISE_SUMMARY" in context
    assert "duplicate=1" in context
    assert "noise=1" in context
    assert "apple_speech_microphone" not in context
    assert "apple_speech_system_audio" not in context
    assert "apple_speech_full_meeting" not in context


def test_prompt_builder_formats_local_whisper_full_meeting_for_report_context() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="transcript",
                id=1,
                timestamp=datetime(2026, 5, 26, 10, 0, tzinfo=UTC),
                content=(
                    "회의 전사 수집됨:\n"
                    "[00:00 system_audio] 카카오 소셜로그인은 안 되죠?\n"
                    "[00:15 microphone] 프리사인 URL 머지 검토 필요합니다.\n"
                    "[00:30 system_audio] 쉬는 시간입니다.\n"
                    "[00:45 microphone] 자막 제공 및 광고를 포함하고 있습니다."
                ),
                meeting_id=8,
                source="local_whisper_full_meeting",
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)
    context = _prompt_section(prompt, "MEETING_MEMO_CONTEXT:", "PRIORITY_MEETING_TRANSCRIPTS:")

    assert "source_type=local_whisper_full_meeting" in context
    assert "sources=microphone,system_audio" in context
    assert "category=discussion" in context
    assert "category=follow_up_candidate" in context
    assert "카카오 소셜로그인은 안 되죠?" in context
    assert "프리사인 URL 머지 검토 필요합니다." in context
    assert "[00:00 system_audio]" not in context
    assert "[00:15 microphone]" not in context
    assert "쉬는 시간입니다" not in context
    assert "자막 제공" not in context
    assert "TRANSCRIPT_GROUP | meeting_id=8" in prompt
    assert "source_type=local_whisper_full_meeting" in prompt
    assert "[00:00 system_audio]" not in prompt


def test_prompt_builder_keeps_apple_speech_transcript_context() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="transcript",
                id=1,
                timestamp=datetime(2026, 5, 26, 10, 0, tzinfo=UTC),
                content="회의 전사 수집됨: Apple Speech 회의 전사 저장 품질을 점검했습니다.",
                meeting_id=4,
                source="apple_speech_full_meeting",
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)
    context = _prompt_section(prompt, "MEETING_MEMO_CONTEXT:", "PRIORITY_MEETING_TRANSCRIPTS:")

    assert "MEETING_TRANSCRIPT | meeting_id=4" in context
    assert "source_type=standard_transcript" in context
    assert "Apple Speech 회의 전사 저장 품질을 점검했습니다." in context
    assert "apple_speech_full_meeting" not in context


def test_prompt_builder_keeps_real_subtitle_feature_discussion() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="transcript",
                id=1,
                timestamp=datetime(2026, 5, 26, 10, 0, tzinfo=UTC),
                content=(
                    "회의 전사 수집됨:\n"
                    "[00:00 microphone] 자막 제공 기능의 접근성 개선을 검토했습니다."
                ),
                meeting_id=6,
                source="local_whisper_full_meeting",
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)
    context = _prompt_section(prompt, "MEETING_MEMO_CONTEXT:", "PRIORITY_MEETING_TRANSCRIPTS:")

    assert "자막 제공 기능의 접근성 개선을 검토했습니다." in context
    assert "category=discussion" in context


def test_prompt_builder_does_not_turn_discussion_transcript_into_decision() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="transcript",
                id=1,
                timestamp=datetime(2026, 5, 26, 10, 0, tzinfo=UTC),
                content=(
                    "회의 전사 수집됨: meeting transcript report quality를 "
                    "다음 마일스톤 후보로 검토했습니다."
                ),
                meeting_id=9,
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)
    context = _prompt_section(prompt, "MEETING_MEMO_CONTEXT:", "PRIORITY_MEETING_TRANSCRIPTS:")

    assert "category=decision" not in context
    assert "category=follow_up_candidate" in context
    assert "discussion/follow_up_candidate는 논의사항이나 후속작업 후보로 다루세요." in prompt


def test_prompt_builder_omits_meeting_memo_context_when_no_meeting_or_memo() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="event",
                id=1,
                timestamp=datetime(2026, 5, 26, 9, 0, tzinfo=UTC),
                source="terminal",
                content="uv run pytest tests/test_ai_components.py",
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "MEETING_MEMO_CONTEXT:" not in prompt


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


def test_prompt_builder_prioritizes_dev_events_before_screen_observations() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=2,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 9, 0, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                status="unknown",
                content="Git 변경 파일 확인: reset_dev_data.py, report_service.py",
                details_json={
                    "changed_files": ["reset_dev_data.py", "report_service.py"],
                    "diff_stat": "2 files changed",
                },
            ),
            TimelineItem(
                type="screen_ocr",
                id=2,
                timestamp=datetime(2026, 5, 26, 9, 5, tzinfo=UTC),
                content="화면 텍스트 수집됨",
                ocr_text="dashboard text",
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "PRIORITY_DEV_EVENTS:" in prompt
    assert prompt.index("PRIORITY_DEV_EVENTS:") < prompt.index("WORK_EVIDENCE_BY_TIME:")
    assert "DEV_EVENT |" in prompt
    assert "REPORT_EVIDENCE_BLOCKS:" in prompt
    assert "evidence_type=code_change_evidence" in prompt
    assert "related_files_count=2" in prompt
    assert "changed_files=reset_dev_data.py, report_service.py" not in prompt


def test_prompt_builder_groups_auto_git_snapshots_for_report_input() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=8,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 0, 5, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/auto-dev-tracking",
                status="unknown",
                content="Git 변경 파일 확인: backend/scripts/dev_tracking.py",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "sig-1",
                    "changed_files": ["backend/scripts/dev_tracking.py"],
                    "diff_summary": [
                        {
                            "file": "backend/scripts/dev_tracking.py",
                            "insertions": 120,
                            "deletions": 20,
                        }
                    ],
                },
            ),
            TimelineItem(
                type="dev_event",
                id=2,
                timestamp=datetime(2026, 5, 26, 0, 15, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/auto-dev-tracking",
                status="unknown",
                content="Git 변경 파일 확인: backend/tests/test_dev_event_scripts.py",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "sig-2",
                    "changed_files": ["backend/tests/test_dev_event_scripts.py"],
                    "diff_summary": [
                        {
                            "file": "backend/tests/test_dev_event_scripts.py",
                            "insertions": 80,
                            "deletions": 5,
                        }
                    ],
                },
            ),
            TimelineItem(
                type="dev_event",
                id=3,
                timestamp=datetime(2026, 5, 26, 0, 18, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/auto-dev-tracking",
                status="unknown",
                content="Git 변경 파일 확인: backend/scripts/watch_dev_context.py",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "sig-3",
                    "changed_files": ["backend/scripts/watch_dev_context.py"],
                    "diff_summary": [
                        {
                            "file": "backend/scripts/watch_dev_context.py",
                            "insertions": 15,
                            "deletions": 3,
                        }
                    ],
                },
            ),
            TimelineItem(
                type="dev_event",
                id=4,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/auto-dev-tracking",
                status="unknown",
                content="Git 변경 파일 확인: manual_snapshot.py",
                details_json={
                    "changed_files": ["manual_snapshot.py"],
                    "diff_stat": "1 file changed",
                },
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert prompt.count("DEV_EVENT_GROUP |") == 1
    assert "time_range=09:00~09:20" in prompt
    assert "branch_hint=auto dev tracking" in prompt
    assert "work_area=backend/scripts, backend/tests" in prompt
    assert "related_files_count=3" in prompt
    assert "diff_evidence=files=3, insertions=215, deletions=28" in prompt
    assert prompt.count("Git 변경 파일 확인: backend/scripts/dev_tracking.py") == 0
    assert "DEV_EVENT |" in prompt
    assert "manual_snapshot.py" not in prompt


def test_prompt_builder_splits_auto_git_snapshot_groups_by_twenty_minute_bucket() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=2,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 0, 5, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/bucket",
                status="unknown",
                content="Git 변경 파일 확인",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "sig-1",
                    "changed_files": ["backend/scripts/a.py"],
                },
            ),
            TimelineItem(
                type="dev_event",
                id=2,
                timestamp=datetime(2026, 5, 26, 0, 25, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/bucket",
                status="unknown",
                content="Git 변경 파일 확인",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "sig-2",
                    "changed_files": ["backend/scripts/b.py"],
                },
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert prompt.count("DEV_EVENT_GROUP |") == 2
    assert "time_range=09:00~09:20" in prompt
    assert "time_range=09:20~09:40" in prompt


def test_prompt_builder_splits_auto_git_snapshot_groups_by_branch() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=2,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 0, 5, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/a",
                status="unknown",
                content="Git 변경 파일 확인",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "sig-a",
                    "changed_files": ["backend/scripts/a.py"],
                },
            ),
            TimelineItem(
                type="dev_event",
                id=2,
                timestamp=datetime(2026, 5, 26, 0, 10, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/b",
                status="unknown",
                content="Git 변경 파일 확인",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "sig-b",
                    "changed_files": ["backend/scripts/b.py"],
                },
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert prompt.count("DEV_EVENT_GROUP |") == 2
    assert "branch_hint=a" in prompt
    assert "branch_hint=b" in prompt
    assert "branch=feat/a" not in prompt
    assert "branch=feat/b" not in prompt


def test_prompt_builder_limits_auto_git_snapshot_changed_files_and_omits_diff_body() -> None:
    changed_files = [f"backend/scripts/file_{index}.py" for index in range(10)]
    diff_summary = [
        {
            "file": file_path,
            "insertions": index + 1,
            "deletions": index,
        }
        for index, file_path in enumerate(changed_files)
    ]
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 0, 5, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/limit",
                status="unknown",
                content="Git 변경 파일 확인",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "sig-limit",
                    "changed_files": changed_files,
                    "diff_summary": diff_summary,
                    "diff_stat": "diff --git a/secret.py b/secret.py",
                },
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "related_files_count=10" in prompt
    assert "diff_evidence=files=10, insertions=36, deletions=28, limited=8" in prompt
    assert "backend/scripts/file_7.py(+8/-7)" not in prompt
    assert "backend/scripts/file_8.py(+9/-8)" not in prompt
    assert "diff --git" not in prompt


def test_prompt_builder_formats_binary_and_untracked_auto_git_diff_summary() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 0, 5, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/diff-summary",
                status="unknown",
                content="Git 변경 파일 확인",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "sig-diff-summary",
                    "changed_files": ["asset.bin", "new_file.py"],
                    "diff_summary": [
                        {"file": "asset.bin", "binary": True},
                        {"file": "new_file.py", "untracked": True},
                    ],
                },
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "diff_evidence=files=2, binary=1, added=1" in prompt
    assert "asset.bin(binary)" not in prompt
    assert "new_file.py(added)" not in prompt
    assert "work_area=root files" in prompt


def test_prompt_builder_builds_report_evidence_blocks_without_raw_git_noise() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=5,
        items=[
            TimelineItem(
                type="memo",
                id=1,
                timestamp=datetime(2026, 5, 26, 9, 0, tzinfo=UTC),
                content="TimelineBuilder 입력을 작업 단위 evidence block으로 압축하기",
            ),
            TimelineItem(
                type="dev_event",
                id=2,
                timestamp=datetime(2026, 5, 26, 9, 5, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/timeline-builder-quality",
                content="Git 변경 감지: backend/app/services/timeline_builder.py",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "sig-quality",
                    "changed_files": [
                        "backend/app/services/timeline_builder.py",
                        "backend/app/ai/prompt_builder.py",
                        "backend/tests/test_ai_components.py",
                    ],
                },
            ),
            TimelineItem(
                type="dev_event",
                id=3,
                timestamp=datetime(2026, 5, 26, 9, 10, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="uv run pytest -q",
                content="명령 성공: uv run pytest -q",
                details_json={"exit_code": 0, "duration_ms": 1200, "cwd": "/repo"},
            ),
            TimelineItem(
                type="activity_segment",
                id=4,
                timestamp=datetime(2026, 5, 26, 9, 12, tzinfo=UTC),
                content="Safari / Search",
                display_title="Safari / Search",
                duration_seconds=12,
                signal_level="low_signal",
                hidden_by_default=True,
                noise_reason="short_app_switch",
            ),
            TimelineItem(
                type="activity_segment",
                id=5,
                timestamp=datetime(2026, 5, 26, 9, 30, tzinfo=UTC),
                ended_at=datetime(2026, 5, 26, 10, 10, tzinfo=UTC),
                content="PyCharm / TimelineBuilder",
                display_title="PyCharm / TimelineBuilder",
                duration_seconds=2400,
                signal_level="high_signal",
                hidden_by_default=False,
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)
    compressed_timeline = prompt.split("압축 타임라인:", 1)[1]
    evidence_section = _prompt_section(
        prompt,
        "REPORT_EVIDENCE_BLOCKS:",
        "MEETING_MEMO_CONTEXT:",
    )

    assert "REPORT_EVIDENCE_BLOCK | evidence_type=code_change_evidence" in evidence_section
    assert "title=타임라인 작업 근거 품질 개선" in evidence_section
    assert "related_files_count=3" in evidence_section
    assert "validation_evidence=uv run pytest" in evidence_section
    assert "PyCharm / TimelineBuilder" in evidence_section
    assert "Safari / Search" not in evidence_section
    assert "Git 변경 감지" not in compressed_timeline
    assert "changed_files=" not in compressed_timeline
    assert "duration_ms" not in compressed_timeline
    assert "cwd=/repo" not in compressed_timeline
    assert "branch=feat/timeline-builder-quality" not in compressed_timeline
    assert "backend/app/services/timeline_builder.py" not in evidence_section
    assert "backend/app/ai/prompt_builder.py" not in evidence_section
    assert "uv run pytest -q" not in evidence_section


def test_prompt_builder_includes_current_git_diff_context(tmp_path: Path) -> None:
    repo = _init_git_repo(tmp_path)
    (repo / "backend/app/service.py").parent.mkdir(parents=True)
    (repo / "backend/app/service.py").write_text("def old():\n    return 1\n")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "initial")
    (repo / "backend/app/service.py").write_text(
        "def old():\n    token='secret-token'\n    return 2\n"
    )
    (repo / ".env").write_text("API_KEY=raw-secret")
    (repo / "data.db").write_bytes(b"sqlite-data")
    timeline = _timeline_with_repo(repo)

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "PRIORITY_CURRENT_GIT_DIFF_CONTEXT:" in prompt
    assert f"repo_path={repo}" in prompt
    assert "diff_policy=not_stored_privacy_filtered" in prompt
    assert "usage=latest_work_intent_primary_evidence" in prompt
    assert "backend/app/service.py" in prompt
    assert "return 2" in prompt
    assert "secret-token" not in prompt
    assert "[MASKED]" in prompt
    assert "API_KEY=raw-secret" not in prompt
    assert "data.db" not in prompt
    assert "raw diff나 코드 라인을 그대로 인용하지 마세요." in prompt
    assert "Git 변경 감지 문구, 변경 횟수, 브랜치명, 파일 경로를 반복하지 말고" in prompt
    assert "구현 의도와 작업 결과를 자연어로 요약하세요." in prompt
    assert prompt.index("PRIORITY_CURRENT_GIT_DIFF_CONTEXT:") < prompt.index(
        "PRIORITY_DEV_EVENTS:"
    )


def test_prompt_builder_adds_current_git_change_hints_before_diff_context(
    tmp_path: Path,
) -> None:
    repo = _init_git_repo(tmp_path)
    (repo / "backend/scripts/dev_tracking.py").parent.mkdir(parents=True)
    (repo / "backend/scripts/dev_tracking.py").write_text("class Tracker:\n    pass\n")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "initial")
    (repo / "backend/scripts/dev_tracking.py").write_text(
        "\n".join(
            [
                "class DevTrackingStateStore:",
                "    pass",
                "dedupe_ttl_seconds = 21600",
                "debounce_seconds = 20",
                "pending_signatures = {}",
                "tracking_signature = 'abc'",
                "api_key='secret-token'",
            ]
        )
    )
    timeline = _timeline_with_repo(repo)

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "PRIORITY_CURRENT_GIT_CHANGE_HINTS:" in prompt
    assert prompt.index("PRIORITY_CURRENT_GIT_CHANGE_HINTS:") < prompt.index(
        "PRIORITY_CURRENT_GIT_DIFF_CONTEXT:"
    )
    hint_section = _prompt_section(
        prompt,
        "PRIORITY_CURRENT_GIT_CHANGE_HINTS:",
        "PRIORITY_CURRENT_GIT_DIFF_CONTEXT:",
    )
    assert "backend/scripts/dev_tracking.py:" in hint_section
    assert "Dev Tracking persistent state" in hint_section
    assert "TTL dedupe" in hint_section
    assert "debounce 안정화" in hint_section
    assert "class DevTrackingStateStore" not in hint_section
    assert "secret-token" not in hint_section
    assert "[MASKED]" not in hint_section
    assert "구체 기능 단위로 작성하세요." in prompt
    assert "코드 리팩토링'처럼 근거 없는 일반 표현은 피하세요." in prompt


def test_prompt_builder_adds_current_work_focus_before_priority_sections() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=2,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="failed",
                command="uv run pytest tests/not_exists.py",
                content="명령 실패: uv run pytest tests/not_exists.py exit_code=4",
                details_json={"exit_code": 4},
            ),
            TimelineItem(
                type="dev_event",
                id=2,
                timestamp=datetime(2026, 5, 26, 1, 5, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="uv run pytest tests/test_ai_components.py",
                content="명령 성공: uv run pytest tests/test_ai_components.py",
                details_json={"exit_code": 0},
            ),
        ],
    )
    context = GitDiffContext(
        repo_path="/repo",
        branch="feature/report-quality",
        content="\n".join(
            [
                "diff --git a/backend/app/ai/prompt_builder.py b/backend/app/ai/prompt_builder.py",
                "+ PRIORITY_COMMAND_FLOWS",
                "+ CURRENT_WORK_FOCUS",
                "diff --git a/backend/tests/test_ai_components.py "
                "b/backend/tests/test_ai_components.py",
                "+ failed_to_success",
                "+ inspection command",
                "+ meeting transcript instruction",
                "+ next action 후보 보정",
            ]
        ),
        change_hints=[
            "backend/app/ai/prompt_builder.py: PRIORITY_COMMAND_FLOWS, failed_to_success, "
            "inspection command, meeting transcript instruction, next action 후보 보정",
            "backend/tests/test_ai_components.py: CURRENT_WORK_FOCUS report quality test",
        ],
    )

    prompt = PromptBuilder(
        privacy_filter=PrivacyFilter(),
        git_diff_context_builder=_StaticGitDiffContextBuilder(context),
    ).build_daily_report_prompt(timeline)
    focus_section = _prompt_section(
        prompt,
        "CURRENT_WORK_FOCUS:",
        "PRIORITY_CURRENT_GIT_CHANGE_HINTS:",
    )

    assert prompt.index("CURRENT_WORK_FOCUS:") < prompt.index("PRIORITY_CURRENT_GIT_CHANGE_HINTS:")
    assert prompt.index("PRUNED_REPORT_CONTEXT:") < prompt.index(
        "PRIORITY_CURRENT_GIT_CHANGE_HINTS:"
    )
    assert prompt.index("CURRENT_WORK_FOCUS:") < prompt.index("PRIORITY_COMMAND_FLOWS:")
    assert "current_focus=report quality 개선" in focus_section
    assert "evidence_work_area=backend/app, backend/tests" in focus_section
    assert "related_files_count=2" in focus_section
    assert "PRIORITY_COMMAND_FLOWS" in focus_section
    assert "failed_to_success" in focus_section
    assert "inspection command" in focus_section
    assert "meeting transcript instruction" in focus_section
    assert "next action 후보 보정" in focus_section
    assert "오늘 한 일 요약의 첫 문장은 이 주제를 중심" in prompt
    assert "시간대별 작업 흐름과 다음 작업 후보도 이 주제를 중심" in prompt
    assert "과거 마일스톤은 배경으로만 짧게" in prompt


def test_prompt_builder_adds_pruned_report_context_near_top() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=12,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="sqlite3 data/mwoham.sqlite3 'select * from dev_events'",
                content="명령 성공: sqlite3 data/mwoham.sqlite3",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=2,
                timestamp=datetime(2026, 5, 26, 1, 1, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="curl http://127.0.0.1:8765/reports/daily",
                content="명령 성공: curl http://127.0.0.1:8765/reports/daily",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=3,
                timestamp=datetime(2026, 5, 26, 1, 2, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="git switch feature/report-quality",
                content="명령 성공: git switch feature/report-quality",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=4,
                timestamp=datetime(2026, 5, 26, 1, 3, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="git pull origin main",
                content="명령 성공: git pull origin main",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=5,
                timestamp=datetime(2026, 5, 26, 1, 4, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="source ~/.zshrc",
                content="명령 성공: source ~/.zshrc",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=6,
                timestamp=datetime(2026, 5, 26, 1, 3, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="failed",
                command="uv run pytest tests/not_exists.py",
                content="명령 실패: uv run pytest tests/not_exists.py exit_code=4",
                details_json={"exit_code": 4},
            ),
            TimelineItem(
                type="dev_event",
                id=7,
                timestamp=datetime(2026, 5, 26, 1, 4, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="uv run pytest tests/test_ai_components.py",
                content="명령 성공: uv run pytest tests/test_ai_components.py",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=8,
                timestamp=datetime(2026, 5, 26, 1, 5, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="rm -rf /tmp/MwohamMacDerivedData",
                content="명령 성공: rm -rf /tmp/MwohamMacDerivedData",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=9,
                timestamp=datetime(2026, 5, 26, 1, 6, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/timeline-filtering",
                content="timeline filtering 문서 정리 완료",
                details_json={"changed_files": ["README.md"]},
            ),
            TimelineItem(
                type="screen_ocr",
                id=10,
                timestamp=datetime(2026, 5, 26, 1, 7, tzinfo=UTC),
                content="화면 텍스트 수집됨",
                ocr_text="command_talled mianation v0.8.0-time line-filtering",
                ai_inference="mianation 화면 단서",
            ),
            TimelineItem(
                type="dev_event",
                id=11,
                timestamp=datetime(2026, 5, 26, 1, 8, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/timeline-filtering",
                content="자동 Dev Tracking: timeline filtering 변경 감지",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "timeline-sig",
                    "changed_files": ["backend/app/web/templates/timeline.html"],
                },
            ),
            TimelineItem(
                type="dev_event",
                id=12,
                timestamp=datetime(2026, 5, 26, 1, 9, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feature/report-quality",
                content="자동 Dev Tracking: report input pruning 변경 감지",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "report-sig",
                    "changed_files": ["backend/app/ai/prompt_builder.py"],
                },
            ),
        ],
    )
    context = GitDiffContext(
        repo_path="/repo",
        branch="feature/report-quality",
        content="\n".join(
            [
                "diff --git a/backend/app/ai/prompt_builder.py b/backend/app/ai/prompt_builder.py",
                "+ PRUNED_REPORT_CONTEXT",
                "diff --git a/backend/tests/test_ai_components.py "
                "b/backend/tests/test_ai_components.py",
                "+ report input pruning test",
            ]
        ),
        change_hints=[
            "backend/app/ai/prompt_builder.py: report input pruning, PRUNED_REPORT_CONTEXT",
            "backend/tests/test_ai_components.py: report input pruning test",
        ],
    )

    prompt = PromptBuilder(
        privacy_filter=PrivacyFilter(),
        git_diff_context_builder=_StaticGitDiffContextBuilder(context),
    ).build_daily_report_prompt(timeline)
    pruned_section = _prompt_section(
        prompt,
        "PRUNED_REPORT_CONTEXT:",
        "PRIORITY_CURRENT_GIT_CHANGE_HINTS:",
    )
    dev_event_section = _prompt_section(
        prompt,
        "PRIORITY_DEV_EVENTS:",
        "PRIORITY_COMMAND_FLOWS:",
    )
    command_flow_section = _prompt_section(
        prompt,
        "PRIORITY_COMMAND_FLOWS:",
        "WORK_EVIDENCE_BY_TIME:",
    )

    assert prompt.index("CURRENT_WORK_FOCUS:") < prompt.index("PRUNED_REPORT_CONTEXT:")
    assert prompt.index("PRUNED_REPORT_CONTEXT:") < prompt.index(
        "PRIORITY_CURRENT_GIT_CHANGE_HINTS:"
    )
    assert "focus_relevant=report quality 개선 관련" in pruned_section
    assert "validation=uv run pytest" in pruned_section
    assert "qa_failures=tests/not_exists.py 실패는 failed command 기록 검증용 QA" in pruned_section
    assert "inspection=inspection/setup command" in pruned_section
    assert "sqlite3, curl, git switch" in pruned_section
    assert "cleanup=불필요한 앱/빌드 산출물 정리" in pruned_section
    assert "background=timeline filtering 관련 과거 이벤트는 현재 focus의 배경으로만 사용" in (
        pruned_section
    )
    assert "sqlite3 data/mwoham.sqlite3" not in dev_event_section
    assert "curl http://127.0.0.1:8765/reports/daily" not in dev_event_section
    assert "git switch feature/report-quality" not in dev_event_section
    assert "git pull origin main" not in dev_event_section
    assert "source ~/.zshrc" not in dev_event_section
    assert "tests/not_exists.py" not in dev_event_section
    assert "rm -rf /tmp/MwohamMacDerivedData" not in dev_event_section
    assert "inspection/setup commands summarized" in command_flow_section
    assert "cleanup command summarized" in command_flow_section
    assert "intentional QA failure + validation command summarized" in command_flow_section
    work_evidence_and_dump = prompt.split("WORK_EVIDENCE_BY_TIME:", 1)[1]
    assert "sqlite3 data/mwoham.sqlite3" not in work_evidence_and_dump
    assert "curl http://127.0.0.1:8765/reports/daily" not in work_evidence_and_dump
    assert "git switch feature/report-quality" not in work_evidence_and_dump
    assert "git pull origin main" not in work_evidence_and_dump
    assert "source ~/.zshrc" not in work_evidence_and_dump
    assert "rm -rf /tmp/MwohamMacDerivedData" not in work_evidence_and_dump
    assert "timeline filtering 문서 정리 완료" not in prompt
    assert "feat/timeline-filtering" not in prompt
    assert "backend/app/web/templates/timeline.html" not in prompt
    assert "branch_hint=report quality" in dev_event_section
    assert "branch=feature/report-quality" not in dev_event_section
    assert "title=리포트 입력 품질 개선" in dev_event_section
    assert "work_area=backend/app" in dev_event_section
    assert "backend/app/ai/prompt_builder.py" not in dev_event_section
    assert "command_talled" not in prompt
    assert "mianation" not in prompt


def test_prompt_builder_adds_process_output_change_hint_for_swift_diff(
    tmp_path: Path,
) -> None:
    repo = _init_git_repo(tmp_path)
    swift_file = repo / "mac-client/MwohamMac/MwohamMac/DevTrackingProcessController.swift"
    swift_file.parent.mkdir(parents=True)
    swift_file.write_text("final class DevTrackingProcessController {}\n")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "initial")
    swift_file.write_text(
        "\n".join(
            [
                "let outputPipe = Pipe()",
                "process.standardOutput = outputPipe",
                "process.standardError = Pipe()",
                "environment[\"PYTHONUNBUFFERED\"] = \"1\"",
            ]
        )
    )
    timeline = _timeline_with_repo(repo)

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    hint_section = _prompt_section(
        prompt,
        "PRIORITY_CURRENT_GIT_CHANGE_HINTS:",
        "PRIORITY_CURRENT_GIT_DIFF_CONTEXT:",
    )
    assert "DevTrackingProcessController.swift:" in hint_section
    assert "watcher stdout/stderr 상태 표시" in hint_section
    assert "process.standardOutput" not in hint_section


def test_prompt_builder_instructs_report_to_merge_repetitive_dev_tracking_flow() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/dev-tracking",
                content="Git 변경 감지: 테스트 코드 작성 및 수정",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "sig",
                    "changed_files": ["backend/tests/test_dev_event_scripts.py"],
                },
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "반복되는 자동 Dev Tracking, 테스트 코드 수정, diff context 개선" in prompt
    assert "여러 줄로 반복하지 말고 하나의 흐름으로 묶으세요." in prompt
    assert "DEV_EVENT_GROUP의 20분 단위는 입력 압축 단위일 뿐입니다." in prompt
    assert "30분~2시간 단위까지 병합할 수 있습니다." in prompt
    assert "'테스트 코드 작성 및 수정'이 반복되면" in prompt
    assert "상세 리포트 기준으로 오늘 한 일 요약은 2~4문장" in prompt
    assert "시간대별 작업 흐름은 고정 5~6개 제한을 두지 말고" in prompt
    assert "6~10개 bullet까지 허용" in prompt
    assert "구현 기능, 수정 로직, 검증 테스트" in prompt
    assert "QA 결과 중 하나 이상을 담은 작업 단위 설명" in prompt
    assert "시간대별 작업 흐름은 최대 5~6개 bullet로 제한" not in prompt
    assert "REPORT_MODE" not in prompt


def test_prompt_builder_instructs_to_ignore_uncertain_ocr_transcript_noise() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="screen_ocr",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                content="화면 텍스트 수집됨",
                ocr_text="command_talled mianation v0.8.0-time line-filtering",
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "OCR/전사/화면 단서에서 나온 불확실한 단어" in prompt
    assert "깨진 버전명" in prompt
    assert "공백이 이상한 태그명" in prompt
    assert "command_talled" not in prompt
    assert "mianation" not in prompt
    assert "명확한 파일명/명령/DevEvent 근거가 없으면 생략하세요." in prompt


def test_prompt_builder_instructs_report_to_focus_on_feature_flow_not_branches() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/dev-tracking-repo-path",
                content="Git 변경 감지: mac-client/MwohamMac 파일 변경",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "sig",
                    "changed_files": [
                        "mac-client/MwohamMac/MwohamMac/DevTrackingProcessController.swift"
                    ],
                },
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "Git 변경 감지 문구, 변경 횟수, 브랜치명, 파일 경로를 반복하지 말고" in prompt
    assert "구현 의도와 작업 결과를 자연어로 요약하세요." in prompt
    assert "시간대별 작업 흐름에서 branch명은 반복하지 마세요." in prompt
    assert "파일명은 필요한 경우 1~2개만 근거로 짧게 언급" in prompt
    assert "문장의 중심은 기능명과 검증 흐름" in prompt


def test_prompt_builder_instructs_troubleshooting_keywords_and_format() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="command_result",
                source="script",
                status="failed",
                command="uv run pytest",
                content="pytest failed with PermissionError",
                details_json={"exit_code": 1},
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "트러블슈팅 후보 키워드:" in prompt
    assert "PermissionError" in prompt
    assert "Operation not permitted" in prompt
    assert "code 126" in prompt
    assert "code 127" in prompt
    assert "actor isolation" in prompt
    assert "/private/tmp" in prompt
    assert "'문제 / 원인 / 해결 방식'으로 짧게" in prompt
    assert "현재 작업의 후속 리팩토링 점검, 문서 정리, 최종 검증, 다음 태그 준비" in prompt


def test_prompt_builder_prioritizes_failed_terminal_commands() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=2,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 5, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="uv run pytest",
                content="명령 성공: uv run pytest",
                details_json={"exit_code": 0, "duration_ms": 2000},
            ),
            TimelineItem(
                type="dev_event",
                id=2,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="failed",
                command="uv run pytest",
                content="명령 실패: uv run pytest exit_code=1",
                details_json={"exit_code": 1, "duration_ms": 1000, "cwd": "/repo"},
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)
    dev_event_section = prompt.split("PRIORITY_DEV_EVENTS:", 1)[1]

    assert "source=terminal인 command_result" in prompt
    assert "실패한 terminal command는 성공한 명령보다 우선적으로" in prompt
    assert "터미널 출력 전문은 입력에 포함되지 않습니다." in prompt
    assert "tests/not_exists.py처럼 존재하지 않는 파일 실행은 failed command 기록 검증용" in prompt
    assert "failed command 기록 검증을 위해 의도적 실패 명령을 실행했고" in prompt
    assert "정상 테스트 명령으로 success 저장도 확인한 흐름으로 묶으세요." in prompt
    assert dev_event_section.index("status=failed") < dev_event_section.index("status=success")
    assert "command_family=uv run pytest" in dev_event_section
    assert "duration_ms=1000" not in dev_event_section
    assert "cwd=/repo" not in dev_event_section
    assert "tracking_mode=command_hook" not in dev_event_section


def test_prompt_builder_keeps_priority_dev_events_chronological() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=3,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 5, 25, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="failed",
                command="uv run pytest",
                content="명령 실패: uv run pytest exit_code=1",
                details_json={"exit_code": 1},
            ),
            TimelineItem(
                type="dev_event",
                id=2,
                timestamp=datetime(2026, 5, 26, 2, 31, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="uv run python scripts/run_dev_checks.py --no-record",
                content="명령 성공: uv run python scripts/run_dev_checks.py --no-record",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=3,
                timestamp=datetime(2026, 5, 26, 4, 33, tzinfo=UTC),
                event_type="test_result",
                source="script",
                status="success",
                content="release QA 통과",
                details_json={"exit_code": 0},
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)
    dev_event_section = _prompt_section(
        prompt,
        "PRIORITY_DEV_EVENTS:",
        "PRIORITY_COMMAND_FLOWS:",
    )

    assert "timestamp순을 유지하세요" in prompt
    assert dev_event_section.index("time=2026-05-26 11:31") < dev_event_section.index(
        "time=2026-05-26 13:33"
    )
    assert dev_event_section.index("time=2026-05-26 13:33") < dev_event_section.index(
        "time=2026-05-26 14:25"
    )


def test_prompt_builder_demotes_failed_git_switch_from_troubleshooting_flow() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=2,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="failed",
                command="git switch feature/missing-branch",
                content="명령 실패: git switch feature/missing-branch exit_code=1",
                details_json={"exit_code": 1},
            ),
            TimelineItem(
                type="dev_event",
                id=2,
                timestamp=datetime(2026, 5, 26, 1, 5, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="uv run pytest tests/test_ai_components.py",
                content="명령 성공: uv run pytest tests/test_ai_components.py",
                details_json={"exit_code": 0},
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)
    dev_event_section = _prompt_section(
        prompt,
        "PRIORITY_DEV_EVENTS:",
        "PRIORITY_COMMAND_FLOWS:",
    )
    command_flow_section = _prompt_section(
        prompt,
        "PRIORITY_COMMAND_FLOWS:",
        "WORK_EVIDENCE_BY_TIME:",
    )

    assert "트러블슈팅으로 올리지 마세요" in prompt
    assert "git switch feature/missing-branch" not in dev_event_section
    assert "flow_type=failed_only" not in command_flow_section
    assert "flow_type=failed_to_success" not in command_flow_section
    assert "flow_type=inspection" in command_flow_section
    assert "inspection/setup commands summarized" in command_flow_section


def test_prompt_builder_adds_command_flow_hints_for_failed_then_success() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=3,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="failed",
                command="uv run pytest tests/not_exists.py",
                content="명령 실패: uv run pytest tests/not_exists.py exit_code=4",
                details_json={"exit_code": 4, "duration_ms": 900},
            ),
            TimelineItem(
                type="dev_event",
                id=2,
                timestamp=datetime(2026, 5, 26, 1, 5, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="uv run pytest tests/test_health.py",
                content="명령 성공: uv run pytest tests/test_health.py",
                details_json={"exit_code": 0, "duration_ms": 500},
            ),
            TimelineItem(
                type="dev_event",
                id=3,
                timestamp=datetime(2026, 5, 26, 1, 10, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="feat/report-quality",
                content="Git 변경 파일 확인: backend/app/ai/prompt_builder.py",
                details_json={
                    "changed_files": ["backend/app/ai/prompt_builder.py"],
                },
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)
    command_flow_section = _prompt_section(
        prompt,
        "PRIORITY_COMMAND_FLOWS:",
        "WORK_EVIDENCE_BY_TIME:",
    )

    assert "PRIORITY_COMMAND_FLOWS:" in prompt
    assert "COMMAND_FLOW |" in command_flow_section
    assert "flow_type=failed_to_success" in command_flow_section
    assert "command_family=uv run pytest" in command_flow_section
    assert "statuses=failed->success" in command_flow_section
    assert "개별 명령 나열보다 수정/보완/검증" in command_flow_section
    assert "같은 시간대의 git_snapshot, command_result, diff context를 묶어" in prompt
    assert "작업 단위와 검증 흐름으로 요약하세요." in prompt


def test_prompt_builder_demotes_inspection_terminal_commands() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=4,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="sqlite3 data/mwoham.sqlite3 'select * from dev_events'",
                content="명령 성공: sqlite3 data/mwoham.sqlite3",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=2,
                timestamp=datetime(2026, 5, 26, 1, 1, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="echo ok",
                content="명령 성공: echo ok",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=3,
                timestamp=datetime(2026, 5, 26, 1, 2, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="uv run pytest tests/test_health.py",
                content="명령 성공: uv run pytest tests/test_health.py",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=4,
                timestamp=datetime(2026, 5, 26, 1, 3, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="failed",
                command="curl http://127.0.0.1:8765/reports/daily",
                content="명령 실패: curl http://127.0.0.1:8765/reports/daily exit_code=7",
                details_json={"exit_code": 7},
            ),
            TimelineItem(
                type="dev_event",
                id=5,
                timestamp=datetime(2026, 5, 26, 1, 4, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="mwoham_command_tracking_status",
                content="명령 성공: mwoham_command_tracking_status",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=6,
                timestamp=datetime(2026, 5, 26, 1, 5, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="git tag",
                content="명령 성공: git tag",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=7,
                timestamp=datetime(2026, 5, 26, 1, 6, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="git tag --list",
                content="명령 성공: git tag --list",
                details_json={"exit_code": 0},
            ),
            TimelineItem(
                type="dev_event",
                id=8,
                timestamp=datetime(2026, 5, 26, 1, 7, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="git tag -a v1.0.0 -m release",
                content="명령 성공: git tag -a v1.0.0 -m release",
                details_json={"exit_code": 0},
            ),
        ],
    )

    builder = PromptBuilder(privacy_filter=PrivacyFilter())
    prompt = builder.build_daily_report_prompt(timeline)
    dev_event_section = _prompt_section(
        prompt,
        "PRIORITY_DEV_EVENTS:",
        "PRIORITY_COMMAND_FLOWS:",
    )
    command_flow_section = prompt.split("PRIORITY_COMMAND_FLOWS:", 1)[1]

    assert "inspection/setup command는 직접 나열하지 말고 보조 근거로만 참고하세요." in prompt
    assert "mwoham_command_tracking_status" in prompt
    assert "mwoham_command_tracking_disable" in prompt
    assert "DB 조회와 report 생성으로 저장 결과를 확인했다" in prompt
    assert "검증/개발 command는 높은 우선순위" in prompt
    assert "flow_type=inspection" in command_flow_section
    assert "확인용 command입니다." in command_flow_section
    assert "inspection/setup commands summarized" in command_flow_section
    assert "inspection/setup command는 직접 나열하지 말고" in prompt
    assert "git switch" in prompt
    assert "git pull" in prompt
    assert "command_family=uv run pytest" in dev_event_section
    assert "uv run pytest tests/test_health.py" not in dev_event_section
    assert "sqlite3 data/mwoham.sqlite3" not in dev_event_section
    assert "echo ok" not in dev_event_section
    assert "curl http://127.0.0.1:8765/reports/daily" not in dev_event_section
    assert "git tag --list" not in dev_event_section
    assert "command=git tag |" not in dev_event_section
    assert "git tag -a v1.0.0 -m release" in dev_event_section
    assert builder._is_inspection_command("git tag")
    assert builder._is_inspection_command("git tag | grep report")
    assert builder._is_inspection_command("git tag --list")
    assert not builder._is_inspection_command("git tag -a v1.0.0 -m release")
    assert not builder._is_inspection_command("git tag -d v1.0.0")


def test_prompt_builder_removes_git_checkout_status_diff_log_from_report_input() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=6,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 9, 0, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="git checkout feat/timeline-ux",
                content="checkout 명령이 성공적으로 실행되었습니다.",
            ),
            TimelineItem(
                type="dev_event",
                id=2,
                timestamp=datetime(2026, 5, 26, 9, 1, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="git status",
                content="Git 변경 사항을 확인했습니다.",
            ),
            TimelineItem(
                type="dev_event",
                id=3,
                timestamp=datetime(2026, 5, 26, 9, 2, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="git diff",
                content="Git diff 확인",
            ),
            TimelineItem(
                type="dev_event",
                id=4,
                timestamp=datetime(2026, 5, 26, 9, 3, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="git log --oneline",
                content="Git log 확인",
            ),
            TimelineItem(
                type="dev_event",
                id=5,
                timestamp=datetime(2026, 5, 26, 9, 4, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="git diff --check",
                content="git diff --check 통과",
            ),
            TimelineItem(
                type="dev_event",
                id=6,
                timestamp=datetime(2026, 5, 26, 9, 5, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                branch="fix/timeline-builder-quality",
                content="Git 변경 감지",
                details_json={"changed_files": ["backend/app/ai/prompt_builder.py"]},
            ),
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)
    compressed_timeline = prompt.split("압축 타임라인:", 1)[1]
    command_flow_section = _prompt_section(
        prompt,
        "PRIORITY_COMMAND_FLOWS:",
        "WORK_EVIDENCE_BY_TIME:",
    )

    assert "git checkout feat/timeline-ux" not in compressed_timeline
    assert "checkout 명령이 성공적으로 실행" not in compressed_timeline
    assert "Git 변경 사항을 확인했습니다" not in compressed_timeline
    assert "command_family=git diff --check" in command_flow_section
    assert "title=리포트 입력 품질 개선" in compressed_timeline
    assert "branch=fix/timeline-builder-quality" not in compressed_timeline
    assert "branch_hint=timeline builder quality" not in compressed_timeline


def test_prompt_builder_instructs_destructive_commands_to_stay_concise() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="rm -rf /tmp/MwohamMacDerivedData",
                content="명령 성공: rm -rf /tmp/MwohamMacDerivedData",
                details_json={"exit_code": 0},
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "rm -rf 같은 destructive command" in prompt
    assert "불필요한 앱/빌드 산출물 정리" in prompt
    assert "inspection/cleanup flow는 본문 직접 나열 대상이 아니라 보조 검증 근거" in prompt
    assert "flow_type=cleanup" in prompt


def test_prompt_builder_instructs_next_tasks_not_to_repeat_completed_features() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                content="persistent state TTL dedupe debounce 구현",
                details_json={"changed_files": ["backend/scripts/dev_tracking.py"]},
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "이미 오늘 완료된 기능을 다시 구현 과제로 제안하지 마세요." in prompt
    assert "입력에 구현/검증 완료로 보이는 항목이 있으면" in prompt
    assert "persistent state" in prompt
    assert "TTL dedupe" in prompt
    assert "debounce" in prompt
    assert "repo path 설정" in prompt
    assert "stdout/stderr 상태 표시" in prompt
    assert "report input 20분 압축" in prompt
    assert "CURRENT_GIT_DIFF_CONTEXT" in prompt
    assert "CURRENT_GIT_CHANGE_HINTS" in prompt
    assert "command_result" in prompt
    assert "timeline filtering" in prompt
    assert "PRIORITY_COMMAND_FLOWS" in prompt
    assert "CURRENT_WORK_FOCUS" in prompt
    assert (
        "terminal command 자동 기록이 이미 입력에 있으면 다음 작업 후보로 반복 제안하지"
        in prompt
    )
    assert "timeline filtering 구현/검증이 이미 입력에 있으면 반복 제안하지" in prompt
    assert "문서 정리 완료, 태그 완료, 검증 통과로 보이는 힌트" in prompt
    assert "timeline filtering 문서 정리" in prompt
    assert "command tracking report input 압축" in prompt
    assert "CURRENT_WORK_FOCUS 구현은 입력에 완료 근거가 있으면" in prompt
    assert "다음 작업 후보는 3~5개로 제한" in prompt


def test_prompt_builder_instructs_not_to_emit_internal_input_labels() -> None:
    timeline = TimelineResponse(date=date(2026, 5, 26), total=0, items=[])

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "prompt/input 내부 라벨명은" in prompt
    assert "리포트에 쓰지 말고" in prompt
    assert "CURRENT_WORK_FOCUS, MEETING_MEMO_CONTEXT, PRIORITY_MEETING_TRANSCRIPTS" in prompt
    assert "WORK_EVIDENCE_BY_TIME 등 prompt/input 내부" in prompt
    assert "자연어 요약에만 반영하세요" in prompt


def test_prompt_builder_instructs_current_work_topic_from_context() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="command_result",
                source="terminal",
                status="success",
                command="uv run pytest tests/test_dev_event_scripts.py",
                content="명령 성공: uv run pytest tests/test_dev_event_scripts.py",
                details_json={"exit_code": 0, "duration_ms": 1000},
            )
        ],
    )

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "PRIORITY_COMMAND_FLOWS, command_result를 보고 현재 작업 주제를 먼저" in prompt
    assert "작업 주제가 command tracking이면 터미널 명령 자동 기록 중심" in prompt
    assert "이전 마일스톤에서 완료된 기능명이 입력에 있어도" in prompt
    assert "직접 관련이 약하면 배경 정보로만 다루세요." in prompt


def test_prompt_builder_instructs_command_tracking_keywords() -> None:
    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(
        TimelineResponse(date=date(2026, 5, 26), total=0, items=[])
    )

    assert "zsh hook" in prompt
    assert "preexec" in prompt
    assert "precmd" in prompt
    assert "record_command_result.py" in prompt
    assert "mwoham_zsh_tracking.zsh" in prompt
    assert "mwoham_command_tracking_status" in prompt
    assert "mwoham_command_tracking_disable" in prompt
    assert "inspection command priority" in prompt


def test_prompt_builder_does_not_hardcode_version_numbers_in_instructions() -> None:
    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(
        TimelineResponse(date=date(2026, 5, 26), total=0, items=[])
    )
    instructions = prompt.split("압축 타임라인:", 1)[0]

    assert "v0." not in instructions
    assert "특정 버전 번호를 추측해서 쓰지 마세요." in instructions


def test_prompt_builder_includes_safe_untracked_diff_context(tmp_path: Path) -> None:
    repo = _init_git_repo(tmp_path)
    (repo / "README.md").write_text("initial\n")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "initial")
    (repo / "backend/scripts/new_tool.py").parent.mkdir(parents=True)
    (repo / "backend/scripts/new_tool.py").write_text("print('new tool')\n")
    (repo / "image.png").write_bytes(b"\x89PNG\r\n")
    timeline = _timeline_with_repo(repo)

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "PRIORITY_CURRENT_GIT_DIFF_CONTEXT:" in prompt
    assert "backend/scripts/new_tool.py" in prompt
    assert "print('new tool')" in prompt
    assert "image.png" not in prompt


def test_prompt_builder_limits_large_git_diff_context(tmp_path: Path) -> None:
    repo = _init_git_repo(tmp_path)
    (repo / "large.py").write_text("x = 1\n")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "initial")
    (repo / "large.py").write_text("\n".join(f"line_{index} = {index}" for index in range(80)))
    timeline = _timeline_with_repo(repo)
    builder = GitDiffContextBuilder(
        privacy_filter=PrivacyFilter(),
        max_total_chars=500,
        max_file_chars=200,
    )

    prompt = PromptBuilder(
        privacy_filter=PrivacyFilter(),
        git_diff_context_builder=builder,
    ).build_daily_report_prompt(timeline)

    assert "PRIORITY_CURRENT_GIT_DIFF_CONTEXT:" in prompt
    assert "... diff 일부 생략 ..." in prompt
    assert len(prompt) < 7900


def test_prompt_builder_omits_current_git_diff_context_when_clean(tmp_path: Path) -> None:
    repo = _init_git_repo(tmp_path)
    (repo / "README.md").write_text("initial\n")
    _git(repo, "add", ".")
    _git(repo, "commit", "-m", "initial")
    timeline = _timeline_with_repo(repo)

    prompt = PromptBuilder(privacy_filter=PrivacyFilter()).build_daily_report_prompt(timeline)

    assert "PRIORITY_CURRENT_GIT_DIFF_CONTEXT:" not in prompt
    assert "DEV_EVENT |" in prompt


def test_prompt_builder_does_not_store_raw_diff_in_dev_event_details(tmp_path: Path) -> None:
    repo = _init_git_repo(tmp_path)
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                repo_path=str(repo),
                branch="main",
                content="Git 변경 감지",
                details_json={
                    "tracking_mode": "watch",
                    "tracking_signature": "abc",
                    "changed_files": ["backend/app/service.py"],
                    "diff_summary": [
                        {
                            "file": "backend/app/service.py",
                            "insertions": 10,
                            "deletions": 2,
                        }
                    ],
                },
            )
        ],
    )

    details = timeline.items[0].details_json or {}

    assert "diff --git" not in str(details)
    assert "+++" not in str(details)
    assert "@@" not in str(details)


def test_gemini_client_returns_none_without_api_key() -> None:
    client = GeminiClient(api_key=None, model="gemini-2.5-flash")

    assert client.generate_text("hello") is None
    assert client.generate_text_result("hello").error_reason == "api_key_missing"


def test_ai_provider_defaults_to_gemini_without_env(monkeypatch: pytest.MonkeyPatch) -> None:
    for key in [
        "AI_PROVIDER",
        "AI_MODEL",
        "GEMINI_API_KEY",
        "GEMINI_MODEL",
        "OPENAI_API_KEY",
        "OPENAI_MODEL",
    ]:
        monkeypatch.delenv(key, raising=False)

    provider_config = resolve_ai_provider_config(Settings(_env_file=None))

    assert provider_config.provider == AIProvider.GEMINI
    assert provider_config.api_key is None
    assert provider_config.model == "gemini-2.5-flash-lite"


def test_ai_provider_uses_openai_when_selected() -> None:
    provider_config = resolve_ai_provider_config(
        Settings(
            ai_provider="openai",
            ai_model="gpt-test-mini",
            openai_api_key="test-openai-key",
            gemini_api_key="test-gemini-key",
        )
    )

    assert provider_config.provider == AIProvider.OPENAI
    assert provider_config.api_key == "test-openai-key"
    assert provider_config.model == "gpt-test-mini"


def test_ai_provider_keeps_gemini_env_compatibility() -> None:
    provider_config = resolve_ai_provider_config(
        Settings(
            gemini_api_key="test-gemini-key",
            gemini_model="gemini-test-model",
        )
    )

    assert provider_config.provider == AIProvider.GEMINI
    assert provider_config.api_key == "test-gemini-key"
    assert provider_config.model == "gemini-test-model"


def test_ai_provider_can_infer_openai_when_only_openai_key_exists(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("GEMINI_API_KEY", raising=False)
    monkeypatch.delenv("GEMINI_MODEL", raising=False)
    provider_config = resolve_ai_provider_config(
        Settings(
            _env_file=None,
            openai_api_key="test-openai-key",
            openai_model="gpt-test-mini",
        )
    )

    assert provider_config.provider == AIProvider.OPENAI
    assert provider_config.api_key == "test-openai-key"
    assert provider_config.model == "gpt-test-mini"


def test_openai_client_returns_none_without_api_key() -> None:
    client = OpenAIClient(api_key=None, model="gpt-test-mini")

    assert client.generate_text("hello") is None
    assert client.generate_text_result("hello").error_reason == "api_key_missing"


def test_openai_client_extracts_output_text(monkeypatch: pytest.MonkeyPatch) -> None:
    def fake_post(*args, **kwargs):
        return httpx.Response(
            200,
            json={"status": "completed", "output_text": "정상 응답입니다."},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)

    result = OpenAIClient(api_key="test-openai-key", model="gpt-test-mini").generate_text_result(
        "hello"
    )

    assert result.text == "정상 응답입니다."
    assert result.finish_reason == "completed"


def test_openai_client_extracts_nested_output_content(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_post(*args, **kwargs):
        return httpx.Response(
            200,
            json={
                "status": "completed",
                "output": [
                    {
                        "content": [
                            {"type": "output_text", "text": "첫 줄"},
                            {"type": "output_text", "text": "둘째 줄"},
                        ]
                    }
                ],
            },
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)

    result = OpenAIClient(api_key="test-openai-key", model="gpt-test-mini").generate_text_result(
        "hello"
    )

    assert result.text == "첫 줄\n둘째 줄"


def test_openai_client_classifies_invalid_key_response(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_post(*args, **kwargs):
        return httpx.Response(
            401,
            json={"error": {"message": "invalid api key"}},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)

    result = OpenAIClient(api_key="test-openai-key", model="gpt-test-mini").generate_text_result(
        "hello"
    )

    assert result.text is None
    assert result.error_reason == "invalid_api_key"
    assert result.status_code == 401


def test_openai_client_classifies_quota_response(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def fake_post(*args, **kwargs):
        return httpx.Response(
            429,
            json={"error": {"message": "quota exceeded"}},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)

    result = OpenAIClient(api_key="test-openai-key", model="gpt-test-mini").generate_text_result(
        "hello"
    )

    assert result.text is None
    assert result.error_reason == "quota_exceeded"
    assert result.status_code == 429


def test_report_service_uses_openai_client_when_provider_is_openai(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    original_values = {
        "ai_provider": settings.ai_provider,
        "ai_model": settings.ai_model,
        "openai_api_key": settings.openai_api_key,
        "gemini_api_key": settings.gemini_api_key,
    }
    monkeypatch.setattr(settings, "ai_provider", "openai")
    monkeypatch.setattr(settings, "ai_model", "gpt-test-mini")
    monkeypatch.setattr(settings, "openai_api_key", "test-openai-key")
    monkeypatch.setattr(settings, "gemini_api_key", None)
    try:
        service = get_report_service()
    finally:
        for key, value in original_values.items():
            monkeypatch.setattr(settings, key, value)

    assert isinstance(service.summarizer.client, OpenAIClient)
    assert service.summarizer.client.model == "gpt-test-mini"


def test_report_service_defaults_to_gemini_client_without_provider(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    original_values = {
        "ai_provider": settings.ai_provider,
        "ai_model": settings.ai_model,
        "openai_api_key": settings.openai_api_key,
        "gemini_api_key": settings.gemini_api_key,
        "gemini_model": settings.gemini_model,
    }
    monkeypatch.setattr(settings, "ai_provider", None)
    monkeypatch.setattr(settings, "ai_model", None)
    monkeypatch.setattr(settings, "openai_api_key", None)
    monkeypatch.setattr(settings, "gemini_api_key", None)
    monkeypatch.setattr(settings, "gemini_model", "gemini-test-model")
    try:
        service = get_report_service()
    finally:
        for key, value in original_values.items():
            monkeypatch.setattr(settings, key, value)

    assert isinstance(service.summarizer.client, GeminiClient)
    assert service.summarizer.client.model == "gemini-test-model"


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


def test_report_content_cleaner_removes_internal_prompt_labels_from_output() -> None:
    content = "\n\n".join(
        [
            "## 오늘 한 일 요약\n- CURRENT_WORK_FOCUS: local Whisper report input 개선",
            (
                "## 시간대별 작업 흐름\n"
                "- WORK_EVIDENCE_BY_TIME: prompt builder와 cleaner 보강\n"
                "- MEETING_MEMO_CONTEXT 근거로 회의 전사 내용을 요약"
            ),
            "## 주요 트러블슈팅\nPRIORITY_MEETING_TRANSCRIPTS:",
            "## 회의/메모에서 나온 결정사항\n- 결정사항 없음.",
            "## 다음 작업 후보\n- CURRENT_WORK_FOCUS",
        ]
    )

    cleaned = ReportContentCleaner().clean(content)

    assert "CURRENT_WORK_FOCUS" not in cleaned
    assert "MEETING_MEMO_CONTEXT" not in cleaned
    assert "PRIORITY_MEETING_TRANSCRIPTS" not in cleaned
    assert "WORK_EVIDENCE_BY_TIME" not in cleaned
    assert "- local Whisper report input 개선" in cleaned
    assert "- prompt builder와 cleaner 보강" in cleaned
    assert "회의 전사 내용을 요약" in cleaned
    assert "## 주요 트러블슈팅\n확인된 내용 없음." in cleaned


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

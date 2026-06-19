import re
from collections import defaultdict
from datetime import datetime, timedelta

from app.ai.git_diff_context import GitDiffContextBuilder
from app.core.timezone import KST, as_kst
from app.schemas.timeline import TimelineResponse
from app.services.privacy_filter import PrivacyFilter, get_privacy_filter
from app.services.screen_observation_summarizer import SAFE_UNCLEAR_INFERENCE
from app.services.self_observation_filter import (
    SelfObservationFilter,
    get_self_observation_filter,
)
from app.services.transcript_quality import TranscriptQualityPolicy, get_transcript_quality_policy


class PromptBuilder:
    KST = KST
    WORK_HINT_KEYWORDS = (
        "pytest",
        "ruff",
        "alembic",
        "xcodebuild",
        "quota",
        "gemini",
        "ocr",
        "timeline",
        "report",
        "pdf",
        "release",
        "package",
        "fastapi",
        "swift",
        "api",
        "migration",
    )
    OCR_NOISE_MARKERS = (
        "chatgpt can make mistakes",
        "chatgpt는 실수를 할 수",
        "nw_path_necp_check",
        "nsdebugdescription",
        "userinfo={",
        "connection invalid",
        "message chatgpt",
        "무엇이든 물어보세요",
        "공유된 ",
        "tb 사용",
        "order by",
    )
    LOCAL_WHISPER_FULL_MEETING_SOURCE = "local_whisper_full_meeting"
    MEETING_SEGMENT_PREFIX_RE = re.compile(
        r"^\[(?P<time>\d{1,2}:\d{2}(?::\d{2})?)\s+"
        r"(?P<source>microphone|system_audio)\]\s*(?P<text>.*)$"
    )

    def __init__(
        self,
        privacy_filter: PrivacyFilter,
        self_observation_filter: SelfObservationFilter | None = None,
        transcript_quality_policy: TranscriptQualityPolicy | None = None,
        git_diff_context_builder: GitDiffContextBuilder | None = None,
    ) -> None:
        self.privacy_filter = privacy_filter
        self.self_observation_filter = self_observation_filter or get_self_observation_filter()
        self.transcript_quality_policy = (
            transcript_quality_policy or get_transcript_quality_policy()
        )
        self.git_diff_context_builder = git_diff_context_builder or GitDiffContextBuilder(
            privacy_filter=privacy_filter
        )

    def build_daily_report_prompt(self, timeline: TimelineResponse) -> str:
        compressed_timeline = self._compress_timeline(timeline)
        safe_timeline = self.privacy_filter.mask(compressed_timeline)
        return "\n".join(
            [
                "다음은 개인 로컬 작업 기록 에이전트가 만든 일일 압축 타임라인입니다.",
                "원본 화면, 음성, 스크린샷, 오디오 파일은 포함하지 않았습니다.",
                "secret/token 패턴은 마스킹되었습니다.",
                "",
                "요청:",
                "- 한국어 Markdown 리포트를 작성하고, 타임라인의 사실만 쓰세요.",
                "- 빈 섹션은 '확인된 내용 없음'처럼 짧게 처리하세요.",
                "- 빈 타임라인이면 '기록된 작업이 없습니다.' 한 문장만 반환하세요.",
                "- 앱 이름은 작업 도구나 환경 정보로만 참고하세요.",
                "- 앱 이름은 업무 주체가 아니라 작업 환경 보조 정보로만 다루고, 실제 작업 내용, "
                "결정사항, 문제 해결 과정을 중심으로 요약하세요.",
                "- Swift, API, FastAPI 같은 기술명만 나열하지 말고, 관찰된 메모와 화면 단서에 "
                "기반해 구체 작업 단위로 작성하세요.",
                "- 시간대별 작업 흐름은 앱 사용 시간이 아니라 실제로 진행한 작업 후보 중심으로 "
                "작성하세요.",
                "- 상세 리포트 기준으로 오늘 한 일 요약은 2~4문장 허용, "
                "CURRENT_WORK_FOCUS, 핵심 구현, 검증 결과를 함께 쓰세요.",
                "- 시간대별 작업 흐름은 고정 5~6개 제한을 두지 말고 필요하면 6~10개 bullet까지 "
                "허용하세요. 각 bullet은 구현 기능, 수정 로직, 검증 테스트, 실패 후 성공 흐름, "
                "QA 결과 중 하나 이상을 담은 작업 단위 설명이어야 합니다.",
                "- Git 변경, command, 파일명, 브랜치명, 테스트를 각각 나열하지 말고, 같은 "
                "시간대의 git_snapshot, command_result, diff context를 묶어 작업 단위와 "
                "검증 흐름으로 요약하세요.",
                "- CURRENT_WORK_FOCUS, MEETING_MEMO_CONTEXT, PRIORITY_MEETING_TRANSCRIPTS, "
                "WORK_EVIDENCE_BY_TIME 등 prompt/input 내부 라벨명은 리포트에 "
                "쓰지 말고 자연어 요약에만 반영하세요.",
                "- CURRENT_WORK_FOCUS가 있으면 오늘 한 일 요약의 첫 문장은 이 주제를 중심으로 "
                "작성하고, 시간대별 작업 흐름과 다음 작업 후보도 이 주제를 중심으로 작성하세요. "
                "하루 중 이전 작업이 많더라도 CURRENT_WORK_FOCUS와 직접 관련이 약한 과거 "
                "마일스톤은 배경으로만 짧게 다루세요.",
                "- CURRENT_GIT_CHANGE_HINTS, CURRENT_GIT_DIFF_CONTEXT, PRIORITY_DEV_EVENTS, "
                "PRIORITY_COMMAND_FLOWS, command_result를 보고 현재 작업 주제를 먼저 "
                "추론하세요.",
                "- 작업 주제가 command tracking이면 터미널 명령 자동 기록 중심으로, report 품질 "
                "개선이면 report prompt/input 개선 중심으로, 문서 정리이면 docs/README 중심으로 "
                "작성하세요.",
                "- 이전 마일스톤에서 완료된 기능명이 입력에 있어도 현재 diff나 command_result와 "
                "직접 관련이 약하면 배경 정보로만 다루세요.",
                "- PRIORITY_CURRENT_GIT_DIFF_CONTEXT가 있으면 최신 개발 작업 판단의 가장 강한 "
                "근거로 우선 사용하세요.",
                "- PRIORITY_CURRENT_GIT_CHANGE_HINTS가 있으면 오늘 한 일 요약과 시간대별 작업 "
                "흐름에 힌트의 구체 기능명을 포함하세요.",
                "- '자동 Dev Tracking 기능 개선'처럼 넓은 표현만 쓰지 말고, 확인된 구체 기능 "
                "단위로 작성하세요.",
                "- '코드 리팩토링'처럼 근거 없는 일반 표현은 피하세요.",
                "- Git 변경 감지 문구, 변경 횟수, 브랜치명, 파일 경로를 반복하지 말고, diff에서 "
                "드러나는 구현 의도와 작업 결과를 자연어로 요약하세요.",
                "- 시간대별 작업 흐름에서 branch명은 반복하지 마세요. 파일명은 필요한 경우 "
                "1~2개만 근거로 짧게 언급하고, 문장의 중심은 기능명과 검증 흐름으로 쓰세요.",
                "- 반복되는 자동 Dev Tracking, 테스트 코드 수정, diff context 개선은 여러 줄로 "
                "반복하지 말고 하나의 흐름으로 묶으세요.",
                "- DEV_EVENT_GROUP의 20분 단위는 입력 압축 단위일 뿐입니다. 최종 리포트는 "
                "20분마다 쓰지 말고 30분~2시간 단위까지 병합할 수 있습니다.",
                "- '테스트 코드 작성 및 수정'이 반복되면 어떤 기능의 테스트를 보강했는지로 "
                "합치세요.",
                "- DEV_EVENT_GROUP은 시간대 흐름 보조 근거입니다. "
                "PRIORITY_CURRENT_GIT_DIFF_CONTEXT가 있으면 최신 작업 내용은 diff context를 "
                "우선 사용하세요.",
                "- 주요 트러블슈팅 섹션에는 DEV_EVENT나 diff context에 오류, 실패, 해결 흔적이 "
                "있을 때만 요약하세요.",
                "- source=terminal인 command_result는 사용자가 zsh에서 실행한 개발 명령입니다. "
                "검증 command는 테스트/검증 결과 근거로만 사용하고, checkout/status/diff/log "
                "같은 git inspection command는 본문에 쓰지 마세요.",
                "- zsh hook/preexec/precmd, command_result, record_command_result.py, "
                "install_command_tracking_hook.py, uninstall_command_tracking_hook.py, "
                "mwoham_zsh_tracking.zsh, mwoham_command_tracking_status, "
                "mwoham_command_tracking_disable, failed/success command, "
                "inspection command priority가 보이면 command tracking 근거로 해석하세요.",
                "- 실패한 terminal command는 성공한 명령보다 우선적으로 트러블슈팅 후보로 "
                "검토하세요. 같은 계열 명령이 실패 후 성공했다면 하나의 해결 흐름으로 "
                "요약하세요.",
                "- PRIORITY_COMMAND_FLOWS가 있으면 failed->success 흐름, 개발 검증 명령, "
                "확인용 명령을 개별 command 나열보다 우선해서 하나의 검증/보완 흐름으로 "
                "해석하세요.",
                "- PRIORITY_COMMAND_FLOWS의 inspection/cleanup flow는 본문 직접 나열 대상이 "
                "아니라 보조 검증 근거입니다. development_validation/failed_to_success flow는 "
                "구현 검증 흐름으로 요약하세요.",
                "- echo, sqlite3, curl, source, mwoham_command_tracking_status, "
                "mwoham_command_tracking_disable, git checkout, git branch, git status, "
                "git diff, git log, git switch, git pull 같은 inspection/setup "
                "command는 직접 나열하지 말고 보조 근거로만 참고하세요. 필요하면 'DB 조회와 "
                "report 생성으로 저장 결과를 확인했다'처럼 묶으세요.",
                "- uv run pytest, uv run python scripts/run_dev_checks.py, uv run alembic check, "
                "git diff --check, ruff, xcodebuild, bash -n, zsh -n 같은 검증/개발 command는 "
                "높은 우선순위로 참고하세요.",
                "- rm -rf 같은 destructive command는 command 문자열을 필요 이상으로 자세히 "
                "나열하지 말고, 근거가 있으면 불필요한 앱/빌드 산출물 정리 정도로 짧게 "
                "요약하세요.",
                "- 터미널 출력 전문은 입력에 포함되지 않습니다. 실패 원인은 command family와 "
                "주변 DevEvent, diff context 근거가 있을 때만 보수적으로 판단하세요.",
                "- failed command가 의도적 QA인지 실제 장애인지 주변 context로 구분하세요. "
                "tests/not_exists.py처럼 존재하지 않는 파일 실행은 failed command 기록 검증용일 "
                "수 있으므로 실제 장애처럼 과장하지 마세요. command tracking QA 문맥이면 "
                "failed command 기록 검증을 위해 의도적 실패 명령을 실행했고, 정상 테스트 "
                "명령으로 success 저장도 확인한 흐름으로 묶으세요.",
                "- 트러블슈팅 후보 키워드: failed, error, PermissionError, Operation not "
                "permitted, code 126, code 127, ruff, xcodebuild 실패, actor isolation, PATH, "
                "uv, /private/tmp, CI.",
                "- 트러블슈팅은 근거가 있을 때만 '문제 / 원인 / 해결 방식'으로 짧게 정리하세요.",
                "- 버전명은 DevEvent, git tag, branch, memo, command context 등 입력에 명확한 "
                "근거가 있을 때만 사용하세요. 특정 버전 번호를 추측해서 쓰지 마세요.",
                "- 다음 작업 후보에는 이미 오늘 완료된 기능을 다시 구현 과제로 제안하지 마세요.",
                "- 다음 작업 후보는 명시된 로드맵, 실패한 QA, TODO 메모, 미완료 항목 기준으로만 "
                "작성하세요. 현재 로드맵은 13차 Launch at Login, 14차 메뉴바/플로팅 위젯 "
                "리팩토링, 15차 Release 패키징입니다.",
                "- 입력에 구현/검증 완료로 보이는 항목이 있으면 다음 작업 후보에서 반복 제안하지 "
                "마세요. 예: persistent state, TTL dedupe, debounce, repo path 설정, "
                "stdout/stderr 상태 표시, report input 20분 압축, CURRENT_GIT_DIFF_CONTEXT, "
                "CURRENT_GIT_CHANGE_HINTS, command_result, timeline filtering, "
                "PRIORITY_COMMAND_FLOWS, CURRENT_WORK_FOCUS.",
                "- timeline filtering 문서 정리, 태그 준비, command tracking report input 압축, "
                "Dev Tracking report input 압축, CURRENT_GIT_DIFF_CONTEXT 구현, "
                "CURRENT_GIT_CHANGE_HINTS 구현, PRIORITY_COMMAND_FLOWS 구현, CURRENT_WORK_FOCUS "
                "구현은 입력에 완료 근거가 있으면 다음 작업 후보에서 제외하세요.",
                "- 문서 정리 완료, 태그 완료, 검증 통과로 보이는 힌트가 있으면 그 작업을 다음 "
                "작업 후보로 다시 제안하지 마세요.",
                "- 다음 작업 후보에는 이미 구현한 기능의 추가 테스트만 반복하지 말고, "
                "현재 작업의 후속 리팩토링 점검, 문서 정리, 최종 검증, 다음 태그 준비처럼 "
                "근거 있는 다음 단계 후보를 제안하세요.",
                "- 다음 작업 후보는 3~5개로 제한하고, 완료한 구현 파일명이나 테스트 파일명을 "
                "다음 작업으로 제안하지 마세요. 현재 입력에서 자연스럽게 이어지는 단계만 "
                "제안하세요.",
                "- terminal command 자동 기록이 이미 입력에 있으면 다음 작업 후보로 반복 제안하지 "
                "마세요. timeline filtering 구현/검증이 이미 입력에 있으면 반복 제안하지 "
                "마세요.",
                "- 회의 전사는 결정사항, 논의사항, 후속작업 후보로 나눠 반영하되, 근거 없이 "
                "결정사항을 만들지 마세요. source 값은 근거로만 참고하고 최종 리포트에 과하게 "
                "나열하지 마세요. MEETING_MEMO_CONTEXT는 회의/메모 근거입니다. 개발 로그와 "
                "섞지 말고, manual memo는 사용자 직접 입력으로 전사보다 우선하세요.",
                "- source=local_whisper_full_meeting은 microphone/system_audio가 시간순으로 "
                "병합된 회의 전사입니다. timestamp와 source label은 내부 근거로만 보고, 최종 "
                "리포트에는 필요 이상으로 그대로 노출하지 마세요.",
                "- category=decision만 결정사항으로 쓰고 discussion/follow_up_candidate는 "
                "논의사항이나 후속작업 후보로 다루세요. TRANSCRIPT_NOISE_SUMMARY는 제외/약화 "
                "통계이며 짧은 발화, 반복어, source 중복 전사는 본문 사실로 쓰지 마세요.",
                "- OCR/전사/화면 단서에서 나온 불확실한 단어, 깨진 버전명, 공백이 이상한 태그명은 "
                "확정 사실처럼 쓰지 마세요. "
                "명확한 파일명/명령/DevEvent 근거가 없으면 생략하세요.",
                "- raw diff나 코드 라인을 그대로 인용하지 마세요.",
                "- secret/token/password로 보이는 값은 언급하지 마세요.",
                "- diff 일부가 생략되어 있으면 DEV_EVENT 요약과 함께 보수적으로 추론하세요.",
                "- 근거가 부족한 섹션은 '확인된 내용 없음.'으로 작성하세요.",
                "- 섹션 순서를 지키세요.",
                "",
                "리포트 구조:",
                "## 오늘 한 일 요약",
                "## 시간대별 작업 흐름",
                "## 주요 트러블슈팅",
                "## 회의/메모에서 나온 결정사항",
                "## 테스트/검증 결과",
                "## 영향 없는 범위",
                "## 다음 작업 후보",
                "",
                "압축 타임라인:",
                safe_timeline,
            ]
        )

    def build_simple_daily_report_prompt(self, timeline: TimelineResponse) -> str:
        compressed_timeline = self._compress_timeline(timeline)
        safe_timeline = self.privacy_filter.mask(compressed_timeline)
        return "\n".join(
            [
                "다음은 개인 로컬 작업 기록 에이전트가 만든 일일 압축 타임라인입니다.",
                "원본 화면, 음성, 스크린샷, 오디오 파일은 포함하지 않았습니다.",
                "secret/token 패턴은 마스킹되었습니다.",
                "",
                "요청:",
                "- 한국어 Markdown 간단 리포트를 작성하고, 타임라인의 사실만 쓰세요.",
                "- 전체 내용을 짧고 실행 가능한 요약으로 압축하세요.",
                "- simple 리포트는 5~10줄 수준을 유지하고 파일 경로/브랜치/명령 로그를 숨기세요.",
                "- 오늘 한 일 요약은 3~5개 bullet로 작성하세요.",
                "- 완료한 작업은 입력에서 완료/구현/검증 근거가 있는 항목만 쓰세요.",
                "- 다음 작업은 이미 완료된 항목을 반복하지 말고 1~3개만 제안하세요.",
                "- 테스트/검증 결과는 pytest, run_dev_checks.py, git diff --check, ruff, "
                "alembic, xcodebuild 같은 검증 근거가 있을 때만 쓰세요.",
                "- 다음 작업은 로드맵/TODO/실패 QA/미완료 항목 기준으로만 쓰세요. 현재 로드맵은 "
                "13차 Launch at Login, 14차 메뉴바/플로팅 위젯 리팩토링, "
                "15차 Release 패키징입니다.",
                "- 회의 전사는 결정사항, 논의사항, 후속작업 후보로 짧게 반영하되, 잡담이나 "
                "휴식 대화를 작업 완료/결정사항으로 과장하지 마세요.",
                "- source=local_whisper_full_meeting의 timestamp와 microphone/system_audio "
                "label은 내부 근거로만 보고 리포트에 그대로 노출하지 마세요.",
                "- CURRENT_WORK_FOCUS, MEETING_MEMO_CONTEXT, PRIORITY_MEETING_TRANSCRIPTS, "
                "WORK_EVIDENCE_BY_TIME 등 prompt/input 내부 라벨명은 리포트에 "
                "쓰지 말고 자연어 요약에만 반영하세요.",
                "- raw diff나 코드 라인을 그대로 인용하지 마세요.",
                "- secret/token/password로 보이는 값은 언급하지 마세요.",
                "- 근거가 부족한 섹션은 '확인된 내용 없음.'으로 작성하세요.",
                "- 섹션 순서를 지키세요.",
                "",
                "리포트 구조:",
                "## 오늘 한 일 요약",
                "## 완료한 작업",
                "## 다음 작업",
                "## 테스트/검증 결과",
                "",
                "압축 타임라인:",
                safe_timeline,
            ]
        )

    def _compress_timeline(self, timeline: TimelineResponse) -> str:
        if not timeline.items:
            return f"DATE: {timeline.date.isoformat()}\nEMPTY: 기록된 작업이 없습니다."

        report_items = [
            item
            for item in timeline.items
            if item.type != "activity_segment" and not self._is_self_service_screen_item(item)
        ]
        activity_segments = [item for item in timeline.items if item.type == "activity_segment"]

        git_diff_context = self.git_diff_context_builder.build_for_timeline(timeline)
        command_flow_lines = self._format_command_flow_hints(report_items)

        lines = [
            f"DATE: {timeline.date.isoformat()}",
            f"TOTAL_ITEMS: {len(report_items)}",
            "NOTE: ActivitySegment는 주요 작업 환경 보조 정보이며 "
            "작업 내용의 직접 근거가 아닙니다.",
        ]
        current_focus_lines = self._format_current_work_focus(
            report_items,
            git_diff_context=git_diff_context,
            command_flow_lines=command_flow_lines,
        )
        if current_focus_lines:
            lines.append("CURRENT_WORK_FOCUS:")
            lines.extend(current_focus_lines)
        pruned_context_lines = self._format_pruned_report_context(
            report_items,
            git_diff_context=git_diff_context,
            current_focus_lines=current_focus_lines,
        )
        if pruned_context_lines:
            lines.append("PRUNED_REPORT_CONTEXT:")
            lines.extend(pruned_context_lines)
        report_evidence_blocks = self._format_report_evidence_blocks(
            report_items,
            activity_segments,
            current_focus_lines=current_focus_lines,
        )
        if report_evidence_blocks:
            lines.append("REPORT_EVIDENCE_BLOCKS:")
            lines.extend(report_evidence_blocks)

        meeting_memo_context_lines = self._format_meeting_memo_context(report_items)
        if meeting_memo_context_lines:
            lines.append("MEETING_MEMO_CONTEXT:")
            lines.extend(meeting_memo_context_lines)

        if git_diff_context is not None:
            if git_diff_context.change_hints:
                lines.append("PRIORITY_CURRENT_GIT_CHANGE_HINTS:")
                lines.extend(f"- {hint}" for hint in git_diff_context.change_hints[:8])
            lines.extend(
                [
                    "PRIORITY_CURRENT_GIT_DIFF_CONTEXT:",
                    f"repo_path={git_diff_context.repo_path}",
                    f"branch={git_diff_context.branch}",
                    "diff_policy=not_stored_privacy_filtered",
                    "usage=latest_work_intent_primary_evidence",
                    "content:",
                    "```diff",
                    git_diff_context.content,
                    "```",
                ]
            )
        memo_lines = [
            self._format_timeline_item(item)
            for item in report_items
            if item.type == "memo"
        ]
        if memo_lines:
            lines.append("PRIORITY_MEMOS:")
            lines.extend(memo_lines[:10])

        dev_event_lines = self._format_priority_dev_events(
            report_items,
            current_focus_lines=current_focus_lines,
        )
        if dev_event_lines:
            lines.append("PRIORITY_DEV_EVENTS:")
            lines.extend(dev_event_lines[:20])

        if command_flow_lines:
            lines.append("PRIORITY_COMMAND_FLOWS:")
            lines.extend(command_flow_lines[:10])

        transcript_lines = self._format_transcript_groups(report_items)
        if transcript_lines:
            lines.append("PRIORITY_MEETING_TRANSCRIPTS:")
            lines.extend(transcript_lines[:12])

        evidence_lines = self._format_work_evidence_by_time(
            report_items,
            current_focus_lines=current_focus_lines,
        )
        if evidence_lines:
            lines.append("WORK_EVIDENCE_BY_TIME:")
            lines.extend(evidence_lines)

        for item in report_items:
            if item.type in {"memo", "transcript"}:
                continue
            if self._should_prune_item_from_direct_report_input(
                item,
                report_items,
                current_focus_lines=current_focus_lines,
            ):
                continue
            lines.append(self._format_timeline_item(item))
        environment_summary = self._format_activity_environment_summary(activity_segments)
        if environment_summary:
            lines.append(environment_summary)
        return "\n".join(lines)

    def _format_timeline_item(self, item) -> str:
        timestamp = self._format_kst_time(item.timestamp)
        if item.type == "event":
            return (
                f"- EVENT | time={timestamp} | source={item.source or '-'} | "
                f"app={item.app_name or '-'} | window={item.window_title or '-'} | "
                f"content={item.content}"
            )
        if item.type == "activity_segment":
            ended_at = self._format_kst_time(item.ended_at) if item.ended_at else "-"
            return (
                f"- ACTIVITY_SEGMENT | start={timestamp} | end={ended_at} | "
                f"duration_seconds={item.duration_seconds or 0} | "
                f"samples={item.sample_count or 0} | "
                f"app={item.app_name or '-'} | window={item.window_title or '-'}"
            )
        if item.type == "memo":
            return (
                f"- MEMO | time={timestamp} | linked_type={item.linked_type or '-'} | "
                f"linked_id={item.linked_id or '-'} | content={item.content}"
            )
        if item.type == "screen_ocr":
            ocr_excerpt = self._build_ocr_evidence_snippet(item.ocr_text or item.content)
            inference = self._safe_inference(item.ai_inference or item.content)
            return (
                f"- SCREEN_OCR | time={timestamp} | app={item.app_name or '-'} | "
                f"keywords={item.detected_keywords or []} | "
                f"inference={inference} | "
                f"ocr_excerpt={ocr_excerpt}"
            )
        if item.type == "dev_event":
            return self._format_dev_event_for_report_input(item)
        if item.type == "meeting":
            return (
                f"- MEETING | time={timestamp} | meeting_id={item.meeting_id or item.id} | "
                f"content={item.content}"
            )
        if item.type == "transcript":
            text = self._normalize_transcript_content(item.content)
            return (
                f"- TRANSCRIPT | time={timestamp} | meeting_id={item.meeting_id or '-'} | "
                f"speaker={item.speaker or '-'} | confidence={item.confidence or '-'} | "
                f"text={text}"
            )
        return f"- {item.type.upper()} | time={timestamp} | content={item.content}"

    def _format_work_evidence_by_time(self, items, *, current_focus_lines=None) -> list[str]:
        grouped: dict[str, list[str]] = defaultdict(list)
        for item in items:
            if self._is_background_event(item, current_focus_lines or []):
                continue
            evidence = self._extract_item_evidence(item)
            if not evidence:
                continue
            local_timestamp = self._as_kst(item.timestamp)
            bucket_start = local_timestamp.replace(
                minute=(local_timestamp.minute // 30) * 30,
                second=0,
                microsecond=0,
            )
            bucket_end = bucket_start + timedelta(minutes=30)
            key = f"{bucket_start.strftime('%H:%M')}~{bucket_end.strftime('%H:%M')}"
            if evidence not in grouped[key]:
                grouped[key].append(evidence)

        lines: list[str] = []
        for time_range in sorted(grouped):
            evidence_text = " / ".join(grouped[time_range][:5])
            lines.append(f"- WORK_BLOCK | time_range={time_range} | evidence={evidence_text}")
        return lines[:12]

    def _extract_item_evidence(self, item) -> str:
        if item.type == "memo":
            return ""
        if item.type == "screen_ocr":
            if self._contains_uncertain_noise(item.content, item.ocr_text, item.ai_inference):
                return ""
            inference = self._safe_inference(item.ai_inference or "")
            snippet = self._build_ocr_evidence_snippet(item.ocr_text or item.content)
            keywords = self._extract_work_keywords(
                " ".join(
                    value
                    for value in [
                        item.content,
                        item.ocr_text,
                        item.ai_inference,
                        " ".join(item.detected_keywords or [])
                        if isinstance(item.detected_keywords, list)
                        else "",
                    ]
                    if value
                )
            )
            if inference != "-":
                return f"화면 관찰: {inference}"
            if snippet:
                keyword_text = f" keywords={keywords}" if keywords else ""
                return f"화면 단서: {snippet}{keyword_text}"
            return ""
        if item.type == "dev_event":
            if item.event_type == "git_snapshot":
                changed_files = self._details_list(item.details_json, "changed_files")
                if not changed_files:
                    return ""
                return (
                    f"개발 근거: {self._infer_work_title_from_files(changed_files)} "
                    f"({self._summarize_file_groups(changed_files) or '일반 코드'}, "
                    f"{len(changed_files)}개 파일)"
                )
            if item.event_type == "command_result":
                command = item.command or item.content
                if (
                    self._is_inspection_command(command)
                    or self._is_destructive_cleanup_command(command)
                    or "tests/not_exists.py" in self._normalize_command(command)
                ):
                    return ""
            if self._is_auto_git_snapshot(item):
                return ""
            return f"개발 근거: {self._truncate(item.content, 180)}"
        if item.type == "event" and item.source != "mac_active_window":
            keywords = self._extract_work_keywords(item.content)
            if keywords or self._looks_like_work_evidence(item.content):
                return f"이벤트: {self._truncate(item.content, 140)}"
        if item.type == "transcript":
            return ""
        return ""

    def _format_auto_git_snapshot_groups(self, items, *, current_focus_lines=None) -> list[str]:
        grouped: dict[tuple[str, str], list] = defaultdict(list)
        for item in items:
            if not self._is_auto_git_snapshot(item):
                continue
            if self._is_background_event(item, current_focus_lines or []):
                continue
            local_timestamp = self._as_kst(item.timestamp)
            bucket_start = local_timestamp.replace(
                minute=(local_timestamp.minute // 20) * 20,
                second=0,
                microsecond=0,
            )
            bucket_end = bucket_start + timedelta(minutes=20)
            time_range = f"{bucket_start.strftime('%H:%M')}~{bucket_end.strftime('%H:%M')}"
            branch = item.branch or "-"
            grouped[(time_range, branch)].append(item)

        lines: list[str] = []
        for time_range, branch in sorted(grouped):
            group_items = sorted(grouped[(time_range, branch)], key=lambda item: item.timestamp)
            changed_files = self._collect_changed_files(group_items)
            diff_summary = self._collect_diff_summary(group_items)
            file_groups = self._summarize_file_groups(changed_files)
            work_title = self._infer_work_title_from_files(changed_files)
            diff_evidence = self._format_diff_summary_list(diff_summary)
            diff_suffix = f" | diff_evidence={diff_evidence}" if diff_evidence else ""
            lines.append(
                "- DEV_EVENT_GROUP | "
                f"time_range={time_range} | event_type=git_snapshot | "
                f"source=watch | evidence_type=code_change_evidence | "
                f"branch_hint={self._branch_hint(branch)} | "
                f"title={work_title} | work_area={file_groups or '일반 코드'} | "
                f"related_files_count={len(changed_files)} | "
                f"source_event_ids={self._source_event_ids(group_items)}"
                f"{diff_suffix}"
            )
        return lines

    def _format_priority_dev_events(self, items, *, current_focus_lines=None) -> list[str]:
        grouped_lines = self._format_auto_git_snapshot_groups(
            items,
            current_focus_lines=current_focus_lines,
        )
        manual_events = [
            item
            for item in items
            if (
                item.type == "dev_event"
                and not self._is_auto_git_snapshot(item)
                and not self._should_prune_command_from_direct_report_input(item, items)
                and not self._is_background_event(item, current_focus_lines or [])
            )
        ]
        manual_events.sort(key=self._dev_event_priority_key)
        return grouped_lines + [
            self._format_dev_event_for_report_input(item) for item in manual_events
        ]

    def _format_report_evidence_blocks(
        self,
        items,
        activity_segments,
        *,
        current_focus_lines: list[str],
    ) -> list[str]:
        lines: list[str] = []
        git_evidence_blocks = self._format_git_evidence_blocks(
            items,
            current_focus_lines=current_focus_lines,
        )
        for line in git_evidence_blocks:
            lines.append(line)
        validation_summary = self._summarize_validation_commands(items)
        if validation_summary:
            lines.append(
                "- REPORT_EVIDENCE_BLOCK | evidence_type=validation | "
                f"title=테스트/검증 결과 | validation_evidence={validation_summary} | "
                "signal_level=high_signal"
            )
        for item in activity_segments:
            if getattr(item, "hidden_by_default", False) or getattr(item, "noise_reason", None):
                continue
            signal_level = getattr(item, "signal_level", None) or "medium_signal"
            if signal_level not in {"high_signal", "medium_signal"}:
                continue
            display_title = getattr(item, "display_title", None) or self._activity_display_title(
                item
            )
            lines.append(
                "- REPORT_EVIDENCE_BLOCK | evidence_type=activity_context | "
                f"time_range={self._format_activity_range(item)} | title={display_title} | "
                f"signal_level={signal_level} | duration_seconds={item.duration_seconds or 0} | "
                f"source_event_ids={item.id}"
            )
        return lines[:16]

    def _format_git_evidence_blocks(self, items, *, current_focus_lines: list[str]) -> list[str]:
        grouped: dict[str, list] = defaultdict(list)
        for item in items:
            if item.type != "dev_event" or item.event_type != "git_snapshot":
                continue
            if self._is_background_event(item, current_focus_lines):
                continue
            changed_files = self._details_list(item.details_json, "changed_files")
            if not changed_files:
                continue
            title = self._infer_work_title_from_files(changed_files)
            grouped[title].append(item)

        lines: list[str] = []
        for title, group_items in grouped.items():
            sorted_items = sorted(group_items, key=lambda item: item.timestamp)
            changed_files = self._collect_changed_files(sorted_items)
            file_groups = self._summarize_file_groups(changed_files)
            lines.append(
                "- REPORT_EVIDENCE_BLOCK | evidence_type=code_change_evidence | "
                f"time_range={self._format_kst_time(sorted_items[0].timestamp)}~"
                f"{self._format_kst_time(sorted_items[-1].timestamp)} | "
                f"title={title} | work_area={file_groups or '일반 코드'} | "
                f"related_files_count={len(changed_files)} | "
                f"source_event_ids={self._source_event_ids(sorted_items)}"
            )
        return lines

    def _format_dev_event_for_report_input(self, item) -> str:
        timestamp = self._format_kst_time(item.timestamp)
        if item.event_type == "git_snapshot":
            changed_files = self._details_list(item.details_json, "changed_files")
            return (
                "- DEV_EVENT | "
                f"time={timestamp} | event_type=git_snapshot | "
                "evidence_type=code_change_evidence | "
                f"title={self._infer_work_title_from_files(changed_files)} | "
                f"work_area={self._summarize_file_groups(changed_files) or '일반 코드'} | "
                f"related_files_count={len(changed_files)} | source_event_ids={item.id}"
            )
        if item.event_type == "command_result":
            command = item.command or item.content
            return (
                "- DEV_EVENT | "
                f"time={timestamp} | event_type=command_result | source={item.source or '-'} | "
                f"status={item.status or '-'} | command_family={self._command_family(command)} | "
                f"summary={self._summarize_command_event(item)}"
            )
        if item.event_type in {"test_result", "build_result"}:
            return (
                "- DEV_EVENT | "
                f"time={timestamp} | event_type={item.event_type} | "
                f"status={item.status or '-'} | summary={self._truncate(item.content, 160)}"
            )
        return (
            "- DEV_EVENT | "
            f"time={timestamp} | event_type={item.event_type or '-'} | "
            f"status={item.status or '-'} | summary={self._truncate(item.content, 180)}"
        )

    def _format_current_work_focus(
        self,
        items,
        *,
        git_diff_context,
        command_flow_lines: list[str],
    ) -> list[str]:
        evidence_files = self._current_focus_evidence_files(items, git_diff_context)
        focus_keywords = self._current_focus_keywords(
            evidence_files=evidence_files,
            git_diff_context=git_diff_context,
            command_flow_lines=command_flow_lines,
        )
        current_focus = self._infer_current_focus(
            evidence_files=evidence_files,
            focus_keywords=focus_keywords,
            git_diff_context=git_diff_context,
        )
        if not current_focus and not evidence_files and not focus_keywords:
            return []

        lines = [
            f"- current_focus={current_focus or 'latest timeline evidence review'}",
        ]
        if evidence_files:
            lines.append(
                f"- evidence_work_area={self._summarize_file_groups(evidence_files)} | "
                f"related_files_count={len(evidence_files)}"
            )
        if focus_keywords:
            lines.append(f"- focus_keywords={', '.join(focus_keywords[:10])}")
        lines.append(
            "- usage=오늘 한 일 요약의 첫 문장과 시간대별 작업 흐름은 이 최신 작업 주제를 "
            "우선 중심으로 작성"
        )
        return lines

    def _format_pruned_report_context(
        self,
        items,
        *,
        git_diff_context,
        current_focus_lines: list[str],
    ) -> list[str]:
        lines: list[str] = [
            "- usage=이 섹션은 원본 이벤트 나열보다 우선하는 report input pruning 요약입니다."
        ]
        focus_summary = self._summarize_focus_relevant_events(
            items,
            git_diff_context=git_diff_context,
            current_focus_lines=current_focus_lines,
        )
        if focus_summary:
            lines.append(f"- focus_relevant={focus_summary}")
        validation_summary = self._summarize_validation_commands(items)
        if validation_summary:
            lines.append(f"- validation={validation_summary}")
        qa_failure_summary = self._summarize_intentional_qa_failures(items)
        if qa_failure_summary:
            lines.append(f"- qa_failures={qa_failure_summary}")
        inspection_summary = self._summarize_inspection_commands(items)
        if inspection_summary:
            lines.append(f"- inspection={inspection_summary}")
        cleanup_summary = self._summarize_cleanup_commands(items)
        if cleanup_summary:
            lines.append(f"- cleanup={cleanup_summary}")
        background_summary = self._summarize_background_events(items, current_focus_lines)
        if background_summary:
            lines.append(f"- background={background_summary}")
        if len(lines) <= 2:
            return []
        return lines

    def _summarize_focus_relevant_events(
        self,
        items,
        *,
        git_diff_context,
        current_focus_lines: list[str],
    ) -> str:
        focus_text = " ".join(current_focus_lines).lower()
        evidence_files = self._current_focus_evidence_files(items, git_diff_context)
        relevant_files: list[str] = []
        for file_path in evidence_files:
            if file_path not in relevant_files:
                relevant_files.append(file_path)
        if relevant_files:
            file_text = ", ".join(relevant_files[:4])
            if "report quality" in focus_text or "report quality 개선" in focus_text:
                return f"report quality 개선 관련 {file_text} 변경과 테스트 보강"
            return f"현재 focus 관련 {file_text} 변경"
        return ""

    def _summarize_validation_commands(self, items) -> str:
        commands: list[str] = []
        for item in self._terminal_command_items(items):
            if item.status != "success" or not self._is_development_command(
                item.command or item.content
            ):
                continue
            family = self._command_family(item.command or item.content)
            if family not in commands:
                commands.append(family)
        return ", ".join(commands[:6])

    def _summarize_intentional_qa_failures(self, items) -> str:
        failures = [
            item
            for item in self._terminal_command_items(items)
            if self._is_intentional_qa_failure(item, items)
        ]
        if not failures:
            return ""
        return (
            "tests/not_exists.py 실패는 failed command 기록 검증용 QA로 판단. "
            "실제 제품 장애로 과장하지 말 것."
        )

    def _summarize_inspection_commands(self, items) -> str:
        commands = [
            item
            for item in self._terminal_command_items(items)
            if self._is_inspection_command(item.command or item.content)
        ]
        if not commands:
            return ""
        families: list[str] = []
        for item in commands:
            family = self._command_family(item.command or item.content)
            if family not in families:
                families.append(family)
        return (
            f"inspection/setup command {len(commands)}개는 DB 조회, report 생성, status 확인, "
            f"브랜치 준비 보조 근거로 축약({', '.join(families[:5])})"
        )

    def _summarize_cleanup_commands(self, items) -> str:
        commands = [
            item
            for item in self._terminal_command_items(items)
            if self._is_destructive_cleanup_command(item.command or item.content)
        ]
        if not commands:
            return ""
        return "불필요한 앱/빌드 산출물 정리"

    def _summarize_background_events(self, items, current_focus_lines: list[str]) -> str:
        focus_text = " ".join(current_focus_lines).lower()
        background_markers = []
        for item in items:
            text = " ".join(
                str(value)
                for value in [item.content, item.branch, item.event_type, item.source]
                if value
            ).lower()
            if "timeline" in text and "filter" in text and "timeline filtering" not in focus_text:
                background_markers.append("timeline filtering")
            if "command tracking" in text and "command tracking" not in focus_text:
                background_markers.append("command tracking")
            if "xcodebuild" in text and "xcodebuild" not in focus_text:
                background_markers.append("xcodebuild")
        deduped = []
        for marker in background_markers:
            if marker not in deduped:
                deduped.append(marker)
        if not deduped:
            return ""
        return f"{', '.join(deduped[:4])} 관련 과거 이벤트는 현재 focus의 배경으로만 사용"

    def _current_focus_evidence_files(self, items, git_diff_context) -> list[str]:
        evidence_files: list[str] = []
        if git_diff_context is not None:
            for hint in git_diff_context.change_hints:
                file_path = hint.split(":", 1)[0].strip()
                if "/" in file_path and file_path not in evidence_files:
                    evidence_files.append(file_path)
            for file_path in self._extract_diff_file_paths(git_diff_context.content):
                if file_path not in evidence_files:
                    evidence_files.append(file_path)

        if evidence_files:
            return evidence_files[:8]

        dev_items = [
            item
            for item in items
            if item.type == "dev_event" and item.details_json and item.timestamp is not None
        ]
        for item in sorted(dev_items, key=lambda item: item.timestamp, reverse=True)[:5]:
            for file_path in self._details_list(item.details_json, "changed_files"):
                if file_path not in evidence_files:
                    evidence_files.append(file_path)
        return evidence_files[:8]

    def _extract_diff_file_paths(self, diff_content: str | None) -> list[str]:
        if not diff_content:
            return []
        paths: list[str] = []
        for match in re.finditer(r"^diff --git a/(.+?) b/", diff_content, flags=re.MULTILINE):
            file_path = match.group(1).strip()
            if file_path and file_path not in paths:
                paths.append(file_path)
        return paths

    def _current_focus_keywords(
        self,
        *,
        evidence_files: list[str],
        git_diff_context,
        command_flow_lines: list[str],
    ) -> list[str]:
        source_text = " ".join(evidence_files)
        if git_diff_context is not None:
            source_text = " ".join(
                [
                    source_text,
                    " ".join(git_diff_context.change_hints),
                    git_diff_context.content,
                ]
            )
        source_text = " ".join([source_text, " ".join(command_flow_lines)])
        lowered = source_text.lower()
        keyword_rules = [
            ("PRIORITY_COMMAND_FLOWS", "priority_command_flows"),
            ("failed_to_success", "failed_to_success"),
            ("inspection command", "inspection"),
            ("cleanup command", "cleanup"),
            ("meeting transcript instruction", "transcript"),
            ("next action 후보 보정", "next task"),
            ("next action 후보 보정", "next action"),
            ("CURRENT_WORK_FOCUS", "current_work_focus"),
            ("prompt_builder.py", "prompt_builder.py"),
            ("test_ai_components.py", "test_ai_components.py"),
            ("timeline filtering", "timeline"),
            ("command_result", "command_result"),
            ("git_snapshot", "git_snapshot"),
        ]
        keywords: list[str] = []
        for label, marker in keyword_rules:
            if marker.lower() in lowered and label not in keywords:
                keywords.append(label)
        return keywords

    def _infer_current_focus(
        self,
        *,
        evidence_files: list[str],
        focus_keywords: list[str],
        git_diff_context,
    ) -> str:
        focus_text = " ".join(evidence_files + focus_keywords)
        if git_diff_context is not None:
            focus_text = " ".join([focus_text, " ".join(git_diff_context.change_hints)])
        lowered = focus_text.lower()
        if (
            "prompt_builder.py" in lowered
            or "test_ai_components.py" in lowered
            or "priority_command_flows" in lowered
            or "current_work_focus" in lowered
        ):
            return "report quality 개선"
        if "timeline" in lowered and "filter" in lowered:
            return "timeline filtering 개선"
        if "command" in lowered and "tracking" in lowered:
            return "command tracking 개선"
        if "meeting" in lowered or "transcript" in lowered:
            return "meeting transcript 품질 개선"
        if evidence_files:
            return "current implementation refinement"
        return ""

    def _format_command_flow_hints(self, items) -> list[str]:
        terminal_commands = self._terminal_command_items(items)
        if not terminal_commands:
            return []

        sorted_commands = sorted(terminal_commands, key=lambda item: item.timestamp)
        lines: list[str] = []
        paired_success_ids: set[int] = set()
        for item in sorted_commands:
            if item.status != "failed":
                continue
            next_success = self._find_next_success_command(item, sorted_commands)
            if next_success is None:
                lines.append(
                    self._format_command_flow_line(
                        [item],
                        flow_type="failed_only",
                        hint=(
                            "failed command입니다. stdout/stderr 전문이 없으므로 실패 원인은 "
                            "주변 DevEvent와 diff context 근거가 있을 때만 보수적으로 판단하세요."
                        ),
                    )
                )
                continue
            paired_success_ids.add(next_success.id)
            lines.append(
                self._format_command_flow_line(
                    [item, next_success],
                    flow_type="failed_to_success",
                    hint=(
                        "같은 명령군의 실패 후 성공 흐름입니다. 개별 명령 나열보다 "
                        "수정/보완/검증이 이어진 하나의 흐름으로 요약하세요."
                    ),
                )
            )

        development_commands = [
            item
            for item in sorted_commands
            if (
                item.status == "success"
                and item.id not in paired_success_ids
                and self._is_development_command(item.command or item.content)
            )
        ]
        if development_commands:
            lines.append(
                self._format_command_flow_line(
                    development_commands[:5],
                    flow_type="development_validation",
                    hint="개발 검증 command입니다. 구현 내용의 검증 근거로 우선 반영하세요.",
                )
            )

        inspection_commands = [
            item
            for item in sorted_commands
            if self._is_inspection_command(item.command or item.content)
        ]
        if inspection_commands:
            lines.append(
                self._format_command_flow_line(
                    inspection_commands[:5],
                    flow_type="inspection",
                    hint=(
                        "확인용 command입니다. 최종 리포트에 직접 나열하지 말고 "
                        "저장 결과/리포트 생성 확인 같은 보조 검증으로 묶으세요."
                    ),
                )
            )

        destructive_commands = [
            item
            for item in sorted_commands
            if self._is_destructive_cleanup_command(item.command or item.content)
        ]
        if destructive_commands:
            lines.append(
                self._format_command_flow_line(
                    destructive_commands[:3],
                    flow_type="cleanup",
                    hint=(
                        "destructive cleanup command입니다. 경로나 명령을 과하게 나열하지 말고 "
                        "불필요한 앱/빌드 산출물 정리 정도로 짧게 요약하세요."
                    ),
                )
            )

        return lines

    def _find_next_success_command(self, failed_item, sorted_commands) -> object | None:
        failed_family = self._command_family(failed_item.command or failed_item.content)
        for candidate in sorted_commands:
            if candidate.timestamp <= failed_item.timestamp:
                continue
            if candidate.status != "success":
                continue
            if self._command_family(candidate.command or candidate.content) != failed_family:
                continue
            elapsed = candidate.timestamp - failed_item.timestamp
            if elapsed.total_seconds() > 45 * 60:
                continue
            return candidate
        return None

    def _format_command_flow_line(self, items, *, flow_type: str, hint: str) -> str:
        sorted_items = sorted(items, key=lambda item: item.timestamp)
        start_time = self._format_kst_time(sorted_items[0].timestamp)
        end_time = self._format_kst_time(sorted_items[-1].timestamp)
        if flow_type == "inspection":
            commands = ["inspection/setup commands summarized"]
        elif flow_type == "cleanup":
            commands = ["cleanup command summarized"]
        elif any(self._is_intentional_qa_failure(item, sorted_items) for item in sorted_items):
            commands = ["intentional QA failure + validation command summarized"]
            hint = (
                f"{hint} tests/not_exists.py 실패는 failed command 기록 검증용 QA로 판단하고 "
                "실제 제품 장애처럼 과장하지 마세요."
            )
        else:
            commands = [
                self._truncate(self._normalize_command(item.command or item.content), 120)
                for item in sorted_items
            ]
        statuses = "->".join(str(item.status or "unknown") for item in sorted_items)
        command_families = []
        for item in sorted_items:
            family = self._command_family(item.command or item.content)
            if family not in command_families:
                command_families.append(family)
        if flow_type == "inspection":
            command_families = ["inspection/setup"]
        elif flow_type == "cleanup":
            command_families = ["cleanup"]
        return (
            "- COMMAND_FLOW | "
            f"time_range={start_time}~{end_time} | "
            f"flow_type={flow_type} | "
            f"command_family={', '.join(command_families) or '-'} | "
            f"statuses={statuses} | "
            f"commands={'; '.join(commands)} | "
            f"hint={hint}"
        )

    def _terminal_command_items(self, items) -> list:
        return [
            item
            for item in items
            if (
                item.type == "dev_event"
                and item.event_type == "command_result"
                and item.source == "terminal"
            )
        ]

    def _should_prune_command_from_direct_report_input(self, item, items) -> bool:
        if item.type != "dev_event" or item.event_type != "command_result":
            return False
        command = item.command or item.content
        return (
            self._is_inspection_command(command)
            or self._is_destructive_cleanup_command(command)
            or self._is_intentional_qa_failure(item, items)
        )

    def _should_prune_item_from_direct_report_input(
        self,
        item,
        items,
        *,
        current_focus_lines: list[str],
    ) -> bool:
        if self._is_auto_git_snapshot(item):
            return True
        if item.type == "dev_event":
            if item.event_type == "command_result":
                return self._should_prune_command_from_direct_report_input(item, items)
            return self._is_background_event(item, current_focus_lines)
        if item.type in {"screen_ocr", "transcript", "event"}:
            return self._contains_uncertain_noise(
                item.content,
                getattr(item, "ocr_text", None),
                getattr(item, "ai_inference", None),
            )
        return False

    def _command_family(self, command: str | None) -> str:
        normalized = self._normalize_command(command)
        if normalized.startswith("uv run pytest"):
            return "uv run pytest"
        if normalized.startswith("pytest"):
            return "pytest"
        if normalized.startswith("uv run python scripts/run_dev_checks.py"):
            return "uv run python scripts/run_dev_checks.py"
        if normalized.startswith("uv run alembic check"):
            return "uv run alembic check"
        if normalized.startswith("./scripts/build_macos_app.sh"):
            return "./scripts/build_macos_app.sh"
        if normalized.startswith("./scripts/test_macos_timeline_presentation.sh"):
            return "./scripts/test_macos_timeline_presentation.sh"
        if normalized.startswith("./scripts/test_macos_report_presentation.sh"):
            return "./scripts/test_macos_report_presentation.sh"
        if normalized.startswith(("uv run ruff", "ruff")):
            return "ruff"
        if normalized.startswith("xcodebuild"):
            return "xcodebuild"
        if normalized.startswith("git diff --check"):
            return "git diff --check"
        if normalized.startswith("git checkout"):
            return "git checkout"
        if normalized.startswith("git branch"):
            return "git branch"
        if normalized.startswith("git status"):
            return "git status"
        if normalized.startswith("git diff"):
            return "git diff"
        if normalized.startswith("git log"):
            return "git log"
        if normalized.startswith(("bash -n", "zsh -n")):
            return "shell syntax check"
        if normalized.startswith("curl"):
            return "curl"
        if normalized.startswith("sqlite3"):
            return "sqlite3"
        if normalized.startswith("source"):
            return "source"
        if normalized.startswith("git switch"):
            return "git switch"
        if normalized.startswith("git pull"):
            return "git pull"
        if normalized.startswith("git tag"):
            return "git tag"
        first_words = normalized.split(maxsplit=2)
        return " ".join(first_words[:2]) if first_words else "-"

    def _dev_event_priority_key(self, item) -> tuple[int, datetime]:
        if item.event_type == "command_result" and item.source == "terminal":
            if item.status == "failed":
                return (0, item.timestamp)
            if self._is_development_command(item.command or item.content):
                return (1, item.timestamp)
            if self._is_inspection_command(item.command or item.content):
                return (4, item.timestamp)
            return (2, item.timestamp)
        if item.event_type in {"test_result", "build_result"} and item.status == "failed":
            return (3, item.timestamp)
        return (5, item.timestamp)

    def _is_development_command(self, command: str | None) -> bool:
        normalized = self._normalize_command(command)
        return normalized.startswith(
            (
                "uv run pytest",
                "uv run python scripts/run_dev_checks.py",
                "uv run alembic check",
                "./scripts/build_macos_app.sh",
                "./scripts/test_macos_timeline_presentation.sh",
                "./scripts/test_macos_report_presentation.sh",
                "git diff --check",
                "ruff",
                "uv run ruff",
                "xcodebuild",
                "bash -n",
                "zsh -n",
            )
        )

    def _is_inspection_command(self, command: str | None) -> bool:
        normalized = self._normalize_command(command)
        return normalized.startswith(
            (
                "sqlite3",
                "echo",
                "source ~/.zshrc",
                "source .zshrc",
                "mwoham_command_tracking_status",
                "mwoham_command_tracking_disable",
                "git checkout",
                "git branch",
                "git status",
                "git diff",
                "git log",
                "git switch",
                "git pull",
            )
        ) or normalized.startswith("curl") or self._is_git_tag_inspection_command(normalized)

    def _is_git_tag_inspection_command(self, normalized_command: str) -> bool:
        return (
            normalized_command == "git tag"
            or normalized_command.startswith("git tag |")
            or normalized_command.startswith("git tag --list")
            or normalized_command.startswith("git tag -l")
        )

    def _is_destructive_cleanup_command(self, command: str | None) -> bool:
        normalized = self._normalize_command(command)
        return normalized.startswith("rm -rf") or " rm -rf " in f" {normalized} "

    def _is_intentional_qa_failure(self, item, items) -> bool:
        if item.status != "failed":
            return False
        normalized = self._normalize_command(item.command or item.content)
        if "tests/not_exists.py" not in normalized:
            return False
        item_timestamp = getattr(item, "timestamp", None)
        if item_timestamp is None:
            return True
        for candidate in self._terminal_command_items(items):
            if candidate.status != "success":
                continue
            if not self._is_development_command(candidate.command or candidate.content):
                continue
            elapsed = abs((candidate.timestamp - item_timestamp).total_seconds())
            if elapsed <= 45 * 60:
                return True
        return False

    def _is_background_event(self, item, current_focus_lines: list[str]) -> bool:
        focus_text = " ".join(current_focus_lines).lower()
        text = " ".join(
            str(value)
            for value in [item.content, item.branch, item.event_type, item.source]
            if value
        ).lower()
        if "timeline" in text and "filter" in text and "timeline filtering" not in focus_text:
            return True
        if "command tracking" in text and "command tracking" not in focus_text:
            return True
        if "xcodebuild" in text and "xcodebuild" not in focus_text:
            return True
        return False

    def _contains_uncertain_noise(self, *values: str | None) -> bool:
        text = " ".join(value for value in values if value).lower()
        if not text:
            return False
        noise_tokens = (
            "command_talled",
            "mianation",
            "time line-filtering",
            "time line filtering",
        )
        return any(token in text for token in noise_tokens)

    def _normalize_command(self, command: str | None) -> str:
        return " ".join((command or "").split()).strip()

    def _is_auto_git_snapshot(self, item) -> bool:
        if item.type != "dev_event" or item.event_type != "git_snapshot":
            return False
        details = item.details_json or {}
        return details.get("tracking_mode") == "watch" or bool(details.get("tracking_signature"))

    def _collect_changed_files(self, items) -> list[str]:
        changed_files: list[str] = []
        for item in items:
            for file_path in self._details_list(item.details_json, "changed_files"):
                if file_path not in changed_files:
                    changed_files.append(file_path)
        return changed_files

    def _collect_diff_summary(self, items) -> list[dict]:
        summary_by_file: dict[str, dict] = {}
        for item in items:
            details = item.details_json or {}
            diff_summary = details.get("diff_summary")
            if not isinstance(diff_summary, list):
                continue
            for raw_entry in diff_summary:
                if not isinstance(raw_entry, dict):
                    continue
                file_path = raw_entry.get("file")
                if not isinstance(file_path, str) or not file_path:
                    continue
                if file_path not in summary_by_file:
                    summary_by_file[file_path] = dict(raw_entry)
        changed_files = self._collect_changed_files(items)
        return [
            summary_by_file[file_path]
            for file_path in changed_files
            if file_path in summary_by_file
        ]

    def _summarize_file_groups(self, changed_files: list[str]) -> str:
        if not changed_files:
            return ""

        priority_prefixes = (
            "backend/scripts",
            "backend/tests",
            "backend/app",
            "mac-client/MwohamMac",
            "docs",
        )
        groups: list[str] = []
        for file_path in changed_files:
            group = next(
                (prefix for prefix in priority_prefixes if file_path.startswith(prefix)),
                self._generic_file_group(file_path),
            )
            if group and group not in groups:
                groups.append(group)
        return ", ".join(groups[:4])

    def _generic_file_group(self, file_path: str) -> str:
        parts = [part for part in file_path.split("/") if part]
        if len(parts) >= 2:
            return "/".join(parts[:2])
        return "root files" if parts else ""

    def _format_changed_file_list(self, changed_files: list[str], limit: int = 8) -> str:
        if not changed_files:
            return ""
        visible_files = changed_files[:limit]
        suffix = f" 외 {len(changed_files) - limit}개" if len(changed_files) > limit else ""
        return ", ".join(visible_files) + suffix

    def _format_diff_summary_list(self, diff_summary: list[dict], limit: int = 8) -> str:
        if not diff_summary:
            return ""
        visible = diff_summary[:limit]
        binary_count = sum(1 for item in diff_summary if item.get("binary"))
        untracked_count = sum(1 for item in diff_summary if item.get("untracked"))
        insertions = sum(
            item.get("insertions") for item in visible if isinstance(item.get("insertions"), int)
        )
        deletions = sum(
            item.get("deletions") for item in visible if isinstance(item.get("deletions"), int)
        )
        parts = [f"files={len(diff_summary)}"]
        if insertions or deletions:
            parts.append(f"insertions={insertions}")
            parts.append(f"deletions={deletions}")
        if binary_count:
            parts.append(f"binary={binary_count}")
        if untracked_count:
            parts.append(f"added={untracked_count}")
        if len(diff_summary) > limit:
            parts.append(f"limited={limit}")
        return ", ".join(parts)

    def _format_diff_summary_item(self, item: dict) -> str:
        file_path = item.get("file")
        if not isinstance(file_path, str) or not file_path:
            return ""
        if item.get("binary"):
            return f"{file_path}(binary)"
        if item.get("untracked"):
            return f"{file_path}(added)"
        insertions = item.get("insertions")
        deletions = item.get("deletions")
        if isinstance(insertions, int) and isinstance(deletions, int):
            return f"{file_path}(+{insertions}/-{deletions})"
        return file_path

    def _infer_work_title_from_files(self, changed_files: list[str]) -> str:
        lowered = " ".join(path.lower() for path in changed_files)
        if "timeline_builder" in lowered or "activity_event_refiner" in lowered:
            return "타임라인 작업 근거 품질 개선"
        if "prompt_builder" in lowered or "report_fallback_builder" in lowered:
            return "리포트 입력 품질 개선"
        if "reportpageview" in lowered or "/reports.html" in lowered or "report_" in lowered:
            return "리포트 편집 UX 개선"
        if "timeline" in lowered and "mac-client" in lowered:
            return "macOS 타임라인 UX 개선"
        if "meeting" in lowered or "transcript" in lowered or "whisper" in lowered:
            return "회의 전사 품질 개선"
        if "dev_tracking" in lowered or "record_command_result" in lowered:
            return "개발 이벤트 추적 개선"
        if "permission" in lowered or "signing" in lowered:
            return "macOS 권한/서명 안정화"
        if "test" in lowered:
            return "테스트 보강"
        if any(path.startswith("docs/") for path in changed_files):
            return "문서 및 QA 정리"
        if changed_files:
            return "구현 변경 정리"
        return "개발 작업 근거 정리"

    def _branch_hint(self, branch: str) -> str:
        if not branch or branch == "-":
            return "-"
        normalized = branch.replace("_", "-")
        tail = normalized.split("/")[-1]
        return " ".join(part for part in tail.split("-") if part) or "-"

    def _source_event_ids(self, items) -> str:
        return ",".join(str(item.id) for item in items)

    def _summarize_command_event(self, item) -> str:
        command = item.command or item.content
        family = self._command_family(command)
        status = (
            "성공"
            if item.status == "success"
            else "실패"
            if item.status == "failed"
            else "확인"
        )
        if self._is_development_command(command):
            return f"{family} 검증 {status}"
        if self._is_inspection_command(command):
            return "상태 확인용 명령"
        if self._is_destructive_cleanup_command(command):
            return "불필요한 산출물 정리"
        return self._truncate(item.content, 140)

    def _activity_display_title(self, item) -> str:
        title = getattr(item, "display_title", None)
        if title:
            return title
        values = [
            value
            for value in [getattr(item, "app_name", None), getattr(item, "window_title", None)]
            if value
        ]
        return " / ".join(values) if values else "작업 환경"

    def _format_activity_range(self, item) -> str:
        start = self._format_kst_time(item.timestamp)
        end = self._format_kst_time(item.ended_at) if item.ended_at else start
        return f"{start}~{end}"

    def _details_list(self, details: dict | None, key: str) -> list[str]:
        if not details:
            return []
        value = details.get(key)
        if not isinstance(value, list):
            return []
        return [str(item) for item in value if item is not None]

    def _normalize_transcript_content(self, content: str) -> str:
        prefixes = ("회의 전사 수집됨:", "회의 전사 수집됨")
        normalized = re.sub(r"\s+", " ", content).strip()
        for prefix in prefixes:
            if normalized.startswith(prefix):
                return normalized.removeprefix(prefix).strip()
        return normalized

    def _transcript_content_without_collection_prefix(self, content: str) -> str:
        prefixes = ("회의 전사 수집됨:", "회의 전사 수집됨")
        normalized = content.strip()
        for prefix in prefixes:
            if normalized.startswith(prefix):
                return normalized.removeprefix(prefix).strip()
        return normalized

    def _is_local_whisper_full_meeting(self, item) -> bool:
        return getattr(item, "source", None) == self.LOCAL_WHISPER_FULL_MEETING_SOURCE

    def _iter_report_transcript_entries(self, item) -> list[dict[str, str]]:
        if self._is_local_whisper_full_meeting(item):
            return self._extract_local_whisper_entries(item.content)
        text = self._normalize_transcript_content(item.content)
        return [{"text": text, "source_label": "", "time_label": ""}] if text else []

    def _extract_local_whisper_entries(self, content: str) -> list[dict[str, str]]:
        text = self._transcript_content_without_collection_prefix(content)
        entries: list[dict[str, str]] = []
        fallback_lines: list[str] = []
        for raw_line in text.splitlines():
            line = " ".join(raw_line.split())
            if not line:
                continue
            match = self.MEETING_SEGMENT_PREFIX_RE.match(line)
            if match:
                segment_text = self._weaken_transcript_for_report(match.group("text"))
                if segment_text:
                    entries.append(
                        {
                            "text": segment_text,
                            "source_label": match.group("source"),
                            "time_label": match.group("time"),
                        }
                    )
            else:
                fallback_lines.append(line)

        if entries:
            return entries

        fallback_text = self._weaken_transcript_for_report(" ".join(fallback_lines))
        if not fallback_text:
            return []
        return [{"text": fallback_text, "source_label": "", "time_label": ""}]

    def _weaken_transcript_for_report(self, text: str) -> str:
        without_prefix = self.MEETING_SEGMENT_PREFIX_RE.sub(r"\g<text>", text.strip())
        normalized = re.sub(r"\s+", " ", without_prefix).strip()
        if not normalized:
            return ""
        lowered = normalized.lower()
        if self._is_subtitle_ad_transcript_noise(lowered):
            return ""
        if self._is_casual_meeting_noise(normalized):
            return ""
        return normalized

    def _is_subtitle_ad_transcript_noise(self, lowered: str) -> bool:
        strong_markers = (
            "광고를 포함하고 있습니다",
            "한글자막 by",
            "자막 by",
            "번역 by",
            "구독 좋아요",
            "시청해주셔서 감사합니다",
            "subtitles by",
            "translated by",
        )
        if any(marker in lowered for marker in strong_markers):
            return True
        if "자막 제공" not in lowered:
            return False
        work_markers = ("기능", "접근성", "구현", "검토", "정책", "설정", "ui")
        if any(marker in lowered for marker in work_markers):
            return False
        return lowered.count("자막 제공") >= 2 or len(lowered) <= 20

    def _format_meeting_memo_context(self, items) -> list[str]:
        memo_lines = self._format_manual_memo_context(items)
        transcript_lines, noise_summary = self._format_meeting_transcript_context(items)
        lines: list[str] = []
        if memo_lines:
            lines.append("source_policy=manual_memo_is_user_direct_evidence")
            lines.extend(memo_lines[:8])
        if transcript_lines:
            lines.append("transcript_policy=deduplicated_grouped_by_meeting_context")
            lines.extend(transcript_lines[:8])
        if noise_summary:
            lines.append(noise_summary)
        return lines

    def _format_manual_memo_context(self, items) -> list[str]:
        lines: list[str] = []
        for item in items:
            if item.type != "memo":
                continue
            content = " ".join(item.content.split())
            if not content or self._contains_uncertain_noise(content):
                continue
            category = self._meeting_context_category(content, is_memo=True)
            lines.append(
                f"- MANUAL_MEMO | time={self._format_kst_time(item.timestamp)} | "
                f"category={category} | confidence=user_direct | "
                f"content={self._truncate(content, 220)}"
            )
        return lines

    def _format_meeting_transcript_context(self, items) -> tuple[list[str], str]:
        grouped: dict[int | str, list[dict]] = defaultdict(list)
        skipped_short = 0
        skipped_noise = 0
        skipped_duplicate = 0
        for item in items:
            if item.type != "transcript":
                continue
            key = item.meeting_id or f"transcript-{item.id}"
            for entry in self._iter_report_transcript_entries(item):
                text = entry["text"]
                if self._contains_uncertain_noise(text) or self._is_transcript_filler_noise(text):
                    skipped_noise += 1
                    continue
                if not self.transcript_quality_policy.is_meaningful_for_report(text):
                    skipped_short += 1
                    continue
                if self._has_similar_transcript(grouped[key], text):
                    skipped_duplicate += 1
                    continue
                grouped[key].append(
                    {
                        "item": item,
                        "text": text,
                        "source_label": entry.get("source_label", ""),
                        "time_label": entry.get("time_label", ""),
                        "source_type": (
                            self.LOCAL_WHISPER_FULL_MEETING_SOURCE
                            if self._is_local_whisper_full_meeting(item)
                            else "standard_transcript"
                        ),
                    }
                )

        lines: list[str] = []
        for key, group_items in grouped.items():
            sorted_items = sorted(
                group_items,
                key=lambda entry: (entry["item"].timestamp, entry.get("time_label", "")),
            )
            categorized: dict[str, list[str]] = defaultdict(list)
            source_labels: set[str] = set()
            source_types: set[str] = set()
            for entry in sorted_items:
                text = entry["text"]
                category = self._meeting_context_category(text, is_memo=False)
                if text not in categorized[category]:
                    categorized[category].append(text)
                if entry.get("source_label"):
                    source_labels.add(entry["source_label"])
                if entry.get("source_type"):
                    source_types.add(entry["source_type"])
            start_time = self._format_kst_time(sorted_items[0]["item"].timestamp)
            end_time = self._format_kst_time(sorted_items[-1]["item"].timestamp)
            source_text = ",".join(sorted(source_labels)) if source_labels else "-"
            source_type_text = ",".join(sorted(source_types)) if source_types else "-"
            for category in ("decision", "discussion", "follow_up_candidate", "utterance"):
                texts = categorized.get(category)
                if not texts:
                    continue
                label = self._meeting_context_label(category)
                merged = self._truncate(" / ".join(texts[:4]), 420)
                lines.append(
                    f"- MEETING_TRANSCRIPT | meeting_id={key} | "
                    f"time_range={start_time}~{end_time} | category={category} | "
                    f"label={label} | source_type={source_type_text} | "
                    f"sources={source_text} | content={merged}"
                )

        total_skipped = skipped_short + skipped_noise + skipped_duplicate
        if not total_skipped:
            return lines, ""
        return (
            lines,
            "- TRANSCRIPT_NOISE_SUMMARY | "
            f"short={skipped_short} | noise={skipped_noise} | duplicate={skipped_duplicate} | "
            "policy=excluded_or_weakened_not_report_facts",
        )

    def _has_similar_transcript(self, existing_items: list, text: str) -> bool:
        return any(
            self.transcript_quality_policy.is_near_duplicate(
                item["text"]
                if isinstance(item, dict)
                else self._normalize_transcript_content(item.content),
                text,
            )
            for item in existing_items
        )

    def _meeting_context_category(self, text: str, *, is_memo: bool) -> str:
        normalized = text.lower()
        decision_markers = (
            "결정",
            "확정",
            "승인",
            "합의",
            "진행하기로",
            "적용하기로",
            "유지하기로",
            "보류하기로",
            "하기로 했다",
            "하기로 했습니다",
        )
        follow_up_markers = (
            "다음 작업",
            "후속",
            "해야",
            "해야 함",
            "할 것",
            "todo",
            "검토 필요",
            "정리 필요",
            "후보",
        )
        discussion_markers = (
            "논의",
            "검토",
            "확인",
            "점검",
            "이야기",
            "가능성",
            "이슈",
            "공유",
            "인가요",
            "되나요",
            "되죠",
            "안 되",
        )
        if any(marker in normalized for marker in decision_markers):
            return "decision"
        if any(marker in normalized for marker in follow_up_markers):
            return "follow_up_candidate"
        if any(marker in normalized for marker in discussion_markers):
            return "discussion"
        return "discussion" if is_memo else "utterance"

    def _meeting_context_label(self, category: str) -> str:
        return {
            "decision": "결정사항",
            "discussion": "논의사항",
            "follow_up_candidate": "후속작업 후보",
            "utterance": "단순 발화",
        }.get(category, "회의 전사")

    def _is_transcript_filler_noise(self, text: str) -> bool:
        compacted = re.sub(r"[\s.?!,]+", "", text)
        if not compacted:
            return True
        filler_words = {
            "네",
            "예",
            "응",
            "음",
            "어",
            "아",
            "오",
            "맞아요",
            "그렇죠",
            "잠시만요",
        }
        if compacted in filler_words:
            return True
        return len(set(compacted)) <= 2 and len(compacted) >= 4

    def _is_casual_meeting_noise(self, text: str) -> bool:
        normalized = re.sub(r"\s+", " ", text).strip().lower()
        if not normalized:
            return True
        casual_markers = (
            "농담",
            "웃기",
            "ㅋㅋ",
            "ㅎㅎ",
            "쉬는 시간",
            "휴식",
            "잡담",
            "점심",
            "커피",
        )
        if any(marker in normalized for marker in casual_markers):
            work_markers = (
                "결정",
                "진행",
                "검토",
                "작업",
                "이슈",
                "머지",
                "배포",
                "테스트",
                "로그인",
                "url",
            )
            return not any(marker in normalized for marker in work_markers)
        return False

    def _format_transcript_groups(self, items) -> list[str]:
        grouped: dict[int | str, list[dict]] = defaultdict(list)
        for item in items:
            if item.type != "transcript":
                continue
            key = item.meeting_id or f"transcript-{item.id}"
            for entry in self._iter_report_transcript_entries(item):
                text = entry["text"]
                if self._contains_uncertain_noise(text):
                    continue
                if self._is_transcript_filler_noise(text):
                    continue
                if not self.transcript_quality_policy.is_meaningful_for_report(text):
                    continue
                grouped[key].append(
                    {
                        "item": item,
                        "text": text,
                        "source_label": entry.get("source_label", ""),
                        "source_type": (
                            self.LOCAL_WHISPER_FULL_MEETING_SOURCE
                            if self._is_local_whisper_full_meeting(item)
                            else "standard_transcript"
                        ),
                    }
                )

        lines: list[str] = []
        for key, group_items in grouped.items():
            sorted_items = sorted(
                group_items,
                key=lambda entry: entry["item"].timestamp,
            )
            texts: list[str] = []
            for entry in sorted_items:
                text = entry["text"]
                if text and text not in texts:
                    texts.append(text)
            if not texts:
                continue
            start_time = self._format_kst_time(sorted_items[0]["item"].timestamp)
            end_time = self._format_kst_time(sorted_items[-1]["item"].timestamp)
            merged = self._truncate(" / ".join(texts[:5]), 500)
            speakers = sorted(
                {
                    entry["item"].speaker
                    for entry in sorted_items
                    if getattr(entry["item"], "speaker", None)
                }
            )
            source_labels = sorted(
                {
                    entry["source_label"]
                    for entry in sorted_items
                    if entry.get("source_label")
                }
            )
            source_types = sorted(
                {
                    entry["source_type"]
                    for entry in sorted_items
                    if entry.get("source_type")
                }
            )
            speaker_text = ",".join(speakers) if speakers else "-"
            source_text = ",".join(source_labels) if source_labels else "-"
            source_type_text = ",".join(source_types) if source_types else "-"
            lines.append(
                f"- TRANSCRIPT_GROUP | meeting_id={key} | time_range={start_time}~{end_time} | "
                f"count={len(sorted_items)} | speaker={speaker_text} | "
                f"source_type={source_type_text} | sources={source_text} | text={merged}"
            )
        return lines

    def _format_dev_event_details(self, details: dict | None) -> str:
        if not details:
            return "-"
        parts: list[str] = []
        recent_commits = details.get("recent_commits")
        exit_code = details.get("exit_code")
        tracking_mode = details.get("tracking_mode")
        if isinstance(recent_commits, list) and recent_commits:
            parts.append(f"recent_commits={'; '.join(str(item) for item in recent_commits[:3])}")
        if exit_code is not None:
            parts.append(f"exit_code={exit_code}")
        if tracking_mode:
            parts.append(f"tracking_mode={tracking_mode}")
        return " | ".join(parts) if parts else "-"

    def _build_ocr_evidence_snippet(self, text: str | None, *, limit: int = 180) -> str:
        if not text:
            return ""
        lines: list[str] = []
        seen: set[str] = set()
        for raw_line in text.splitlines():
            line = self._normalize_ocr_line(raw_line)
            if not line or self._is_noise_line(line) or self._is_self_service_text(line):
                continue
            line_key = line.lower()
            if line_key in seen:
                continue
            seen.add(line_key)
            lines.append(line)
            if len(" / ".join(lines)) >= limit:
                break

        if not lines:
            return ""

        prioritized = sorted(
            lines,
            key=lambda line: (not self._extract_work_keywords(line), len(line)),
        )
        return self._truncate(" / ".join(prioritized[:4]), limit)

    def _format_activity_environment_summary(self, items) -> str:
        if not items:
            return ""

        duration_by_environment: dict[str, int] = {}
        for item in items:
            if getattr(item, "hidden_by_default", False) or getattr(item, "noise_reason", None):
                continue
            signal_level = getattr(item, "signal_level", None)
            if signal_level == "low_signal":
                continue
            environment = getattr(item, "display_title", None) or " / ".join(
                value
                for value in [item.app_name or "알 수 없는 앱", item.window_title]
                if value
            )
            duration_by_environment[environment] = duration_by_environment.get(environment, 0) + (
                item.duration_seconds or 0
            )

        summaries = sorted(
            duration_by_environment.items(),
            key=lambda item: item[1],
            reverse=True,
        )[:5]
        summary_text = "; ".join(
            f"{environment} {duration_seconds}초"
            for environment, duration_seconds in summaries
        )
        return f"- ACTIVITY_ENVIRONMENT_SUMMARY | {summary_text}"

    def _is_self_service_screen_item(self, item) -> bool:
        if item.type != "screen_ocr":
            return False
        values = [item.app_name, item.window_title, item.content, item.ocr_text, item.ai_inference]
        return self.self_observation_filter.is_self_service_values(values)

    def _is_self_service_text(self, text: str) -> bool:
        return self.self_observation_filter.is_self_service_text(text)

    def _normalize_ocr_line(self, text: str) -> str:
        return re.sub(r"\s+", " ", text).strip(" -|·•\t")

    def _is_noise_line(self, text: str) -> bool:
        lowered = text.lower()
        if len(text) <= 2:
            return True
        if any(marker in lowered for marker in self.OCR_NOISE_MARKERS):
            return True
        alpha_numeric_count = sum(char.isalnum() for char in text)
        if alpha_numeric_count == 0:
            return True
        return alpha_numeric_count / max(len(text), 1) < 0.35

    def _format_kst_time(self, value: datetime) -> str:
        return self._as_kst(value).strftime("%Y-%m-%d %H:%M")

    def _as_kst(self, value: datetime) -> datetime:
        return as_kst(value)

    def _extract_work_keywords(self, text: str | None) -> list[str]:
        if not text:
            return []
        lowered = text.lower()
        return [keyword for keyword in self.WORK_HINT_KEYWORDS if keyword in lowered]

    def _looks_like_work_evidence(self, text: str | None) -> bool:
        if not text:
            return False
        return len(text.strip()) >= 12

    def _truncate(self, text: str, limit: int) -> str:
        if len(text) <= limit:
            return text
        return text[:limit].rstrip() + "..."

    def _safe_inference(self, inference: str | None) -> str:
        if not inference:
            return "-"
        if self._has_unbalanced_delimiter(inference):
            return SAFE_UNCLEAR_INFERENCE
        if not self._ends_with_complete_korean_sentence(inference):
            return SAFE_UNCLEAR_INFERENCE
        return inference

    def _has_unbalanced_delimiter(self, text: str) -> bool:
        delimiter_pairs = [("'", "'"), ('"', '"'), ("`", "`"), ("(", ")"), ("[", "]"), ("{", "}")]
        for opener, closer in delimiter_pairs:
            if opener == closer:
                if text.count(opener) % 2 != 0:
                    return True
            elif text.count(opener) != text.count(closer):
                return True
        return False

    def _ends_with_complete_korean_sentence(self, text: str) -> bool:
        complete_endings = (
            "합니다.",
            "있습니다.",
            "보입니다.",
            "어렵습니다.",
            "진행하고 있습니다.",
            "확인하고 있습니다.",
            "진행 중입니다.",
            "확인 중입니다.",
            "같습니다.",
            "않습니다.",
            "됩니다.",
            "했습니다.",
        )
        return text.endswith(complete_endings)


def get_prompt_builder() -> PromptBuilder:
    return PromptBuilder(
        privacy_filter=get_privacy_filter(),
        self_observation_filter=get_self_observation_filter(),
    )

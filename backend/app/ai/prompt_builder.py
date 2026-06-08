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
                "API key, token, password, secret 패턴은 마스킹되었습니다.",
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
                "command, exit_code, duration_ms, cwd, branch를 작업 흐름 근거로 사용하세요.",
                "- zsh hook/preexec/precmd, command_result, record_command_result.py, "
                "install_command_tracking_hook.py, uninstall_command_tracking_hook.py, "
                "mwoham_zsh_tracking.zsh, mwoham_command_tracking_status, "
                "mwoham_command_tracking_disable, exit_code, duration_ms, failed/success command, "
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
                "mwoham_command_tracking_disable, git switch, git pull 같은 inspection/setup "
                "command는 직접 나열하지 말고 보조 근거로만 참고하세요. 필요하면 'DB 조회와 "
                "report 생성으로 저장 결과를 확인했다'처럼 묶으세요.",
                "- uv run pytest, uv run python scripts/run_dev_checks.py, uv run alembic check, "
                "git diff --check, ruff, xcodebuild, bash -n, zsh -n 같은 검증/개발 command는 "
                "높은 우선순위로 참고하세요.",
                "- rm -rf 같은 destructive command는 command 문자열을 필요 이상으로 자세히 "
                "나열하지 말고, 근거가 있으면 불필요한 앱/빌드 산출물 정리 정도로 짧게 "
                "요약하세요.",
                "- 터미널 출력 전문은 입력에 포함되지 않습니다. 실패 원인은 command, exit_code, "
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
                "- 다음 작업 후보는 3~5개로 제한하고, 현재 입력에서 자연스럽게 이어지는 단계만 "
                "제안하세요.",
                "- terminal command 자동 기록이 이미 입력에 있으면 다음 작업 후보로 반복 제안하지 "
                "마세요. timeline filtering 구현/검증이 이미 입력에 있으면 반복 제안하지 "
                "마세요.",
                "- 회의 전사는 결정사항, 논의사항, 후속작업 후보로 나눠 반영하되, 근거 없이 "
                "결정사항을 만들지 마세요. source 값은 근거로만 참고하고 최종 리포트에 과하게 "
                "나열하지 마세요.",
                "- OCR/전사/화면 단서에서 나온 불확실한 단어, 깨진 버전명, 공백이 이상한 태그명은 "
                "확정 사실처럼 쓰지 마세요. 예: command_talled, mianation, 공백이 섞인 tag명. "
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
                "## 다음 작업 후보",
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

        dev_event_lines = self._format_priority_dev_events(report_items)
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

        evidence_lines = self._format_work_evidence_by_time(report_items)
        if evidence_lines:
            lines.append("WORK_EVIDENCE_BY_TIME:")
            lines.extend(evidence_lines)

        for item in report_items:
            if item.type in {"memo", "transcript"}:
                continue
            if self._is_auto_git_snapshot(item):
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
            return (
                f"- DEV_EVENT | time={timestamp} | event_type={item.event_type or '-'} | "
                f"source={item.source or '-'} | status={item.status or '-'} | "
                f"repo={item.repo_path or '-'} | branch={item.branch or '-'} | "
                f"command={item.command or '-'} | summary={item.content} | "
                f"details={self._format_dev_event_details(item.details_json)}"
            )
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

    def _format_work_evidence_by_time(self, items) -> list[str]:
        grouped: dict[str, list[str]] = defaultdict(list)
        for item in items:
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
            return f"메모: {self._truncate(item.content, 140)}"
        if item.type == "screen_ocr":
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
            if self._is_auto_git_snapshot(item):
                return ""
            return f"개발 근거: {self._truncate(item.content, 180)}"
        if item.type == "event" and item.source != "mac_active_window":
            keywords = self._extract_work_keywords(item.content)
            if keywords or self._looks_like_work_evidence(item.content):
                return f"이벤트: {self._truncate(item.content, 140)}"
        if item.type == "transcript":
            transcript = self._normalize_transcript_content(item.content)
            if not self.transcript_quality_policy.is_meaningful_for_report(transcript):
                return ""
            return f"회의 전사: {self._truncate(transcript, 180)}"
        return ""

    def _format_auto_git_snapshot_groups(self, items) -> list[str]:
        grouped: dict[tuple[str, str], list] = defaultdict(list)
        for item in items:
            if not self._is_auto_git_snapshot(item):
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
            group_text = (
                f"{file_groups} 중심으로 " if file_groups else ""
            )
            changed_file_text = self._format_diff_summary_list(diff_summary) or (
                self._format_changed_file_list(changed_files)
            )
            file_suffix = f" | changed_files={changed_file_text}" if changed_file_text else ""
            lines.append(
                "- DEV_EVENT_GROUP | "
                f"time_range={time_range} | event_type=git_snapshot | "
                f"source=watch | branch={branch} | "
                f"summary=자동 Dev Tracking: {branch} 브랜치에서 "
                f"{group_text}Git 변경 {len(group_items)}회 감지"
                f"{file_suffix}"
            )
        return lines

    def _format_priority_dev_events(self, items) -> list[str]:
        grouped_lines = self._format_auto_git_snapshot_groups(items)
        manual_events = [
            item
            for item in items
            if item.type == "dev_event" and not self._is_auto_git_snapshot(item)
        ]
        manual_events.sort(key=self._dev_event_priority_key)
        return grouped_lines + [self._format_timeline_item(item) for item in manual_events]

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
            lines.append(f"- evidence={', '.join(evidence_files[:6])}")
        if focus_keywords:
            lines.append(f"- focus_keywords={', '.join(focus_keywords[:10])}")
        lines.append(
            "- usage=오늘 한 일 요약의 첫 문장과 시간대별 작업 흐름은 이 최신 작업 주제를 "
            "우선 중심으로 작성"
        )
        return lines

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
        terminal_commands = [
            item
            for item in items
            if (
                item.type == "dev_event"
                and item.event_type == "command_result"
                and item.source == "terminal"
            )
        ]
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
        commands = [
            self._truncate(self._normalize_command(item.command or item.content), 120)
            for item in sorted_items
        ]
        statuses = "->".join(str(item.status or "unknown") for item in sorted_items)
        exit_codes = [
            str((item.details_json or {}).get("exit_code"))
            for item in sorted_items
            if (item.details_json or {}).get("exit_code") is not None
        ]
        command_families = []
        for item in sorted_items:
            family = self._command_family(item.command or item.content)
            if family not in command_families:
                command_families.append(family)
        return (
            "- COMMAND_FLOW | "
            f"time_range={start_time}~{end_time} | "
            f"flow_type={flow_type} | "
            f"command_family={', '.join(command_families) or '-'} | "
            f"statuses={statuses} | "
            f"exit_codes={','.join(exit_codes) or '-'} | "
            f"commands={'; '.join(commands)} | "
            f"hint={hint}"
        )

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
        if normalized.startswith(("uv run ruff", "ruff")):
            return "ruff"
        if normalized.startswith("xcodebuild"):
            return "xcodebuild"
        if normalized.startswith("git diff --check"):
            return "git diff --check"
        if normalized.startswith(("bash -n", "zsh -n")):
            return "shell syntax check"
        if normalized.startswith("curl"):
            return "curl"
        if normalized.startswith("sqlite3"):
            return "sqlite3"
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
            )
        ) or normalized.startswith("curl")

    def _is_destructive_cleanup_command(self, command: str | None) -> bool:
        normalized = self._normalize_command(command)
        return normalized.startswith("rm -rf") or " rm -rf " in f" {normalized} "

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
        return parts[0] if parts else ""

    def _format_changed_file_list(self, changed_files: list[str], limit: int = 8) -> str:
        if not changed_files:
            return ""
        visible_files = changed_files[:limit]
        suffix = f" 외 {len(changed_files) - limit}개" if len(changed_files) > limit else ""
        return ", ".join(visible_files) + suffix

    def _format_diff_summary_list(self, diff_summary: list[dict], limit: int = 8) -> str:
        if not diff_summary:
            return ""
        formatted_items = [
            self._format_diff_summary_item(item)
            for item in diff_summary[:limit]
        ]
        suffix = f" 외 {len(diff_summary) - limit}개" if len(diff_summary) > limit else ""
        return ", ".join(item for item in formatted_items if item) + suffix

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

    def _format_transcript_groups(self, items) -> list[str]:
        grouped: dict[int | str, list] = defaultdict(list)
        for item in items:
            if item.type != "transcript":
                continue
            text = self._normalize_transcript_content(item.content)
            if not self.transcript_quality_policy.is_meaningful_for_report(text):
                continue
            key = item.meeting_id or f"transcript-{item.id}"
            grouped[key].append(item)

        lines: list[str] = []
        for key, group_items in grouped.items():
            sorted_items = sorted(group_items, key=lambda item: item.timestamp)
            texts: list[str] = []
            for item in sorted_items:
                text = self._normalize_transcript_content(item.content)
                if text and text not in texts:
                    texts.append(text)
            if not texts:
                continue
            start_time = self._format_kst_time(sorted_items[0].timestamp)
            end_time = self._format_kst_time(sorted_items[-1].timestamp)
            merged = self._truncate(" / ".join(texts[:5]), 500)
            speakers = sorted(
                {
                    item.speaker
                    for item in sorted_items
                    if getattr(item, "speaker", None)
                }
            )
            speaker_text = ",".join(speakers) if speakers else "-"
            lines.append(
                f"- TRANSCRIPT_GROUP | meeting_id={key} | time_range={start_time}~{end_time} | "
                f"count={len(sorted_items)} | speaker={speaker_text} | text={merged}"
            )
        return lines

    def _format_dev_event_details(self, details: dict | None) -> str:
        if not details:
            return "-"
        parts: list[str] = []
        changed_files = details.get("changed_files")
        recent_commits = details.get("recent_commits")
        diff_stat = details.get("diff_stat")
        exit_code = details.get("exit_code")
        duration_ms = details.get("duration_ms")
        duration_seconds = details.get("duration_seconds")
        cwd = details.get("cwd")
        tracking_mode = details.get("tracking_mode")
        if isinstance(changed_files, list) and changed_files:
            parts.append(f"changed_files={', '.join(str(item) for item in changed_files[:8])}")
        if diff_stat:
            parts.append(f"diff_stat={self._truncate(str(diff_stat), 160)}")
        if isinstance(recent_commits, list) and recent_commits:
            parts.append(f"recent_commits={'; '.join(str(item) for item in recent_commits[:3])}")
        if exit_code is not None:
            parts.append(f"exit_code={exit_code}")
        if duration_ms is not None:
            parts.append(f"duration_ms={duration_ms}")
        if duration_seconds is not None:
            parts.append(f"duration_seconds={duration_seconds}")
        if cwd:
            parts.append(f"cwd={self._truncate(str(cwd), 120)}")
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
            environment = " / ".join(
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

import re
from collections import defaultdict
from datetime import datetime, timedelta

from app.core.timezone import KST, as_kst
from app.schemas.timeline import TimelineResponse
from app.services.privacy_filter import PrivacyFilter, get_privacy_filter
from app.services.screen_observation_summarizer import SAFE_UNCLEAR_INFERENCE
from app.services.self_observation_filter import (
    SelfObservationFilter,
    get_self_observation_filter,
)


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
    ) -> None:
        self.privacy_filter = privacy_filter
        self.self_observation_filter = self_observation_filter or get_self_observation_filter()

    def build_daily_report_prompt(self, timeline: TimelineResponse) -> str:
        compressed_timeline = self._compress_timeline(timeline)
        safe_timeline = self.privacy_filter.mask(compressed_timeline)
        return "\n".join(
            [
                "다음은 개인 로컬 작업 기록 에이전트가 만든 일일 압축 타임라인입니다.",
                "원본 화면, 음성, 스크린샷, 오디오 파일은 포함하지 않았습니다.",
                "민감할 수 있는 API key, token, password, secret 패턴은 마스킹되었습니다.",
                "",
                "요청:",
                "- 자연스러운 한국어 업무 리포트를 Markdown 형식으로 작성하세요.",
                "- 과장하지 말고 타임라인에 있는 사실만 사용하세요.",
                "- 비어 있는 섹션은 억지로 늘리지 말고 '확인된 내용 없음'처럼 짧게 처리하세요.",
                "- 빈 타임라인이면 '기록된 작업이 없습니다.' 한 문장만 반환하세요.",
                "- 앱 이름은 작업 도구나 환경 정보로만 참고하세요.",
                "- 'Codex 앱에서', 'Chrome 앱에서', 'VSCode 앱에서'처럼 앱이 업무 주체인 듯한 "
                "표현을 피하세요.",
                "- 앱 이름보다 실제 작업 내용, 결정사항, 문제 해결 과정을 중심으로 요약하세요.",
                "- 앱 이름을 작업 내용으로 착각하지 마세요. 앱 이름은 작업 환경 보조 정보입니다.",
                "- Swift, API, FastAPI 같은 기술명만 나열하지 말고, 관찰된 메모와 화면 단서에 "
                "기반해 구체 작업 단위로 작성하세요.",
                "- 시간대별 작업 흐름은 앱 사용 시간이 아니라 실제로 진행한 작업 후보 중심으로 "
                "작성하세요.",
                "- 근거가 부족한 섹션은 '확인된 내용 없음.'으로 작성하세요.",
                "- 아래 섹션 순서를 지키세요.",
                "",
                "리포트 구조:",
                "## 오늘 한 일 요약",
                "## 시간대별 작업 흐름",
                "## 주요 트러블슈팅",
                "## 회의/메모에서 나온 결정사항",
                "## 다음 작업 후보",
                "",
                "타입별 입력 의미:",
                "- EVENT: 앱/터미널/윈도우 등에서 관찰된 작업 이벤트입니다.",
                "- DEV_EVENT: Git 상태, 테스트/빌드/개발 명령 결과입니다. OCR보다 신뢰도 높은 "
                "개발 작업 근거로 우선 참고하세요.",
                "- ACTIVITY_SEGMENT: 같은 앱/창이 유지된 보조 작업 컨텍스트입니다. "
                "주요 작업 내용 판단에는 SCREEN_OCR의 AI 추론과 MEMO를 우선 참고하세요.",
                "- MEMO: 사용자가 직접 남긴 메모입니다.",
                "- SCREEN_OCR: 화면 OCR 기반 AI 추론과 감지 키워드입니다. "
                "원본 이미지는 포함하지 않았고, ai_inference를 우선 참고하세요.",
                "- MEETING: 회의 시작/종료 등 회의 상태 이벤트입니다.",
                "- TRANSCRIPT: 회의 전사 텍스트입니다. 원본 음성은 포함하지 않았습니다. "
                "회의/메모에서 나온 결정사항 섹션과 시간대별 작업 흐름에 우선 반영하세요.",
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

        lines = [
            f"DATE: {timeline.date.isoformat()}",
            f"TOTAL_ITEMS: {len(report_items)}",
            "NOTE: ActivitySegment는 주요 작업 환경 보조 정보이며 "
            "작업 내용의 직접 근거가 아닙니다.",
        ]
        memo_lines = [
            self._format_timeline_item(item)
            for item in report_items
            if item.type == "memo"
        ]
        if memo_lines:
            lines.append("PRIORITY_MEMOS:")
            lines.extend(memo_lines[:10])

        dev_event_lines = [
            self._format_timeline_item(item)
            for item in report_items
            if item.type == "dev_event"
        ]
        if dev_event_lines:
            lines.append("PRIORITY_DEV_EVENTS:")
            lines.extend(dev_event_lines[:20])

        transcript_lines = [
            self._format_timeline_item(item)
            for item in report_items
            if item.type == "transcript"
        ]
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
            return f"개발 근거: {self._truncate(item.content, 180)}"
        if item.type == "event" and item.source != "mac_active_window":
            keywords = self._extract_work_keywords(item.content)
            if keywords or self._looks_like_work_evidence(item.content):
                return f"이벤트: {self._truncate(item.content, 140)}"
        if item.type == "transcript":
            transcript = self._normalize_transcript_content(item.content)
            return f"회의 전사: {self._truncate(transcript, 180)}"
        return ""

    def _normalize_transcript_content(self, content: str) -> str:
        prefixes = ("회의 전사 수집됨:", "회의 전사 수집됨")
        normalized = re.sub(r"\s+", " ", content).strip()
        for prefix in prefixes:
            if normalized.startswith(prefix):
                return normalized.removeprefix(prefix).strip()
        return normalized

    def _format_dev_event_details(self, details: dict | None) -> str:
        if not details:
            return "-"
        parts: list[str] = []
        changed_files = details.get("changed_files")
        recent_commits = details.get("recent_commits")
        diff_stat = details.get("diff_stat")
        exit_code = details.get("exit_code")
        duration_seconds = details.get("duration_seconds")
        if isinstance(changed_files, list) and changed_files:
            parts.append(f"changed_files={', '.join(str(item) for item in changed_files[:8])}")
        if diff_stat:
            parts.append(f"diff_stat={self._truncate(str(diff_stat), 160)}")
        if isinstance(recent_commits, list) and recent_commits:
            parts.append(f"recent_commits={'; '.join(str(item) for item in recent_commits[:3])}")
        if exit_code is not None:
            parts.append(f"exit_code={exit_code}")
        if duration_seconds is not None:
            parts.append(f"duration_seconds={duration_seconds}")
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

import re
from datetime import datetime

from app.core.timezone import as_kst
from app.schemas.timeline import TimelineResponse
from app.services.self_observation_filter import SelfObservationFilter, get_self_observation_filter


class ReportFallbackBuilder:
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
        "무엇이든 물어보세요",
        "공유된 ",
        "tb 사용",
        "order by",
    )

    def __init__(self, self_observation_filter: SelfObservationFilter) -> None:
        self.self_observation_filter = self_observation_filter

    def build(self, timeline: TimelineResponse, *, mode: str = "detailed") -> str:
        memos = [item for item in timeline.items if item.type == "memo"]
        screen_observations = [
            item
            for item in timeline.items
            if item.type == "screen_ocr" and not self._is_self_service_screen_item(item)
        ]
        activity_segments = [item for item in timeline.items if item.type == "activity_segment"]
        events = [item for item in timeline.items if item.type == "event"]
        if mode == "simple":
            return self._build_simple(timeline)
        work_candidates = self._build_work_candidates(memos, screen_observations, events)
        lines = [
            f"# {timeline.date.isoformat()} 일일 작업 리포트",
            "",
            "## 요약",
            f"- 오늘 수집된 타임라인 항목은 총 {timeline.total}개입니다.",
            "- Gemini 응답을 사용할 수 없어 핵심 항목만 간단히 정리했습니다.",
            "",
            "## 작업 후보",
        ]
        if work_candidates:
            lines.extend(f"- {candidate}" for candidate in work_candidates[:8])
        else:
            lines.append("- 확인된 작업 단서가 부족합니다.")

        lines.extend(["", "## 주요 메모"])
        if not timeline.items:
            lines.append("- 기록된 이벤트나 메모가 없습니다.")
            return "\n".join(lines)

        lines.extend(self._format_placeholder_items(memos, empty_text="주요 메모가 없습니다."))
        lines.extend(["", "## 주요 화면 관찰"])
        lines.extend(
            self._format_placeholder_items(
                screen_observations,
                empty_text="주요 화면 관찰이 없습니다.",
                formatter=self._format_screen_observation_placeholder,
            )
        )
        lines.extend(["", "## 주요 작업 환경"])
        lines.extend(
            self._format_environment_placeholder_items(
                activity_segments,
                events,
                empty_text="주요 작업 환경 정보가 없습니다.",
            )
        )
        return "\n".join(lines)

    def _build_simple(self, timeline: TimelineResponse) -> str:
        completed_candidates = self._build_simple_completed_candidates(timeline.items)
        validation_candidates = self._build_simple_validation_candidates(timeline.items)
        lines = [
            f"# {timeline.date.isoformat()} 간단 리포트",
            "",
            "## 오늘 한 일 요약",
            f"- 오늘 수집된 타임라인 항목은 총 {timeline.total}개입니다.",
            "- Gemini 응답을 사용할 수 없어 핵심 항목만 간단히 정리했습니다.",
            "",
            "## 완료한 작업",
        ]
        if completed_candidates:
            lines.extend(f"- {candidate}" for candidate in completed_candidates[:5])
        else:
            lines.append("- 확인된 핵심 작업 없음")
        lines.extend(
            [
                "",
                "## 다음 작업",
                "- 확인된 내용 없음.",
                "",
                "## 테스트/검증 결과",
            ]
        )
        if validation_candidates:
            lines.extend(f"- {candidate}" for candidate in validation_candidates[:5])
        else:
            lines.append("- 확인된 내용 없음.")
        return "\n".join(lines)

    def _build_simple_completed_candidates(self, items) -> list[str]:
        candidates: list[str] = []
        for item in items:
            if item.type == "memo":
                memo_summary = self._summarize_simple_text(item.content)
                if memo_summary:
                    candidates.append(f"메모 기반 작업 정리: {memo_summary}")
                continue
            if item.type == "transcript":
                transcript_summary = self._summarize_simple_transcript(item.content)
                if transcript_summary:
                    candidates.append(transcript_summary)
                continue
            if item.type != "dev_event":
                continue
            if self._is_validation_event(item):
                continue
            if self._is_high_confidence_dev_event(item):
                dev_summary = self._summarize_simple_dev_event(item)
                if dev_summary:
                    candidates.append(dev_summary)
        return self._deduplicate(candidates)

    def _build_simple_validation_candidates(self, items) -> list[str]:
        candidates: list[str] = []
        for item in items:
            if item.type != "dev_event" or not self._is_validation_event(item):
                continue
            candidates.append(self._summarize_simple_validation_event(item))
        return self._deduplicate(candidates)

    def _format_placeholder_items(
        self,
        items,
        *,
        empty_text: str,
        limit: int = 5,
        formatter=None,
    ) -> list[str]:
        if not items:
            return [f"- {empty_text}"]
        item_formatter = formatter or self._format_default_placeholder_item
        return [item_formatter(item) for item in items[:limit]]

    def _format_default_placeholder_item(self, item) -> str:
        return f"- {self._format_kst_clock(item.timestamp)} {item.content}"

    def _format_screen_observation_placeholder(self, item) -> str:
        content = item.ai_inference or self._build_ocr_evidence_snippet(
            item.ocr_text or item.content
        )
        if not content:
            content = "화면 텍스트 수집됨"
        return f"- {self._format_kst_clock(item.timestamp)} {content}"

    def _format_environment_placeholder_items(
        self,
        activity_segments,
        events,
        *,
        empty_text: str,
        limit: int = 5,
    ) -> list[str]:
        environment_counts: dict[str, int] = {}
        for item in activity_segments:
            app_name = item.app_name or "알 수 없는 앱"
            environment_counts[app_name] = environment_counts.get(app_name, 0) + (
                item.duration_seconds or 0
            )
        if environment_counts:
            return [
                f"- {app_name}: {duration_seconds}초"
                for app_name, duration_seconds in sorted(
                    environment_counts.items(),
                    key=lambda entry: entry[1],
                    reverse=True,
                )[:limit]
            ]

        return self._format_placeholder_items(events, empty_text=empty_text, limit=limit)

    def _build_work_candidates(self, memos, screen_observations, events) -> list[str]:
        candidates: list[str] = []
        for item in memos:
            candidates.append(f"{self._format_kst_clock(item.timestamp)} 메모: {item.content}")
        for item in screen_observations:
            evidence = item.ai_inference or self._build_ocr_evidence_snippet(
                item.ocr_text or item.content
            )
            if evidence:
                candidates.append(
                    f"{self._format_kst_clock(item.timestamp)} 화면 단서: {evidence}"
                )
        for item in events:
            if item.source == "mac_active_window":
                continue
            if self._extract_work_keywords(item.content) or len(item.content.strip()) >= 12:
                candidates.append(
                    f"{self._format_kst_clock(item.timestamp)} 이벤트: {item.content}"
                )

        return self._deduplicate(candidates)

    def _is_high_confidence_dev_event(self, item) -> bool:
        if item.event_type in {"git_snapshot", "command_result", "test_result"}:
            return True
        content = item.content or ""
        if self._extract_work_keywords(content):
            return True
        changed_files = (item.details_json or {}).get("changed_files") or []
        return any(self._is_report_related_path(path) for path in changed_files)

    def _is_validation_event(self, item) -> bool:
        if item.event_type == "test_result":
            return True
        command = (item.command or "").lower()
        content = (item.content or "").lower()
        validation_markers = (
            "pytest",
            "ruff",
            "alembic",
            "run_dev_checks.py",
            "git diff --check",
            "xcodebuild",
        )
        return any(marker in command or marker in content for marker in validation_markers)

    def _is_report_related_path(self, path: str) -> bool:
        lowered = path.lower()
        return (
            "report" in lowered
            or lowered.startswith("docs/")
            or lowered.startswith("backend/tests/")
        )

    def _summarize_simple_text(self, text: str | None) -> str:
        if not text:
            return ""
        cleaned = self._remove_raw_metadata(text)
        cleaned = re.sub(r"\s+", " ", cleaned).strip(" -|·•\t")
        if not cleaned:
            return ""
        return self._semantic_report_summary(cleaned)

    def _summarize_simple_transcript(self, content: str | None) -> str:
        transcript = self._normalize_transcript_content(content)
        if not transcript:
            return ""
        without_prefixes = []
        for raw_line in transcript.splitlines():
            line = re.sub(
                r"^\[\d{1,2}:\d{2}(?::\d{2})?\s+(?:microphone|system_audio)\]\s*",
                "",
                raw_line.strip(),
            )
            if line:
                without_prefixes.append(line)
        normalized = " ".join(without_prefixes) if without_prefixes else transcript
        normalized = self._remove_raw_metadata(normalized)
        summary = self._semantic_report_summary(normalized)
        if not summary:
            return ""
        return f"회의 전사 기반 논의 정리: {summary}"

    def _summarize_simple_dev_event(self, item) -> str:
        if item.event_type == "git_snapshot":
            changed_files = (item.details_json or {}).get("changed_files") or []
            return self._summarize_changed_files(changed_files, item.content)
        if item.event_type == "command_result":
            command = (item.command or "").lower()
            content = item.content or ""
            if "reports/daily" in command or "reports/today" in command:
                return "report API 생성/조회 동작 확인"
            if "git" in command:
                return "git 상태와 변경 흐름 확인"
            return self._semantic_report_summary(content) or "개발 명령 실행 결과 확인"
        changed_files = (item.details_json or {}).get("changed_files") or []
        if changed_files:
            return self._summarize_changed_files(changed_files, item.content)
        return self._semantic_report_summary(item.content)

    def _summarize_simple_validation_event(self, item) -> str:
        text = " ".join(part for part in (item.command, item.content) if part)
        lowered = text.lower()
        status = (
            "통과"
            if item.status == "success" or "success" in lowered or "통과" in text
            else "확인"
        )
        if "run_dev_checks.py" in lowered:
            return f"backend dev checks {status}"
        if "pytest" in lowered:
            return f"pytest 검증 {status}"
        if "ruff" in lowered:
            return f"ruff 정적 검사 {status}"
        if "alembic" in lowered:
            return f"alembic migration 검사 {status}"
        if "git diff --check" in lowered:
            return f"git diff whitespace 검사 {status}"
        if "xcodebuild" in lowered:
            return f"macOS 빌드 검증 {status}"
        return f"검증 명령 {status}"

    def _summarize_changed_files(self, changed_files: list[str], fallback_text: str | None) -> str:
        lowered_paths = [path.lower() for path in changed_files]
        joined_paths = " ".join(lowered_paths)
        fallback = (fallback_text or "").lower()
        if any("report_fallback_builder" in path for path in lowered_paths):
            return "simple report fallback 요약 로직 정리"
        if any("prompt_builder" in path for path in lowered_paths):
            return "report prompt/context 로직 수정"
        if any("report_content_cleaner" in path for path in lowered_paths):
            return "report internal label guard 정리"
        if any("report_repository" in path or "report_service" in path for path in lowered_paths):
            return "report 생성/조회 정책 수정"
        if any("tests/test_report_api" in path for path in lowered_paths):
            return "report API 회귀 테스트 보강"
        if any(path.startswith("docs/") for path in lowered_paths):
            return "report QA 문서 갱신"
        if "local_whisper" in fallback or "meeting transcript" in fallback:
            return "회의 전사 report 반영 흐름 정리"
        if "report" in joined_paths or "report" in fallback:
            return "report 관련 파일 수정"
        return "개발 변경 사항 정리"

    def _semantic_report_summary(self, text: str | None) -> str:
        if not text:
            return ""
        normalized = self._remove_raw_metadata(text)
        lowered = normalized.lower()
        if "local_whisper" in lowered or "local whisper" in lowered:
            return "local Whisper 회의 전사 report 반영 흐름 정리"
        if "internal label" in lowered or "current_work_focus" in lowered:
            return "report internal label 노출 방지 정리"
        if "simple" in lowered and "fallback" in lowered:
            return "simple report fallback 품질 보강"
        if "fallback" in lowered and "report" in lowered:
            return "report fallback 품질 보강"
        if "upsert" in lowered or "date + mode + project_id" in lowered:
            return "report 중복 생성 방지 정책 정리"
        if "mode" in lowered and ("simple" in lowered or "detailed" in lowered):
            return "detailed/simple report mode 분리"
        if "transcript" in lowered or "회의" in normalized:
            return "회의 전사 report 반영 내용 점검"
        if "report" in lowered:
            return "report 생성 흐름 정리"
        return self._truncate(normalized, 80)

    def _remove_raw_metadata(self, text: str) -> str:
        cleaned = re.sub(
            r"^\[\d{1,2}:\d{2}(?::\d{2})?\s+(?:microphone|system_audio)\]\s*",
            "",
            text,
            flags=re.MULTILINE,
        )
        cleaned = re.sub(
            r"\b(?:changed_files|exit_code|duration_ms|cwd|branch|command)="
            r"[^|,\n]+",
            "",
            cleaned,
        )
        cleaned = re.sub(r"https?://\S+", "", cleaned)
        cleaned = re.sub(r"\bcurl\s+\S+", "report API 확인", cleaned)
        return re.sub(r"\s+", " ", cleaned).strip(" -|,")

    def _normalize_transcript_content(self, content: str | None) -> str:
        if not content:
            return ""
        normalized = re.sub(r"\s+", " ", content).strip()
        for prefix in ("회의 전사 수집됨:", "회의 전사 수집됨"):
            if normalized.startswith(prefix):
                return normalized.removeprefix(prefix).strip()
        return normalized

    def _deduplicate(self, candidates: list[str]) -> list[str]:
        deduplicated: list[str] = []
        seen: set[str] = set()
        for candidate in candidates:
            key = candidate.lower()
            if key in seen:
                continue
            seen.add(key)
            deduplicated.append(candidate)
        return deduplicated

    def _build_ocr_evidence_snippet(self, text: str | None, *, limit: int = 160) -> str:
        if not text:
            return ""
        lines: list[str] = []
        seen: set[str] = set()
        for raw_line in text.splitlines():
            line = re.sub(r"\s+", " ", raw_line).strip(" -|·•\t")
            if not line or self._is_self_service_text(line) or self._is_noise_line(line):
                continue
            key = line.lower()
            if key in seen:
                continue
            seen.add(key)
            lines.append(line)
        return self._truncate(" / ".join(lines[:4]), limit) if lines else ""

    def _is_noise_line(self, text: str) -> bool:
        lowered = text.lower()
        if len(text) <= 2:
            return True
        if any(marker in lowered for marker in self.OCR_NOISE_MARKERS):
            return True
        alpha_numeric_count = sum(char.isalnum() for char in text)
        return alpha_numeric_count / max(len(text), 1) < 0.35

    def _is_self_service_screen_item(self, item) -> bool:
        values = [item.app_name, item.window_title, item.content, item.ocr_text, item.ai_inference]
        return self.self_observation_filter.is_self_service_values(values)

    def _is_self_service_text(self, text: str) -> bool:
        return self.self_observation_filter.is_self_service_text(text)

    def _extract_work_keywords(self, text: str | None) -> list[str]:
        if not text:
            return []
        lowered = text.lower()
        return [keyword for keyword in self.WORK_HINT_KEYWORDS if keyword in lowered]

    def _truncate(self, text: str, limit: int) -> str:
        if len(text) <= limit:
            return text
        return text[:limit].rstrip() + "..."

    def _format_kst_clock(self, value: datetime) -> str:
        return as_kst(value).strftime("%H:%M")


def get_report_fallback_builder() -> ReportFallbackBuilder:
    return ReportFallbackBuilder(self_observation_filter=get_self_observation_filter())

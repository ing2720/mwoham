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

    def build(self, timeline: TimelineResponse) -> str:
        memos = [item for item in timeline.items if item.type == "memo"]
        screen_observations = [
            item
            for item in timeline.items
            if item.type == "screen_ocr" and not self._is_self_service_screen_item(item)
        ]
        activity_segments = [item for item in timeline.items if item.type == "activity_segment"]
        events = [item for item in timeline.items if item.type == "event"]
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

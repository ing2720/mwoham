import re

REQUIRED_SECTIONS = [
    "오늘 한 일 요약",
    "시간대별 작업 흐름",
    "주요 트러블슈팅",
    "회의/메모에서 나온 결정사항",
    "다음 작업 후보",
]

EMPTY_SECTION_TEXT = "확인된 내용 없음."
HEADING_PATTERN = re.compile(r"^##\s+(.+?)\s*$")
INTERNAL_PROMPT_LABEL_REPLACEMENTS = {
    "CURRENT_WORK_FOCUS": "현재 작업 주제",
    "MEETING_MEMO_CONTEXT": "회의/메모",
    "PRIORITY_MEETING_TRANSCRIPTS": "회의 전사",
    "WORK_EVIDENCE_BY_TIME": "시간대별 작업 기록",
    "PRIORITY_MEMOS": "메모",
    "PRIORITY_DEV_EVENTS": "개발 이벤트",
    "PRIORITY_COMMAND_FLOWS": "명령 실행 흐름",
    "PRIORITY_CURRENT_GIT_CHANGE_HINTS": "최신 git 변경",
    "PRIORITY_CURRENT_GIT_DIFF_CONTEXT": "최신 diff",
    "CURRENT_GIT_CHANGE_HINTS": "git 변경",
    "CURRENT_GIT_DIFF_CONTEXT": "diff",
    "PRUNED_REPORT_CONTEXT": "압축 작업 기록",
    "ACTIVITY_ENVIRONMENT_SUMMARY": "작업 환경",
    "TRANSCRIPT_GROUP": "전사",
    "MEETING_TRANSCRIPT": "회의 전사",
    "TRANSCRIPT_NOISE_SUMMARY": "전사 품질",
    "DEV_EVENT_GROUP": "개발 이벤트",
    "FULL_CONTEXT_DUMP": "추가 기록",
}
INTERNAL_PROMPT_LABELS = tuple(INTERNAL_PROMPT_LABEL_REPLACEMENTS)
INTERNAL_PROMPT_LABEL_PATTERN = re.compile(
    r"\b(" + "|".join(re.escape(label) for label in INTERNAL_PROMPT_LABELS) + r")\b"
)
INTERNAL_PROMPT_LABEL_PREFIX_PATTERN = re.compile(
    r"^(\s*(?:[-*•]\s*)?)"
    r"(?:(?:"
    + "|".join(re.escape(label) for label in INTERNAL_PROMPT_LABELS)
    + r")\s*:?\s*)+"
)


class ReportContentCleaner:
    def clean(self, content: str) -> str:
        cleaned = self._remove_empty_bullets(content)
        cleaned = self._remove_internal_prompt_labels(cleaned)
        cleaned = self._collapse_blank_lines(cleaned)
        cleaned = self._ensure_required_sections(cleaned)
        return cleaned.strip()

    def _remove_empty_bullets(self, content: str) -> str:
        lines = []
        for line in content.splitlines():
            if line.strip() in {"*", "-", "•"}:
                continue
            lines.append(line.rstrip())
        return "\n".join(lines)

    def _remove_internal_prompt_labels(self, content: str) -> str:
        lines = []
        for line in content.splitlines():
            heading_match = HEADING_PATTERN.match(line)
            if heading_match and self._is_internal_label_only(heading_match.group(1)):
                continue

            if self._is_internal_label_only(line):
                continue

            line_without_prefix = INTERNAL_PROMPT_LABEL_PREFIX_PATTERN.sub(r"\1", line)
            sanitized = self._replace_internal_prompt_labels(line_without_prefix)
            sanitized = re.sub(r"[ \t]{2,}", " ", sanitized).rstrip()
            if sanitized.strip():
                lines.append(sanitized)
        return "\n".join(lines)

    def _is_internal_label_only(self, line: str) -> bool:
        normalized = line.strip()
        normalized = re.sub(r"^(?:##+\s*|[-*•]\s*)", "", normalized).strip()
        normalized = normalized.rstrip(":").strip()
        if not normalized:
            return False
        return normalized in INTERNAL_PROMPT_LABELS

    def _replace_internal_prompt_labels(self, line: str) -> str:
        def replacement(match: re.Match[str]) -> str:
            return INTERNAL_PROMPT_LABEL_REPLACEMENTS[match.group(1)]

        return INTERNAL_PROMPT_LABEL_PATTERN.sub(replacement, line)

    def _collapse_blank_lines(self, content: str) -> str:
        lines = content.splitlines()
        collapsed = []
        previous_blank = False
        for line in lines:
            is_blank = not line.strip()
            if is_blank and previous_blank:
                continue
            collapsed.append(line)
            previous_blank = is_blank
        return "\n".join(collapsed)

    def _ensure_required_sections(self, content: str) -> str:
        sections = self._split_sections(content)
        preface = sections.pop("", [])
        output = preface[:]

        for required_section in REQUIRED_SECTIONS:
            body = sections.pop(required_section, None)
            if body is None:
                output.extend(["", f"## {required_section}", EMPTY_SECTION_TEXT])
                continue

            output.extend(["", f"## {required_section}"])
            meaningful_body = [line for line in body if line.strip()]
            if meaningful_body:
                output.extend(body)
            else:
                output.append(EMPTY_SECTION_TEXT)

        for section, body in sections.items():
            output.extend(["", f"## {section}", *body])

        return self._collapse_blank_lines("\n".join(output))

    def _split_sections(self, content: str) -> dict[str, list[str]]:
        sections: dict[str, list[str]] = {"": []}
        current_section = ""
        for line in content.splitlines():
            heading_match = HEADING_PATTERN.match(line)
            if heading_match:
                current_section = heading_match.group(1).strip()
                sections.setdefault(current_section, [])
                continue
            sections.setdefault(current_section, []).append(line)
        return sections


def get_report_content_cleaner() -> ReportContentCleaner:
    return ReportContentCleaner()

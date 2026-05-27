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


class ReportContentCleaner:
    def clean(self, content: str) -> str:
        cleaned = self._remove_empty_bullets(content)
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

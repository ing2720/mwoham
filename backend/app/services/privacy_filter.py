import re


class PrivacyFilter:
    _patterns = [
        re.compile(r"(?i)(api[_-]?key|token|password|secret)\s*[:=]\s*['\"]?([^\s'\"&]+)"),
        re.compile(r"(?i)(bearer)\s+([a-z0-9._\-]+)"),
    ]

    def mask(self, text: str) -> str:
        masked = text
        for pattern in self._patterns:
            masked = pattern.sub(r"\1=[MASKED]", masked)
        return masked


def get_privacy_filter() -> PrivacyFilter:
    return PrivacyFilter()

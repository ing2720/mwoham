import re


class PrivacyFilter:
    _patterns = [
        re.compile(r"(?i)(authorization)\s*[:=]\s*(bearer)\s+([a-z0-9._\-]+)"),
        re.compile(
            r"(?i)(api[_-]?key|apikey|token|password|passwd|secret|authorization|"
            r"access[_-]?key|refresh[_-]?token)"
            r"\s*[:=]\s*['\"]?([^\s'\"&]+)"
        ),
        re.compile(r"(?i)(bearer)\s+([a-z0-9._\-]+)"),
        re.compile(
            r"(?i)([A-Z0-9_]*(?:TOKEN|SECRET|PASSWORD|PASSWD|API_KEY|APIKEY|"
            r"ACCESS_KEY|REFRESH_TOKEN|AUTHORIZATION|BEARER)[A-Z0-9_]*)=([^\s]+)"
        ),
    ]

    def mask(self, text: str) -> str:
        masked = text
        for pattern in self._patterns:
            masked = pattern.sub(r"\1=[MASKED]", masked)
        return masked


def get_privacy_filter() -> PrivacyFilter:
    return PrivacyFilter()

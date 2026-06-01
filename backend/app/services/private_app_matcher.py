import logging
import re
from dataclasses import dataclass

from app.models.private_app import PrivateApp

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class PrivateAppRule:
    app_name: str
    match_type: str
    is_enabled: bool = True


class PrivateAppMatcher:
    def is_private_app(
        self,
        app_name: str | None,
        rules: list[PrivateApp] | list[PrivateAppRule],
    ) -> bool:
        if not app_name:
            return False
        return any(self.matches(app_name, rule) for rule in rules)

    def matches(self, app_name: str, rule: PrivateApp | PrivateAppRule) -> bool:
        if not rule.is_enabled:
            return False
        pattern = rule.app_name
        if rule.match_type == "exact":
            return app_name == pattern
        if rule.match_type == "contains":
            return pattern.lower() in app_name.lower()
        if rule.match_type == "regex":
            return self._matches_regex(app_name, pattern)
        return False

    def _matches_regex(self, app_name: str, pattern: str) -> bool:
        try:
            return re.search(pattern, app_name) is not None
        except re.error:
            logger.warning("Invalid private app regex ignored: pattern=%r", pattern)
            return False


def get_private_app_matcher() -> PrivateAppMatcher:
    return PrivateAppMatcher()

import re
from difflib import SequenceMatcher


class TranscriptQualityPolicy:
    min_storage_chars = 2
    min_report_chars = 8
    near_duplicate_ratio = 0.96

    def normalize(self, text: str) -> str:
        return re.sub(r"\s+", " ", text).strip()

    def is_too_short_for_storage(self, text: str) -> bool:
        return len(self._compact(text)) < self.min_storage_chars

    def is_meaningful_for_report(self, text: str) -> bool:
        normalized = self.normalize(text)
        if len(self._compact(normalized)) >= self.min_report_chars:
            return True
        return any(
            marker in normalized
            for marker in ("결정", "진행", "검토", "점검", "완료", "다음", "작업")
        )

    def is_near_duplicate(self, previous: str, current: str) -> bool:
        previous_normalized = self.normalize(previous)
        current_normalized = self.normalize(current)
        if not previous_normalized or not current_normalized:
            return False
        if previous_normalized == current_normalized:
            return True

        previous_compact = self._compact(previous_normalized)
        current_compact = self._compact(current_normalized)
        if self._is_minor_extension(previous_compact, current_compact):
            return True

        ratio = SequenceMatcher(None, previous_normalized, current_normalized).ratio()
        return ratio >= self.near_duplicate_ratio

    def should_replace_duplicate(self, previous: str, current: str) -> bool:
        return len(self._compact(current)) > len(self._compact(previous))

    def _is_minor_extension(self, previous: str, current: str) -> bool:
        if not previous or not current:
            return False
        shorter, longer = sorted((previous, current), key=len)
        if shorter not in longer:
            return False
        return len(shorter) / len(longer) >= 0.75

    def _compact(self, text: str) -> str:
        return re.sub(r"\s+", "", text)


def get_transcript_quality_policy() -> TranscriptQualityPolicy:
    return TranscriptQualityPolicy()

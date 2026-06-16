from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime

from app.models.activity_segment import ActivitySegment

LOW_SIGNAL_DURATION_SECONDS = 30
HIGH_SIGNAL_DURATION_SECONDS = 900
MERGE_GAP_SECONDS = 120
WEAK_TITLES = {
    "",
    "-",
    "unknown",
    "untitled",
    "no title",
    "new window",
    "새 창",
    "제목 없음",
    "알 수 없음",
}


@dataclass(frozen=True)
class RefinedActivityEvent:
    id: int
    original_event_ids: list[int]
    app_name: str | None
    window_title: str | None
    display_title: str
    started_at: datetime
    ended_at: datetime
    duration_seconds: int
    sample_count: int
    event_count: int
    source: str | None
    session_id: int | None
    signal_level: str
    hidden_by_default: bool
    noise_reason: str | None


class ActivityEventRefiner:
    def refine(self, segments: list[ActivitySegment]) -> list[RefinedActivityEvent]:
        if not segments:
            return []

        sorted_segments = sorted(
            segments,
            key=lambda segment: (self._as_utc(segment.started_at), segment.id),
        )
        groups: list[list[ActivitySegment]] = []
        for segment in sorted_segments:
            if groups and self._should_merge(groups[-1][-1], segment):
                groups[-1].append(segment)
            else:
                groups.append([segment])

        return [self._to_refined_event(group) for group in groups]

    def _should_merge(self, previous: ActivitySegment, current: ActivitySegment) -> bool:
        if self._signature(previous) != self._signature(current):
            return False
        previous_end = self._as_utc(previous.ended_at)
        current_start = self._as_utc(current.started_at)
        gap_seconds = int((current_start - previous_end).total_seconds())
        return gap_seconds <= MERGE_GAP_SECONDS

    def _to_refined_event(self, segments: list[ActivitySegment]) -> RefinedActivityEvent:
        first = segments[0]
        started_at = min(segments, key=lambda segment: self._as_utc(segment.started_at)).started_at
        ended_at = max(segments, key=lambda segment: self._as_utc(segment.ended_at)).ended_at
        duration_seconds = max(
            0,
            int((self._as_utc(ended_at) - self._as_utc(started_at)).total_seconds()),
        )
        sample_count = sum(segment.sample_count for segment in segments)
        display_title = self.display_title(first.app_name, first.window_title)
        signal_level, hidden_by_default, noise_reason = self._classify(
            app_name=first.app_name,
            window_title=first.window_title,
            duration_seconds=duration_seconds,
            event_count=len(segments),
        )
        return RefinedActivityEvent(
            id=first.id,
            original_event_ids=[segment.id for segment in segments],
            app_name=first.app_name,
            window_title=first.window_title,
            display_title=display_title,
            started_at=started_at,
            ended_at=ended_at,
            duration_seconds=duration_seconds,
            sample_count=sample_count,
            event_count=len(segments),
            source=first.source,
            session_id=first.session_id,
            signal_level=signal_level,
            hidden_by_default=hidden_by_default,
            noise_reason=noise_reason,
        )

    def display_title(self, app_name: str | None, window_title: str | None) -> str:
        app = self._clean(app_name)
        title = self._clean(window_title)
        if not app and not title:
            return "알 수 없는 앱"
        if not title or self._is_weak_title(title):
            return app or "알 수 없는 앱"
        if app and title.casefold() == app.casefold():
            return app
        if app:
            return f"{app} / {self._truncate(title, 120)}"
        return self._truncate(title, 120)

    def _classify(
        self,
        *,
        app_name: str | None,
        window_title: str | None,
        duration_seconds: int,
        event_count: int,
    ) -> tuple[str, bool, str | None]:
        title = self._clean(window_title)
        if duration_seconds < LOW_SIGNAL_DURATION_SECONDS:
            return "low_signal", True, "short_app_switch"
        if self._is_weak_title(title):
            return "low_signal", True, "weak_window_title"
        if event_count > 1 and duration_seconds < 300:
            return "low_signal", True, "repeated_app_window"
        if duration_seconds >= HIGH_SIGNAL_DURATION_SECONDS:
            return "high_signal", False, None
        if self._clean(app_name):
            return "medium_signal", False, None
        return "low_signal", True, "weak_app_context"

    def _signature(self, segment: ActivitySegment) -> tuple[str, str]:
        return (
            self._clean(segment.app_name).casefold(),
            self._clean(segment.window_title).casefold(),
        )

    def _is_weak_title(self, value: str) -> bool:
        return self._clean(value).casefold() in WEAK_TITLES

    def _clean(self, value: str | None) -> str:
        return " ".join((value or "").split())

    def _truncate(self, value: str, limit: int) -> str:
        if len(value) <= limit:
            return value
        return value[:limit].rstrip() + "..."

    def _as_utc(self, value: datetime) -> datetime:
        if value.tzinfo is None:
            return value.replace(tzinfo=UTC)
        return value.astimezone(UTC)


def get_activity_event_refiner() -> ActivityEventRefiner:
    return ActivityEventRefiner()

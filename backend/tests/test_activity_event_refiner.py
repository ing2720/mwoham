from datetime import UTC, datetime, timedelta

from app.models.activity_segment import ActivitySegment
from app.services.activity_event_refiner import ActivityEventRefiner


def _segment(
    segment_id: int,
    *,
    app_name: str | None = "Chrome",
    window_title: str | None = "Dashboard",
    start_offset: int,
    duration: int,
) -> ActivitySegment:
    started_at = datetime(2026, 5, 26, 10, 0, tzinfo=UTC) + timedelta(seconds=start_offset)
    ended_at = started_at + timedelta(seconds=duration)
    return ActivitySegment(
        id=segment_id,
        session_id=1,
        app_name=app_name,
        window_title=window_title,
        source="mac_active_window",
        started_at=started_at,
        ended_at=ended_at,
        last_seen_at=ended_at,
        duration_seconds=duration,
        sample_count=1,
    )


def test_short_activity_is_low_signal_and_hidden_by_default() -> None:
    refined = ActivityEventRefiner().refine(
        [
            _segment(
                1,
                app_name="Safari",
                window_title="Search",
                start_offset=0,
                duration=12,
            )
        ]
    )

    assert len(refined) == 1
    assert refined[0].signal_level == "low_signal"
    assert refined[0].hidden_by_default is True
    assert refined[0].noise_reason == "short_app_switch"
    assert refined[0].original_event_ids == [1]


def test_consecutive_same_app_window_segments_are_merged_without_deleting_original_ids() -> None:
    refined = ActivityEventRefiner().refine(
        [
            _segment(1, start_offset=0, duration=180),
            _segment(2, start_offset=200, duration=240),
            _segment(3, app_name="Xcode", window_title="Project", start_offset=600, duration=90),
        ]
    )

    assert len(refined) == 2
    assert refined[0].id == 1
    assert refined[0].original_event_ids == [1, 2]
    assert refined[0].event_count == 2
    assert refined[0].duration_seconds == 440
    assert refined[1].original_event_ids == [3]


def test_weak_or_duplicate_window_title_uses_display_title_without_mutating_raw_values() -> None:
    refined = ActivityEventRefiner().refine(
        [
            _segment(
                1,
                app_name="Finder",
                window_title="Untitled",
                start_offset=0,
                duration=120,
            ),
            _segment(
                2,
                app_name="Xcode",
                window_title="Xcode",
                start_offset=300,
                duration=120,
            ),
        ]
    )

    assert refined[0].display_title == "Finder"
    assert refined[0].window_title == "Untitled"
    assert refined[0].noise_reason == "weak_window_title"
    assert refined[1].display_title == "Xcode"
    assert refined[1].window_title == "Xcode"

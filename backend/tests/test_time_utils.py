from datetime import UTC, date, datetime

from app.core.timezone import (
    format_datetime_kst,
    get_kst_day_range_as_utc,
    parse_date_or_today_kst,
)


def test_get_kst_day_range_as_utc_returns_exclusive_utc_range() -> None:
    start, end = get_kst_day_range_as_utc(date(2026, 6, 1))

    assert start == datetime(2026, 5, 31, 15, 0, tzinfo=UTC)
    assert end == datetime(2026, 6, 1, 15, 0, tzinfo=UTC)


def test_parse_date_or_today_kst_accepts_iso_date() -> None:
    assert parse_date_or_today_kst("2026-06-01") == date(2026, 6, 1)


def test_format_datetime_kst_formats_utc_as_kst() -> None:
    value = datetime(2026, 5, 31, 15, 0, tzinfo=UTC)

    assert format_datetime_kst(value) == "2026-06-01 00:00:00"

from datetime import UTC, date, datetime, time, timedelta
from zoneinfo import ZoneInfo

KST = ZoneInfo("Asia/Seoul")


def now_utc() -> datetime:
    return datetime.now(UTC)


def now_kst() -> datetime:
    return datetime.now(KST)


def as_utc(value: datetime) -> datetime:
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(UTC)


def as_kst(value: datetime) -> datetime:
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(KST)


def get_kst_day_range_as_utc(target_date: date) -> tuple[datetime, datetime]:
    kst_start = datetime.combine(target_date, time.min, tzinfo=KST)
    kst_end = kst_start + timedelta(days=1)
    return kst_start.astimezone(UTC), kst_end.astimezone(UTC)


def get_today_kst_day_range_as_utc() -> tuple[datetime, datetime]:
    return get_kst_day_range_as_utc(now_kst().date())


def parse_date_or_today_kst(value: date | str | None = None) -> date:
    if value is None:
        return now_kst().date()
    if isinstance(value, date):
        return value
    return date.fromisoformat(value)


def format_datetime_kst(value: datetime, fmt: str = "%Y-%m-%d %H:%M:%S") -> str:
    return as_kst(value).strftime(fmt)


def utc_range_for_kst_date(target_date: date) -> tuple[datetime, datetime]:
    return get_kst_day_range_as_utc(target_date)

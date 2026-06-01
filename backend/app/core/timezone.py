from datetime import UTC, date, datetime, time
from zoneinfo import ZoneInfo

KST = ZoneInfo("Asia/Seoul")


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


def utc_range_for_kst_date(target_date: date) -> tuple[datetime, datetime]:
    kst_start = datetime.combine(target_date, time.min, tzinfo=KST)
    kst_end = datetime.combine(target_date, time.max, tzinfo=KST)
    return kst_start.astimezone(UTC), kst_end.astimezone(UTC)

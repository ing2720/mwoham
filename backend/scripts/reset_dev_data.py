"""Reset local development/test data.

Run from backend:
    uv run python scripts/reset_dev_data.py --today
    uv run python scripts/reset_dev_data.py --today --yes
    uv run python scripts/reset_dev_data.py --reports-only --yes

This is a local development helper, not an application API.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass
from datetime import date, datetime
from pathlib import Path

from sqlalchemy import Select, delete, func, select
from sqlalchemy.orm import Session

ROOT_DIR = Path(__file__).resolve().parents[1]
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from app.core.timezone import now_kst, utc_range_for_kst_date  # noqa: E402
from app.db.init_db import prepare_database  # noqa: E402
from app.db.session import SessionLocal  # noqa: E402
from app.models.activity_segment import ActivitySegment  # noqa: E402
from app.models.manual_memo import ManualMemo  # noqa: E402
from app.models.report import Report  # noqa: E402
from app.models.screen_observation import ScreenObservation  # noqa: E402
from app.models.work_event import WorkEvent  # noqa: E402

TARGET_LABELS = {
    "reports": "reports",
    "screen_observations": "screen_observations",
    "activity_segments": "activity_segments",
    "work_events": "work_events",
    "manual_memos": "manual_memos",
}
DEFAULT_TARGETS = tuple(TARGET_LABELS)


@dataclass(frozen=True)
class ResetDevDataOptions:
    today: bool = False
    all_data: bool = False
    reports_only: bool = False
    observations_only: bool = False
    activity_only: bool = False
    memos_only: bool = False
    events_only: bool = False
    yes: bool = False
    target_date: date | None = None


@dataclass(frozen=True)
class ResetDevDataResult:
    counts: dict[str, int]
    deleted: bool
    scope_label: str


def reset_dev_data(db: Session, options: ResetDevDataOptions) -> ResetDevDataResult:
    if options.today and options.all_data:
        raise ValueError("--today and --all cannot be used together.")

    targets = _resolve_targets(options)
    if not targets:
        return ResetDevDataResult(counts={}, deleted=False, scope_label="none")

    target_date = options.target_date or now_kst().date()
    scope = _resolve_scope(options, target_date=target_date)
    counts = {target: _count_target(db, target=target, scope=scope) for target in targets}

    if not options.yes:
        return ResetDevDataResult(counts=counts, deleted=False, scope_label=scope.label)

    for target in targets:
        _delete_target(db, target=target, scope=scope)
    db.commit()
    return ResetDevDataResult(counts=counts, deleted=True, scope_label=scope.label)


@dataclass(frozen=True)
class _DeleteScope:
    label: str
    start: datetime | None = None
    end: datetime | None = None
    report_date: date | None = None


def _resolve_targets(options: ResetDevDataOptions) -> list[str]:
    selected: list[str] = []
    if options.reports_only:
        selected.append("reports")
    if options.observations_only:
        selected.append("screen_observations")
    if options.activity_only:
        selected.append("activity_segments")
    if options.events_only:
        selected.append("work_events")
    if options.memos_only:
        selected.append("manual_memos")

    if selected:
        return selected
    if options.today or options.all_data:
        return list(DEFAULT_TARGETS)
    return []


def _resolve_scope(options: ResetDevDataOptions, *, target_date: date) -> _DeleteScope:
    if options.today:
        start, end = utc_range_for_kst_date(target_date)
        return _DeleteScope(
            label=f"today:{target_date.isoformat()} KST",
            start=start,
            end=end,
            report_date=target_date,
        )
    return _DeleteScope(label="all")


def _count_target(db: Session, *, target: str, scope: _DeleteScope) -> int:
    statement = _select_target(target, scope=scope)
    return db.scalar(select(func.count()).select_from(statement.subquery())) or 0


def _delete_target(db: Session, *, target: str, scope: _DeleteScope) -> None:
    model, conditions = _target_model_and_conditions(target, scope=scope)
    statement = delete(model)
    for condition in conditions:
        statement = statement.where(condition)
    db.execute(statement)


def _select_target(target: str, *, scope: _DeleteScope) -> Select:
    model, conditions = _target_model_and_conditions(target, scope=scope)
    statement = select(model)
    for condition in conditions:
        statement = statement.where(condition)
    return statement


def _target_model_and_conditions(target: str, *, scope: _DeleteScope):
    if target == "reports":
        conditions = []
        if scope.report_date is not None:
            conditions.append(Report.date == scope.report_date)
        return Report, conditions
    if target == "screen_observations":
        return ScreenObservation, _timestamp_conditions(ScreenObservation.timestamp, scope=scope)
    if target == "activity_segments":
        if scope.start is None or scope.end is None:
            return ActivitySegment, []
        return ActivitySegment, [
            ActivitySegment.started_at <= scope.end,
            ActivitySegment.ended_at >= scope.start,
        ]
    if target == "work_events":
        return WorkEvent, _timestamp_conditions(WorkEvent.timestamp, scope=scope)
    if target == "manual_memos":
        return ManualMemo, _timestamp_conditions(ManualMemo.timestamp, scope=scope)
    raise ValueError(f"Unknown reset target: {target}")


def _timestamp_conditions(column, *, scope: _DeleteScope) -> list:
    if scope.start is None or scope.end is None:
        return []
    return [column >= scope.start, column <= scope.end]


def _build_options(args: argparse.Namespace) -> ResetDevDataOptions:
    return ResetDevDataOptions(
        today=args.today,
        all_data=args.all,
        reports_only=args.reports_only,
        observations_only=args.observations_only,
        activity_only=args.activity_only,
        memos_only=args.memos_only,
        events_only=args.events_only,
        yes=args.yes,
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Reset local development/test data. Requires --yes to delete.",
    )
    parser.add_argument("--today", action="store_true", help="delete KST today's data")
    parser.add_argument("--all", action="store_true", help="delete all target data")
    parser.add_argument("--reports-only", action="store_true", help="delete reports only")
    parser.add_argument(
        "--observations-only",
        action="store_true",
        help="delete screen_observations only",
    )
    parser.add_argument(
        "--activity-only",
        action="store_true",
        help="delete activity_segments only",
    )
    parser.add_argument("--memos-only", action="store_true", help="delete manual_memos only")
    parser.add_argument("--events-only", action="store_true", help="delete work_events only")
    parser.add_argument("--yes", action="store_true", help="actually delete data")
    args = parser.parse_args()

    prepare_database()
    with SessionLocal() as db:
        result = reset_dev_data(db, _build_options(args))

    if not result.counts:
        print("삭제 대상 옵션이 없습니다. 예: --today, --all, --reports-only")
        return

    print(f"삭제 범위: {result.scope_label}")
    for target, count in result.counts.items():
        print(f"- {TARGET_LABELS[target]}: {count}개")

    if result.deleted:
        print("삭제 완료")
    else:
        print("dry-run입니다. 실제 삭제하려면 --yes를 추가하세요.")


if __name__ == "__main__":
    main()

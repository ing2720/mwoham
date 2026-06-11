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
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parents[1]
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from app.db.init_db import prepare_database  # noqa: E402
from app.db.session import SessionLocal  # noqa: E402
from app.services.dev_data_reset_service import (  # noqa: E402
    TARGET_LABELS,
    ResetDevDataOptions,
    get_dev_data_reset_service,
)


def _build_options(args: argparse.Namespace) -> ResetDevDataOptions:
    return ResetDevDataOptions(
        today=args.today,
        all_data=args.all,
        reports_only=args.reports_only,
        dev_events_only=args.dev_events_only,
        transcripts_only=args.transcripts_only,
        meetings_only=args.meetings_only,
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
    parser.add_argument("--dev-events-only", action="store_true", help="delete dev_events only")
    parser.add_argument(
        "--transcripts-only",
        action="store_true",
        help="delete voice_transcripts only",
    )
    parser.add_argument(
        "--meetings-only",
        action="store_true",
        help="delete meeting_sessions only",
    )
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
        result = get_dev_data_reset_service().reset(db, _build_options(args))

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

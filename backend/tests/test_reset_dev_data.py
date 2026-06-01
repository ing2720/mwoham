from datetime import UTC, date, datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from app.models.activity_segment import ActivitySegment
from app.models.manual_memo import ManualMemo
from app.models.report import Report
from app.models.screen_observation import ScreenObservation
from app.models.work_event import WorkEvent
from app.models.work_session import WorkSession
from app.services.dev_data_reset_service import ResetDevDataOptions, get_dev_data_reset_service


def test_reset_dev_data_today_deletes_only_kst_day_range(db: Session) -> None:
    session = _create_session(db)
    inside = datetime(2026, 5, 31, 16, 0, tzinfo=UTC)
    outside = datetime(2026, 5, 31, 14, 30, tzinfo=UTC)
    next_day_boundary = datetime(2026, 6, 1, 15, 0, tzinfo=UTC)

    _create_report(db, report_date=date(2026, 6, 1), title="today report")
    _create_report(db, report_date=date(2026, 5, 31), title="previous report")
    _create_event(db, session_id=session.id, timestamp=inside, content="inside event")
    _create_event(db, session_id=session.id, timestamp=outside, content="outside event")
    _create_event(
        db,
        session_id=session.id,
        timestamp=next_day_boundary,
        content="next day boundary event",
    )
    _create_memo(db, session_id=session.id, timestamp=inside, content="inside memo")
    _create_memo(db, session_id=session.id, timestamp=outside, content="outside memo")
    _create_observation(db, session_id=session.id, timestamp=inside, text="inside screen")
    _create_observation(db, session_id=session.id, timestamp=outside, text="outside screen")
    _create_segment(db, session_id=session.id, started_at=inside)
    _create_segment(db, session_id=session.id, started_at=outside)

    result = get_dev_data_reset_service().reset(
        db,
        ResetDevDataOptions(today=True, yes=True, target_date=date(2026, 6, 1)),
    )

    assert result.deleted is True
    assert result.counts == {
        "reports": 1,
        "screen_observations": 1,
        "activity_segments": 1,
        "work_events": 1,
        "manual_memos": 1,
    }
    assert _count(db, Report) == 1
    assert _count(db, WorkEvent) == 2
    assert _count(db, ManualMemo) == 1
    assert _count(db, ScreenObservation) == 1
    assert _count(db, ActivitySegment) == 1
    assert {
        event.content for event in db.scalars(select(WorkEvent).order_by(WorkEvent.timestamp))
    } == {"outside event", "next day boundary event"}


def test_reset_dev_data_reports_only_deletes_reports_only(db: Session) -> None:
    session = _create_session(db)
    _create_report(db, report_date=date(2026, 6, 1), title="report")
    _create_event(db, session_id=session.id, timestamp=datetime(2026, 6, 1, tzinfo=UTC))

    result = get_dev_data_reset_service().reset(
        db,
        ResetDevDataOptions(reports_only=True, yes=True),
    )

    assert result.counts == {"reports": 1}
    assert _count(db, Report) == 0
    assert _count(db, WorkEvent) == 1


def test_reset_dev_data_without_yes_does_not_delete(db: Session) -> None:
    session = _create_session(db)
    _create_report(db, report_date=date(2026, 6, 1), title="report")
    _create_event(db, session_id=session.id, timestamp=datetime(2026, 6, 1, tzinfo=UTC))

    result = get_dev_data_reset_service().reset(db, ResetDevDataOptions(all_data=True))

    assert result.deleted is False
    assert result.counts["reports"] == 1
    assert result.counts["work_events"] == 1
    assert _count(db, Report) == 1
    assert _count(db, WorkEvent) == 1


def test_reset_dev_data_all_yes_deletes_target_data(db: Session) -> None:
    session = _create_session(db)
    timestamp = datetime(2026, 6, 1, tzinfo=UTC)
    _create_report(db, report_date=date(2026, 6, 1), title="report")
    _create_event(db, session_id=session.id, timestamp=timestamp)
    _create_memo(db, session_id=session.id, timestamp=timestamp)
    _create_observation(db, session_id=session.id, timestamp=timestamp)
    _create_segment(db, session_id=session.id, started_at=timestamp)

    result = get_dev_data_reset_service().reset(
        db,
        ResetDevDataOptions(all_data=True, yes=True),
    )

    assert result.deleted is True
    assert all(count == 1 for count in result.counts.values())
    assert _count(db, Report) == 0
    assert _count(db, WorkEvent) == 0
    assert _count(db, ManualMemo) == 0
    assert _count(db, ScreenObservation) == 0
    assert _count(db, ActivitySegment) == 0
    assert _count(db, WorkSession) == 1


def _create_session(db: Session) -> WorkSession:
    session = WorkSession(
        started_at=datetime(2026, 6, 1, 0, 0, tzinfo=UTC),
        status="stopped",
        title="dev reset test",
    )
    db.add(session)
    db.commit()
    db.refresh(session)
    return session


def _create_report(db: Session, *, report_date: date, title: str) -> None:
    db.add(
        Report(
            date=report_date,
            mode="daily",
            title=title,
            content="content",
            created_by="system",
        )
    )
    db.commit()


def _create_event(
    db: Session,
    *,
    session_id: int,
    timestamp: datetime,
    content: str = "event",
) -> None:
    db.add(
        WorkEvent(
            session_id=session_id,
            timestamp=timestamp,
            source="test",
            content=content,
        )
    )
    db.commit()


def _create_memo(
    db: Session,
    *,
    session_id: int,
    timestamp: datetime,
    content: str = "memo",
) -> None:
    db.add(ManualMemo(session_id=session_id, timestamp=timestamp, content=content))
    db.commit()


def _create_observation(
    db: Session,
    *,
    session_id: int,
    timestamp: datetime,
    text: str = "screen",
) -> None:
    db.add(
        ScreenObservation(
            session_id=session_id,
            timestamp=timestamp,
            ocr_text=text,
        )
    )
    db.commit()


def _create_segment(db: Session, *, session_id: int, started_at: datetime) -> None:
    db.add(
        ActivitySegment(
            session_id=session_id,
            app_name="Test",
            source="test",
            started_at=started_at,
            ended_at=started_at + timedelta(minutes=10),
            last_seen_at=started_at + timedelta(minutes=10),
            duration_seconds=600,
            sample_count=1,
        )
    )
    db.commit()


def _count(db: Session, model) -> int:
    return db.scalar(select(func.count()).select_from(model)) or 0

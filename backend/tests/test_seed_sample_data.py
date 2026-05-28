from sqlalchemy.orm import Session

from app.services.timeline_builder import get_timeline_builder
from scripts.seed_sample_data import seed_sample_data


def test_seed_sample_data_creates_report_timeline_sources(db: Session) -> None:
    result = seed_sample_data(db, reset=True)
    timeline = get_timeline_builder().build_for_date(db)

    item_types = {item.type for item in timeline.items}
    timeline_text = "\n".join(item.content for item in timeline.items)

    assert result["session_id"] > 0
    assert result["meeting_id"] > 0
    assert {"event", "memo", "screen_ocr", "meeting", "transcript"}.issubset(item_types)
    assert "Chrome" in timeline_text
    assert "VSCode" in timeline_text
    assert "테스트가 통과" in timeline_text


def test_seed_sample_data_reset_keeps_sample_size_stable(db: Session) -> None:
    seed_sample_data(db, reset=True)
    first_total = get_timeline_builder().build_for_date(db).total

    seed_sample_data(db, reset=True)
    second_total = get_timeline_builder().build_for_date(db).total

    assert first_total == second_total

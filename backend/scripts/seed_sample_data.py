"""Seed sample data for local report quality checks.

Run from backend:
    uv run python scripts/seed_sample_data.py
    uv run python scripts/seed_sample_data.py --reset
"""

from __future__ import annotations

import argparse
import sys
from datetime import UTC, datetime, time, timedelta
from pathlib import Path

from sqlalchemy import delete, select
from sqlalchemy.orm import Session

ROOT_DIR = Path(__file__).resolve().parents[1]
if str(ROOT_DIR) not in sys.path:
    sys.path.insert(0, str(ROOT_DIR))

from app.db.init_db import prepare_database  # noqa: E402
from app.db.session import SessionLocal  # noqa: E402
from app.models.manual_memo import ManualMemo  # noqa: E402
from app.models.meeting_session import MeetingSession  # noqa: E402
from app.models.screen_observation import ScreenObservation  # noqa: E402
from app.models.voice_transcript import VoiceTranscript  # noqa: E402
from app.models.work_event import WorkEvent  # noqa: E402
from app.models.work_session import WorkSession  # noqa: E402
from app.schemas.meeting import MeetingEndRequest, MeetingStartRequest  # noqa: E402
from app.schemas.memo import MemoCreate  # noqa: E402
from app.schemas.recording import RecordingStartRequest  # noqa: E402
from app.schemas.screen_observation import ScreenObservationCreate  # noqa: E402
from app.schemas.transcript import TranscriptCreate  # noqa: E402
from app.schemas.work_event import WorkEventCreate  # noqa: E402
from app.services.event_service import get_event_service  # noqa: E402
from app.services.meeting_service import get_meeting_service  # noqa: E402
from app.services.memo_service import get_memo_service  # noqa: E402
from app.services.recording_service import get_recording_service  # noqa: E402
from app.services.screen_observation_service import get_screen_observation_service  # noqa: E402

SAMPLE_MARKER = "[sample-report-quality]"
SAMPLE_SESSION_TITLE = f"{SAMPLE_MARKER} 리포트 품질 검증 세션"
SAMPLE_MEETING_TITLE = f"{SAMPLE_MARKER} 리포트 품질 개선 회의"


def seed_sample_data(db: Session, *, reset: bool = False) -> dict[str, int]:
    if reset:
        reset_sample_data(db)

    started_at = datetime.combine(datetime.now(UTC).date(), time(hour=9), tzinfo=UTC)
    session_id = _ensure_session(db, started_at)

    _create_events(db, session_id=session_id, started_at=started_at)
    _create_memo(db, session_id=session_id, timestamp=started_at + timedelta(hours=2, minutes=45))
    _create_screen_observation(
        db,
        session_id=session_id,
        timestamp=started_at + timedelta(hours=3, minutes=10),
    )
    meeting_id = _create_meeting(
        db,
        session_id=session_id,
        started_at=started_at + timedelta(hours=4),
    )
    _create_transcripts(db, meeting_id=meeting_id, started_at=started_at + timedelta(hours=4))

    return {"session_id": session_id, "meeting_id": meeting_id}


def reset_sample_data(db: Session) -> None:
    meeting_ids = db.scalars(
        select(MeetingSession.id).where(MeetingSession.title == SAMPLE_MEETING_TITLE)
    ).all()
    if meeting_ids:
        db.execute(delete(VoiceTranscript).where(VoiceTranscript.meeting_id.in_(meeting_ids)))
        db.execute(delete(MeetingSession).where(MeetingSession.id.in_(meeting_ids)))

    session_ids = db.scalars(
        select(WorkSession.id).where(WorkSession.title == SAMPLE_SESSION_TITLE)
    ).all()
    if session_ids:
        db.execute(delete(WorkEvent).where(WorkEvent.session_id.in_(session_ids)))
        db.execute(delete(ScreenObservation).where(ScreenObservation.session_id.in_(session_ids)))
        db.execute(delete(ManualMemo).where(ManualMemo.session_id.in_(session_ids)))
        db.execute(delete(WorkSession).where(WorkSession.id.in_(session_ids)))

    db.execute(delete(ManualMemo).where(ManualMemo.content.like(f"%{SAMPLE_MARKER}%")))
    db.commit()


def _ensure_session(db: Session, started_at: datetime) -> int:
    existing = db.scalar(select(WorkSession).where(WorkSession.title == SAMPLE_SESSION_TITLE))
    if existing is not None:
        return existing.id

    current = db.scalar(select(WorkSession).where(WorkSession.status.in_(["active", "paused"])))
    if current is not None:
        return current.id

    session = get_recording_service().start(
        db,
        RecordingStartRequest(title=SAMPLE_SESSION_TITLE, started_at=started_at),
    )
    return session.session_id


def _create_events(db: Session, *, session_id: int, started_at: datetime) -> None:
    service = get_event_service()
    events = [
        (
            "Chrome",
            "FastAPI 문서 - Background Tasks",
            "browser",
            "Chrome에서 FastAPI 문서를 확인하며 "
            "리포트 export 흐름에 필요한 응답 구조를 검토했습니다.",
            20,
        ),
        (
            "VSCode",
            "backend/app/report/pdf_generator.py",
            "editor",
            "VSCode에서 PDF 렌더링 스타일과 Markdown 변환 로직을 수정했습니다.",
            70,
        ),
        (
            "Terminal",
            "uv run pytest",
            "terminal",
            "Terminal에서 테스트를 실행했으나 다운로드 헤더 검증 케이스가 실패했습니다.",
            115,
        ),
        (
            "Terminal",
            "uv run pytest",
            "terminal",
            "Terminal에서 테스트를 다시 실행해 전체 테스트가 통과했습니다.",
            150,
        ),
    ]
    for app_name, window_title, source, content, minutes in events:
        service.create(
            db,
            WorkEventCreate(
                session_id=session_id,
                timestamp=started_at + timedelta(minutes=minutes),
                source=source,
                app_name=app_name,
                window_title=window_title,
                content=f"{SAMPLE_MARKER} {content}",
                project_name="mwoham-backend",
                confidence=0.95,
            ),
        )


def _create_memo(db: Session, *, session_id: int, timestamp: datetime) -> None:
    get_memo_service().create(
        db,
        MemoCreate(
            session_id=session_id,
            timestamp=timestamp,
            content=(
                f"{SAMPLE_MARKER} 리포트에는 실패 원인, 수정 내용, 재검증 결과를 "
                "짧게 분리해서 정리하기로 했습니다."
            ),
        ),
    )


def _create_screen_observation(db: Session, *, session_id: int, timestamp: datetime) -> None:
    get_screen_observation_service().create(
        db,
        ScreenObservationCreate(
            session_id=session_id,
            timestamp=timestamp,
            app_name="Terminal",
            window_title="pytest failure",
            ocr_text=(
                f"{SAMPLE_MARKER} AssertionError: Content-Disposition header does not "
                "contain attachment filename"
            ),
            detected_keywords=["pytest", "AssertionError", "Content-Disposition", "download"],
            ai_inference="다운로드 응답 헤더 검증 로직을 확인해야 합니다.",
            frame_hash=f"{SAMPLE_MARKER}-terminal-failure",
        ),
    )


def _create_meeting(db: Session, *, session_id: int, started_at: datetime) -> int:
    service = get_meeting_service()
    meeting = service.start_meeting(
        db,
        MeetingStartRequest(
            session_id=session_id,
            started_at=started_at,
            meeting_app="Zoom",
            title=SAMPLE_MEETING_TITLE,
            transcript_enabled=True,
        ),
    )
    service.end_meeting(
        db,
        meeting_id=meeting.id,
        request=MeetingEndRequest(
            ended_at=started_at + timedelta(minutes=35),
            summary=(
                "리포트 품질 검증을 위해 샘플 타임라인을 만들고 Gemini 입력을 점검하기로 했습니다."
            ),
        ),
    )
    return meeting.id


def _create_transcripts(db: Session, *, meeting_id: int, started_at: datetime) -> None:
    service = get_meeting_service()
    transcripts = [
        (
            "mentor",
            "오늘 리포트는 앱 이름보다 실제 작업 내용과 문제 해결 과정을 중심으로 정리합시다.",
            5,
        ),
        (
            "developer",
            "실패한 테스트와 수정 후 통과한 결과를 시간대별 흐름에 포함하겠습니다.",
            12,
        ),
        (
            "mentor",
            "다음 작업 후보에는 Swift 위젯 연동 전에 로컬 API 스모크 테스트를 추가합시다.",
            25,
        ),
    ]
    for speaker, text, minutes in transcripts:
        service.create_transcript(
            db,
            TranscriptCreate(
                meeting_id=meeting_id,
                timestamp=started_at + timedelta(minutes=minutes),
                speaker=speaker,
                text=f"{SAMPLE_MARKER} {text}",
                confidence=0.92,
            ),
        )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Create sample local worklog data for report quality checks.",
    )
    parser.add_argument(
        "--reset",
        action="store_true",
        help="delete previous sample rows before seeding to avoid duplicate sample data",
    )
    args = parser.parse_args()

    prepare_database()
    with SessionLocal() as db:
        result = seed_sample_data(db, reset=args.reset)

    print("샘플 데이터 생성 완료")
    print(f"- session_id: {result['session_id']}")
    print(f"- meeting_id: {result['meeting_id']}")
    print("- 확인: uv run uvicorn app.main:app --host 127.0.0.1 --port 8765")
    print("- 타임라인: http://127.0.0.1:8765/timeline")
    print("- 리포트 생성: http://127.0.0.1:8765/reports")
    print("- 중복이 많아지면: uv run python scripts/seed_sample_data.py --reset")


if __name__ == "__main__":
    main()

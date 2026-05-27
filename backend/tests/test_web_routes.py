from collections.abc import Generator
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.ai.gemini_client import GeminiClient
from app.ai.prompt_builder import get_prompt_builder
from app.ai.summarizer import GeminiSummarizer
from app.db.session import get_db
from app.main import app
from app.models import Base
from app.repositories.report_repository import ReportRepository
from app.services.report_service import ReportService, get_report_service
from app.services.timeline_builder import get_timeline_builder


@pytest.fixture
def client() -> Generator[TestClient]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    testing_session_local = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    Base.metadata.create_all(bind=engine)

    def override_get_db() -> Generator[Session]:
        db = testing_session_local()
        try:
            yield db
        finally:
            db.close()

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_report_service] = lambda: ReportService(
        repository=ReportRepository(),
        timeline_builder=get_timeline_builder(),
        summarizer=GeminiSummarizer(
            client=GeminiClient(api_key=None, model="gemini-2.5-flash"),
            prompt_builder=get_prompt_builder(),
        ),
    )
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.clear()
        Base.metadata.drop_all(bind=engine)


def test_dashboard_renders_status_events_and_memos(client: TestClient) -> None:
    now = datetime.now(UTC)
    client.post("/recording/start", json={"title": "Dashboard test"})
    client.post(
        "/events",
        json={
            "timestamp": now.replace(hour=9, minute=30, second=0, microsecond=0).isoformat(),
            "source": "window",
            "app_name": "VSCode",
            "window_title": "backend",
            "content": "Edited dashboard route",
        },
    )
    client.post(
        "/memos",
        json={
            "timestamp": now.replace(hour=9, minute=45, second=0, microsecond=0).isoformat(),
            "content": "Check timeline merge",
        },
    )

    response = client.get("/dashboard")

    assert response.status_code == 200
    assert "대시보드" in response.text
    assert "active" in response.text
    assert "Edited dashboard route" in response.text
    assert "Check timeline merge" in response.text


def test_timeline_renders_events_and_memos_in_time_order(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 26, 8, 30, tzinfo=UTC).isoformat(),
            "source": "terminal",
            "content": "Ran pytest",
        },
    )
    client.post(
        "/memos",
        json={
            "timestamp": datetime(2026, 5, 26, 9, 0, tzinfo=UTC).isoformat(),
            "content": "Document edge case",
        },
    )

    response = client.get("/timeline?date=2026-05-26")

    assert response.status_code == 200
    assert "타임라인" in response.text
    assert response.text.index("Ran pytest") < response.text.index("Document edge case")


def test_timeline_renders_screen_ocr_items(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/screen-observations",
        json={
            "timestamp": datetime(2026, 5, 26, 10, 0, tzinfo=UTC).isoformat(),
            "app_name": "Chrome",
            "ocr_text": "로그인 실패 화면",
            "detected_keywords": ["로그인", "실패"],
            "ai_inference": "인증 흐름 확인 필요",
        },
    )

    response = client.get("/timeline?date=2026-05-26")

    assert response.status_code == 200
    assert "화면 OCR" in response.text
    assert "로그인 실패 화면" in response.text
    assert "인증 흐름 확인 필요" in response.text


def test_timeline_renders_meeting_and_transcript_items(client: TestClient) -> None:
    client.post("/recording/start", json={})
    meeting = client.post(
        "/meetings/start",
        json={
            "started_at": datetime(2026, 5, 26, 15, 0, tzinfo=UTC).isoformat(),
            "title": "리포트 회의",
            "meeting_app": "Zoom",
            "transcript_enabled": True,
        },
    ).json()
    client.post(
        "/transcripts",
        json={
            "meeting_id": meeting["id"],
            "timestamp": datetime(2026, 5, 26, 15, 5, tzinfo=UTC).isoformat(),
            "speaker": "mentor",
            "text": "전사 내용은 리포트 입력에 포함합니다.",
        },
    )

    response = client.get("/timeline?date=2026-05-26")

    assert response.status_code == 200
    assert "회의" in response.text
    assert "전사" in response.text
    assert "전사 내용은 리포트 입력에 포함합니다." in response.text


@pytest.mark.parametrize("path,title", [("/reports", "리포트"), ("/settings", "설정")])
def test_placeholder_pages_render(client: TestClient, path: str, title: str) -> None:
    response = client.get(path, headers={"accept": "text/html"})

    assert response.status_code == 200
    assert title in response.text


def test_settings_page_renders_settings_and_private_apps(client: TestClient) -> None:
    client.patch("/settings", json={"settings": {"capture_enabled": True}})
    client.post(
        "/settings/private-apps",
        json={"app_name": "KakaoTalk", "match_type": "exact", "is_enabled": True},
    )

    response = client.get("/settings", headers={"accept": "text/html"})

    assert response.status_code == 200
    assert "capture_enabled" in response.text
    assert "KakaoTalk" in response.text
    assert "기록 제외 앱" in response.text


def test_reports_page_and_detail_render_generated_report(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 26, 10, 0, tzinfo=UTC).isoformat(),
            "source": "terminal",
            "content": "Implemented report skeleton",
        },
    )
    created = client.post("/reports/daily", json={"date": "2026-05-26"}).json()

    list_response = client.get("/reports", headers={"accept": "text/html"})
    detail_response = client.get(f"/reports/{created['id']}/view")

    assert list_response.status_code == 200
    assert "일일 작업 리포트" in list_response.text
    assert detail_response.status_code == 200
    assert "Implemented report skeleton" in detail_response.text
    assert "Markdown 내보내기" in detail_response.text
    assert "PDF 내보내기" in detail_response.text
    assert f"/reports/{created['id']}/download" in detail_response.text
    assert 'name="format" value="markdown"' in detail_response.text
    assert 'name="format" value="pdf"' in detail_response.text
    assert "상세 리포트" in detail_response.text
    assert "시스템" in detail_response.text

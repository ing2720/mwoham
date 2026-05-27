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


class StubSummarizer:
    def __init__(self, content: str | None) -> None:
        self.content = content
        self.calls = 0

    def summarize_daily_report(self, timeline):
        self.calls += 1
        return self.content


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


def test_daily_report_api_uses_timeline_placeholder_content(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 26, 9, 0, tzinfo=UTC).isoformat(),
            "source": "window",
            "app_name": "VSCode",
            "content": "리포트 서비스 뼈대 구현",
        },
    )
    client.post(
        "/memos",
        json={
            "timestamp": datetime(2026, 5, 26, 9, 30, tzinfo=UTC).isoformat(),
            "content": "Gemini는 아직 호출하지 않음",
        },
    )

    create_response = client.post("/reports/daily", json={"date": "2026-05-26"})

    assert create_response.status_code == 201
    created = create_response.json()
    assert created["date"] == "2026-05-26"
    assert created["created_by"] == "system"
    assert "placeholder" in created["content"]
    assert "리포트 서비스 뼈대 구현" in created["content"]
    assert "Gemini는 아직 호출하지 않음" in created["content"]

    today_response = client.get("/reports/today?date=2026-05-26")
    assert today_response.status_code == 200
    assert today_response.json()["total"] == 1

    list_response = client.get("/reports")
    assert list_response.status_code == 200
    assert list_response.json()["total"] == 1

    detail_response = client.get(f"/reports/{created['id']}")
    assert detail_response.status_code == 200
    assert detail_response.json()["id"] == created["id"]


def test_report_update_marks_report_as_user_edited(client: TestClient) -> None:
    created = client.post("/reports/daily", json={"date": "2026-05-26"}).json()

    response = client.patch(
        f"/reports/{created['id']}",
        json={"title": "수정된 리포트", "content": "사용자가 수정한 본문"},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["title"] == "수정된 리포트"
    assert body["content"] == "사용자가 수정한 본문"
    assert body["created_by"] == "user"


def test_missing_report_returns_404(client: TestClient) -> None:
    response = client.get("/reports/999")

    assert response.status_code == 404


def test_daily_report_uses_mocked_gemini_summary_when_available(client: TestClient) -> None:
    original_service = ReportService(
        repository=ReportRepository(),
        timeline_builder=get_timeline_builder(),
        summarizer=GeminiSummarizer(
            client=GeminiClient(api_key=None, model="gemini-2.5-flash"),
            prompt_builder=get_prompt_builder(),
        ),
    )
    summarizer = StubSummarizer("## Gemini 요약\n- mock 리포트")
    original_service.summarizer = summarizer
    app.dependency_overrides[get_report_service] = lambda: original_service
    try:
        response = client.post("/reports/daily", json={"date": "2026-05-26"})
    finally:
        app.dependency_overrides.pop(get_report_service, None)

    assert response.status_code == 201
    body = response.json()
    assert body["created_by"] == "ai"
    assert body["content"] == "## Gemini 요약\n- mock 리포트"
    assert summarizer.calls == 1


def test_daily_report_falls_back_when_mocked_gemini_returns_none(client: TestClient) -> None:
    original_service = ReportService(
        repository=ReportRepository(),
        timeline_builder=get_timeline_builder(),
        summarizer=GeminiSummarizer(
            client=GeminiClient(api_key=None, model="gemini-2.5-flash"),
            prompt_builder=get_prompt_builder(),
        ),
    )
    summarizer = StubSummarizer(None)
    original_service.summarizer = summarizer
    app.dependency_overrides[get_report_service] = lambda: original_service
    try:
        response = client.post("/reports/daily", json={"date": "2026-05-26"})
    finally:
        app.dependency_overrides.pop(get_report_service, None)

    assert response.status_code == 201
    body = response.json()
    assert body["created_by"] == "system"
    assert "placeholder" in body["content"]

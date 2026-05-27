from collections.abc import Generator
from datetime import UTC, datetime

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.session import get_db
from app.main import app
from app.models import Base


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


@pytest.mark.parametrize("path,title", [("/reports", "리포트"), ("/settings", "설정")])
def test_placeholder_pages_render(client: TestClient, path: str, title: str) -> None:
    response = client.get(path, headers={"accept": "text/html"})

    assert response.status_code == 200
    assert title in response.text


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

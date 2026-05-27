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

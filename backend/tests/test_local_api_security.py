from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.core.config import settings
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
    original_token = settings.local_api_token
    try:
        yield TestClient(app)
    finally:
        settings.local_api_token = original_token
        app.dependency_overrides.clear()
        Base.metadata.drop_all(bind=engine)


def test_protected_api_allows_requests_when_local_token_is_not_configured(
    client: TestClient,
) -> None:
    settings.local_api_token = ""

    response = client.post("/recording/start", json={})

    assert response.status_code == 200
    assert response.json()["status"] == "active"


def test_protected_api_rejects_missing_and_invalid_token_when_configured(
    client: TestClient,
) -> None:
    settings.local_api_token = "test-local-token"

    missing_response = client.post("/recording/start", json={})
    invalid_response = client.post(
        "/recording/start",
        json={},
        headers={"Authorization": "Bearer wrong-token"},
    )

    assert missing_response.status_code == 401
    assert invalid_response.status_code == 401


def test_protected_api_accepts_valid_bearer_token_when_configured(client: TestClient) -> None:
    settings.local_api_token = "test-local-token"

    response = client.post(
        "/recording/start",
        json={},
        headers={"Authorization": "Bearer test-local-token"},
    )

    assert response.status_code == 200
    assert response.json()["status"] == "active"


def test_public_status_and_health_do_not_require_token(client: TestClient) -> None:
    settings.local_api_token = "test-local-token"

    health_response = client.get("/health")
    status_response = client.get("/status")

    assert health_response.status_code == 200
    assert status_response.status_code == 200


def test_web_dashboard_form_bypasses_api_token_dependency(client: TestClient) -> None:
    settings.local_api_token = "test-local-token"

    response = client.post("/dashboard/recording/start", data={"title": "웹 기록"})

    assert response.status_code == 200
    assert "active" in response.text

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
    TestingSessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
    Base.metadata.create_all(bind=engine)

    def override_get_db() -> Generator[Session]:
        db = TestingSessionLocal()
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


def test_recording_lifecycle_and_status(client: TestClient) -> None:
    stopped_status = client.get("/status")
    assert stopped_status.status_code == 200
    assert stopped_status.json()["status"] == "stopped"

    start_response = client.post("/recording/start", json={"title": "API flow"})
    assert start_response.status_code == 200
    started = start_response.json()
    assert started["status"] == "active"
    session_id = started["session_id"]

    duplicate_start = client.post("/recording/start", json={})
    assert duplicate_start.status_code == 409

    pause_response = client.post("/recording/pause", json={})
    assert pause_response.status_code == 200
    assert pause_response.json()["status"] == "paused"

    resume_response = client.post("/recording/resume", json={"session_id": session_id})
    assert resume_response.status_code == 200
    assert resume_response.json()["status"] == "active"

    status_response = client.get("/status")
    assert status_response.status_code == 200
    assert status_response.json()["session_id"] == session_id
    assert status_response.json()["status"] == "active"

    stop_response = client.post("/recording/stop", json={"session_id": session_id})
    assert stop_response.status_code == 200
    assert stop_response.json()["status"] == "stopped"
    assert stop_response.json()["ended_at"] is not None

    final_status = client.get("/status")
    assert final_status.status_code == 200
    assert final_status.json()["status"] == "stopped"


def test_events_can_be_created_and_listed(client: TestClient) -> None:
    start_response = client.post("/recording/start", json={})
    session_id = start_response.json()["session_id"]
    timestamp = datetime(2026, 5, 26, 10, 30, tzinfo=UTC).isoformat()

    create_response = client.post(
        "/events",
        json={
            "timestamp": timestamp,
            "source": "terminal",
            "app_name": "Terminal",
            "window_title": "pytest",
            "content": "pytest backend/tests",
            "project_name": "mwoham",
            "metadata_json": {"command": "pytest"},
            "confidence": 0.95,
        },
    )

    assert create_response.status_code == 201
    assert create_response.json()["saved"] is True

    list_response = client.get(f"/events?session_id={session_id}&source=terminal&date=2026-05-26")
    assert list_response.status_code == 200
    body = list_response.json()
    assert body["total"] == 1
    assert body["items"][0]["content"] == "pytest backend/tests"

    status_response = client.get("/status")
    assert status_response.json()["current_app"] == "Terminal"
    assert status_response.json()["current_window"] == "pytest"


def test_event_without_active_session_returns_404(client: TestClient) -> None:
    response = client.post(
        "/events",
        json={
            "timestamp": datetime.now(UTC).isoformat(),
            "source": "window",
            "content": "active window changed",
        },
    )

    assert response.status_code == 404


def test_memos_can_be_created_and_listed_without_session(client: TestClient) -> None:
    timestamp = datetime(2026, 5, 26, 12, 0, tzinfo=UTC).isoformat()

    create_response = client.post(
        "/memos",
        json={
            "timestamp": timestamp,
            "content": "Remember the recording API edge case.",
            "linked_type": "work_event",
            "linked_id": 1,
        },
    )

    assert create_response.status_code == 201
    assert create_response.json()["session_id"] is None

    list_response = client.get("/memos?date=2026-05-26")
    assert list_response.status_code == 200
    body = list_response.json()
    assert body["total"] == 1
    assert body["items"][0]["content"] == "Remember the recording API edge case."


def test_screen_observations_are_saved_listed_and_deduplicated(client: TestClient) -> None:
    start_response = client.post("/recording/start", json={})
    session_id = start_response.json()["session_id"]
    timestamp = datetime(2026, 5, 26, 13, 0, tzinfo=UTC).isoformat()
    payload = {
        "timestamp": timestamp,
        "app_name": "Chrome",
        "window_title": "Swagger UI",
        "ocr_text": "401 Unauthorized token=secret",
        "detected_keywords": ["401", "Authorization"],
        "ai_inference": "인증 헤더 누락 가능성",
        "frame_hash": "same-frame",
    }

    first = client.post("/screen-observations", json=payload)
    second = client.post("/screen-observations", json=payload)

    assert first.status_code == 201
    assert first.json()["saved"] is True
    assert second.status_code == 201
    assert second.json()["saved"] is False
    assert second.json()["duplicate"] is True
    assert second.json()["id"] == first.json()["id"]

    list_response = client.get(f"/screen-observations?session_id={session_id}&date=2026-05-26")
    assert list_response.status_code == 200
    body = list_response.json()
    assert body["total"] == 1
    assert body["items"][0]["ocr_text"] == "401 Unauthorized token=secret"
    assert body["items"][0]["detected_keywords"] == ["401", "Authorization"]


def test_timeline_today_includes_screen_ocr_items(client: TestClient) -> None:
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
        "/screen-observations",
        json={
            "timestamp": datetime(2026, 5, 26, 8, 45, tzinfo=UTC).isoformat(),
            "app_name": "Chrome",
            "ocr_text": "OAuth callback error",
            "detected_keywords": ["OAuth", "error"],
        },
    )
    client.post(
        "/memos",
        json={
            "timestamp": datetime(2026, 5, 26, 9, 0, tzinfo=UTC).isoformat(),
            "content": "Check auth settings",
        },
    )

    response = client.get("/timeline/today?date=2026-05-26")

    assert response.status_code == 200
    body = response.json()
    assert [item["type"] for item in body["items"]] == ["event", "screen_ocr", "memo"]
    assert body["items"][1]["content"] == "OAuth callback error"
    assert body["items"][1]["detected_keywords"] == ["OAuth", "error"]


def test_settings_and_private_apps_crud(client: TestClient) -> None:
    settings_response = client.patch(
        "/settings",
        json={"settings": {"poll_interval_seconds": 5, "capture_enabled": True}},
    )
    assert settings_response.status_code == 200
    assert settings_response.json()["total"] == 2

    create_response = client.post(
        "/settings/private-apps",
        json={"app_name": "KakaoTalk", "match_type": "exact", "is_enabled": True},
    )
    assert create_response.status_code == 200
    assert create_response.json()["app_name"] == "KakaoTalk"

    list_response = client.get("/settings/private-apps")
    assert list_response.status_code == 200
    assert list_response.json()["total"] == 1

    delete_response = client.delete("/settings/private-apps/KakaoTalk")
    assert delete_response.status_code == 200
    assert delete_response.json()["deleted"] is True


def test_private_app_minimizes_event_and_screen_observation(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/settings/private-apps",
        json={"app_name": "Kakao", "match_type": "contains", "is_enabled": True},
    )

    event_response = client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 26, 10, 0, tzinfo=UTC).isoformat(),
            "source": "window",
            "app_name": "KakaoTalk",
            "window_title": "친구와의 대화",
            "content": "민감한 메시지 token=secret",
            "metadata_json": {"raw": "sensitive"},
        },
    )
    screen_response = client.post(
        "/screen-observations",
        json={
            "timestamp": datetime(2026, 5, 26, 10, 1, tzinfo=UTC).isoformat(),
            "app_name": "KakaoTalk",
            "window_title": "친구와의 대화",
            "ocr_text": "민감한 화면 텍스트",
            "detected_keywords": ["민감"],
        },
    )

    assert event_response.status_code == 201
    assert screen_response.status_code == 201

    events = client.get("/events?date=2026-05-26").json()["items"]
    observations = client.get("/screen-observations?date=2026-05-26").json()["items"]
    assert events[0]["content"] == "비공개 앱 사용 중"
    assert events[0]["window_title"] is None
    assert events[0]["metadata_json"] is None
    assert observations[0]["ocr_text"] is None
    assert observations[0]["window_title"] is None
    assert observations[0]["detected_keywords"] is None


def test_disabled_private_app_rule_is_ignored(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/settings/private-apps",
        json={"app_name": "SecretApp", "match_type": "exact", "is_enabled": False},
    )

    response = client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 26, 11, 0, tzinfo=UTC).isoformat(),
            "source": "window",
            "app_name": "SecretApp",
            "window_title": "Visible title",
            "content": "Visible content",
        },
    )

    assert response.status_code == 201
    event = client.get("/events?date=2026-05-26").json()["items"][0]
    assert event["content"] == "Visible content"
    assert event["window_title"] == "Visible title"


def test_private_app_regex_match_minimizes_event(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/settings/private-apps",
        json={"app_name": "^Bank", "match_type": "regex", "is_enabled": True},
    )

    client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 26, 12, 0, tzinfo=UTC).isoformat(),
            "source": "window",
            "app_name": "BankSecure",
            "window_title": "Account",
            "content": "Balance details",
        },
    )

    event = client.get("/events?date=2026-05-26").json()["items"][0]
    assert event["content"] == "비공개 앱 사용 중"

from datetime import UTC, datetime

from fastapi.testclient import TestClient

from app.main import app
from app.repositories.screen_observation_repository import ScreenObservationRepository
from app.repositories.work_session_repository import WorkSessionRepository
from app.services.screen_observation_service import (
    ScreenObservationService,
    get_screen_observation_service,
)
from app.services.setting_service import get_setting_service


class SpyScreenObservationSummarizer:
    def __init__(self) -> None:
        self.calls = 0

    def summarize(self, *, ocr_text, app_name, window_title):
        self.calls += 1
        return f"AI 요약 {self.calls}"


def _override_screen_observation_service(
    summarizer,
    *,
    enable_ai_inference: bool,
    ai_min_interval_seconds: int = 300,
    ai_daily_limit: int = 5,
) -> None:
    app.dependency_overrides[get_screen_observation_service] = lambda: ScreenObservationService(
        observation_repository=ScreenObservationRepository(),
        session_repository=WorkSessionRepository(),
        setting_service=get_setting_service(),
        observation_summarizer=summarizer,
        enable_ai_inference=enable_ai_inference,
        ai_min_interval_seconds=ai_min_interval_seconds,
        ai_daily_limit=ai_daily_limit,
    )


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
    assert status_response.json()["session_started_at"] is not None
    assert isinstance(status_response.json()["elapsed_seconds"], int)

    stop_response = client.post("/recording/stop", json={"session_id": session_id})
    assert stop_response.status_code == 200
    assert stop_response.json()["status"] == "stopped"
    assert stop_response.json()["ended_at"] is not None

    final_status = client.get("/status")
    assert final_status.status_code == 200
    assert final_status.json()["status"] == "stopped"
    assert final_status.json()["session_started_at"] is None
    assert final_status.json()["elapsed_seconds"] is None


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


def test_activity_segments_are_created_updated_and_added_to_timeline(client: TestClient) -> None:
    client.post("/recording/start", json={})
    started_at = datetime(2026, 5, 26, 10, 0, tzinfo=UTC)
    last_seen_at = datetime(2026, 5, 26, 10, 0, 2, tzinfo=UTC)

    create_response = client.post(
        "/activity-segments",
        json={
            "started_at": started_at.isoformat(),
            "last_seen_at": last_seen_at.isoformat(),
            "source": "mac_active_window",
            "app_name": "Chrome",
            "window_title": "PR 작성",
        },
    )

    assert create_response.status_code == 201
    segment = create_response.json()
    assert segment["duration_seconds"] == 2
    assert segment["sample_count"] == 1

    update_response = client.patch(
        f"/activity-segments/{segment['id']}",
        json={"last_seen_at": datetime(2026, 5, 26, 10, 0, 8, tzinfo=UTC).isoformat()},
    )

    assert update_response.status_code == 200
    updated = update_response.json()
    assert updated["duration_seconds"] == 8
    assert updated["sample_count"] == 2

    status_response = client.get("/status")
    assert status_response.json()["current_app"] == "Chrome"
    assert status_response.json()["current_window"] == "PR 작성"

    client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 26, 10, 0, 4, tzinfo=UTC).isoformat(),
            "source": "mac_active_window",
            "app_name": "Chrome",
            "window_title": "PR 작성",
            "content": "Chrome / PR 작성",
        },
    )
    client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 26, 10, 1, tzinfo=UTC).isoformat(),
            "source": "terminal",
            "content": "Ran pytest",
        },
    )
    client.post(
        "/memos",
        json={
            "timestamp": datetime(2026, 5, 26, 10, 2, tzinfo=UTC).isoformat(),
            "content": "Manual note",
        },
    )

    timeline_response = client.get("/timeline/today?date=2026-05-26")
    assert timeline_response.status_code == 200
    items = timeline_response.json()["items"]
    segment_items = [item for item in items if item["type"] == "activity_segment"]
    event_items = [item for item in items if item["type"] == "event"]
    memo_items = [item for item in items if item["type"] == "memo"]
    assert segment_items[0]["app_name"] == "Chrome"
    assert segment_items[0]["duration_seconds"] == 8
    assert "mac_active_window" not in {item["source"] for item in event_items}
    assert event_items[0]["content"] == "Ran pytest"
    assert memo_items[0]["content"] == "Manual note"


def test_private_apps_are_not_saved_as_activity_segments(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/settings/private-apps",
        json={"app_name": "Discord", "match_type": "exact", "is_enabled": True},
    )

    create_response = client.post(
        "/activity-segments",
        json={
            "started_at": datetime(2026, 5, 26, 11, 0, tzinfo=UTC).isoformat(),
            "last_seen_at": datetime(2026, 5, 26, 11, 0, 2, tzinfo=UTC).isoformat(),
            "source": "mac_active_window",
            "app_name": "Discord",
            "window_title": "DM",
        },
    )

    assert create_response.status_code == 201
    assert create_response.json()["saved"] is False
    assert create_response.json()["id"] is None

    list_response = client.get("/activity-segments?date=2026-05-26")
    assert list_response.status_code == 200
    assert list_response.json()["total"] == 0


def test_disabled_private_app_rule_does_not_block_activity_segments(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/settings/private-apps",
        json={"app_name": "Discord", "match_type": "exact", "is_enabled": False},
    )

    create_response = client.post(
        "/activity-segments",
        json={
            "started_at": datetime(2026, 5, 26, 11, 30, tzinfo=UTC).isoformat(),
            "last_seen_at": datetime(2026, 5, 26, 11, 30, 4, tzinfo=UTC).isoformat(),
            "source": "mac_active_window",
            "app_name": "Discord",
            "window_title": "General",
        },
    )

    assert create_response.status_code == 201
    assert create_response.json()["saved"] is True
    assert create_response.json()["id"] is not None


def test_timeline_filters_private_activity_segments_defensively(client: TestClient) -> None:
    client.post("/recording/start", json={})
    create_response = client.post(
        "/activity-segments",
        json={
            "started_at": datetime(2026, 5, 26, 12, 0, tzinfo=UTC).isoformat(),
            "last_seen_at": datetime(2026, 5, 26, 12, 0, 3, tzinfo=UTC).isoformat(),
            "source": "mac_active_window",
            "app_name": "KakaoTalk",
            "window_title": "친구와의 대화",
        },
    )
    client.post(
        "/activity-segments",
        json={
            "started_at": datetime(2026, 5, 26, 12, 5, tzinfo=UTC).isoformat(),
            "last_seen_at": datetime(2026, 5, 26, 12, 5, 3, tzinfo=UTC).isoformat(),
            "source": "mac_active_window",
            "app_name": "PyCharm",
            "window_title": "backend",
        },
    )
    client.post(
        "/settings/private-apps",
        json={"app_name": "Kakao", "match_type": "contains", "is_enabled": True},
    )

    assert create_response.json()["saved"] is True

    timeline_response = client.get("/timeline/today?date=2026-05-26")
    items = timeline_response.json()["items"]
    segment_items = [item for item in items if item["type"] == "activity_segment"]
    assert {item["app_name"] for item in segment_items} == {"PyCharm"}


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


def test_screen_observation_ai_inference_is_disabled_by_default(client: TestClient) -> None:
    summarizer = SpyScreenObservationSummarizer()
    _override_screen_observation_service(summarizer, enable_ai_inference=False)
    client.post("/recording/start", json={})

    try:
        response = client.post(
            "/screen-observations",
            json={
                "timestamp": datetime(2026, 5, 26, 14, 0, tzinfo=UTC).isoformat(),
                "app_name": "Chrome",
                "window_title": "Dashboard",
                "ocr_text": "Mwoham dashboard report generation screen observation",
                "detected_keywords": ["report"],
            },
        )
    finally:
        app.dependency_overrides.pop(get_screen_observation_service, None)

    assert response.status_code == 201
    observations = client.get("/screen-observations?date=2026-05-26").json()["items"]
    assert summarizer.calls == 0
    assert observations[0]["ai_inference"] is None
    assert observations[0]["ocr_text"] == "Mwoham dashboard report generation screen observation"


def test_screen_observation_ai_inference_can_be_enabled(client: TestClient) -> None:
    summarizer = SpyScreenObservationSummarizer()
    _override_screen_observation_service(summarizer, enable_ai_inference=True)
    client.post("/recording/start", json={})

    try:
        response = client.post(
            "/screen-observations",
            json={
                "timestamp": datetime(2026, 5, 26, 14, 10, tzinfo=UTC).isoformat(),
                "app_name": "Chrome",
                "window_title": "Dashboard",
                "ocr_text": "Mwoham dashboard report generation screen observation",
            },
        )
    finally:
        app.dependency_overrides.pop(get_screen_observation_service, None)

    assert response.status_code == 201
    observations = client.get("/screen-observations?date=2026-05-26").json()["items"]
    assert summarizer.calls == 1
    assert observations[0]["ai_inference"] == "AI 요약 1"


def test_screen_observation_ai_inference_respects_min_interval(client: TestClient) -> None:
    summarizer = SpyScreenObservationSummarizer()
    _override_screen_observation_service(
        summarizer,
        enable_ai_inference=True,
        ai_min_interval_seconds=300,
    )
    client.post("/recording/start", json={})

    try:
        for timestamp in [
            datetime(2026, 5, 26, 14, 20, tzinfo=UTC),
            datetime(2026, 5, 26, 14, 21, tzinfo=UTC),
        ]:
            client.post(
                "/screen-observations",
                json={
                    "timestamp": timestamp.isoformat(),
                    "app_name": "Chrome",
                    "window_title": "Dashboard",
                    "ocr_text": "Mwoham dashboard report generation screen observation",
                    "frame_hash": f"frame-{timestamp.minute}",
                },
            )
    finally:
        app.dependency_overrides.pop(get_screen_observation_service, None)

    observations = client.get("/screen-observations?date=2026-05-26").json()["items"]
    assert summarizer.calls == 1
    assert [item["ai_inference"] for item in observations] == [None, "AI 요약 1"]


def test_screen_observation_ai_inference_respects_daily_limit(client: TestClient) -> None:
    summarizer = SpyScreenObservationSummarizer()
    _override_screen_observation_service(
        summarizer,
        enable_ai_inference=True,
        ai_min_interval_seconds=0,
        ai_daily_limit=1,
    )
    client.post("/recording/start", json={})

    try:
        for index, app_name in enumerate(["Chrome", "PyCharm"], start=1):
            client.post(
                "/screen-observations",
                json={
                    "timestamp": datetime(2026, 5, 26, 14, 30 + index, tzinfo=UTC).isoformat(),
                    "app_name": app_name,
                    "window_title": "Work",
                    "ocr_text": "Mwoham dashboard report generation screen observation",
                    "frame_hash": f"daily-limit-{index}",
                },
            )
    finally:
        app.dependency_overrides.pop(get_screen_observation_service, None)

    observations = client.get("/screen-observations?date=2026-05-26").json()["items"]
    assert summarizer.calls == 1
    assert [item["ai_inference"] for item in observations] == [None, "AI 요약 1"]


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
            "ocr_text": "OAuth callback error while testing FastAPI login flow",
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
    assert body["items"][1]["content"] == "OAuth callback error while testing FastAPI login flow"
    assert body["items"][1]["ocr_text"] == "OAuth callback error while testing FastAPI login flow"
    assert body["items"][1]["ai_inference"] is None
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


def test_meeting_lifecycle_and_transcripts(client: TestClient) -> None:
    start_session = client.post("/recording/start", json={})
    session_id = start_session.json()["session_id"]

    meeting_start = client.post(
        "/meetings/start",
        json={
            "started_at": datetime(2026, 5, 26, 14, 0, tzinfo=UTC).isoformat(),
            "meeting_app": "Zoom",
            "title": "인증 플로우 회의",
            "transcript_enabled": True,
        },
    )
    assert meeting_start.status_code == 200
    meeting = meeting_start.json()
    assert meeting["session_id"] == session_id
    assert meeting["transcript_enabled"] is True

    transcript = client.post(
        "/transcripts",
        json={
            "meeting_id": meeting["id"],
            "timestamp": datetime(2026, 5, 26, 14, 5, tzinfo=UTC).isoformat(),
            "speaker": "speaker_1",
            "text": "콜백 오류는 redirect URI 설정을 먼저 확인하겠습니다.",
            "confidence": 0.91,
        },
    )
    assert transcript.status_code == 201
    assert transcript.json()["speaker"] == "speaker_1"

    meeting_end = client.post(
        f"/meetings/{meeting['id']}/end",
        json={
            "ended_at": datetime(2026, 5, 26, 14, 30, tzinfo=UTC).isoformat(),
            "summary": "redirect URI 확인 결정",
        },
    )
    assert meeting_end.status_code == 200
    assert meeting_end.json()["summary"] == "redirect URI 확인 결정"

    meetings = client.get("/meetings?date=2026-05-26")
    transcripts = client.get(f"/meetings/{meeting['id']}/transcripts")
    assert meetings.status_code == 200
    assert meetings.json()["total"] == 1
    assert transcripts.status_code == 200
    assert transcripts.json()["total"] == 1
    assert transcripts.json()["items"][0]["text"].startswith("콜백 오류")


def test_timeline_today_includes_meeting_and_transcript_items(client: TestClient) -> None:
    client.post("/recording/start", json={})
    meeting = client.post(
        "/meetings/start",
        json={
            "started_at": datetime(2026, 5, 26, 10, 0, tzinfo=UTC).isoformat(),
            "title": "스프린트 회의",
            "meeting_app": "Google Meet",
            "transcript_enabled": True,
        },
    ).json()
    client.post(
        "/transcripts",
        json={
            "meeting_id": meeting["id"],
            "timestamp": datetime(2026, 5, 26, 10, 10, tzinfo=UTC).isoformat(),
            "speaker": "PM",
            "text": "오늘은 전사 저장 API를 마무리합니다.",
        },
    )
    client.post(
        f"/meetings/{meeting['id']}/end",
        json={"ended_at": datetime(2026, 5, 26, 10, 30, tzinfo=UTC).isoformat()},
    )

    response = client.get("/timeline/today?date=2026-05-26")

    assert response.status_code == 200
    body = response.json()
    assert [item["type"] for item in body["items"]] == ["meeting", "transcript", "meeting"]
    assert body["items"][0]["content"] == "스프린트 회의 시작"
    assert body["items"][1]["content"] == "오늘은 전사 저장 API를 마무리합니다."
    assert body["items"][1]["speaker"] == "PM"
    assert body["items"][2]["content"] == "스프린트 회의 종료"

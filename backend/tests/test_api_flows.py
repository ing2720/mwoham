from datetime import UTC, datetime

from fastapi.testclient import TestClient

from app.core.timezone import KST
from app.main import app
from app.repositories.screen_observation_repository import ScreenObservationRepository
from app.repositories.work_session_repository import WorkSessionRepository
from app.services.screen_observation_policy import ScreenObservationInferencePolicy
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
    observation_repository = ScreenObservationRepository()
    app.dependency_overrides[get_screen_observation_service] = lambda: ScreenObservationService(
        observation_repository=observation_repository,
        session_repository=WorkSessionRepository(),
        setting_service=get_setting_service(),
        observation_summarizer=summarizer,
        inference_policy=ScreenObservationInferencePolicy(
            observation_repository=observation_repository,
            enable_ai_inference=enable_ai_inference,
            ai_min_interval_seconds=ai_min_interval_seconds,
            ai_daily_limit=ai_daily_limit,
        ),
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


def test_activity_segments_are_created_updated_and_added_to_detail_timeline(
    client: TestClient,
) -> None:
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
    detail_response = client.get("/timeline/today/detail?date=2026-05-26")
    assert timeline_response.status_code == 200
    assert detail_response.status_code == 200
    items = detail_response.json()["items"]
    segment_items = [item for item in items if item["type"] == "activity_segment"]
    event_items = [item for item in items if item["type"] == "event"]
    memo_items = [item for item in items if item["type"] == "memo"]
    basic_items = timeline_response.json()["items"]
    assert [item for item in basic_items if item["type"] == "activity_segment"] == []
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

    timeline_response = client.get("/timeline/today/detail?date=2026-05-26")
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
    assert body["items"][1]["content"] == "화면 텍스트 수집됨"
    assert body["items"][1]["ocr_text"] is None
    assert body["items"][1]["ai_inference"] is None
    assert body["items"][1]["detected_keywords"] == ["OAuth", "error"]


def test_basic_timeline_prioritizes_ai_inference_and_hides_raw_ocr(
    client: TestClient,
) -> None:
    client.post("/recording/start", json={})
    raw_ocr = "very long raw OCR text with console output and browser navigation"
    client.post(
        "/screen-observations",
        json={
            "timestamp": datetime(2026, 5, 26, 8, 45, tzinfo=UTC).isoformat(),
            "app_name": "Chrome",
            "ocr_text": raw_ocr,
            "ai_inference": "사용자는 인증 오류를 확인하고 있습니다.",
        },
    )

    response = client.get("/timeline/today?date=2026-05-26")

    assert response.status_code == 200
    item = response.json()["items"][0]
    assert item["content"] == "사용자는 인증 오류를 확인하고 있습니다."
    assert item["ocr_text"] is None
    assert raw_ocr not in item["content"]


def test_self_service_screen_observation_is_excluded_from_basic_timeline(
    client: TestClient,
) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/screen-observations",
        json={
            "timestamp": datetime(2026, 5, 26, 8, 45, tzinfo=UTC).isoformat(),
            "app_name": "Google Chrome",
            "window_title": "대시보드 - 뭐함",
            "ocr_text": "127.0.0.1:8765 dashboard 작업 기록 자동화 서비스",
        },
    )
    client.post(
        "/memos",
        json={
            "timestamp": datetime(2026, 5, 26, 9, 0, tzinfo=UTC).isoformat(),
            "content": "사용자 메모",
        },
    )

    basic_response = client.get("/timeline/today?date=2026-05-26")
    detail_response = client.get("/timeline/today/detail?date=2026-05-26")

    assert [item["type"] for item in basic_response.json()["items"]] == ["memo"]
    assert any(item["type"] == "screen_ocr" for item in detail_response.json()["items"])


def test_mac_active_window_work_event_is_excluded_from_basic_timeline(
    client: TestClient,
) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 26, 8, 30, tzinfo=UTC).isoformat(),
            "source": "mac_active_window",
            "content": "Chrome / Dashboard",
        },
    )
    client.post(
        "/memos",
        json={
            "timestamp": datetime(2026, 5, 26, 9, 0, tzinfo=UTC).isoformat(),
            "content": "Manual memo",
        },
    )

    response = client.get("/timeline/today?date=2026-05-26")

    assert [item["type"] for item in response.json()["items"]] == ["memo"]


def test_dev_events_can_be_created_listed_and_added_to_timeline(client: TestClient) -> None:
    response = client.post(
        "/dev-events",
        json={
            "event_type": "test_result",
            "source": "api",
            "command": "uv run pytest",
            "status": "success",
            "summary": "pytest 통과: 111 passed",
            "details_json": {
                "changed_files": ["backend/app/services/report_service.py"],
                "exit_code": 0,
            },
            "occurred_at": datetime(2026, 5, 26, 13, 0, tzinfo=UTC).isoformat(),
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["event_type"] == "test_result"
    assert body["summary"] == "pytest 통과: 111 passed"

    list_response = client.get("/dev-events?date=2026-05-26")
    assert list_response.status_code == 200
    assert list_response.json()["total"] == 1

    basic_timeline = client.get("/timeline/today?date=2026-05-26").json()["items"]
    detail_timeline = client.get("/timeline/today/detail?date=2026-05-26").json()["items"]
    assert basic_timeline[0]["type"] == "dev_event"
    assert basic_timeline[0]["content"] == "테스트 실행 결과: pytest 통과: 111 passed"
    assert detail_timeline[0]["details_json"]["changed_files"] == [
        "backend/app/services/report_service.py"
    ]
    assert "exit_code=0" in detail_timeline[0]["content"]


def test_git_dev_events_have_manual_and_watcher_display_labels(
    client: TestClient,
) -> None:
    client.post(
        "/dev-events",
        json={
            "event_type": "git_snapshot",
            "source": "script",
            "summary": "Git 변경 파일 확인: backend/app/services/report_service.py",
            "details_json": {
                "changed_files": ["backend/app/services/report_service.py"],
            },
            "occurred_at": datetime(2026, 5, 26, 13, 0, tzinfo=UTC).isoformat(),
        },
    )
    client.post(
        "/dev-events",
        json={
            "event_type": "git_snapshot",
            "source": "script",
            "summary": "Git 변경 감지: 2 files changed on feat/dev-tracking",
            "details_json": {
                "tracking_mode": "watch",
                "changed_files": ["backend/scripts/dev_tracking.py"],
            },
            "occurred_at": datetime(2026, 5, 26, 13, 5, tzinfo=UTC).isoformat(),
        },
    )

    basic_timeline = client.get("/timeline/today?date=2026-05-26").json()["items"]
    detail_timeline = client.get("/timeline/today/detail?date=2026-05-26").json()["items"]

    assert [item["display_label"] for item in basic_timeline] == [
        "수동 Git 상태 수집",
        "자동 Git 변경 감지",
    ]
    assert [item["display_label"] for item in detail_timeline] == [
        "수동 Git 상태 수집",
        "자동 Git 변경 감지",
    ]


def test_dev_event_masks_sensitive_summary_and_details(client: TestClient) -> None:
    response = client.post(
        "/dev-events",
        json={
            "event_type": "command_result",
            "source": "api",
            "command": "curl -H 'Authorization: Bearer abc123'",
            "status": "failed",
            "summary": "token=abc123 secret=hidden",
            "details_json": {"stderr_excerpt": "password=hunter2"},
            "occurred_at": datetime(2026, 5, 26, 13, 10, tzinfo=UTC).isoformat(),
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert "abc123" not in body["summary"]
    assert "hidden" not in body["summary"]
    assert "hunter2" not in body["details_json"]["stderr_excerpt"]
    assert "abc123" not in body["command"]


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


def test_invalid_private_app_regex_does_not_block_storage(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/settings/private-apps",
        json={"app_name": "[", "match_type": "regex", "is_enabled": True},
    )

    response = client.post(
        "/activity-segments",
        json={
            "started_at": datetime(2026, 5, 26, 12, 10, tzinfo=UTC).isoformat(),
            "last_seen_at": datetime(2026, 5, 26, 12, 10, 2, tzinfo=UTC).isoformat(),
            "source": "mac_active_window",
            "app_name": "BankSecure",
        },
    )

    assert response.status_code == 201
    assert response.json()["saved"] is True


def test_private_screen_observation_is_excluded_from_timeline(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/settings/private-apps",
        json={"app_name": "Kakao", "match_type": "contains", "is_enabled": True},
    )
    client.post(
        "/screen-observations",
        json={
            "timestamp": datetime(2026, 5, 26, 12, 20, tzinfo=UTC).isoformat(),
            "app_name": "KakaoTalk",
            "window_title": "친구와의 대화",
            "ocr_text": "민감한 화면 텍스트",
        },
    )

    basic_response = client.get("/timeline/today?date=2026-05-26")
    detail_response = client.get("/timeline/today/detail?date=2026-05-26")

    assert basic_response.status_code == 200
    assert detail_response.status_code == 200
    assert basic_response.json()["items"] == []
    assert detail_response.json()["items"] == []


def test_screen_observation_ai_daily_limit_uses_kst_date(client: TestClient) -> None:
    summarizer = SpyScreenObservationSummarizer()
    _override_screen_observation_service(
        summarizer,
        enable_ai_inference=True,
        ai_min_interval_seconds=0,
        ai_daily_limit=1,
    )
    client.post("/recording/start", json={})

    try:
        for timestamp, frame_hash in [
            (datetime(2026, 5, 31, 14, 50, tzinfo=UTC), "kst-previous-day"),
            (datetime(2026, 5, 31, 15, 10, tzinfo=UTC), "kst-target-day"),
            (datetime(2026, 5, 31, 16, 10, tzinfo=UTC), "kst-target-day-second"),
        ]:
            client.post(
                "/screen-observations",
                json={
                    "timestamp": timestamp.isoformat(),
                    "app_name": "Chrome",
                    "window_title": frame_hash,
                    "ocr_text": "report timeline OCR quota test",
                    "frame_hash": frame_hash,
                },
            )
    finally:
        app.dependency_overrides.pop(get_screen_observation_service, None)

    previous_day = client.get("/screen-observations?date=2026-05-31").json()["items"]
    target_day = client.get("/screen-observations?date=2026-06-01").json()["items"]
    assert summarizer.calls == 2
    assert [item["ai_inference"] for item in previous_day] == ["AI 요약 1"]
    assert [item["ai_inference"] for item in target_day] == [None, "AI 요약 2"]


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


def test_current_meeting_and_status_reflect_active_meeting(client: TestClient) -> None:
    client.post("/recording/start", json={})

    meeting_start = client.post(
        "/meetings/start",
        json={
            "started_at": datetime(2026, 5, 26, 14, 0, tzinfo=UTC).isoformat(),
            "title": "상태 확인 회의",
        },
    )

    assert meeting_start.status_code == 200
    meeting = meeting_start.json()
    assert meeting["status"] == "active"

    current = client.get("/meetings/current")
    status_response = client.get("/status")

    assert current.status_code == 200
    assert current.json()["id"] == meeting["id"]
    assert current.json()["status"] == "active"
    assert status_response.status_code == 200
    assert status_response.json()["meeting_mode"] is True
    assert status_response.json()["current_meeting"]["id"] == meeting["id"]

    meeting_end = client.post(
        f"/meetings/{meeting['id']}/end",
        json={"ended_at": datetime(2026, 5, 26, 14, 30, tzinfo=UTC).isoformat()},
    )

    assert meeting_end.status_code == 200
    assert meeting_end.json()["status"] == "ended"
    assert client.get("/meetings/current").json() is None
    ended_status = client.get("/status").json()
    assert ended_status["meeting_mode"] is False
    assert ended_status["current_meeting"] is None


def test_start_meeting_rejects_existing_active_meeting(client: TestClient) -> None:
    client.post("/recording/start", json={})
    first = client.post("/meetings/start", json={"title": "첫 회의"})
    second = client.post("/meetings/start", json={"title": "두 번째 회의"})

    assert first.status_code == 200
    assert second.status_code == 409


def test_end_meeting_rejects_missing_or_already_ended_meeting(client: TestClient) -> None:
    client.post("/recording/start", json={})
    missing = client.post("/meetings/999/end", json={})
    meeting = client.post("/meetings/start", json={"title": "종료 테스트"}).json()
    first_end = client.post(f"/meetings/{meeting['id']}/end", json={})
    second_end = client.post(f"/meetings/{meeting['id']}/end", json={})

    assert missing.status_code == 404
    assert first_end.status_code == 200
    assert second_end.status_code == 409


def test_create_meeting_transcript_with_explicit_meeting_session_id(client: TestClient) -> None:
    client.post("/recording/start", json={})
    meeting = client.post("/meetings/start", json={"title": "전사 API 회의"}).json()

    response = client.post(
        "/meeting-transcripts",
        json={
            "meeting_session_id": meeting["id"],
            "text": "결정사항은 다음 스프린트에서 OCR 품질을 검증하는 것입니다.",
            "source": "manual",
            "started_at": datetime(2026, 5, 26, 12, 0, tzinfo=UTC).isoformat(),
            "ended_at": datetime(2026, 5, 26, 12, 1, tzinfo=UTC).isoformat(),
        },
    )

    assert response.status_code == 201
    body = response.json()
    assert body["meeting_session_id"] == meeting["id"]
    assert body["source"] == "manual"
    assert body["text"].startswith("결정사항은")

    transcripts = client.get(f"/meetings/{meeting['id']}/transcripts")
    assert transcripts.status_code == 200
    assert transcripts.json()["items"][0]["source"] == "manual"


def test_create_meeting_transcript_auto_links_active_meeting(client: TestClient) -> None:
    client.post("/recording/start", json={})
    meeting = client.post("/meetings/start", json={"title": "자동 연결 회의"}).json()

    response = client.post(
        "/meeting-transcripts",
        json={"text": "Apple Speech 전사 결과를 활성 회의에 자동 연결합니다."},
    )

    assert response.status_code == 201
    assert response.json()["meeting_session_id"] == meeting["id"]
    assert response.json()["source"] == "apple_speech"


def test_create_meeting_transcript_accepts_system_audio_source(client: TestClient) -> None:
    client.post("/recording/start", json={})
    meeting = client.post("/meetings/start", json={"title": "시스템 오디오 회의"}).json()

    response = client.post(
        "/meeting-transcripts",
        json={
            "meeting_session_id": meeting["id"],
            "text": "시스템 오디오 기반 Apple Speech 전사 결과를 저장합니다.",
            "source": "apple_speech_system_audio",
        },
    )

    assert response.status_code == 201
    assert response.json()["meeting_session_id"] == meeting["id"]
    assert response.json()["source"] == "apple_speech_system_audio"


def test_create_meeting_transcript_accepts_full_meeting_source(client: TestClient) -> None:
    client.post("/recording/start", json={})
    meeting = client.post("/meetings/start", json={"title": "회의 전체 전사"}).json()

    response = client.post(
        "/meeting-transcripts",
        json={
            "meeting_session_id": meeting["id"],
            "text": "회의 전체 Apple Speech 전사 결과를 저장합니다.",
            "source": "apple_speech_full_meeting",
        },
    )

    assert response.status_code == 201
    assert response.json()["meeting_session_id"] == meeting["id"]
    assert response.json()["source"] == "apple_speech_full_meeting"


def test_create_meeting_transcript_allows_nullable_meeting_when_no_active_meeting(
    client: TestClient,
) -> None:
    response = client.post(
        "/meeting-transcripts",
        json={"text": "회의 세션 연결 없이도 전사 텍스트는 유실하지 않습니다."},
    )

    assert response.status_code == 201
    assert response.json()["meeting_session_id"] is None


def test_create_meeting_transcript_rejects_empty_text(client: TestClient) -> None:
    response = client.post("/meeting-transcripts", json={"text": "   "})

    assert response.status_code == 400


def test_create_meeting_transcript_rejects_too_short_text(client: TestClient) -> None:
    response = client.post("/meeting-transcripts", json={"text": "둘"})

    assert response.status_code == 400


def test_create_meeting_transcript_deduplicates_repeated_text(client: TestClient) -> None:
    client.post("/recording/start", json={})
    meeting = client.post("/meetings/start", json={"title": "중복 방어 회의"}).json()

    first = client.post(
        "/meeting-transcripts",
        json={
            "meeting_session_id": meeting["id"],
            "text": "Apple Speech 전사 저장 품질을 점검합니다.",
        },
    )
    duplicate = client.post(
        "/meeting-transcripts",
        json={
            "meeting_session_id": meeting["id"],
            "text": "Apple Speech 전사 저장 품질을 점검합니다.",
        },
    )
    transcripts = client.get(f"/meetings/{meeting['id']}/transcripts")

    assert first.status_code == 201
    assert duplicate.status_code == 201
    assert first.json()["id"] == duplicate.json()["id"]
    assert transcripts.json()["total"] == 1


def test_create_meeting_transcript_updates_minor_extension_instead_of_new_row(
    client: TestClient,
) -> None:
    client.post("/recording/start", json={})
    meeting = client.post("/meetings/start", json={"title": "누적 결과 회의"}).json()

    first = client.post(
        "/meeting-transcripts",
        json={
            "meeting_session_id": meeting["id"],
            "text": "Apple Speech 전사 품질 점검",
        },
    )
    extended = client.post(
        "/meeting-transcripts",
        json={
            "meeting_session_id": meeting["id"],
            "text": "Apple Speech 전사 품질 점검 완료",
        },
    )
    transcripts = client.get(f"/meetings/{meeting['id']}/transcripts")

    assert first.status_code == 201
    assert extended.status_code == 201
    assert first.json()["id"] == extended.json()["id"]
    assert transcripts.json()["total"] == 1
    assert transcripts.json()["items"][0]["text"] == "Apple Speech 전사 품질 점검 완료"


def test_meeting_transcript_masks_sensitive_text(client: TestClient) -> None:
    response = client.post(
        "/meeting-transcripts",
        json={"text": "Gemini token=abc123 password=secret 값을 공유하지 않습니다."},
    )

    assert response.status_code == 201
    assert "abc123" not in response.json()["text"]
    assert "secret" not in response.json()["text"]
    assert "[MASKED]" in response.json()["text"]


def test_meeting_transcripts_today_uses_kst_date(client: TestClient, monkeypatch) -> None:
    monkeypatch.setattr(
        "app.services.meeting_transcript_service.now_kst",
        lambda: datetime(2026, 6, 1, 9, 0, tzinfo=KST),
    )

    client.post(
        "/meeting-transcripts",
        json={
            "text": "KST 이전 날짜 전사",
            "started_at": datetime(2026, 5, 31, 14, 50, tzinfo=UTC).isoformat(),
        },
    )
    client.post(
        "/meeting-transcripts",
        json={
            "text": "KST 오늘 전사",
            "started_at": datetime(2026, 5, 31, 15, 10, tzinfo=UTC).isoformat(),
        },
    )

    response = client.get("/meeting-transcripts/today")

    assert response.status_code == 200
    assert response.json()["total"] == 1
    assert response.json()["items"][0]["text"] == "KST 오늘 전사"


def test_meeting_transcript_appears_in_basic_and_detail_timeline(client: TestClient) -> None:
    long_text = " ".join(["회의에서 OCR 수집 정책과 리포트 입력 우선순위를 논의했습니다."] * 20)
    client.post(
        "/meeting-transcripts",
        json={
            "text": long_text,
            "started_at": datetime(2026, 5, 26, 9, 0, tzinfo=UTC).isoformat(),
        },
    )

    basic_response = client.get("/timeline/today?date=2026-05-26")
    detail_response = client.get("/timeline/today/detail?date=2026-05-26")

    assert basic_response.status_code == 200
    assert detail_response.status_code == 200
    basic_item = basic_response.json()["items"][0]
    detail_item = detail_response.json()["items"][0]
    assert basic_item["type"] == "transcript"
    assert basic_item["content"].startswith("회의 전사 수집됨")
    assert len(basic_item["content"]) < len(long_text)
    assert detail_item["type"] == "transcript"
    assert len(detail_item["content"]) < len(long_text)


def test_short_meeting_transcript_does_not_fill_basic_timeline(client: TestClient) -> None:
    client.post(
        "/meeting-transcripts",
        json={
            "text": "테스트",
            "started_at": datetime(2026, 5, 26, 9, 0, tzinfo=UTC).isoformat(),
        },
    )

    basic_response = client.get("/timeline/today?date=2026-05-26")
    detail_response = client.get("/timeline/today/detail?date=2026-05-26")

    assert basic_response.status_code == 200
    assert detail_response.status_code == 200
    assert [item["type"] for item in basic_response.json()["items"]] == []
    assert [item["type"] for item in detail_response.json()["items"]] == ["transcript"]


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
    assert body["items"][1]["content"].startswith("회의 전사 수집됨")
    assert "오늘은 전사 저장 API를 마무리합니다." in body["items"][1]["content"]
    assert body["items"][1]["speaker"] == "PM"
    assert body["items"][2]["content"] == "스프린트 회의 종료"

from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient


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
    assert ".000000" not in response.text
    assert "기록 시작" in response.text
    assert "개발용 이벤트 입력" in response.text
    assert "메모 입력" in response.text
    assert "오늘 리포트 생성" in response.text


def test_dashboard_forms_drive_recording_event_and_memo_flow(client: TestClient) -> None:
    start_response = client.post("/dashboard/recording/start", data={"title": "웹 기록"})
    assert start_response.status_code == 200
    assert "active" in start_response.text

    event_response = client.post(
        "/dashboard/events",
        data={
            "app_name": "Browser",
            "window_title": "Dashboard",
            "source": "web",
            "content": "웹 폼으로 이벤트 저장",
        },
    )
    memo_response = client.post(
        "/dashboard/memos",
        data={"content": "웹 폼으로 메모 저장"},
    )

    assert event_response.status_code == 200
    assert "웹 폼으로 이벤트 저장" in event_response.text
    assert memo_response.status_code == 200
    assert "웹 폼으로 메모 저장" in memo_response.text

    pause_response = client.post("/dashboard/recording/pause")
    resume_response = client.post("/dashboard/recording/resume")
    stop_response = client.post("/dashboard/recording/stop")

    assert pause_response.status_code == 200
    assert resume_response.status_code == 200
    assert stop_response.status_code == 200
    assert "stopped" in stop_response.text


def test_dashboard_recent_timeline_uses_basic_timeline(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/activity-segments",
        json={
            "started_at": datetime(2026, 5, 26, 7, 3, 22, tzinfo=UTC).isoformat(),
            "last_seen_at": datetime(2026, 5, 26, 7, 3, 25, tzinfo=UTC).isoformat(),
            "source": "mac_active_window",
            "app_name": "Google Chrome",
            "window_title": "Dashboard",
        },
    )
    client.post(
        "/memos",
        json={
            "timestamp": datetime.now(UTC).isoformat(),
            "content": "대시보드 기본 타임라인 확인",
        },
    )

    response = client.get("/dashboard")

    assert response.status_code == 200
    assert "대시보드 기본 타임라인 확인" in response.text
    assert "작업 구간" not in response.text


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
    assert "2026-05-26 17:30" in response.text
    assert "2026-05-26T08:30" not in response.text


def test_timeline_renders_manual_and_watcher_git_dev_event_labels(
    client: TestClient,
) -> None:
    now = datetime.now(UTC)
    client.post(
        "/dev-events",
        json={
            "event_type": "git_snapshot",
            "source": "script",
            "summary": "Git 변경 파일 확인: backend/README.md",
            "details_json": {
                "changed_files": ["backend/README.md"],
            },
            "occurred_at": now.isoformat(),
        },
    )
    client.post(
        "/dev-events",
        json={
            "event_type": "git_snapshot",
            "source": "script",
            "summary": "Git 변경 감지: 1 file changed on feat/dev-tracking",
            "details_json": {
                "tracking_mode": "watch",
                "changed_files": ["backend/scripts/dev_tracking.py"],
            },
            "occurred_at": (now + timedelta(minutes=1)).isoformat(),
        },
    )

    timeline_response = client.get("/timeline")
    dashboard_response = client.get("/dashboard")

    assert timeline_response.status_code == 200
    assert dashboard_response.status_code == 200
    assert "수동 Git 상태 수집" in timeline_response.text
    assert "자동 Git 변경 감지" in timeline_response.text
    assert "수동 Git 상태 수집" in dashboard_response.text
    assert "자동 Git 변경 감지" in dashboard_response.text


def test_timeline_detail_renders_activity_segments_without_event_duplication(
    client: TestClient,
) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/activity-segments",
        json={
            "started_at": datetime(2026, 5, 26, 7, 3, 22, tzinfo=UTC).isoformat(),
            "last_seen_at": datetime(2026, 5, 26, 7, 3, 22, tzinfo=UTC).isoformat(),
            "source": "mac_active_window",
            "app_name": "Google Chrome",
            "window_title": "",
        },
    )
    client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 26, 7, 3, 22, tzinfo=UTC).isoformat(),
            "source": "mac_active_window",
            "app_name": "Google Chrome",
            "window_title": "",
            "content": "Google Chrome /",
        },
    )
    client.post(
        "/memos",
        json={
            "timestamp": datetime(2026, 5, 26, 7, 5, tzinfo=UTC).isoformat(),
            "content": "사용자 메모",
        },
    )
    now = datetime.now(UTC)
    client.post(
        "/activity-segments",
        json={
            "started_at": now.isoformat(),
            "last_seen_at": now.isoformat(),
            "source": "mac_active_window",
            "app_name": "PyCharm",
            "window_title": "backend",
        },
    )

    timeline_response = client.get("/timeline?date=2026-05-26")
    detail_response = client.get("/timeline/detail?date=2026-05-26")
    dashboard_response = client.get("/dashboard")

    assert timeline_response.status_code == 200
    assert detail_response.status_code == 200
    assert dashboard_response.status_code == 200
    assert "작업 구간" not in timeline_response.text
    assert "작업 구간" in detail_response.text
    assert "작업 구간" not in dashboard_response.text
    assert "Google Chrome (1초 미만)" in detail_response.text
    assert "16:03:22~16:03:22" in detail_response.text
    assert "Google Chrome /" not in detail_response.text
    assert "사용자 메모" in timeline_response.text
    assert "메모" in timeline_response.text


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
    assert "인증 흐름 확인 필요" in response.text
    assert "로그인 실패 화면" not in response.text


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

    response = client.get("/timeline?date=2026-05-27")

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
    assert "제외 앱 추가" in response.text
    assert "삭제" in response.text
    assert "데이터 초기화" in response.text


def test_settings_private_app_forms_add_and_delete(client: TestClient) -> None:
    add_response = client.post(
        "/settings/private-apps/add",
        data={"app_name": "Slack", "match_type": "contains", "is_enabled": "on"},
        headers={"accept": "text/html"},
    )

    assert add_response.status_code == 200
    assert "Slack" in add_response.text
    assert "contains" in add_response.text

    delete_response = client.post(
        "/settings/private-apps/delete",
        data={"app_name": "Slack"},
        headers={"accept": "text/html"},
    )

    assert delete_response.status_code == 200
    assert "Slack" not in delete_response.text


def test_settings_dev_data_reset_form_uses_confirmation_dialog(client: TestClient) -> None:
    response = client.get("/settings", headers={"accept": "text/html"})

    assert response.status_code == 200
    assert "confirm(" in response.text
    assert "선택한 개발/테스트 데이터를 삭제합니다." in response.text
    assert 'name="confirm_delete" value="on"' in response.text


def test_settings_dev_data_reset_can_still_dry_run_without_confirm_value(
    client: TestClient,
) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 26, 10, 0, tzinfo=UTC).isoformat(),
            "source": "terminal",
            "content": "초기화 dry-run 확인",
        },
    )
    client.post("/reports/daily", json={"date": "2026-05-26"})

    response = client.post(
        "/settings/dev-data/reset",
        data={"scope": "all", "target": "reports"},
        headers={"accept": "text/html"},
    )

    assert response.status_code == 200
    assert "삭제 미실행" in response.text
    assert client.get("/reports").json()["total"] == 1


def test_settings_dev_data_reset_deletes_selected_target(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 26, 10, 0, tzinfo=UTC).isoformat(),
            "source": "terminal",
            "content": "리포트만 삭제 후 남을 이벤트",
        },
    )
    client.post("/reports/daily", json={"date": "2026-05-26"})

    response = client.post(
        "/settings/dev-data/reset",
        data={
            "scope": "all",
            "target": "reports",
            "confirm_delete": "on",
        },
        headers={"accept": "text/html"},
    )

    assert response.status_code == 200
    assert "삭제 완료" in response.text
    assert "reports:1" in response.text
    assert client.get("/reports").json()["total"] == 0
    assert "리포트만 삭제 후 남을 이벤트" in client.get("/timeline?date=2026-05-26").text


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
    assert "<h2>요약</h2>" in detail_response.text
    assert "## 요약" not in detail_response.text


def test_web_report_create_form_redirects_to_detail(client: TestClient) -> None:
    now = datetime.now(UTC)
    client.post("/recording/start", json={})
    client.post(
        "/events",
        json={
            "timestamp": now.isoformat(),
            "source": "web",
            "content": "웹에서 리포트 생성",
        },
    )

    response = client.post("/reports/daily/create", follow_redirects=False)

    assert response.status_code == 303
    assert response.headers["location"].startswith("/reports/")
    assert response.headers["location"].endswith("/view")

    detail_response = client.get(response.headers["location"])
    assert detail_response.status_code == 200
    assert "웹에서 리포트 생성" in detail_response.text

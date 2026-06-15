from datetime import UTC, datetime, timedelta

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.core.timezone import parse_date_or_today_kst
from app.models.report import Report


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
    assert "오늘 Daily Report" in response.text
    assert "검증 결과" in response.text
    assert "실패 후 성공 흐름" in response.text
    assert "최근 개발 이벤트 요약" in response.text
    assert "회의/메모 요약" in response.text
    assert 'href="/review/today"' not in response.text


def test_dashboard_review_sections_render_empty_states(client: TestClient) -> None:
    response = client.get("/dashboard")

    assert response.status_code == 200
    assert "오늘 생성된 리포트가 없습니다." in response.text
    assert "확인된 validation command가 없습니다." in response.text
    assert "확인된 실패 후 성공 흐름이 없습니다." in response.text
    assert "확인된 개발 이벤트가 없습니다." in response.text
    assert "확인된 회의/메모 없음" in response.text
    assert "Daily Review" not in response.text
    assert 'href="/daily-review"' not in response.text


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


def test_timeline_renders_events_and_memos_newest_first(client: TestClient) -> None:
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
    assert response.text.index("Document edge case") < response.text.index("Ran pytest")
    assert "2026-05-26 17:30" in response.text
    assert "2026-05-26T08:30" not in response.text


def test_timeline_filter_query_is_preserved_in_detail_link(client: TestClient) -> None:
    response = client.get("/timeline?date=2026-05-26&filter=command")

    assert response.status_code == 200
    assert "터미널 명령" in response.text
    assert "/timeline/detail?date=2026-05-26" in response.text
    assert "filter=command" in response.text
    assert 'name="date" value="2026-05-26"' in response.text
    assert '<option value="command" selected>터미널 명령</option>' in response.text


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


def test_timeline_filters_items_by_query_parameter(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/memos",
        json={
            "timestamp": datetime(2026, 5, 26, 1, 0, tzinfo=UTC).isoformat(),
            "content": "수동 필터 메모",
        },
    )
    client.post(
        "/dev-events",
        json={
            "event_type": "git_snapshot",
            "source": "script",
            "summary": "Git 변경 감지: 1 file changed",
            "details_json": {
                "tracking_mode": "watch",
                "changed_files": ["backend/app.py"],
            },
            "occurred_at": datetime(2026, 5, 26, 1, 10, tzinfo=UTC).isoformat(),
        },
    )
    client.post(
        "/dev-events",
        json={
            "event_type": "command_result",
            "source": "terminal",
            "command": "uv run pytest",
            "status": "success",
            "summary": "명령 성공: uv run pytest",
            "details_json": {"exit_code": 0, "duration_ms": 1200},
            "occurred_at": datetime(2026, 5, 26, 1, 20, tzinfo=UTC).isoformat(),
        },
    )
    client.post(
        "/dev-events",
        json={
            "event_type": "command_result",
            "source": "terminal",
            "command": "uv run pytest tests/not_exists.py",
            "status": "failed",
            "summary": "명령 실패: uv run pytest tests/not_exists.py exit_code=4",
            "details_json": {"exit_code": 4, "duration_ms": 800},
            "occurred_at": datetime(2026, 5, 26, 1, 30, tzinfo=UTC).isoformat(),
        },
    )
    meeting = client.post(
        "/meetings/start",
        json={
            "started_at": datetime(2026, 5, 26, 1, 40, tzinfo=UTC).isoformat(),
            "title": "필터 회의",
            "meeting_app": "Zoom",
            "transcript_enabled": True,
        },
    ).json()
    client.post(
        "/transcripts",
        json={
            "meeting_id": meeting["id"],
            "timestamp": datetime(2026, 5, 26, 1, 45, tzinfo=UTC).isoformat(),
            "speaker": "mentor",
            "text": "필터 회의 전사 내용입니다.",
        },
    )
    client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 26, 2, 0, tzinfo=UTC).isoformat(),
            "source": "web",
            "content": "리포트 필터 입력 이벤트",
        },
    )
    client.post("/reports/daily", json={"date": "2026-05-26"})

    all_response = client.get("/timeline?date=2026-05-26&filter=all")
    unknown_response = client.get("/timeline?date=2026-05-26&filter=unknown")
    dev_response = client.get("/timeline?date=2026-05-26&filter=dev")
    git_response = client.get("/timeline?date=2026-05-26&filter=git")
    command_response = client.get("/timeline?date=2026-05-26&filter=command")
    failed_response = client.get("/timeline?date=2026-05-26&filter=command_failed")
    meeting_response = client.get("/timeline?date=2026-05-26&filter=meeting")
    memo_response = client.get("/timeline?date=2026-05-26&filter=memo")
    report_response = client.get("/timeline?date=2026-05-26&filter=report")

    assert all_response.status_code == 200
    assert unknown_response.status_code == 200
    assert "전체" in unknown_response.text
    assert "수동 필터 메모" in all_response.text
    assert "개발 이벤트" in dev_response.text
    assert "수동 필터 메모" not in dev_response.text
    assert "자동 Git 변경 감지" in git_response.text
    assert "명령 성공" not in git_response.text
    assert "명령 성공" in command_response.text
    assert "명령 실패" in command_response.text
    assert "명령 실패" in failed_response.text
    assert "명령 성공" not in failed_response.text
    assert "필터 회의 전사 내용입니다." in meeting_response.text
    assert "필터 회의 시작" not in meeting_response.text
    assert "수동 필터 메모" in memo_response.text
    assert "명령 실패" not in memo_response.text
    assert "일일 작업 리포트" in report_response.text
    assert "수동 필터 메모" not in report_response.text


def test_dashboard_renders_report_validation_flow_and_daily_evidence(
    client: TestClient,
    db: Session,
) -> None:
    today = parse_date_or_today_kst()
    db.add(
        Report(
            date=today,
            mode="detailed",
            title="Report input pruning 검수",
            content="오늘 한 일 요약: Daily Review 화면에서 하루 작업 검수 정보를 모았습니다.",
            created_by="system",
        )
    )
    db.commit()
    now = datetime.now(UTC)
    client.post(
        "/dev-events",
        json={
            "event_type": "command_result",
            "source": "terminal",
            "command": "uv run pytest tests/not_exists.py",
            "status": "failed",
            "summary": "명령 실패: uv run pytest tests/not_exists.py",
            "details_json": {"exit_code": 4},
            "occurred_at": (now - timedelta(minutes=30)).isoformat(),
        },
    )
    client.post(
        "/dev-events",
        json={
            "event_type": "command_result",
            "source": "terminal",
            "command": "uv run pytest tests/test_web_routes.py",
            "status": "success",
            "summary": "명령 성공: uv run pytest tests/test_web_routes.py",
            "details_json": {"exit_code": 0},
            "occurred_at": (now - timedelta(minutes=25)).isoformat(),
        },
    )
    client.post(
        "/dev-events",
        json={
            "event_type": "command_result",
            "source": "terminal",
            "command": "sqlite3 data/mwoham.sqlite3 'select 1'",
            "status": "success",
            "summary": "명령 성공: sqlite3 data/mwoham.sqlite3",
            "details_json": {"exit_code": 0},
            "occurred_at": (now - timedelta(minutes=20)).isoformat(),
        },
    )
    client.post(
        "/dev-events",
        json={
            "event_type": "command_result",
            "source": "terminal",
            "command": "rm -rf /tmp/MwohamMacDerivedData",
            "status": "success",
            "summary": "명령 성공: rm -rf /tmp/MwohamMacDerivedData",
            "details_json": {"exit_code": 0},
            "occurred_at": (now - timedelta(minutes=19)).isoformat(),
        },
    )
    client.post(
        "/dev-events",
        json={
            "event_type": "git_snapshot",
            "source": "script",
            "summary": "Git 변경 감지: daily review route",
            "details_json": {
                "tracking_mode": "watch",
                "changed_files": ["backend/app/web/templates/daily_review.html"],
            },
            "occurred_at": (now - timedelta(minutes=15)).isoformat(),
        },
    )
    client.post(
        "/memos",
        json={
            "timestamp": (now - timedelta(minutes=10)).isoformat(),
            "content": "Daily Review 수동 QA 확인",
        },
    )

    response = client.get("/dashboard")

    assert response.status_code == 200
    assert "Report input pruning 검수" in response.text
    assert "오늘 한 일 요약: Daily Review 화면" in response.text
    assert "/reports/" in response.text
    assert "uv run pytest tests/test_web_routes.py" in response.text
    assert "failed command 기록 검증" in response.text
    assert "Git 변경 감지: daily review route" in response.text
    assert "Daily Review 수동 QA 확인" in response.text
    assert "sqlite3 data/mwoham.sqlite3" not in response.text
    assert "rm -rf /tmp/MwohamMacDerivedData" not in response.text


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
    assert 'value="except_today"' in response.text
    assert 'value="dev_events"' in response.text
    assert 'value="voice_transcripts"' in response.text
    assert 'value="meeting_sessions"' in response.text


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


def test_reports_page_renders_mode_specific_create_buttons(client: TestClient) -> None:
    response = client.get("/reports", headers={"accept": "text/html"})

    assert response.status_code == 200
    assert "간단 리포트 생성" in response.text
    assert "상세 리포트 생성" in response.text
    assert 'action="/reports/daily/create?mode=simple"' in response.text
    assert 'action="/reports/daily/create?mode=detailed"' in response.text


def test_web_simple_report_create_form_uses_simple_mode(client: TestClient) -> None:
    now = datetime.now(UTC)
    client.post("/recording/start", json={})
    client.post(
        "/memos",
        json={
            "timestamp": now.isoformat(),
            "content": "웹에서 간단 리포트 생성",
        },
    )

    response = client.post("/reports/daily/create?mode=simple", follow_redirects=False)

    assert response.status_code == 303
    assert response.headers["location"].startswith("/reports/")
    assert response.headers["location"].endswith("/view")

    detail_response = client.get(response.headers["location"])
    assert detail_response.status_code == 200
    assert "간단 리포트" in detail_response.text
    assert "웹에서 간단 리포트 생성" in detail_response.text
    assert "완료한 작업" in detail_response.text


def test_web_detailed_report_create_form_uses_detailed_mode(client: TestClient) -> None:
    now = datetime.now(UTC)
    client.post("/recording/start", json={})
    client.post(
        "/events",
        json={
            "timestamp": now.isoformat(),
            "source": "web",
            "content": "웹에서 상세 리포트 생성",
        },
    )

    response = client.post("/reports/daily/create?mode=detailed", follow_redirects=False)

    assert response.status_code == 303
    assert response.headers["location"].startswith("/reports/")
    assert response.headers["location"].endswith("/view")

    detail_response = client.get(response.headers["location"])
    assert detail_response.status_code == 200
    assert "상세 리포트" in detail_response.text
    assert "웹에서 상세 리포트 생성" in detail_response.text
    assert "요약" in detail_response.text


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

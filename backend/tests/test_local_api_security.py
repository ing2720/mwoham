from fastapi.testclient import TestClient

from app.core.config import settings
from app.core.security import require_local_api_token
from app.main import app

PROTECTED_API_ROUTES = {
    ("POST", "/recording/start"),
    ("POST", "/recording/pause"),
    ("POST", "/recording/resume"),
    ("POST", "/recording/stop"),
    ("POST", "/events"),
    ("POST", "/dev-events"),
    ("POST", "/activity-segments"),
    ("PATCH", "/activity-segments/{segment_id}"),
    ("POST", "/memos"),
    ("POST", "/screen-observations"),
    ("POST", "/meetings/start"),
    ("POST", "/meetings/{meeting_id}/end"),
    ("POST", "/meeting-transcripts"),
    ("POST", "/transcripts"),
    ("POST", "/reports/daily"),
    ("PATCH", "/reports/{report_id}"),
    ("POST", "/reports/{report_id}/export"),
    ("PATCH", "/settings"),
    ("POST", "/settings/private-apps"),
    ("DELETE", "/settings/private-apps/{app_name}"),
}

WEB_FORM_ROUTES = {
    ("POST", "/dashboard/recording/start"),
    ("POST", "/dashboard/recording/pause"),
    ("POST", "/dashboard/recording/resume"),
    ("POST", "/dashboard/recording/stop"),
    ("POST", "/dashboard/events"),
    ("POST", "/dashboard/memos"),
    ("POST", "/reports/daily/create"),
    ("POST", "/settings/private-apps/add"),
    ("POST", "/settings/private-apps/delete"),
    ("POST", "/settings/dev-data/reset"),
}


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


def test_meeting_mutation_apis_require_local_token_when_configured(
    client: TestClient,
) -> None:
    settings.local_api_token = "test-local-token"
    client.post(
        "/recording/start",
        json={},
        headers={"Authorization": "Bearer test-local-token"},
    )

    missing_start = client.post("/meetings/start", json={})
    valid_start = client.post(
        "/meetings/start",
        json={},
        headers={"Authorization": "Bearer test-local-token"},
    )
    missing_end = client.post(f"/meetings/{valid_start.json()['id']}/end", json={})

    assert missing_start.status_code == 401
    assert valid_start.status_code == 200
    assert missing_end.status_code == 401


def test_meeting_transcript_create_requires_local_token_when_configured(
    client: TestClient,
) -> None:
    settings.local_api_token = "test-local-token"

    missing = client.post("/meeting-transcripts", json={"text": "회의 전사"})
    valid = client.post(
        "/meeting-transcripts",
        json={"text": "회의 전사"},
        headers={"Authorization": "Bearer test-local-token"},
    )

    assert missing.status_code == 401
    assert valid.status_code == 201


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


def test_mutating_api_routes_have_local_token_dependency() -> None:
    mutating_routes = {}
    for route in app.routes:
        methods = getattr(route, "methods", set()) or set()
        path = getattr(route, "path", "")
        for method in methods.intersection({"POST", "PATCH", "DELETE"}):
            route_key = (method, path)
            if route_key not in WEB_FORM_ROUTES:
                mutating_routes[route_key] = route

    assert set(mutating_routes) == PROTECTED_API_ROUTES

    for route in mutating_routes.values():
        dependency_calls = {dependency.call for dependency in route.dependant.dependencies}
        assert require_local_api_token in dependency_calls

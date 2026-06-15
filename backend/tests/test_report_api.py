from datetime import UTC, date, datetime

from fastapi.testclient import TestClient
from sqlalchemy.orm import Session

from app.ai.gemini_client import GeminiClient
from app.ai.prompt_builder import get_prompt_builder
from app.ai.summarizer import GeminiSummarizer
from app.main import app
from app.models.report import Report
from app.report.export_service import ReportExportService, get_report_export_service
from app.report.markdown_generator import MarkdownGenerator
from app.report.pdf_generator import PdfGenerator
from app.repositories.report_repository import ReportRepository
from app.schemas.timeline import TimelineItem, TimelineResponse
from app.services.report_fallback_builder import get_report_fallback_builder
from app.services.report_service import ReportService, get_report_service
from app.services.timeline_builder import get_timeline_builder


class StubSummarizer:
    def __init__(self, content: str | None) -> None:
        self.content = content
        self.calls = 0
        self.modes: list[str] = []

    def summarize_daily_report(self, timeline, *, mode: str = "detailed"):
        self.calls += 1
        self.modes.append(mode)
        return self.content


class QuotaExceededSummarizer:
    last_error_reason = "quota_exceeded"
    last_finish_reason = None
    last_was_truncated = False

    def __init__(self) -> None:
        self.calls = 0

    def summarize_daily_report(self, timeline, *, mode: str = "detailed"):
        self.calls += 1
        return None


class FakePdfGenerator:
    def generate(self, report, output_path) -> None:
        output_path.write_bytes(b"%PDF-1.4\n% fake test pdf\n")


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
    assert "Gemini 응답을 사용할 수 없어 핵심 항목만 간단히 정리했습니다." in created["content"]
    assert "리포트 서비스 뼈대 구현" in created["content"]
    assert "Gemini는 아직 호출하지 않음" in created["content"]
    assert "## 주요 메모" in created["content"]
    assert "## 주요 화면 관찰" in created["content"]
    assert "## 주요 작업 환경" in created["content"]

    today_response = client.get("/reports/today?date=2026-05-26")
    assert today_response.status_code == 200
    assert today_response.json()["total"] == 1

    list_response = client.get("/reports")
    assert list_response.status_code == 200
    assert list_response.json()["total"] == 1

    detail_response = client.get(f"/reports/{created['id']}")
    assert detail_response.status_code == 200
    assert detail_response.json()["id"] == created["id"]


def test_daily_report_api_updates_existing_same_identity_instead_of_inserting(
    client: TestClient,
) -> None:
    original_override = app.dependency_overrides.get(get_report_service)
    service = ReportService(
        repository=ReportRepository(),
        timeline_builder=get_timeline_builder(),
        summarizer=StubSummarizer("## 오늘 한 일 요약\n첫 번째 생성"),
    )
    app.dependency_overrides[get_report_service] = lambda: service
    try:
        first_response = client.post(
            "/reports/daily",
            json={"date": "2026-05-26", "mode": "detailed", "project_id": None},
        )
        service.summarizer.content = "## 오늘 한 일 요약\n두 번째 생성으로 갱신"
        second_response = client.post(
            "/reports/daily",
            json={"date": "2026-05-26", "mode": "detailed", "project_id": None},
        )
    finally:
        if original_override is None:
            app.dependency_overrides.pop(get_report_service, None)
        else:
            app.dependency_overrides[get_report_service] = original_override

    assert first_response.status_code == 201
    assert second_response.status_code == 201
    first = first_response.json()
    second = second_response.json()
    assert second["id"] == first["id"]
    assert second["created_at"] == first["created_at"]
    assert second["updated_at"] != first["updated_at"]
    assert "두 번째 생성으로 갱신" in second["content"]
    assert "첫 번째 생성" not in second["content"]

    list_response = client.get("/reports?date=2026-05-26&mode=detailed")
    assert list_response.status_code == 200
    assert list_response.json()["total"] == 1
    assert list_response.json()["items"][0]["id"] == first["id"]


def test_daily_report_api_generates_detailed_mode_report(client: TestClient) -> None:
    original_override = app.dependency_overrides.get(get_report_service)
    summarizer = StubSummarizer("## 오늘 한 일 요약\n상세 리포트 생성")
    service = ReportService(
        repository=ReportRepository(),
        timeline_builder=get_timeline_builder(),
        summarizer=summarizer,
    )
    app.dependency_overrides[get_report_service] = lambda: service
    try:
        response = client.post(
            "/reports/daily",
            json={"date": "2026-05-26", "mode": "detailed"},
        )
    finally:
        if original_override is None:
            app.dependency_overrides.pop(get_report_service, None)
        else:
            app.dependency_overrides[get_report_service] = original_override

    assert response.status_code == 201
    body = response.json()
    assert body["mode"] == "detailed"
    assert body["title"] == "2026-05-26 일일 작업 리포트"
    assert "## 오늘 한 일 요약\n상세 리포트 생성" in body["content"]
    assert "## 시간대별 작업 흐름\n확인된 내용 없음." in body["content"]
    assert "## 다음 작업 후보\n확인된 내용 없음." in body["content"]
    assert summarizer.modes == ["detailed"]


def test_daily_report_api_generates_simple_mode_report(client: TestClient) -> None:
    original_override = app.dependency_overrides.get(get_report_service)
    summarizer = StubSummarizer("## 오늘 한 일 요약\n- 간단 리포트 생성")
    service = ReportService(
        repository=ReportRepository(),
        timeline_builder=get_timeline_builder(),
        summarizer=summarizer,
    )
    app.dependency_overrides[get_report_service] = lambda: service
    try:
        response = client.post(
            "/reports/daily",
            json={"date": "2026-05-26", "mode": "simple"},
        )
    finally:
        if original_override is None:
            app.dependency_overrides.pop(get_report_service, None)
        else:
            app.dependency_overrides[get_report_service] = original_override

    assert response.status_code == 201
    body = response.json()
    assert body["mode"] == "simple"
    assert body["title"] == "2026-05-26 간단 작업 리포트"
    assert "## 오늘 한 일 요약\n- 간단 리포트 생성" in body["content"]
    assert "## 완료한 작업\n확인된 내용 없음." in body["content"]
    assert "## 다음 작업\n확인된 내용 없음." in body["content"]
    assert "## 테스트/검증 결과\n확인된 내용 없음." in body["content"]
    assert "## 시간대별 작업 흐름" not in body["content"]
    assert "## 다음 작업 후보" not in body["content"]
    assert summarizer.modes == ["simple"]


def test_daily_report_api_accepts_simple_mode_query_parameter(
    client: TestClient,
) -> None:
    response = client.post("/reports/daily?mode=simple", json={"date": "2026-05-26"})

    assert response.status_code == 201
    body = response.json()
    assert body["mode"] == "simple"
    assert body["title"] == "2026-05-26 간단 작업 리포트"
    assert "## 완료한 작업" in body["content"]
    assert "## 테스트/검증 결과" in body["content"]

    today_response = client.get("/reports/today?date=2026-05-26&mode=simple")
    assert today_response.status_code == 200
    today_body = today_response.json()
    assert today_body["total"] == 1
    assert len(today_body["items"]) == 1
    assert today_body["items"][0]["id"] == body["id"]
    assert today_body["items"][0]["mode"] == "simple"


def test_daily_report_api_accepts_detailed_mode_query_parameter(
    client: TestClient,
) -> None:
    response = client.post("/reports/daily?mode=detailed", json={"date": "2026-05-26"})

    assert response.status_code == 201
    body = response.json()
    assert body["mode"] == "detailed"
    assert body["title"] == "2026-05-26 일일 작업 리포트"
    assert "## 주요 메모" in body["content"]


def test_daily_report_api_query_mode_overrides_body_mode(
    client: TestClient,
) -> None:
    response = client.post(
        "/reports/daily?mode=simple",
        json={"date": "2026-05-26", "mode": "detailed"},
    )

    assert response.status_code == 201
    body = response.json()
    assert body["mode"] == "simple"
    assert "## 완료한 작업" in body["content"]


def test_simple_fallback_does_not_use_screen_observation_raw_text_as_completed_work(
    client: TestClient,
) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/screen-observations",
        json={
            "timestamp": datetime(2026, 5, 26, 1, 40, tzinfo=UTC).isoformat(),
            "app_name": "Google Chrome",
            "window_title": "Gemini 확장 프로그램 도움말",
            "ocr_text": "\n".join(
                [
                    "feat: 장소 목록 추 83 open...",
                    "ProTip! Ad...",
                    "8888년 83388...",
                    "Gemini 확장 프로그램 도움말",
                ]
            ),
            "frame_hash": "simple-fallback-ocr-noise",
        },
    )

    response = client.post("/reports/daily?mode=simple", json={"date": "2026-05-26"})

    assert response.status_code == 201
    body = response.json()
    assert body["mode"] == "simple"
    assert body["created_by"] == "system"
    assert "## 완료한 작업\n- 확인된 핵심 작업 없음" in body["content"]
    assert "## 다음 작업\n- 확인된 내용 없음." in body["content"]
    assert "feat: 장소 목록 추 83 open" not in body["content"]
    assert "ProTip! Ad" not in body["content"]
    assert "8888년 83388" not in body["content"]
    assert "Gemini 확장 프로그램 도움말" not in body["content"]


def test_simple_fallback_prioritizes_memo_dev_event_and_test_evidence(
    client: TestClient,
) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/screen-observations",
        json={
            "timestamp": datetime(2026, 5, 26, 1, 20, tzinfo=UTC).isoformat(),
            "app_name": "Google Chrome",
            "window_title": "ProTip! Ad",
            "ocr_text": "ProTip! Ad\nGemini 확장 프로그램 도움말",
            "frame_hash": "simple-fallback-ignored-ocr",
        },
    )
    client.post(
        "/memos",
        json={
            "timestamp": datetime(2026, 5, 26, 1, 30, tzinfo=UTC).isoformat(),
            "content": "simple report fallback QA 정책 정리",
        },
    )
    client.post(
        "/dev-events",
        json={
            "event_type": "git_snapshot",
            "source": "script",
            "summary": "Git 변경 파일 확인: backend/app/services/report_fallback_builder.py",
            "details_json": {
                "changed_files": ["backend/app/services/report_fallback_builder.py"]
            },
            "occurred_at": datetime(2026, 5, 26, 1, 40, tzinfo=UTC).isoformat(),
        },
    )
    client.post(
        "/dev-events",
        json={
            "event_type": "test_result",
            "source": "terminal",
            "command": "uv run pytest -q",
            "status": "success",
            "summary": "pytest 통과: 238 passed",
            "details_json": {"exit_code": 0},
            "occurred_at": datetime(2026, 5, 26, 1, 50, tzinfo=UTC).isoformat(),
        },
    )

    response = client.post("/reports/daily?mode=simple", json={"date": "2026-05-26"})

    assert response.status_code == 201
    content = response.json()["content"]
    assert "simple report fallback 품질 보강" in content
    assert "simple report fallback 요약 로직 정리" in content
    assert "pytest 검증 통과" in content
    assert "report_fallback_builder.py" not in content
    assert "uv run pytest -q" not in content
    assert "확인된 핵심 작업 없음" not in content
    assert "ProTip! Ad" not in content
    assert "Gemini 확장 프로그램 도움말" not in content


def test_simple_fallback_summarizes_meeting_transcript_without_raw_prefix() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="transcript",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                content=(
                    "회의 전사 수집됨:\n"
                    "[00:00 microphone] simple fallback 원문 노출을 줄여야 합니다.\n"
                    "[00:05 system_audio] report mode QA도 같이 확인합시다."
                ),
                source="local_whisper_full_meeting",
            )
        ],
    )

    content = get_report_fallback_builder().build(timeline, mode="simple")

    assert "회의 전사 기반 논의 정리" in content
    assert "simple report fallback 품질 보강" in content
    assert "[00:00 microphone]" not in content
    assert "[00:05 system_audio]" not in content
    assert "simple fallback 원문 노출을 줄여야 합니다" not in content
    assert "report mode QA도 같이 확인합시다" not in content


def test_simple_fallback_removes_dev_event_raw_metadata() -> None:
    timeline = TimelineResponse(
        date=date(2026, 5, 26),
        total=1,
        items=[
            TimelineItem(
                type="dev_event",
                id=1,
                timestamp=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                content=(
                    "Git 변경 감지 | changed_files=backend/app/ai/prompt_builder.py | "
                    "exit_code=0 | duration_ms=12 | cwd=/Users/a/Projects/mwoham | "
                    "curl http://127.0.0.1:8765/reports/daily"
                ),
                details_json={"changed_files": ["backend/app/ai/prompt_builder.py"]},
            )
        ],
    )

    content = get_report_fallback_builder().build(timeline, mode="simple")

    assert "report prompt/context 로직 수정" in content
    assert "changed_files=" not in content
    assert "exit_code=" not in content
    assert "duration_ms=" not in content
    assert "cwd=" not in content
    assert "curl http://127.0.0.1" not in content


def test_simple_fallback_limits_completed_work_and_deduplicates_git_events() -> None:
    items = [
        TimelineItem(
            type="dev_event",
            id=index,
            timestamp=datetime(2026, 5, 26, 1, index, tzinfo=UTC),
            event_type="git_snapshot",
            source="script",
            content=f"Git 변경 감지 {index}",
            details_json={"changed_files": ["backend/app/services/report_service.py"]},
        )
        for index in range(1, 8)
    ]
    items.extend(
        [
            TimelineItem(
                type="dev_event",
                id=20,
                timestamp=datetime(2026, 5, 26, 2, 0, tzinfo=UTC),
                event_type="git_snapshot",
                source="script",
                content="Prompt 변경",
                details_json={"changed_files": ["backend/app/ai/prompt_builder.py"]},
            ),
            TimelineItem(
                type="memo",
                id=21,
                timestamp=datetime(2026, 5, 26, 2, 10, tzinfo=UTC),
                content="simple fallback follow-up memo",
            ),
        ]
    )
    timeline = TimelineResponse(date=date(2026, 5, 26), total=len(items), items=items)

    content = get_report_fallback_builder().build(timeline, mode="simple")
    completed_section = content.split("## 완료한 작업", 1)[1].split("## 다음 작업", 1)[0]
    completed_bullets = [
        line for line in completed_section.splitlines() if line.strip().startswith("- ")
    ]

    assert len(completed_bullets) <= 5
    assert completed_section.count("report 생성/조회 정책 수정") == 1
    assert "report prompt/context 로직 수정" in completed_section
    assert "simple report fallback 품질 보강" in completed_section


def test_daily_report_api_keeps_detailed_and_simple_modes_separate(
    client: TestClient,
) -> None:
    original_override = app.dependency_overrides.get(get_report_service)
    summarizer = StubSummarizer("## 오늘 한 일 요약\n상세 생성")
    service = ReportService(
        repository=ReportRepository(),
        timeline_builder=get_timeline_builder(),
        summarizer=summarizer,
    )
    app.dependency_overrides[get_report_service] = lambda: service
    try:
        detailed_response = client.post(
            "/reports/daily",
            json={"date": "2026-05-26", "mode": "detailed"},
        )
        summarizer.content = "## 오늘 한 일 요약\n- 간단 생성"
        simple_response = client.post(
            "/reports/daily",
            json={"date": "2026-05-26", "mode": "simple"},
        )
    finally:
        if original_override is None:
            app.dependency_overrides.pop(get_report_service, None)
        else:
            app.dependency_overrides[get_report_service] = original_override

    detailed = detailed_response.json()
    simple = simple_response.json()
    assert detailed["id"] != simple["id"]
    assert detailed["mode"] == "detailed"
    assert simple["mode"] == "simple"

    list_response = client.get("/reports?date=2026-05-26")
    assert list_response.status_code == 200
    body = list_response.json()
    assert body["total"] == 2
    assert {item["mode"] for item in body["items"]} == {"detailed", "simple"}


def test_today_reports_returns_latest_single_report_with_list_schema(
    client: TestClient,
    db: Session,
) -> None:
    old_report = Report(
        date=date(2026, 5, 26),
        mode="detailed",
        title="이전 리포트",
        content="old",
        created_by="system",
        created_at=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
        updated_at=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
    )
    latest_report = Report(
        date=date(2026, 5, 26),
        mode="summary",
        title="최신 리포트",
        content="latest",
        created_by="system",
        created_at=datetime(2026, 5, 26, 2, 0, tzinfo=UTC),
        updated_at=datetime(2026, 5, 26, 3, 0, tzinfo=UTC),
    )
    db.add_all([old_report, latest_report])
    db.commit()

    response = client.get("/reports/today?date=2026-05-26")

    assert response.status_code == 200
    body = response.json()
    assert len(body["items"]) == 1
    assert body["total"] == 1
    assert body["items"][0]["id"] == latest_report.id
    assert body["items"][0]["title"] == "최신 리포트"


def test_today_reports_filters_latest_report_by_mode(
    client: TestClient,
    db: Session,
) -> None:
    detailed_report = Report(
        date=date(2026, 5, 26),
        mode="detailed",
        title="상세 리포트",
        content="detailed",
        created_by="system",
        created_at=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
        updated_at=datetime(2026, 5, 26, 1, 0, tzinfo=UTC),
    )
    simple_report = Report(
        date=date(2026, 5, 26),
        mode="simple",
        title="간단 리포트",
        content="simple",
        created_by="system",
        created_at=datetime(2026, 5, 26, 2, 0, tzinfo=UTC),
        updated_at=datetime(2026, 5, 26, 3, 0, tzinfo=UTC),
    )
    db.add_all([detailed_report, simple_report])
    db.commit()

    simple_response = client.get("/reports/today?date=2026-05-26&mode=simple")
    detailed_response = client.get("/reports/today?date=2026-05-26&mode=detailed")

    assert simple_response.status_code == 200
    assert simple_response.json()["total"] == 1
    assert simple_response.json()["items"][0]["id"] == simple_report.id
    assert simple_response.json()["items"][0]["mode"] == "simple"
    assert detailed_response.status_code == 200
    assert detailed_response.json()["total"] == 1
    assert detailed_response.json()["items"][0]["id"] == detailed_report.id
    assert detailed_response.json()["items"][0]["mode"] == "detailed"


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
    assert "## Gemini 요약\n- mock 리포트" in body["content"]
    assert "## 오늘 한 일 요약" in body["content"]
    assert "## 다음 작업 후보" in body["content"]
    assert summarizer.calls == 1


def test_daily_report_cleans_mocked_gemini_summary_before_saving(client: TestClient) -> None:
    original_service = ReportService(
        repository=ReportRepository(),
        timeline_builder=get_timeline_builder(),
        summarizer=GeminiSummarizer(
            client=GeminiClient(api_key=None, model="gemini-2.5-flash"),
            prompt_builder=get_prompt_builder(),
        ),
    )
    summarizer = StubSummarizer("## 시간대별 작업 흐름\n- 테스트 실패\n*")
    original_service.summarizer = summarizer
    app.dependency_overrides[get_report_service] = lambda: original_service
    try:
        response = client.post("/reports/daily", json={"date": "2026-05-26"})
    finally:
        app.dependency_overrides.pop(get_report_service, None)

    assert response.status_code == 201
    body = response.json()
    assert body["created_by"] == "ai"
    assert "\n*" not in body["content"]
    assert "## 오늘 한 일 요약\n확인된 내용 없음." in body["content"]
    assert "## 시간대별 작업 흐름\n- 테스트 실패" in body["content"]
    assert "## 다음 작업 후보\n확인된 내용 없음." in body["content"]


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
    assert "Gemini 응답을 사용할 수 없어 핵심 항목만 간단히 정리했습니다." in body["content"]


def test_daily_report_falls_back_when_gemini_quota_is_exceeded(client: TestClient) -> None:
    original_service = ReportService(
        repository=ReportRepository(),
        timeline_builder=get_timeline_builder(),
        summarizer=GeminiSummarizer(
            client=GeminiClient(api_key=None, model="gemini-2.5-flash"),
            prompt_builder=get_prompt_builder(),
        ),
    )
    summarizer = QuotaExceededSummarizer()
    original_service.summarizer = summarizer
    app.dependency_overrides[get_report_service] = lambda: original_service
    try:
        response = client.post("/reports/daily", json={"date": "2026-05-26"})
    finally:
        app.dependency_overrides.pop(get_report_service, None)

    assert response.status_code == 201
    body = response.json()
    assert body["created_by"] == "system"
    assert "Gemini 응답을 사용할 수 없어 핵심 항목만 간단히 정리했습니다." in body["content"]
    assert summarizer.calls == 1


def test_daily_report_placeholder_does_not_dump_raw_timeline(client: TestClient) -> None:
    client.post("/recording/start", json={})
    for index in range(20):
        client.post(
            "/events",
            json={
                "timestamp": datetime(2026, 5, 26, 10, index, tzinfo=UTC).isoformat(),
                "source": "window",
                "content": f"raw event {index}",
            },
        )

    response = client.post("/reports/daily", json={"date": "2026-05-26"})

    assert response.status_code == 201
    content = response.json()["content"]
    assert "raw event 0" in content
    assert "raw event 4" in content
    assert "raw event 5" not in content


def test_daily_report_placeholder_uses_specific_memo_and_ocr_candidates(
    client: TestClient,
) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/memos",
        json={
            "timestamp": datetime(2026, 5, 26, 1, 30, tzinfo=UTC).isoformat(),
            "content": "OCR 수집 주기를 10초로 조정하고 Gemini quota 절약 정책 적용",
        },
    )
    client.post(
        "/screen-observations",
        json={
            "timestamp": datetime(2026, 5, 26, 1, 40, tzinfo=UTC).isoformat(),
            "app_name": "PyCharm",
            "window_title": "report_service.py",
            "ocr_text": "\n".join(
                [
                    "ENABLE_SCREEN_OBSERVATION_AI_INFERENCE=false",
                    "SCREEN_AI_DAILY_LIMIT=5",
                    "uv run pytest",
                ]
            ),
            "detected_keywords": ["Gemini", "quota", "pytest"],
            "frame_hash": "specific-report-fallback",
        },
    )

    response = client.post("/reports/daily", json={"date": "2026-05-26"})

    assert response.status_code == 201
    content = response.json()["content"]
    assert "## 작업 후보" in content
    assert "OCR 수집 주기를 10초로 조정" in content
    assert "ENABLE_SCREEN_OBSERVATION_AI_INFERENCE=false" in content
    assert "uv run pytest" in content
    assert "Swift/API/FastAPI 관련 작업" not in content


def test_daily_report_placeholder_excludes_self_service_screen_ocr(
    client: TestClient,
) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/screen-observations",
        json={
            "timestamp": datetime(2026, 5, 26, 1, 40, tzinfo=UTC).isoformat(),
            "app_name": "Google Chrome",
            "window_title": "대시보드 - 뭐함",
            "ocr_text": "127.0.0.1:8765 작업 기록 자동화 서비스",
            "frame_hash": "self-service-report-fallback",
        },
    )

    response = client.post("/reports/daily", json={"date": "2026-05-26"})

    assert response.status_code == 201
    content = response.json()["content"]
    assert "127.0.0.1:8765" not in content
    assert "작업 기록 자동화 서비스" not in content


def test_daily_report_uses_kst_day_range_for_source_items(client: TestClient) -> None:
    client.post("/recording/start", json={})
    client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 31, 16, 10, tzinfo=UTC).isoformat(),
            "source": "terminal",
            "content": "KST 6월 1일 새벽 release package 검증",
        },
    )
    client.post(
        "/events",
        json={
            "timestamp": datetime(2026, 5, 31, 14, 50, tzinfo=UTC).isoformat(),
            "source": "terminal",
            "content": "KST 5월 31일 밤 이전 작업",
        },
    )

    response = client.post("/reports/daily", json={"date": "2026-06-01"})

    assert response.status_code == 201
    body = response.json()
    assert body["date"] == "2026-06-01"
    assert body["source_range_start"] == "2026-05-31T15:00:00"
    assert body["source_range_end"] == "2026-06-01T15:00:00"
    assert "KST 6월 1일 새벽 release package 검증" in body["content"]
    assert "KST 5월 31일 밤 이전 작업" not in body["content"]


def test_export_report_to_markdown(client: TestClient, tmp_path) -> None:
    app.dependency_overrides[get_report_export_service] = lambda: ReportExportService(
        repository=ReportRepository(),
        markdown_generator=MarkdownGenerator(),
        pdf_generator=FakePdfGenerator(),
        export_dir=tmp_path,
    )
    try:
        created = client.post("/reports/daily", json={"date": "2026-05-26"}).json()
        response = client.post(
            f"/reports/{created['id']}/export",
            json={"export_format": "markdown"},
        )
    finally:
        app.dependency_overrides.pop(get_report_export_service, None)

    assert response.status_code == 200
    body = response.json()
    assert body["format"] == "markdown"
    assert body["file_path"].endswith(f"report_{created['id']}_2026-05-26.md")
    assert body["download_url"] == f"/reports/{created['id']}/download?format=markdown"

    exported_path = tmp_path / f"report_{created['id']}_2026-05-26.md"
    assert exported_path.exists()
    exported_content = exported_path.read_text(encoding="utf-8")
    assert "일일 작업 리포트" in exported_content
    assert "## 본문" in exported_content
    assert "생성 시각" not in exported_content


def test_export_report_to_pdf_uses_pdf_generator(client: TestClient, tmp_path) -> None:
    app.dependency_overrides[get_report_export_service] = lambda: ReportExportService(
        repository=ReportRepository(),
        markdown_generator=MarkdownGenerator(),
        pdf_generator=FakePdfGenerator(),
        export_dir=tmp_path,
    )
    try:
        created = client.post("/reports/daily", json={"date": "2026-05-26"}).json()
        response = client.post(
            f"/reports/{created['id']}/export",
            json={"export_format": "pdf"},
        )
    finally:
        app.dependency_overrides.pop(get_report_export_service, None)

    assert response.status_code == 200
    body = response.json()
    assert body["format"] == "pdf"
    assert body["file_path"].endswith(f"report_{created['id']}_2026-05-26.pdf")
    assert body["download_url"] == f"/reports/{created['id']}/download?format=pdf"

    exported_path = tmp_path / f"report_{created['id']}_2026-05-26.pdf"
    assert exported_path.exists()
    assert exported_path.read_bytes().startswith(b"%PDF-1.4")


def test_export_missing_report_returns_404(client: TestClient, tmp_path) -> None:
    app.dependency_overrides[get_report_export_service] = lambda: ReportExportService(
        repository=ReportRepository(),
        markdown_generator=MarkdownGenerator(),
        pdf_generator=FakePdfGenerator(),
        export_dir=tmp_path,
    )
    try:
        response = client.post("/reports/999/export", json={"export_format": "markdown"})
    finally:
        app.dependency_overrides.pop(get_report_export_service, None)

    assert response.status_code == 404


def test_download_report_returns_file_attachment(client: TestClient, tmp_path) -> None:
    app.dependency_overrides[get_report_export_service] = lambda: ReportExportService(
        repository=ReportRepository(),
        markdown_generator=MarkdownGenerator(),
        pdf_generator=FakePdfGenerator(),
        export_dir=tmp_path,
    )
    try:
        created = client.post("/reports/daily", json={"date": "2026-05-26"}).json()
        response = client.get(f"/reports/{created['id']}/download?format=markdown")
    finally:
        app.dependency_overrides.pop(get_report_export_service, None)

    assert response.status_code == 200
    assert response.headers["content-disposition"].startswith("attachment;")
    assert f"report_{created['id']}_2026-05-26.md" in response.headers["content-disposition"]
    assert "일일 작업 리포트" in response.text


def test_download_missing_report_returns_404(client: TestClient, tmp_path) -> None:
    app.dependency_overrides[get_report_export_service] = lambda: ReportExportService(
        repository=ReportRepository(),
        markdown_generator=MarkdownGenerator(),
        pdf_generator=FakePdfGenerator(),
        export_dir=tmp_path,
    )
    try:
        response = client.get("/reports/999/download?format=pdf")
    finally:
        app.dependency_overrides.pop(get_report_export_service, None)

    assert response.status_code == 404


def test_pdf_generator_converts_markdown_content_to_html() -> None:
    report = Report(
        id=12,
        date=date(2026, 5, 26),
        mode="detailed",
        title="Markdown PDF 테스트",
        content="\n".join(
            [
                "# 요약",
                "",
                "## 세부",
                "- 작업 항목",
                "- `uv run pytest` 실행",
                "",
                "> 중요한 메모",
            ]
        ),
        created_by="ai",
        created_at=datetime(2026, 5, 26, 15, 30, tzinfo=UTC),
    )

    html = PdfGenerator()._build_html(report)

    assert "<h1>요약</h1>" in html
    assert "<h2>세부</h2>" in html
    assert "<li>작업 항목</li>" in html
    assert "<code>uv run pytest</code>" in html
    assert "<blockquote>" in html
    assert "<pre># 요약" not in html
    assert "유형: 상세 리포트" in html
    assert "생성 주체: AI" in html
    assert "생성 시각" not in html

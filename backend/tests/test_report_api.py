from datetime import UTC, date, datetime

from fastapi.testclient import TestClient

from app.ai.gemini_client import GeminiClient
from app.ai.prompt_builder import get_prompt_builder
from app.ai.summarizer import GeminiSummarizer
from app.main import app
from app.models.report import Report
from app.report.export_service import ReportExportService, get_report_export_service
from app.report.markdown_generator import MarkdownGenerator
from app.report.pdf_generator import PdfGenerator
from app.repositories.report_repository import ReportRepository
from app.services.report_service import ReportService, get_report_service
from app.services.timeline_builder import get_timeline_builder


class StubSummarizer:
    def __init__(self, content: str | None) -> None:
        self.content = content
        self.calls = 0

    def summarize_daily_report(self, timeline):
        self.calls += 1
        return self.content


class QuotaExceededSummarizer:
    last_error_reason = "quota_exceeded"
    last_finish_reason = None
    last_was_truncated = False

    def __init__(self) -> None:
        self.calls = 0

    def summarize_daily_report(self, timeline):
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

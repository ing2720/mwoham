from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy.orm import Session

from app.core.config import settings
from app.core.exceptions import ResourceNotFoundError
from app.repositories.report_repository import ReportRepository
from app.schemas.report import ReportExportFormat, ReportExportResponse

from .markdown_generator import MarkdownGenerator
from .pdf_generator import PdfGenerator


class ReportExportService:
    def __init__(
        self,
        repository: ReportRepository,
        markdown_generator: MarkdownGenerator,
        pdf_generator: PdfGenerator,
        export_dir: Path | str = Path("exports/reports"),
    ) -> None:
        self.repository = repository
        self.markdown_generator = markdown_generator
        self.pdf_generator = pdf_generator
        self.export_dir = Path(export_dir)

    def export_report(
        self,
        db: Session,
        *,
        report_id: int,
        export_format: ReportExportFormat,
    ) -> ReportExportResponse:
        report = self.repository.get_by_id(db, report_id)
        if report is None:
            raise ResourceNotFoundError("Report not found.")

        self.export_dir.mkdir(parents=True, exist_ok=True)
        created_at = datetime.now(UTC)
        date_part = report.date.isoformat() if report.date else created_at.date().isoformat()
        extension = "md" if export_format == "markdown" else "pdf"
        output_path = self.export_dir / f"report_{report.id}_{date_part}.{extension}"

        if export_format == "markdown":
            output_path.write_text(self.markdown_generator.generate(report), encoding="utf-8")
        else:
            self.pdf_generator.generate(report, output_path)

        return ReportExportResponse(
            file_path=str(output_path),
            format=export_format,
            created_at=created_at,
            download_url=f"/reports/{report.id}/download?format={export_format}",
        )


def get_report_export_service() -> ReportExportService:
    # TODO: move export storage outside the backend repository for packaged/local releases.
    return ReportExportService(
        repository=ReportRepository(),
        markdown_generator=MarkdownGenerator(),
        pdf_generator=PdfGenerator(),
        export_dir=settings.report_export_dir,
    )

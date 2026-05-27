from app.models.report import Report


class MarkdownGenerator:
    def generate(self, report: Report) -> str:
        title = report.title or "제목 없는 리포트"
        report_date = report.date.isoformat() if report.date else "날짜 없음"

        return "\n".join(
            [
                f"# {title}",
                "",
                f"- 날짜: {report_date}",
                f"- 유형: {report.mode}",
                f"- 생성 주체: {report.created_by}",
                "",
                "## 본문",
                "",
                report.content,
                "",
            ]
        )

from html import escape
from pathlib import Path

from app.models.report import Report


class PdfGenerator:
    def generate(self, report: Report, output_path: Path) -> None:
        html_content = self._build_html(report)

        from weasyprint import HTML

        HTML(string=html_content).write_pdf(str(output_path))

    def _build_html(self, report: Report) -> str:
        title = escape(report.title or "제목 없는 리포트")
        report_date = escape(report.date.isoformat() if report.date else "날짜 없음")
        mode = escape(report.mode)
        created_by = escape(report.created_by)
        content = escape(report.content)

        return f"""<!doctype html>
<html lang="ko">
  <head>
    <meta charset="utf-8">
    <style>
      body {{
        color: #202124;
        font-family: -apple-system, BlinkMacSystemFont, "Apple SD Gothic Neo",
          "Malgun Gothic", "Noto Sans CJK KR", sans-serif;
        line-height: 1.65;
        margin: 36px;
      }}
      h1 {{ font-size: 24px; margin: 0 0 12px; }}
      .meta {{ color: #5f6368; font-size: 12px; margin-bottom: 24px; }}
      pre {{
        font-family: inherit;
        white-space: pre-wrap;
        word-break: break-word;
      }}
    </style>
  </head>
  <body>
    <h1>{title}</h1>
    <div class="meta">{report_date} · {mode} · {created_by}</div>
    <pre>{content}</pre>
  </body>
</html>"""

from html import escape
from pathlib import Path

import markdown as markdown_lib

from app.models.report import Report
from app.report.display import format_created_by, format_report_mode


class PdfGenerator:
    def generate(self, report: Report, output_path: Path) -> None:
        html_content = self._build_html(report)

        from weasyprint import HTML

        HTML(string=html_content).write_pdf(str(output_path))

    def _build_html(self, report: Report) -> str:
        title = escape(report.title or "제목 없는 리포트")
        report_date = escape(report.date.strftime("%Y-%m-%d") if report.date else "날짜 없음")
        mode = escape(format_report_mode(report.mode))
        created_by = escape(format_created_by(report.created_by))
        content_html = markdown_lib.markdown(
            report.content,
            extensions=["extra", "sane_lists", "nl2br"],
            output_format="html5",
        )

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
        margin: 40px;
      }}
      .report-header {{
        border-bottom: 1px solid #dfe3e8;
        margin-bottom: 28px;
        padding-bottom: 18px;
      }}
      .report-title {{
        color: #17463b;
        font-size: 26px;
        line-height: 1.25;
        margin: 0 0 12px;
      }}
      .meta {{
        color: #5f6368;
        display: grid;
        font-size: 12px;
        gap: 4px;
        grid-template-columns: repeat(3, minmax(0, 1fr));
      }}
      .content h1 {{
        border-bottom: 1px solid #edf0f2;
        font-size: 22px;
        margin: 28px 0 12px;
        padding-bottom: 6px;
      }}
      .content h2 {{
        color: #17463b;
        font-size: 18px;
        margin: 24px 0 10px;
      }}
      .content h3 {{
        font-size: 15px;
        margin: 18px 0 8px;
      }}
      .content p {{ margin: 0 0 10px; }}
      .content ul {{ margin: 0 0 14px 20px; padding: 0; }}
      .content li {{ margin: 4px 0; }}
      .content code {{
        background: #f1f4f3;
        border-radius: 4px;
        color: #164235;
        font-family: "SFMono-Regular", Consolas, "Liberation Mono", monospace;
        font-size: 0.92em;
        padding: 1px 4px;
      }}
      pre {{
        background: #f6f8f8;
        border: 1px solid #e1e6e4;
        border-radius: 6px;
        font-family: "SFMono-Regular", Consolas, "Liberation Mono", monospace;
        font-size: 12px;
        padding: 12px;
        white-space: pre-wrap;
        word-break: break-word;
      }}
      pre code {{
        background: transparent;
        border-radius: 0;
        color: inherit;
        padding: 0;
      }}
      blockquote {{
        border-left: 4px solid #b7c9c3;
        color: #4b5563;
        margin: 14px 0;
        padding: 4px 0 4px 14px;
      }}
    </style>
  </head>
  <body>
    <header class="report-header">
      <h1 class="report-title">{title}</h1>
      <div class="meta">
        <div>날짜: {report_date}</div>
        <div>유형: {mode}</div>
        <div>생성 주체: {created_by}</div>
      </div>
    </header>
    <main class="content">
      {content_html}
    </main>
  </body>
</html>"""

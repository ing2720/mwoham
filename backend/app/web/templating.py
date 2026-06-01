import html
from datetime import UTC, datetime
from zoneinfo import ZoneInfo

import markdown as markdown_lib
from fastapi.templating import Jinja2Templates
from markupsafe import Markup

from app.report.display import format_created_by, format_report_mode

KST = ZoneInfo("Asia/Seoul")


def format_kst_time(value: datetime | None) -> str:
    if value is None:
        return "-"
    if value.tzinfo is None:
        value = value.replace(tzinfo=UTC)
    return value.astimezone(KST).strftime("%Y-%m-%d %H:%M")


def render_markdown(value: str | None) -> Markup:
    if not value:
        return Markup("")
    rendered_html = markdown_lib.markdown(
        html.escape(value),
        extensions=["extra", "sane_lists"],
        output_format="html5",
    )
    return Markup(rendered_html)


templates = Jinja2Templates(directory="app/web/templates")
templates.env.filters["created_by_label"] = format_created_by
templates.env.filters["kst_time"] = format_kst_time
templates.env.filters["report_mode_label"] = format_report_mode
templates.env.filters["markdown"] = render_markdown

from fastapi.templating import Jinja2Templates

from app.report.display import format_created_by, format_report_mode

templates = Jinja2Templates(directory="app/web/templates")
templates.env.filters["created_by_label"] = format_created_by
templates.env.filters["report_mode_label"] = format_report_mode

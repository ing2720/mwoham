from datetime import datetime

from app.schemas.common import ApiSchema


class StatusResponse(ApiSchema):
    status: str
    current_app: str | None = None
    current_window: str | None = None
    meeting_mode: bool = False
    last_event_at: datetime | None = None
    report_status: str = "idle"
    session_id: int | None = None
    session_started_at: datetime | None = None
    elapsed_seconds: int | None = None

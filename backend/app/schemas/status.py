from datetime import datetime

from app.schemas.common import ApiSchema
from app.schemas.meeting import MeetingResponse


class StatusResponse(ApiSchema):
    status: str
    current_app: str | None = None
    current_window: str | None = None
    meeting_mode: bool = False
    current_meeting: MeetingResponse | None = None
    last_event_at: datetime | None = None
    report_status: str = "idle"
    session_id: int | None = None
    session_started_at: datetime | None = None
    elapsed_seconds: int | None = None

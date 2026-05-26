from datetime import datetime

from app.schemas.common import ApiSchema


class RecordingStartRequest(ApiSchema):
    project_id: int | None = None
    title: str | None = None
    started_at: datetime | None = None


class RecordingSessionRequest(ApiSchema):
    session_id: int | None = None


class RecordingStopRequest(RecordingSessionRequest):
    ended_at: datetime | None = None


class RecordingResponse(ApiSchema):
    session_id: int
    status: str
    started_at: datetime
    ended_at: datetime | None = None

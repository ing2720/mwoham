from fastapi import APIRouter

from app.api.endpoints import (
    activity_segments,
    dev_events,
    events,
    health,
    meeting_transcripts,
    meetings,
    memos,
    recording,
    reports,
    screen_observations,
    settings,
    status,
    timeline,
    transcripts,
)

api_router = APIRouter()
api_router.include_router(health.router)
api_router.include_router(status.router)
api_router.include_router(recording.router)
api_router.include_router(events.router)
api_router.include_router(activity_segments.router)
api_router.include_router(dev_events.router)
api_router.include_router(screen_observations.router)
api_router.include_router(memos.router)
api_router.include_router(meetings.router)
api_router.include_router(meeting_transcripts.router)
api_router.include_router(transcripts.router)
api_router.include_router(timeline.router)
api_router.include_router(reports.router)
api_router.include_router(settings.router)

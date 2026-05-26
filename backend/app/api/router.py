from fastapi import APIRouter

from app.api.endpoints import events, health, memos, recording, status

api_router = APIRouter()
api_router.include_router(health.router)
api_router.include_router(status.router)
api_router.include_router(recording.router)
api_router.include_router(events.router)
api_router.include_router(memos.router)

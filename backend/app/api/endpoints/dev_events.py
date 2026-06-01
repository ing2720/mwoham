from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.orm import Session

from app.core.security import require_local_api_token
from app.db.session import get_db
from app.schemas.dev_event import DevEventCreate, DevEventListResponse, DevEventRead
from app.services.dev_event_service import DevEventService, get_dev_event_service

router = APIRouter(prefix="/dev-events", tags=["dev-events"])


@router.post("", response_model=DevEventRead, status_code=status.HTTP_201_CREATED)
def create_dev_event(
    request: DevEventCreate,
    _: None = Depends(require_local_api_token),
    db: Session = Depends(get_db),
    service: DevEventService = Depends(get_dev_event_service),
) -> DevEventRead:
    return service.create(db, request)


@router.get("", response_model=DevEventListResponse)
def list_dev_events(
    session_id: int | None = None,
    target_date: Annotated[date | None, Query(alias="date")] = None,
    event_type: str | None = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 100,
    db: Session = Depends(get_db),
    service: DevEventService = Depends(get_dev_event_service),
) -> DevEventListResponse:
    return service.list(
        db,
        session_id=session_id,
        target_date=target_date,
        event_type=event_type,
        limit=limit,
    )


@router.get("/today", response_model=DevEventListResponse)
def list_today_dev_events(
    event_type: str | None = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 100,
    db: Session = Depends(get_db),
    service: DevEventService = Depends(get_dev_event_service),
) -> DevEventListResponse:
    return service.list_today(db, event_type=event_type, limit=limit)

from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.core.exceptions import ResourceNotFoundError
from app.db.session import get_db
from app.schemas.work_event import WorkEventCreate, WorkEventCreateResponse, WorkEventListResponse
from app.services.event_service import EventService, get_event_service

router = APIRouter(prefix="/events", tags=["events"])


@router.post("", response_model=WorkEventCreateResponse, status_code=status.HTTP_201_CREATED)
def create_event(
    request: WorkEventCreate,
    db: Session = Depends(get_db),
    service: EventService = Depends(get_event_service),
) -> WorkEventCreateResponse:
    try:
        return service.create(db, request)
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc


@router.get("", response_model=WorkEventListResponse)
def list_events(
    session_id: int | None = None,
    target_date: Annotated[date | None, Query(alias="date")] = None,
    source: str | None = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 100,
    db: Session = Depends(get_db),
    service: EventService = Depends(get_event_service),
) -> WorkEventListResponse:
    return service.list(
        db,
        session_id=session_id,
        target_date=target_date,
        source=source,
        limit=limit,
    )

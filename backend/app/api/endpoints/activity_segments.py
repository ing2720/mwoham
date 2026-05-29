from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.core.exceptions import ResourceNotFoundError
from app.core.security import require_local_api_token
from app.db.session import get_db
from app.schemas.activity_segment import (
    ActivitySegmentCreate,
    ActivitySegmentListResponse,
    ActivitySegmentResponse,
    ActivitySegmentUpdate,
)
from app.services.activity_segment_service import (
    ActivitySegmentService,
    get_activity_segment_service,
)

router = APIRouter(prefix="/activity-segments", tags=["activity-segments"])


@router.post("", response_model=ActivitySegmentResponse, status_code=status.HTTP_201_CREATED)
def create_activity_segment(
    request: ActivitySegmentCreate,
    _: None = Depends(require_local_api_token),
    db: Session = Depends(get_db),
    service: ActivitySegmentService = Depends(get_activity_segment_service),
) -> ActivitySegmentResponse:
    try:
        return service.create(db, request)
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc


@router.patch("/{segment_id}", response_model=ActivitySegmentResponse)
def update_activity_segment(
    segment_id: int,
    request: ActivitySegmentUpdate,
    _: None = Depends(require_local_api_token),
    db: Session = Depends(get_db),
    service: ActivitySegmentService = Depends(get_activity_segment_service),
) -> ActivitySegmentResponse:
    try:
        return service.update(db, segment_id, request)
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc


@router.get("", response_model=ActivitySegmentListResponse)
def list_activity_segments(
    session_id: int | None = None,
    target_date: Annotated[date | None, Query(alias="date")] = None,
    source: str | None = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 100,
    db: Session = Depends(get_db),
    service: ActivitySegmentService = Depends(get_activity_segment_service),
) -> ActivitySegmentListResponse:
    return service.list(
        db,
        session_id=session_id,
        target_date=target_date,
        source=source,
        limit=limit,
    )

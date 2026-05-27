from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.core.exceptions import ResourceNotFoundError
from app.db.session import get_db
from app.schemas.meeting import (
    MeetingEndRequest,
    MeetingListResponse,
    MeetingResponse,
    MeetingStartRequest,
)
from app.schemas.transcript import TranscriptListResponse
from app.services.meeting_service import MeetingService, get_meeting_service

router = APIRouter(prefix="/meetings", tags=["meetings"])


@router.post("/start", response_model=MeetingResponse)
def start_meeting(
    request: MeetingStartRequest | None = None,
    db: Session = Depends(get_db),
    service: MeetingService = Depends(get_meeting_service),
) -> MeetingResponse:
    try:
        return service.start_meeting(db, request or MeetingStartRequest())
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc


@router.post("/{meeting_id}/end", response_model=MeetingResponse)
def end_meeting(
    meeting_id: int,
    request: MeetingEndRequest | None = None,
    db: Session = Depends(get_db),
    service: MeetingService = Depends(get_meeting_service),
) -> MeetingResponse:
    try:
        return service.end_meeting(
            db, meeting_id=meeting_id, request=request or MeetingEndRequest()
        )
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc


@router.get("", response_model=MeetingListResponse)
def list_meetings(
    session_id: int | None = None,
    target_date: Annotated[date | None, Query(alias="date")] = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 100,
    db: Session = Depends(get_db),
    service: MeetingService = Depends(get_meeting_service),
) -> MeetingListResponse:
    return service.list_meetings(db, session_id=session_id, target_date=target_date, limit=limit)


@router.get("/{meeting_id}/transcripts", response_model=TranscriptListResponse)
def list_meeting_transcripts(
    meeting_id: int,
    limit: Annotated[int, Query(ge=1, le=1000)] = 100,
    db: Session = Depends(get_db),
    service: MeetingService = Depends(get_meeting_service),
) -> TranscriptListResponse:
    try:
        return service.list_transcripts(db, meeting_id=meeting_id, limit=limit)
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.core.exceptions import ResourceNotFoundError
from app.core.security import require_local_api_token
from app.db.session import get_db
from app.schemas.transcript import (
    MeetingTranscriptCreate,
    MeetingTranscriptListResponse,
    MeetingTranscriptResponse,
)
from app.services.meeting_service import MeetingService, get_meeting_service

router = APIRouter(prefix="/meeting-transcripts", tags=["meeting-transcripts"])


@router.post("", response_model=MeetingTranscriptResponse, status_code=status.HTTP_201_CREATED)
def create_meeting_transcript(
    request: MeetingTranscriptCreate,
    _: None = Depends(require_local_api_token),
    db: Session = Depends(get_db),
    service: MeetingService = Depends(get_meeting_service),
) -> MeetingTranscriptResponse:
    try:
        return service.create_meeting_transcript(db, request)
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc


@router.get("/today", response_model=MeetingTranscriptListResponse)
def list_today_meeting_transcripts(
    limit: Annotated[int, Query(ge=1, le=1000)] = 100,
    db: Session = Depends(get_db),
    service: MeetingService = Depends(get_meeting_service),
) -> MeetingTranscriptListResponse:
    return service.list_today_meeting_transcripts(db, limit=limit)

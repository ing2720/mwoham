from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.core.exceptions import ResourceNotFoundError
from app.core.security import require_local_api_token
from app.db.session import get_db
from app.schemas.transcript import TranscriptCreate, TranscriptResponse
from app.services.meeting_transcript_service import (
    MeetingTranscriptService,
    get_meeting_transcript_service,
)

router = APIRouter(prefix="/transcripts", tags=["transcripts"])


@router.post("", response_model=TranscriptResponse, status_code=status.HTTP_201_CREATED)
def create_transcript(
    request: TranscriptCreate,
    _: None = Depends(require_local_api_token),
    db: Session = Depends(get_db),
    service: MeetingTranscriptService = Depends(get_meeting_transcript_service),
) -> TranscriptResponse:
    try:
        return service.create_transcript(db, request)
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc

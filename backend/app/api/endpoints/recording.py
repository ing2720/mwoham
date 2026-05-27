from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from app.core.exceptions import InvalidStateTransitionError, ResourceNotFoundError
from app.core.security import require_local_api_token
from app.db.session import get_db
from app.schemas.recording import (
    RecordingResponse,
    RecordingSessionRequest,
    RecordingStartRequest,
    RecordingStopRequest,
)
from app.services.recording_service import RecordingService, get_recording_service

router = APIRouter(prefix="/recording", tags=["recording"])


@router.post("/start", response_model=RecordingResponse)
def start_recording(
    request: RecordingStartRequest | None = None,
    _: None = Depends(require_local_api_token),
    db: Session = Depends(get_db),
    service: RecordingService = Depends(get_recording_service),
) -> RecordingResponse:
    try:
        return service.start(db, request or RecordingStartRequest())
    except InvalidStateTransitionError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc


@router.post("/pause", response_model=RecordingResponse)
def pause_recording(
    request: RecordingSessionRequest | None = None,
    _: None = Depends(require_local_api_token),
    db: Session = Depends(get_db),
    service: RecordingService = Depends(get_recording_service),
) -> RecordingResponse:
    try:
        return service.pause(db, request or RecordingSessionRequest())
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
    except InvalidStateTransitionError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc


@router.post("/resume", response_model=RecordingResponse)
def resume_recording(
    request: RecordingSessionRequest | None = None,
    _: None = Depends(require_local_api_token),
    db: Session = Depends(get_db),
    service: RecordingService = Depends(get_recording_service),
) -> RecordingResponse:
    try:
        return service.resume(db, request or RecordingSessionRequest())
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
    except InvalidStateTransitionError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc


@router.post("/stop", response_model=RecordingResponse)
def stop_recording(
    request: RecordingStopRequest | None = None,
    _: None = Depends(require_local_api_token),
    db: Session = Depends(get_db),
    service: RecordingService = Depends(get_recording_service),
) -> RecordingResponse:
    try:
        return service.stop(db, request or RecordingStopRequest())
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc
    except InvalidStateTransitionError as exc:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(exc)) from exc

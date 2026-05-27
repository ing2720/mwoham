from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session

from app.core.exceptions import ResourceNotFoundError
from app.core.security import require_local_api_token
from app.db.session import get_db
from app.schemas.screen_observation import (
    ScreenObservationCreate,
    ScreenObservationCreateResponse,
    ScreenObservationListResponse,
)
from app.services.screen_observation_service import (
    ScreenObservationService,
    get_screen_observation_service,
)

router = APIRouter(prefix="/screen-observations", tags=["screen-observations"])


@router.post(
    "", response_model=ScreenObservationCreateResponse, status_code=status.HTTP_201_CREATED
)
def create_screen_observation(
    request: ScreenObservationCreate,
    _: None = Depends(require_local_api_token),
    db: Session = Depends(get_db),
    service: ScreenObservationService = Depends(get_screen_observation_service),
) -> ScreenObservationCreateResponse:
    try:
        return service.create(db, request)
    except ResourceNotFoundError as exc:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(exc)) from exc


@router.get("", response_model=ScreenObservationListResponse)
def list_screen_observations(
    session_id: int | None = None,
    target_date: Annotated[date | None, Query(alias="date")] = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 100,
    db: Session = Depends(get_db),
    service: ScreenObservationService = Depends(get_screen_observation_service),
) -> ScreenObservationListResponse:
    return service.list(db, session_id=session_id, target_date=target_date, limit=limit)

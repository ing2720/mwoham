from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.schemas.status import StatusResponse
from app.services.status_service import StatusService, get_status_service

router = APIRouter(tags=["system"])


@router.get("/status", response_model=StatusResponse)
def get_status(
    db: Session = Depends(get_db),
    service: StatusService = Depends(get_status_service),
) -> StatusResponse:
    return service.get_status(db)

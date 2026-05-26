from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.schemas.health import HealthResponse
from app.services.health_service import HealthService, get_health_service

router = APIRouter(tags=["system"])


@router.get("/health", response_model=HealthResponse)
def health_check(
    db: Session = Depends(get_db),
    service: HealthService = Depends(get_health_service),
) -> HealthResponse:
    return service.check(db)

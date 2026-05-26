from sqlalchemy.orm import Session

from app.core.config import settings
from app.repositories.health_repository import HealthRepository
from app.schemas.health import HealthResponse


class HealthService:
    def __init__(self, repository: HealthRepository) -> None:
        self.repository = repository

    def check(self, db: Session) -> HealthResponse:
        self.repository.can_connect(db)
        return HealthResponse(status="ok", version=settings.app_version, database="ok")


def get_health_service() -> HealthService:
    return HealthService(repository=HealthRepository())

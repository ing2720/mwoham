from sqlalchemy.orm import Session

from app.core.config import settings
from app.repositories.health_repository import HealthRepository
from app.schemas.health import HealthResponse


class HealthService:
    def __init__(self, repository: HealthRepository) -> None:
        self.repository = repository

    def check(self, db: Session) -> HealthResponse:
        self.repository.can_connect(db)
        if not self.repository.has_required_tables(db):
            return HealthResponse(
                status="error",
                version=settings.app_version,
                database="missing_required_tables",
            )
        return HealthResponse(status="ok", version=settings.app_version, database="ok")


def get_health_service() -> HealthService:
    return HealthService(repository=HealthRepository())

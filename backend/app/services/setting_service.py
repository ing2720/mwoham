from sqlalchemy.orm import Session

from app.repositories.setting_repository import SettingRepository
from app.schemas.setting import (
    DeletePrivateAppResponse,
    PrivateAppCreate,
    PrivateAppListResponse,
    PrivateAppResponse,
    SettingsPatchRequest,
    SettingsResponse,
)
from app.services.private_app_matcher import PrivateAppMatcher, get_private_app_matcher


class SettingService:
    def __init__(
        self,
        repository: SettingRepository,
        private_app_matcher: PrivateAppMatcher | None = None,
    ) -> None:
        self.repository = repository
        self.private_app_matcher = private_app_matcher or get_private_app_matcher()

    def get_settings(self, db: Session) -> SettingsResponse:
        items = self.repository.list_settings(db)
        return SettingsResponse(items=items, total=len(items))

    def update_settings(self, db: Session, request: SettingsPatchRequest) -> SettingsResponse:
        self.repository.upsert_settings(db, request.settings)
        return self.get_settings(db)

    def list_private_apps(self, db: Session) -> PrivateAppListResponse:
        items = self.repository.list_private_apps(db)
        return PrivateAppListResponse(items=items, total=len(items))

    def create_private_app(self, db: Session, request: PrivateAppCreate) -> PrivateAppResponse:
        private_app = self.repository.upsert_private_app(
            db,
            app_name=request.app_name,
            match_type=request.match_type,
            is_enabled=request.is_enabled,
        )
        return PrivateAppResponse.model_validate(private_app)

    def delete_private_app(self, db: Session, app_name: str) -> DeletePrivateAppResponse:
        return DeletePrivateAppResponse(
            app_name=app_name,
            deleted=self.repository.delete_private_app(db, app_name),
        )

    def is_private_app(self, db: Session, app_name: str | None) -> bool:
        return self.private_app_matcher.is_private_app(
            app_name,
            self.repository.list_private_apps(db, enabled_only=True),
        )


def get_setting_service() -> SettingService:
    return SettingService(
        repository=SettingRepository(),
        private_app_matcher=get_private_app_matcher(),
    )

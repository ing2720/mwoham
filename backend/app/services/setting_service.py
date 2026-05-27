import re

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


class SettingService:
    def __init__(self, repository: SettingRepository) -> None:
        self.repository = repository

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
        if not app_name:
            return False
        for private_app in self.repository.list_private_apps(db, enabled_only=True):
            if self._matches(app_name, private_app.app_name, private_app.match_type):
                return True
        return False

    def _matches(self, app_name: str, pattern: str, match_type: str) -> bool:
        if match_type == "exact":
            return app_name == pattern
        if match_type == "contains":
            return pattern.lower() in app_name.lower()
        if match_type == "regex":
            try:
                return re.search(pattern, app_name) is not None
            except re.error:
                return False
        return False


def get_setting_service() -> SettingService:
    return SettingService(repository=SettingRepository())

import json
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.models.app_setting import AppSetting
from app.models.private_app import PrivateApp


class SettingRepository:
    def list_settings(self, db: Session) -> list[AppSetting]:
        return list(db.scalars(select(AppSetting).order_by(AppSetting.key.asc())))

    def upsert_settings(self, db: Session, values: dict[str, Any]) -> list[AppSetting]:
        updated = []
        for key, value in values.items():
            setting = db.scalar(select(AppSetting).where(AppSetting.key == key))
            value_type = self._infer_value_type(value)
            serialized = self._serialize_value(value)
            if setting is None:
                setting = AppSetting(key=key, value=serialized, value_type=value_type)
            else:
                setting.value = serialized
                setting.value_type = value_type
            db.add(setting)
            updated.append(setting)
        db.commit()
        for setting in updated:
            db.refresh(setting)
        return updated

    def list_private_apps(self, db: Session, *, enabled_only: bool = False) -> list[PrivateApp]:
        statement = select(PrivateApp).order_by(PrivateApp.app_name.asc())
        if enabled_only:
            statement = statement.where(PrivateApp.is_enabled.is_(True))
        return list(db.scalars(statement))

    def upsert_private_app(
        self,
        db: Session,
        *,
        app_name: str,
        match_type: str,
        is_enabled: bool,
    ) -> PrivateApp:
        private_app = db.scalar(select(PrivateApp).where(PrivateApp.app_name == app_name))
        if private_app is None:
            private_app = PrivateApp(
                app_name=app_name,
                match_type=match_type,
                is_enabled=is_enabled,
            )
        else:
            private_app.match_type = match_type
            private_app.is_enabled = is_enabled
        db.add(private_app)
        db.commit()
        db.refresh(private_app)
        return private_app

    def delete_private_app(self, db: Session, app_name: str) -> bool:
        private_app = db.scalar(select(PrivateApp).where(PrivateApp.app_name == app_name))
        if private_app is None:
            return False
        db.delete(private_app)
        db.commit()
        return True

    def _infer_value_type(self, value: Any) -> str:
        if isinstance(value, bool):
            return "boolean"
        if isinstance(value, int | float):
            return "number"
        if isinstance(value, dict | list):
            return "json"
        return "string"

    def _serialize_value(self, value: Any) -> str | None:
        if value is None:
            return None
        if isinstance(value, dict | list):
            return json.dumps(value, ensure_ascii=False)
        return str(value)

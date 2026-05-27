from fastapi import APIRouter, Depends, Request
from fastapi.responses import Response
from fastapi.templating import Jinja2Templates
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.schemas.setting import (
    DeletePrivateAppResponse,
    PrivateAppCreate,
    PrivateAppListResponse,
    PrivateAppResponse,
    SettingsPatchRequest,
    SettingsResponse,
)
from app.services.setting_service import SettingService, get_setting_service

router = APIRouter(prefix="/settings", tags=["settings"])
templates = Jinja2Templates(directory="app/web/templates")


@router.get("", response_model=None)
def get_settings(
    request: Request,
    db: Session = Depends(get_db),
    service: SettingService = Depends(get_setting_service),
) -> SettingsResponse | Response:
    settings_response = service.get_settings(db)
    if "text/html" in request.headers.get("accept", ""):
        private_apps = service.list_private_apps(db)
        return templates.TemplateResponse(
            request,
            "settings.html",
            {
                "active_page": "settings",
                "settings": settings_response.items,
                "private_apps": private_apps.items,
            },
        )
    return settings_response


@router.patch("", response_model=SettingsResponse)
def update_settings(
    request: SettingsPatchRequest,
    db: Session = Depends(get_db),
    service: SettingService = Depends(get_setting_service),
) -> SettingsResponse:
    return service.update_settings(db, request)


@router.get("/private-apps", response_model=PrivateAppListResponse)
def list_private_apps(
    db: Session = Depends(get_db),
    service: SettingService = Depends(get_setting_service),
) -> PrivateAppListResponse:
    return service.list_private_apps(db)


@router.post("/private-apps", response_model=PrivateAppResponse)
def create_private_app(
    request: PrivateAppCreate,
    db: Session = Depends(get_db),
    service: SettingService = Depends(get_setting_service),
) -> PrivateAppResponse:
    return service.create_private_app(db, request)


@router.delete("/private-apps/{app_name}", response_model=DeletePrivateAppResponse)
def delete_private_app(
    app_name: str,
    db: Session = Depends(get_db),
    service: SettingService = Depends(get_setting_service),
) -> DeletePrivateAppResponse:
    return service.delete_private_app(db, app_name)

from fastapi import APIRouter, Depends, Request
from fastapi.responses import RedirectResponse
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.schemas.setting import PrivateAppCreate
from app.services.setting_service import SettingService, get_setting_service

router = APIRouter(tags=["web"])


@router.post("/settings/private-apps/add")
async def add_private_app_from_settings(
    request: Request,
    db: Session = Depends(get_db),
    service: SettingService = Depends(get_setting_service),
) -> RedirectResponse:
    form = await request.form()
    app_name = str(form.get("app_name") or "").strip()
    if app_name:
        service.create_private_app(
            db,
            PrivateAppCreate(
                app_name=app_name,
                match_type=str(form.get("match_type") or "exact"),
                is_enabled=form.get("is_enabled") == "on",
            ),
        )
    return RedirectResponse("/settings", status_code=303)


@router.post("/settings/private-apps/delete")
async def delete_private_app_from_settings(
    request: Request,
    db: Session = Depends(get_db),
    service: SettingService = Depends(get_setting_service),
) -> RedirectResponse:
    form = await request.form()
    app_name = str(form.get("app_name") or "").strip()
    if app_name:
        service.delete_private_app(db, app_name)
    return RedirectResponse("/settings", status_code=303)

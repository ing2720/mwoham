from urllib.parse import urlencode

from fastapi import APIRouter, Depends, Request
from fastapi.responses import RedirectResponse
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.schemas.setting import PrivateAppCreate
from app.services.dev_data_reset_service import ResetDevDataOptions, get_dev_data_reset_service
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


@router.post("/settings/dev-data/reset")
async def reset_dev_data_from_settings(
    request: Request,
    db: Session = Depends(get_db),
) -> RedirectResponse:
    form = await request.form()
    result = get_dev_data_reset_service().reset(db, _build_reset_options_from_form(form))
    counts = ", ".join(f"{target}:{count}" for target, count in result.counts.items())
    query = urlencode(
        {
            "reset_scope": result.scope_label,
            "reset_deleted": "true" if result.deleted else "false",
            "reset_counts": counts or "대상 없음",
        }
    )
    return RedirectResponse(f"/settings?{query}", status_code=303)


def _build_reset_options_from_form(form) -> ResetDevDataOptions:
    target = str(form.get("target") or "all-targets")
    scope = str(form.get("scope") or "today")
    return ResetDevDataOptions(
        today=scope == "today",
        all_data=scope == "all",
        except_today=scope == "except_today",
        reports_only=target == "reports",
        dev_events_only=target == "dev_events",
        transcripts_only=target == "voice_transcripts",
        meetings_only=target == "meeting_sessions",
        observations_only=target == "screen_observations",
        activity_only=target == "activity_segments",
        memos_only=target == "manual_memos",
        events_only=target == "work_events",
        yes=form.get("confirm_delete") == "on",
    )

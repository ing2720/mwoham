from fastapi import APIRouter

from app.web import dashboard_routes, report_routes, settings_routes

router = APIRouter(tags=["web"])
router.include_router(dashboard_routes.router)
router.include_router(report_routes.router)
router.include_router(settings_routes.router)

import uvicorn
from fastapi import FastAPI

from app.api.router import api_router
from app.core.config import settings
from app.db.init_db import prepare_database


def create_app() -> FastAPI:
    prepare_database()
    app = FastAPI(title=settings.app_name, version=settings.app_version)
    app.include_router(api_router)
    return app


app = create_app()


def run() -> None:
    uvicorn.run("app.main:app", host=settings.app_host, port=settings.app_port, reload=True)

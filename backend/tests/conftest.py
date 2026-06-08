from collections.abc import Generator

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.engine import Engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.ai.gemini_client import GeminiClient
from app.ai.prompt_builder import get_prompt_builder
from app.ai.summarizer import GeminiSummarizer
from app.core.config import settings
from app.db.session import get_db
from app.main import app
from app.models import Base
from app.repositories.report_repository import ReportRepository
from app.repositories.screen_observation_repository import ScreenObservationRepository
from app.repositories.work_session_repository import WorkSessionRepository
from app.services.report_service import ReportService, get_report_service
from app.services.screen_observation_service import (
    ScreenObservationService,
    get_screen_observation_service,
)
from app.services.screen_observation_summarizer import ScreenObservationSummarizer
from app.services.setting_service import get_setting_service
from app.services.timeline_builder import get_timeline_builder


@pytest.fixture
def db_engine() -> Generator[Engine]:
    engine = create_engine(
        "sqlite://",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(bind=engine)
    try:
        yield engine
    finally:
        Base.metadata.drop_all(bind=engine)
        engine.dispose()


@pytest.fixture
def db(db_engine: Engine) -> Generator[Session]:
    testing_session_local = sessionmaker(autocommit=False, autoflush=False, bind=db_engine)
    session = testing_session_local()
    try:
        yield session
    finally:
        session.close()


@pytest.fixture
def client(db_engine: Engine) -> Generator[TestClient]:
    testing_session_local = sessionmaker(autocommit=False, autoflush=False, bind=db_engine)
    original_token = settings.local_api_token

    def override_get_db() -> Generator[Session]:
        db_session = testing_session_local()
        try:
            yield db_session
        finally:
            db_session.close()

    app.dependency_overrides[get_db] = override_get_db
    app.dependency_overrides[get_report_service] = _build_unconfigured_report_service
    app.dependency_overrides[get_screen_observation_service] = (
        _build_unconfigured_screen_observation_service
    )
    try:
        with TestClient(app) as test_client:
            yield test_client
    finally:
        settings.local_api_token = original_token
        app.dependency_overrides.clear()


def _build_unconfigured_report_service() -> ReportService:
    return ReportService(
        repository=ReportRepository(),
        timeline_builder=get_timeline_builder(),
        summarizer=GeminiSummarizer(
            client=GeminiClient(api_key=None, model="gemini-2.5-flash"),
            prompt_builder=get_prompt_builder(),
        ),
    )


def _build_unconfigured_screen_observation_service() -> ScreenObservationService:
    return ScreenObservationService(
        observation_repository=ScreenObservationRepository(),
        session_repository=WorkSessionRepository(),
        setting_service=get_setting_service(),
        observation_summarizer=ScreenObservationSummarizer(
            client=GeminiClient(api_key=None, model="gemini-2.5-flash"),
            privacy_filter=get_prompt_builder().privacy_filter,
        ),
    )

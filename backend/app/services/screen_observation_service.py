from datetime import date

from sqlalchemy.orm import Session

from app.core.exceptions import ResourceNotFoundError
from app.models.work_session import WorkSession
from app.repositories.screen_observation_repository import ScreenObservationRepository
from app.repositories.work_session_repository import WorkSessionRepository
from app.schemas.screen_observation import (
    ScreenObservationCreate,
    ScreenObservationCreateResponse,
    ScreenObservationListResponse,
)
from app.services.setting_service import SettingService, get_setting_service


class ScreenObservationService:
    def __init__(
        self,
        observation_repository: ScreenObservationRepository,
        session_repository: WorkSessionRepository,
        setting_service: SettingService,
    ) -> None:
        self.observation_repository = observation_repository
        self.session_repository = session_repository
        self.setting_service = setting_service

    def create(
        self,
        db: Session,
        request: ScreenObservationCreate,
    ) -> ScreenObservationCreateResponse:
        session = self._resolve_session(db, request.session_id)
        if self.setting_service.is_private_app(db, request.app_name):
            request = ScreenObservationCreate(
                session_id=request.session_id,
                timestamp=request.timestamp,
                app_name=request.app_name,
                window_title=None,
                ocr_text=None,
                detected_keywords=None,
                ai_inference=None,
                frame_hash=request.frame_hash,
            )
        if request.frame_hash:
            duplicate = self.observation_repository.get_recent_by_frame_hash(
                db,
                session_id=session.id,
                frame_hash=request.frame_hash,
            )
            if duplicate is not None:
                return ScreenObservationCreateResponse(
                    id=duplicate.id,
                    saved=False,
                    duplicate=True,
                )

        observation = self.observation_repository.create(
            db,
            observation_in=request,
            session_id=session.id,
        )
        return ScreenObservationCreateResponse(id=observation.id)

    def list(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
        limit: int = 100,
    ) -> ScreenObservationListResponse:
        items = self.observation_repository.list(
            db,
            session_id=session_id,
            target_date=target_date,
            limit=limit,
        )
        total = self.observation_repository.count(
            db,
            session_id=session_id,
            target_date=target_date,
        )
        return ScreenObservationListResponse(items=items, total=total)

    def _resolve_session(self, db: Session, session_id: int | None) -> WorkSession:
        if session_id is not None:
            session = self.session_repository.get_by_id(db, session_id)
        else:
            session = self.session_repository.get_current_by_status(db, "active")

        if session is None:
            raise ResourceNotFoundError("Active recording session not found.")
        return session


def get_screen_observation_service() -> ScreenObservationService:
    return ScreenObservationService(
        observation_repository=ScreenObservationRepository(),
        session_repository=WorkSessionRepository(),
        setting_service=get_setting_service(),
    )

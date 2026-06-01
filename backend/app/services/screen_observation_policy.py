from sqlalchemy.orm import Session

from app.core.timezone import as_kst, as_utc
from app.models.work_session import WorkSession
from app.repositories.screen_observation_repository import ScreenObservationRepository
from app.schemas.screen_observation import ScreenObservationCreate


class ScreenObservationInferencePolicy:
    def __init__(
        self,
        observation_repository: ScreenObservationRepository,
        *,
        enable_ai_inference: bool,
        ai_min_interval_seconds: int,
        ai_daily_limit: int,
    ) -> None:
        self.observation_repository = observation_repository
        self.enable_ai_inference = enable_ai_inference
        self.ai_min_interval_seconds = ai_min_interval_seconds
        self.ai_daily_limit = ai_daily_limit

    def should_generate(
        self,
        db: Session,
        *,
        session: WorkSession,
        request: ScreenObservationCreate,
    ) -> bool:
        if not self.enable_ai_inference:
            return False
        if self.ai_daily_limit <= 0:
            return False

        inference_count = self.observation_repository.count_ai_inference(
            db,
            target_date=as_kst(request.timestamp).date(),
        )
        if inference_count >= self.ai_daily_limit:
            return False

        latest_observation = self.observation_repository.get_latest_ai_inference_by_context(
            db,
            session_id=session.id,
            app_name=request.app_name,
            window_title=request.window_title,
        )
        if latest_observation is None:
            return True

        elapsed_seconds = (
            as_utc(request.timestamp) - as_utc(latest_observation.timestamp)
        ).total_seconds()
        return elapsed_seconds >= self.ai_min_interval_seconds

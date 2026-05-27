from datetime import UTC, date, datetime

from sqlalchemy.orm import Session

from app.models.manual_memo import ManualMemo
from app.models.screen_observation import ScreenObservation
from app.models.work_event import WorkEvent
from app.repositories.memo_repository import MemoRepository
from app.repositories.screen_observation_repository import ScreenObservationRepository
from app.repositories.work_event_repository import WorkEventRepository
from app.schemas.timeline import TimelineItem, TimelineResponse


class TimelineBuilder:
    def __init__(
        self,
        event_repository: WorkEventRepository,
        memo_repository: MemoRepository,
        screen_observation_repository: ScreenObservationRepository,
    ) -> None:
        self.event_repository = event_repository
        self.memo_repository = memo_repository
        self.screen_observation_repository = screen_observation_repository

    def build_for_date(self, db: Session, target_date: date | None = None) -> TimelineResponse:
        timeline_date = target_date or datetime.now(UTC).date()
        events = self.event_repository.list(db, target_date=timeline_date, limit=1000)
        memos = self.memo_repository.list(db, target_date=timeline_date, limit=1000)
        screen_observations = self.screen_observation_repository.list(
            db,
            target_date=timeline_date,
            limit=1000,
        )
        items = [self._event_to_item(event) for event in events]
        items.extend(self._memo_to_item(memo) for memo in memos)
        items.extend(self._screen_observation_to_item(item) for item in screen_observations)
        items.sort(key=lambda item: item.timestamp)
        return TimelineResponse(date=timeline_date, items=items, total=len(items))

    def _event_to_item(self, event: WorkEvent) -> TimelineItem:
        return TimelineItem(
            type="event",
            id=event.id,
            timestamp=event.timestamp,
            content=event.content,
            source=event.source,
            app_name=event.app_name,
            window_title=event.window_title,
            session_id=event.session_id,
        )

    def _memo_to_item(self, memo: ManualMemo) -> TimelineItem:
        return TimelineItem(
            type="memo",
            id=memo.id,
            timestamp=memo.timestamp,
            content=memo.content,
            session_id=memo.session_id,
            linked_type=memo.linked_type,
            linked_id=memo.linked_id,
        )

    def _screen_observation_to_item(self, observation: ScreenObservation) -> TimelineItem:
        return TimelineItem(
            type="screen_ocr",
            id=observation.id,
            timestamp=observation.timestamp,
            content=observation.ocr_text or "",
            app_name=observation.app_name,
            window_title=observation.window_title,
            detected_keywords=observation.detected_keywords,
            ai_inference=observation.ai_inference,
            frame_hash=observation.frame_hash,
            session_id=observation.session_id,
        )


def get_timeline_builder() -> TimelineBuilder:
    return TimelineBuilder(
        event_repository=WorkEventRepository(),
        memo_repository=MemoRepository(),
        screen_observation_repository=ScreenObservationRepository(),
    )

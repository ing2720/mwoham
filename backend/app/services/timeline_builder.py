from datetime import UTC, date, datetime

from sqlalchemy.orm import Session

from app.models.activity_segment import ActivitySegment
from app.models.manual_memo import ManualMemo
from app.models.meeting_session import MeetingSession
from app.models.screen_observation import ScreenObservation
from app.models.voice_transcript import VoiceTranscript
from app.models.work_event import WorkEvent
from app.repositories.activity_segment_repository import ActivitySegmentRepository
from app.repositories.meeting_repository import MeetingRepository
from app.repositories.memo_repository import MemoRepository
from app.repositories.screen_observation_repository import ScreenObservationRepository
from app.repositories.work_event_repository import WorkEventRepository
from app.schemas.timeline import TimelineItem, TimelineResponse
from app.services.setting_service import SettingService, get_setting_service


class TimelineBuilder:
    def __init__(
        self,
        activity_segment_repository: ActivitySegmentRepository,
        event_repository: WorkEventRepository,
        memo_repository: MemoRepository,
        screen_observation_repository: ScreenObservationRepository,
        meeting_repository: MeetingRepository,
        setting_service: SettingService,
    ) -> None:
        self.activity_segment_repository = activity_segment_repository
        self.event_repository = event_repository
        self.memo_repository = memo_repository
        self.screen_observation_repository = screen_observation_repository
        self.meeting_repository = meeting_repository
        self.setting_service = setting_service

    def build_for_date(self, db: Session, target_date: date | None = None) -> TimelineResponse:
        timeline_date = target_date or datetime.now(UTC).date()
        activity_segments = self.activity_segment_repository.list(
            db,
            target_date=timeline_date,
            limit=1000,
        )
        activity_segments = [
            segment
            for segment in activity_segments
            if not self.setting_service.is_private_app(db, segment.app_name)
        ]
        events = [
            event
            for event in self.event_repository.list(db, target_date=timeline_date, limit=1000)
            if event.source != "mac_active_window"
        ]
        memos = self.memo_repository.list(db, target_date=timeline_date, limit=1000)
        screen_observations = self.screen_observation_repository.list(
            db,
            target_date=timeline_date,
            limit=1000,
        )
        meetings = self.meeting_repository.list_meetings(
            db,
            target_date=timeline_date,
            limit=1000,
        )
        transcripts = self.meeting_repository.list_transcripts(
            db,
            target_date=timeline_date,
            limit=1000,
        )
        items = [self._activity_segment_to_item(segment) for segment in activity_segments]
        items.extend(self._event_to_item(event) for event in events)
        items.extend(self._memo_to_item(memo) for memo in memos)
        items.extend(self._screen_observation_to_item(item) for item in screen_observations)
        for meeting in meetings:
            items.extend(self._meeting_to_items(meeting))
        items.extend(self._transcript_to_item(transcript) for transcript in transcripts)
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

    def _activity_segment_to_item(self, segment: ActivitySegment) -> TimelineItem:
        time_range = (
            f"{segment.started_at.strftime('%H:%M:%S')}~{segment.ended_at.strftime('%H:%M:%S')}"
        )
        title = self._activity_title(segment.app_name, segment.window_title)
        duration = self._duration_text(segment.duration_seconds)
        return TimelineItem(
            type="activity_segment",
            id=segment.id,
            timestamp=segment.started_at,
            content=f"{time_range} {title} ({duration})",
            source=segment.source,
            app_name=segment.app_name,
            window_title=segment.window_title,
            session_id=segment.session_id,
            ended_at=segment.ended_at,
            duration_seconds=segment.duration_seconds,
            sample_count=segment.sample_count,
        )

    def _activity_title(self, app_name: str | None, window_title: str | None) -> str:
        title_parts = [
            value.strip()
            for value in [app_name or "알 수 없는 앱", window_title]
            if value and value.strip()
        ]
        return " / ".join(title_parts)

    def _duration_text(self, duration_seconds: int) -> str:
        if duration_seconds <= 0:
            return "1초 미만"
        if duration_seconds < 60:
            return f"{duration_seconds}초"

        minutes = duration_seconds // 60
        seconds = duration_seconds % 60
        if minutes < 60:
            return f"{minutes}분 {seconds:02d}초"

        hours = minutes // 60
        remaining_minutes = minutes % 60
        return f"{hours}시간 {remaining_minutes:02d}분"

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

    def _meeting_to_items(self, meeting: MeetingSession) -> list[TimelineItem]:
        title = meeting.title or "회의"
        items = [
            TimelineItem(
                type="meeting",
                id=meeting.id,
                timestamp=meeting.started_at,
                content=f"{title} 시작",
                app_name=meeting.meeting_app,
                meeting_id=meeting.id,
                session_id=meeting.session_id,
            )
        ]
        if meeting.ended_at is not None:
            items.append(
                TimelineItem(
                    type="meeting",
                    id=meeting.id,
                    timestamp=meeting.ended_at,
                    content=f"{title} 종료",
                    app_name=meeting.meeting_app,
                    ai_inference=meeting.summary,
                    meeting_id=meeting.id,
                    session_id=meeting.session_id,
                )
            )
        return items

    def _transcript_to_item(self, transcript: VoiceTranscript) -> TimelineItem:
        return TimelineItem(
            type="transcript",
            id=transcript.id,
            timestamp=transcript.timestamp,
            content=transcript.text,
            meeting_id=transcript.meeting_id,
            speaker=transcript.speaker,
            confidence=transcript.confidence,
        )


def get_timeline_builder() -> TimelineBuilder:
    return TimelineBuilder(
        activity_segment_repository=ActivitySegmentRepository(),
        event_repository=WorkEventRepository(),
        memo_repository=MemoRepository(),
        screen_observation_repository=ScreenObservationRepository(),
        meeting_repository=MeetingRepository(),
        setting_service=get_setting_service(),
    )

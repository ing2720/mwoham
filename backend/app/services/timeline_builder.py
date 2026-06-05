from datetime import date, datetime

from sqlalchemy.orm import Session

from app.core.timezone import (
    as_utc,
    format_datetime_kst,
    get_kst_day_range_as_utc,
    parse_date_or_today_kst,
)
from app.models.activity_segment import ActivitySegment
from app.models.dev_event import DevEvent
from app.models.manual_memo import ManualMemo
from app.models.meeting_session import MeetingSession
from app.models.screen_observation import ScreenObservation
from app.models.voice_transcript import VoiceTranscript
from app.models.work_event import WorkEvent
from app.repositories.activity_segment_repository import ActivitySegmentRepository
from app.repositories.dev_event_repository import DevEventRepository
from app.repositories.meeting_repository import MeetingRepository
from app.repositories.memo_repository import MemoRepository
from app.repositories.screen_observation_repository import ScreenObservationRepository
from app.repositories.work_event_repository import WorkEventRepository
from app.schemas.timeline import TimelineItem, TimelineResponse
from app.services.self_observation_filter import SelfObservationFilter, get_self_observation_filter
from app.services.setting_service import SettingService, get_setting_service
from app.services.transcript_quality import TranscriptQualityPolicy, get_transcript_quality_policy


class TimelineBuilder:
    def __init__(
        self,
        activity_segment_repository: ActivitySegmentRepository,
        dev_event_repository: DevEventRepository,
        event_repository: WorkEventRepository,
        memo_repository: MemoRepository,
        screen_observation_repository: ScreenObservationRepository,
        meeting_repository: MeetingRepository,
        setting_service: SettingService,
        self_observation_filter: SelfObservationFilter,
        transcript_quality_policy: TranscriptQualityPolicy,
    ) -> None:
        self.activity_segment_repository = activity_segment_repository
        self.dev_event_repository = dev_event_repository
        self.event_repository = event_repository
        self.memo_repository = memo_repository
        self.screen_observation_repository = screen_observation_repository
        self.meeting_repository = meeting_repository
        self.setting_service = setting_service
        self.self_observation_filter = self_observation_filter
        self.transcript_quality_policy = transcript_quality_policy

    def build_for_date(self, db: Session, target_date: date | None = None) -> TimelineResponse:
        timeline_date = parse_date_or_today_kst(target_date)
        events = [
            event
            for event in self.event_repository.list(db, target_date=timeline_date, limit=1000)
            if event.source != "mac_active_window"
        ]
        memos = self.memo_repository.list(db, target_date=timeline_date, limit=1000)
        dev_events = self.dev_event_repository.list(db, target_date=timeline_date, limit=1000)
        screen_observations = [
            observation
            for observation in self.screen_observation_repository.list(
                db,
                target_date=timeline_date,
                limit=1000,
            )
            if not self._should_hide_screen_observation(db, observation)
        ]
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

        items = [self._event_to_item(event) for event in events]
        items.extend(self._dev_event_to_basic_item(event) for event in dev_events)
        items.extend(self._memo_to_item(memo) for memo in memos)
        items.extend(
            self._screen_observation_to_basic_item(item)
            for item in self._deduplicate_screen_observations(screen_observations)
        )
        for meeting in meetings:
            items.extend(self._meeting_to_items(meeting))
        items.extend(
            self._transcript_to_basic_item(transcript)
            for transcript in transcripts
            if self._should_show_basic_transcript(transcript)
        )
        items.sort(key=lambda item: item.timestamp)
        return TimelineResponse(date=timeline_date, items=items, total=len(items))

    def build_detail_for_date(
        self,
        db: Session,
        target_date: date | None = None,
    ) -> TimelineResponse:
        timeline_date = parse_date_or_today_kst(target_date)
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
        dev_events = self.dev_event_repository.list(db, target_date=timeline_date, limit=1000)
        screen_observations = [
            observation
            for observation in self.screen_observation_repository.list(
                db,
                target_date=timeline_date,
                limit=1000,
            )
            if not self.setting_service.is_private_app(db, observation.app_name)
        ]
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
        items.extend(self._dev_event_to_detail_item(event) for event in dev_events)
        items.extend(self._event_to_item(event) for event in events)
        items.extend(self._memo_to_item(memo) for memo in memos)
        items.extend(self._screen_observation_to_item(item) for item in screen_observations)
        for meeting in meetings:
            items.extend(self._meeting_to_items(meeting))
        items.extend(self._transcript_to_detail_item(transcript) for transcript in transcripts)
        items.sort(key=lambda item: item.timestamp)
        return TimelineResponse(date=timeline_date, items=items, total=len(items))

    def build_detail_for_kst_date(
        self,
        db: Session,
        target_date: date,
    ) -> TimelineResponse:
        utc_start, utc_end = get_kst_day_range_as_utc(target_date)
        utc_dates = {utc_start.date(), utc_end.date()}

        items_by_key: dict[tuple[str, int], TimelineItem] = {}
        for utc_date in utc_dates:
            timeline = self.build_detail_for_date(db, target_date=utc_date)
            for item in timeline.items:
                if self._item_overlaps_range(item, start=utc_start, end=utc_end):
                    items_by_key[(item.type, item.id)] = item

        items = sorted(items_by_key.values(), key=lambda item: item.timestamp)
        return TimelineResponse(date=target_date, items=items, total=len(items))

    def _item_overlaps_range(
        self,
        item: TimelineItem,
        *,
        start: datetime,
        end: datetime,
    ) -> bool:
        item_start = self._as_utc(item.timestamp)
        item_end = self._as_utc(item.ended_at) if item.ended_at else item_start
        return item_start < end and item_end >= start

    def _as_utc(self, value: datetime) -> datetime:
        return as_utc(value)

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
            f"{self._format_kst_clock(segment.started_at)}~"
            f"{self._format_kst_clock(segment.ended_at)}"
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

    def _dev_event_to_basic_item(self, event: DevEvent) -> TimelineItem:
        return TimelineItem(
            type="dev_event",
            id=event.id,
            timestamp=event.occurred_at,
            content=self._dev_event_basic_content(event),
            display_label=self._dev_event_display_label(event),
            source=event.source,
            event_type=event.event_type,
            session_id=event.session_id,
            repo_path=event.repo_path,
            branch=event.branch,
            command=event.command,
            status=event.status,
        )

    def _dev_event_to_detail_item(self, event: DevEvent) -> TimelineItem:
        details_summary = self._dev_event_details_summary(event.details_json)
        content = event.summary
        if details_summary:
            content = f"{content} | {details_summary}"
        return TimelineItem(
            type="dev_event",
            id=event.id,
            timestamp=event.occurred_at,
            content=self._truncate(content, 360),
            display_label=self._dev_event_display_label(event),
            source=event.source,
            event_type=event.event_type,
            session_id=event.session_id,
            repo_path=event.repo_path,
            branch=event.branch,
            command=event.command,
            status=event.status,
            details_json=self._compact_details(event.details_json),
        )

    def _dev_event_basic_content(self, event: DevEvent) -> str:
        if event.event_type == "git_snapshot":
            changed_files = self._details_list(event.details_json, "changed_files")
            file_text = ", ".join(changed_files[:5])
            suffix = f": {file_text}" if file_text else ""
            return f"Git 변경 파일 확인{suffix}"
        if event.event_type in {"test_result", "build_result"}:
            label = "테스트 실행 결과" if event.event_type == "test_result" else "빌드 실행 결과"
            return f"{label}: {event.summary}"
        if event.event_type == "command_result":
            return f"개발 명령 실행 결과: {event.summary}"
        return event.summary

    def _dev_event_display_label(self, event: DevEvent) -> str | None:
        if event.event_type != "git_snapshot":
            return None
        if (event.details_json or {}).get("tracking_mode") == "watch":
            return "자동 Git 변경 감지"
        return "수동 Git 상태 수집"

    def _dev_event_details_summary(self, details: dict | None) -> str:
        if not details:
            return ""
        parts: list[str] = []
        changed_files = self._details_list(details, "changed_files")
        recent_commits = self._details_list(details, "recent_commits")
        diff_stat = details.get("diff_stat")
        exit_code = details.get("exit_code")
        duration_seconds = details.get("duration_seconds")
        if changed_files:
            parts.append(f"changed_files={', '.join(changed_files[:8])}")
        if diff_stat:
            parts.append(f"diff_stat={self._truncate(str(diff_stat), 120)}")
        if recent_commits:
            parts.append(f"recent_commits={'; '.join(recent_commits[:3])}")
        if exit_code is not None:
            parts.append(f"exit_code={exit_code}")
        if duration_seconds is not None:
            parts.append(f"duration_seconds={duration_seconds}")
        return " | ".join(parts)

    def _details_list(self, details: dict | None, key: str) -> list[str]:
        if not details:
            return []
        value = details.get(key)
        if not isinstance(value, list):
            return []
        return [str(item) for item in value if item is not None]

    def _compact_details(self, details: dict | None) -> dict | None:
        if not details:
            return None
        compacted = dict(details)
        for key in ["changed_files", "recent_commits"]:
            if isinstance(compacted.get(key), list):
                compacted[key] = compacted[key][:10]
        if "diff_stat" in compacted:
            compacted["diff_stat"] = self._truncate(str(compacted["diff_stat"]), 240)
        return compacted

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
            content=observation.ai_inference
            or self._ocr_excerpt(observation.ocr_text)
            or "화면 텍스트 수집됨",
            app_name=observation.app_name,
            window_title=observation.window_title,
            detected_keywords=observation.detected_keywords,
            ocr_text=self._ocr_excerpt(observation.ocr_text, limit=240),
            ai_inference=observation.ai_inference,
            frame_hash=observation.frame_hash,
            session_id=observation.session_id,
        )

    def _screen_observation_to_basic_item(self, observation: ScreenObservation) -> TimelineItem:
        content = observation.ai_inference or "화면 텍스트 수집됨"
        return TimelineItem(
            type="screen_ocr",
            id=observation.id,
            timestamp=observation.timestamp,
            content=content,
            app_name=observation.app_name,
            window_title=observation.window_title,
            detected_keywords=observation.detected_keywords,
            ai_inference=observation.ai_inference,
            frame_hash=observation.frame_hash,
            session_id=observation.session_id,
        )

    def _deduplicate_screen_observations(
        self,
        observations: list[ScreenObservation],
    ) -> list[ScreenObservation]:
        deduplicated: list[ScreenObservation] = []
        last_seen_by_key: dict[tuple[str | None, str | None, str], datetime] = {}
        for observation in sorted(observations, key=lambda item: item.timestamp):
            content = observation.ai_inference or "화면 텍스트 수집됨"
            key = (observation.app_name, observation.window_title, content)
            last_seen_at = last_seen_by_key.get(key)
            if last_seen_at is not None:
                elapsed_seconds = (
                    self._as_aware_utc(observation.timestamp) - self._as_aware_utc(last_seen_at)
                ).total_seconds()
                if elapsed_seconds < 600:
                    continue
            last_seen_by_key[key] = observation.timestamp
            deduplicated.append(observation)
        return deduplicated

    def _is_self_service_observation(self, observation: ScreenObservation) -> bool:
        values = [
            observation.app_name,
            observation.window_title,
            observation.ocr_text,
            observation.ai_inference,
        ]
        return self.self_observation_filter.is_self_service_values(values)

    def _should_hide_screen_observation(
        self,
        db: Session,
        observation: ScreenObservation,
    ) -> bool:
        return self.setting_service.is_private_app(
            db,
            observation.app_name,
        ) or self._is_self_service_observation(observation)

    def _ocr_excerpt(self, text: str | None, limit: int = 160) -> str:
        if not text:
            return ""
        excerpt = " ".join(text.split())
        if len(excerpt) <= limit:
            return excerpt
        return excerpt[:limit].rstrip() + "..."

    def _truncate(self, text: str, limit: int) -> str:
        if len(text) <= limit:
            return text
        return text[:limit].rstrip() + "..."

    def _as_aware_utc(self, value: datetime) -> datetime:
        return as_utc(value)

    def _format_kst_clock(self, value: datetime) -> str:
        return format_datetime_kst(value, "%H:%M:%S")

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

    def _transcript_to_basic_item(self, transcript: VoiceTranscript) -> TimelineItem:
        excerpt = self._transcript_excerpt(transcript.text, limit=80)
        content = "회의 전사 수집됨"
        if excerpt:
            content = f"{content}: {excerpt}"
        return TimelineItem(
            type="transcript",
            id=transcript.id,
            timestamp=transcript.timestamp,
            content=content,
            source=transcript.source,
            meeting_id=transcript.meeting_id,
            speaker=transcript.speaker,
            confidence=transcript.confidence,
        )

    def _transcript_to_detail_item(self, transcript: VoiceTranscript) -> TimelineItem:
        return TimelineItem(
            type="transcript",
            id=transcript.id,
            timestamp=transcript.timestamp,
            content=self._transcript_excerpt(transcript.text, limit=240),
            source=transcript.source,
            meeting_id=transcript.meeting_id,
            speaker=transcript.speaker,
            confidence=transcript.confidence,
        )

    def _transcript_excerpt(self, text: str, limit: int) -> str:
        return self._truncate(" ".join(text.split()), limit)

    def _should_show_basic_transcript(self, transcript: VoiceTranscript) -> bool:
        return self.transcript_quality_policy.is_meaningful_for_report(transcript.text)


def get_timeline_builder() -> TimelineBuilder:
    return TimelineBuilder(
        activity_segment_repository=ActivitySegmentRepository(),
        dev_event_repository=DevEventRepository(),
        event_repository=WorkEventRepository(),
        memo_repository=MemoRepository(),
        screen_observation_repository=ScreenObservationRepository(),
        meeting_repository=MeetingRepository(),
        setting_service=get_setting_service(),
        self_observation_filter=get_self_observation_filter(),
        transcript_quality_policy=get_transcript_quality_policy(),
    )

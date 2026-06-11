from dataclasses import dataclass
from datetime import date, datetime

from sqlalchemy import Select, delete, func, or_, select
from sqlalchemy.orm import Session

from app.core.timezone import get_kst_day_range_as_utc, parse_date_or_today_kst
from app.models.activity_segment import ActivitySegment
from app.models.dev_event import DevEvent
from app.models.manual_memo import ManualMemo
from app.models.meeting_session import MeetingSession
from app.models.report import Report
from app.models.screen_observation import ScreenObservation
from app.models.voice_transcript import VoiceTranscript
from app.models.work_event import WorkEvent

TARGET_LABELS = {
    "reports": "reports",
    "dev_events": "dev_events",
    "voice_transcripts": "voice_transcripts",
    "meeting_sessions": "meeting_sessions",
    "screen_observations": "screen_observations",
    "activity_segments": "activity_segments",
    "work_events": "work_events",
    "manual_memos": "manual_memos",
}
DEFAULT_TARGETS = tuple(TARGET_LABELS)


@dataclass(frozen=True)
class ResetDevDataOptions:
    today: bool = False
    all_data: bool = False
    except_today: bool = False
    reports_only: bool = False
    dev_events_only: bool = False
    transcripts_only: bool = False
    meetings_only: bool = False
    observations_only: bool = False
    activity_only: bool = False
    memos_only: bool = False
    events_only: bool = False
    yes: bool = False
    target_date: date | None = None


@dataclass(frozen=True)
class ResetDevDataResult:
    counts: dict[str, int]
    deleted: bool
    scope_label: str


class DevDataResetService:
    def reset(self, db: Session, options: ResetDevDataOptions) -> ResetDevDataResult:
        selected_scopes = [options.today, options.all_data, options.except_today]
        if sum(1 for selected in selected_scopes if selected) > 1:
            raise ValueError("--today, --all, and --except-today cannot be used together.")

        targets = self._resolve_targets(options)
        if not targets:
            return ResetDevDataResult(counts={}, deleted=False, scope_label="none")

        target_date = parse_date_or_today_kst(options.target_date)
        scope = self._resolve_scope(options, target_date=target_date)
        counts = {target: self._count_target(db, target=target, scope=scope) for target in targets}

        if not options.yes:
            return ResetDevDataResult(counts=counts, deleted=False, scope_label=scope.label)

        for target in targets:
            self._delete_target(db, target=target, scope=scope)
        db.commit()
        return ResetDevDataResult(counts=counts, deleted=True, scope_label=scope.label)

    def _resolve_targets(self, options: ResetDevDataOptions) -> list[str]:
        selected: list[str] = []
        if options.reports_only:
            selected.append("reports")
        if options.dev_events_only:
            selected.append("dev_events")
        if options.transcripts_only:
            selected.append("voice_transcripts")
        if options.meetings_only:
            selected.append("meeting_sessions")
        if options.observations_only:
            selected.append("screen_observations")
        if options.activity_only:
            selected.append("activity_segments")
        if options.events_only:
            selected.append("work_events")
        if options.memos_only:
            selected.append("manual_memos")

        if selected:
            return selected
        if options.today or options.all_data or options.except_today:
            return list(DEFAULT_TARGETS)
        return []

    def _resolve_scope(self, options: ResetDevDataOptions, *, target_date: date) -> "_DeleteScope":
        if options.today or options.except_today:
            start, end = get_kst_day_range_as_utc(target_date)
            if options.except_today:
                return _DeleteScope(
                    label=f"except-today:{target_date.isoformat()} KST",
                    start=start,
                    end=end,
                    report_date=target_date,
                    except_today=True,
                )
            return _DeleteScope(
                label=f"today:{target_date.isoformat()} KST",
                start=start,
                end=end,
                report_date=target_date,
            )
        return _DeleteScope(label="all")

    def _count_target(self, db: Session, *, target: str, scope: "_DeleteScope") -> int:
        statement = self._select_target(target, scope=scope)
        return db.scalar(select(func.count()).select_from(statement.subquery())) or 0

    def _delete_target(self, db: Session, *, target: str, scope: "_DeleteScope") -> None:
        if target == "meeting_sessions":
            self._delete_meeting_sessions(db, scope=scope)
            return

        model, conditions = self._target_model_and_conditions(target, scope=scope)
        statement = delete(model)
        for condition in conditions:
            statement = statement.where(condition)
        db.execute(statement)

    def _select_target(self, target: str, *, scope: "_DeleteScope") -> Select:
        model, conditions = self._target_model_and_conditions(target, scope=scope)
        statement = select(model)
        for condition in conditions:
            statement = statement.where(condition)
        return statement

    def _target_model_and_conditions(self, target: str, *, scope: "_DeleteScope"):
        if target == "reports":
            conditions = []
            if scope.report_date is not None:
                if scope.except_today:
                    conditions.append(Report.date != scope.report_date)
                else:
                    conditions.append(Report.date == scope.report_date)
            return Report, conditions
        if target == "dev_events":
            return DevEvent, self._timestamp_conditions(DevEvent.occurred_at, scope=scope)
        if target == "voice_transcripts":
            return VoiceTranscript, self._timestamp_conditions(
                VoiceTranscript.timestamp,
                scope=scope,
            )
        if target == "meeting_sessions":
            return MeetingSession, self._timestamp_conditions(
                MeetingSession.started_at,
                scope=scope,
            )
        if target == "screen_observations":
            return ScreenObservation, self._timestamp_conditions(
                ScreenObservation.timestamp,
                scope=scope,
            )
        if target == "activity_segments":
            if scope.start is None or scope.end is None:
                return ActivitySegment, []
            if scope.except_today:
                return ActivitySegment, [
                    or_(
                        ActivitySegment.ended_at < scope.start,
                        ActivitySegment.started_at >= scope.end,
                    )
                ]
            return ActivitySegment, [
                ActivitySegment.started_at < scope.end,
                ActivitySegment.ended_at >= scope.start,
            ]
        if target == "work_events":
            return WorkEvent, self._timestamp_conditions(WorkEvent.timestamp, scope=scope)
        if target == "manual_memos":
            return ManualMemo, self._timestamp_conditions(ManualMemo.timestamp, scope=scope)
        raise ValueError(f"Unknown reset target: {target}")

    def _timestamp_conditions(self, column, *, scope: "_DeleteScope") -> list:
        if scope.start is None or scope.end is None:
            return []
        if scope.except_today:
            return [or_(column < scope.start, column >= scope.end)]
        return [column >= scope.start, column < scope.end]

    def _delete_meeting_sessions(self, db: Session, *, scope: "_DeleteScope") -> None:
        _, conditions = self._target_model_and_conditions("meeting_sessions", scope=scope)
        meeting_ids = select(MeetingSession.id)
        for condition in conditions:
            meeting_ids = meeting_ids.where(condition)

        db.execute(delete(VoiceTranscript).where(VoiceTranscript.meeting_id.in_(meeting_ids)))

        statement = delete(MeetingSession)
        for condition in conditions:
            statement = statement.where(condition)
        db.execute(statement)


@dataclass(frozen=True)
class _DeleteScope:
    label: str
    start: datetime | None = None
    end: datetime | None = None
    report_date: date | None = None
    except_today: bool = False


def get_dev_data_reset_service() -> DevDataResetService:
    return DevDataResetService()

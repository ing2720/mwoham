from datetime import date
from typing import Any

from sqlalchemy.orm import Session

from app.services.event_service import EventService, get_event_service
from app.services.memo_service import MemoService, get_memo_service
from app.services.status_service import StatusService, get_status_service


class WebDashboardService:
    def __init__(
        self,
        status_service: StatusService,
        event_service: EventService,
        memo_service: MemoService,
    ) -> None:
        self.status_service = status_service
        self.event_service = event_service
        self.memo_service = memo_service

    def get_dashboard_context(self, db: Session) -> dict[str, Any]:
        return {
            "status": self.status_service.get_status(db),
            "events": self.event_service.list(db, limit=8).items,
            "memos": self.memo_service.list(db, limit=8).items,
        }

    def get_timeline_context(self, db: Session, target_date: date | None = None) -> dict[str, Any]:
        events = self.event_service.list(db, target_date=target_date, limit=200).items
        memos = self.memo_service.list(db, target_date=target_date, limit=200).items
        items = [
            {"kind": "event", "timestamp": event.timestamp, "item": event}
            for event in events
        ] + [{"kind": "memo", "timestamp": memo.timestamp, "item": memo} for memo in memos]

        return {
            "target_date": target_date,
            "items": sorted(items, key=lambda item: item["timestamp"], reverse=True),
        }


def get_web_dashboard_service() -> WebDashboardService:
    return WebDashboardService(
        status_service=get_status_service(),
        event_service=get_event_service(),
        memo_service=get_memo_service(),
    )

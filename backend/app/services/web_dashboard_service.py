from datetime import date
from typing import Any

from sqlalchemy.orm import Session

from app.services.status_service import StatusService, get_status_service
from app.services.timeline_builder import TimelineBuilder, get_timeline_builder


class WebDashboardService:
    def __init__(
        self,
        status_service: StatusService,
        timeline_builder: TimelineBuilder,
    ) -> None:
        self.status_service = status_service
        self.timeline_builder = timeline_builder

    def get_dashboard_context(self, db: Session) -> dict[str, Any]:
        timeline = self.timeline_builder.build_for_date(db)
        return {
            "status": self.status_service.get_status(db),
            "timeline": timeline,
            "recent_items": timeline.items[-8:],
        }

    def get_timeline_context(self, db: Session, target_date: date | None = None) -> dict[str, Any]:
        return {
            "timeline": self.timeline_builder.build_for_date(db, target_date=target_date),
            "is_detail": False,
        }

    def get_detail_timeline_context(
        self,
        db: Session,
        target_date: date | None = None,
    ) -> dict[str, Any]:
        return {
            "timeline": self.timeline_builder.build_detail_for_date(
                db,
                target_date=target_date,
            ),
            "is_detail": True,
        }


def get_web_dashboard_service() -> WebDashboardService:
    return WebDashboardService(
        status_service=get_status_service(),
        timeline_builder=get_timeline_builder(),
    )

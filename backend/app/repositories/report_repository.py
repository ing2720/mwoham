from datetime import date

from sqlalchemy import Select, func, select
from sqlalchemy.orm import Session

from app.models.report import Report


class ReportRepository:
    def create(self, db: Session, report: Report) -> Report:
        db.add(report)
        db.commit()
        db.refresh(report)
        return report

    def get_by_id(self, db: Session, report_id: int) -> Report | None:
        return db.get(Report, report_id)

    def get_latest_by_identity(
        self,
        db: Session,
        *,
        target_date: date,
        mode: str,
        project_id: int | None,
    ) -> Report | None:
        statement = select(Report).where(
            Report.date == target_date,
            Report.mode == mode,
        )
        if project_id is None:
            statement = statement.where(Report.project_id.is_(None))
        else:
            statement = statement.where(Report.project_id == project_id)
        statement = statement.order_by(
            Report.updated_at.desc(),
            Report.created_at.desc(),
            Report.id.desc(),
        )
        return db.scalars(statement.limit(1)).first()

    def list(
        self,
        db: Session,
        *,
        target_date: date | None = None,
        mode: str | None = None,
        limit: int = 100,
    ) -> list[Report]:
        statement = self._filtered_select(target_date=target_date, mode=mode)
        statement = statement.order_by(
            Report.updated_at.desc(),
            Report.created_at.desc(),
            Report.id.desc(),
        ).limit(limit)
        return list(db.scalars(statement))

    def count(
        self,
        db: Session,
        *,
        target_date: date | None = None,
        mode: str | None = None,
    ) -> int:
        filtered = self._filtered_select(target_date=target_date, mode=mode).subquery()
        return db.scalar(select(func.count()).select_from(filtered)) or 0

    def update(self, db: Session, report: Report) -> Report:
        db.add(report)
        db.commit()
        db.refresh(report)
        return report

    def _filtered_select(
        self,
        *,
        target_date: date | None,
        mode: str | None,
    ) -> Select[tuple[Report]]:
        statement = select(Report)
        if target_date is not None:
            statement = statement.where(Report.date == target_date)
        if mode is not None:
            statement = statement.where(Report.mode == mode)
        return statement

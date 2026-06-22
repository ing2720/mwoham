from sqlalchemy import inspect, select
from sqlalchemy.orm import Session


class HealthRepository:
    REQUIRED_TABLES = {
        "work_sessions",
        "work_events",
        "manual_memos",
        "reports",
    }

    def can_connect(self, db: Session) -> bool:
        db.execute(select(1)).scalar_one()
        return True

    def has_required_tables(self, db: Session) -> bool:
        table_names = set(inspect(db.bind).get_table_names())
        return self.REQUIRED_TABLES.issubset(table_names)

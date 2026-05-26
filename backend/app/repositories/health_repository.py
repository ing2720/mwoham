from sqlalchemy import select
from sqlalchemy.orm import Session


class HealthRepository:
    def can_connect(self, db: Session) -> bool:
        db.execute(select(1)).scalar_one()
        return True

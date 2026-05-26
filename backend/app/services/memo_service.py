from datetime import date

from sqlalchemy.orm import Session

from app.repositories.memo_repository import MemoRepository
from app.repositories.work_session_repository import WorkSessionRepository
from app.schemas.memo import MemoCreate, MemoListResponse, MemoResponse


class MemoService:
    def __init__(
        self,
        memo_repository: MemoRepository,
        session_repository: WorkSessionRepository,
    ) -> None:
        self.memo_repository = memo_repository
        self.session_repository = session_repository

    def create(self, db: Session, request: MemoCreate) -> MemoResponse:
        session_id = request.session_id
        if session_id is None:
            session = self.session_repository.get_current(db)
            session_id = session.id if session is not None else None

        memo = self.memo_repository.create(db, memo_in=request, session_id=session_id)
        return MemoResponse.model_validate(memo)

    def list(
        self,
        db: Session,
        *,
        session_id: int | None = None,
        target_date: date | None = None,
        limit: int = 100,
    ) -> MemoListResponse:
        items = self.memo_repository.list(
            db,
            session_id=session_id,
            target_date=target_date,
            limit=limit,
        )
        total = self.memo_repository.count(db, session_id=session_id, target_date=target_date)
        return MemoListResponse(items=items, total=total)


def get_memo_service() -> MemoService:
    return MemoService(
        memo_repository=MemoRepository(),
        session_repository=WorkSessionRepository(),
    )

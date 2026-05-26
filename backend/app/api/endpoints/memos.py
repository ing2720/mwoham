from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.schemas.memo import MemoCreate, MemoListResponse, MemoResponse
from app.services.memo_service import MemoService, get_memo_service

router = APIRouter(prefix="/memos", tags=["memos"])


@router.post("", response_model=MemoResponse, status_code=status.HTTP_201_CREATED)
def create_memo(
    request: MemoCreate,
    db: Session = Depends(get_db),
    service: MemoService = Depends(get_memo_service),
) -> MemoResponse:
    return service.create(db, request)


@router.get("", response_model=MemoListResponse)
def list_memos(
    session_id: int | None = None,
    target_date: Annotated[date | None, Query(alias="date")] = None,
    limit: Annotated[int, Query(ge=1, le=1000)] = 100,
    db: Session = Depends(get_db),
    service: MemoService = Depends(get_memo_service),
) -> MemoListResponse:
    return service.list(db, session_id=session_id, target_date=target_date, limit=limit)

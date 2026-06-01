from datetime import date
from typing import Annotated

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.schemas.timeline import TimelineResponse
from app.services.timeline_builder import TimelineBuilder, get_timeline_builder

router = APIRouter(prefix="/timeline", tags=["timeline"])


@router.get("/today", response_model=TimelineResponse)
def get_today_timeline(
    target_date: Annotated[date | None, Query(alias="date")] = None,
    db: Session = Depends(get_db),
    builder: TimelineBuilder = Depends(get_timeline_builder),
) -> TimelineResponse:
    return builder.build_for_date(db, target_date=target_date)


@router.get("/today/detail", response_model=TimelineResponse)
def get_detail_timeline(
    target_date: Annotated[date | None, Query(alias="date")] = None,
    db: Session = Depends(get_db),
    builder: TimelineBuilder = Depends(get_timeline_builder),
) -> TimelineResponse:
    return builder.build_detail_for_date(db, target_date=target_date)

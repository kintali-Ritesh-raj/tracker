"""Reports and runtime settings."""
from __future__ import annotations

from datetime import date

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from ..db import get_db
from ..schemas import AttendanceRow, SettingsOut, SiteVisitRow
from ..security import current_device, require_admin
from ..services import reports, runtime_settings

router = APIRouter(tags=["admin"])

# Offset of the reporting day from UTC in minutes; IST (+05:30) by default.
_TZ = Query(default=330, ge=-720, le=840)


@router.get("/reports/attendance", response_model=list[AttendanceRow], dependencies=[Depends(require_admin)])
def attendance(day: date = Query(alias="date"), tz_offset: int = _TZ, db: Session = Depends(get_db)) -> list[AttendanceRow]:
    return reports.attendance(db, day, tz_offset)


@router.get("/reports/site-visits", response_model=list[SiteVisitRow], dependencies=[Depends(require_admin)])
def site_visits(day: date = Query(alias="date"), tz_offset: int = _TZ, db: Session = Depends(get_db)) -> list[SiteVisitRow]:
    return reports.site_visits(db, day, tz_offset)


# Employees read settings too: the phone uses the tracking interval and distance filter.
@router.get("/settings", response_model=SettingsOut, dependencies=[Depends(current_device)])
def get_settings(db: Session = Depends(get_db)) -> SettingsOut:
    return runtime_settings.load(db)


@router.put("/settings", response_model=SettingsOut, dependencies=[Depends(require_admin)])
def put_settings(body: SettingsOut, db: Session = Depends(get_db)) -> SettingsOut:
    return runtime_settings.save(db, body)

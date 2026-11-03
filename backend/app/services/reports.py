"""Attendance and site-visit reports derived from stored fixes."""
from __future__ import annotations

from datetime import date, datetime, time, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from ..models import Employee, LocationUpdate
from ..schemas import AttendanceRow, SiteVisitRow

# A gap longer than this between two fixes at the same site splits the visit.
VISIT_GAP = timedelta(minutes=20)


def _day_bounds(day: date, tz_offset_minutes: int) -> tuple[datetime, datetime]:
    tz = timezone(timedelta(minutes=tz_offset_minutes))
    start = datetime.combine(day, time.min, tzinfo=tz)
    return start, start + timedelta(days=1)


def _fixes(db: Session, day: date, tz_offset_minutes: int) -> list[LocationUpdate]:
    start, end = _day_bounds(day, tz_offset_minutes)
    return list(
        db.scalars(
            select(LocationUpdate)
            .options(selectinload(LocationUpdate.site))
            .where(LocationUpdate.recorded_at >= start, LocationUpdate.recorded_at < end)
            .order_by(LocationUpdate.employee_id, LocationUpdate.recorded_at)
        )
    )


def _visits(fixes: list[LocationUpdate]) -> list[tuple[LocationUpdate, LocationUpdate]]:
    """Group consecutive same-site fixes into (first, last) pairs."""
    visits: list[tuple[LocationUpdate, LocationUpdate]] = []
    first = last = None
    for fix in fixes:
        same = (
            first is not None
            and fix.site_id == first.site_id
            and fix.recorded_at - last.recorded_at <= VISIT_GAP
        )
        if same:
            last = fix
            continue
        if first is not None and first.site_id is not None:
            visits.append((first, last))
        first = last = fix
    if first is not None and first.site_id is not None:
        visits.append((first, last))
    return visits


def site_visits(db: Session, day: date, tz_offset_minutes: int = 330) -> list[SiteVisitRow]:
    fixes = _fixes(db, day, tz_offset_minutes)
    employees = {e.id: e for e in db.scalars(select(Employee))}
    by_employee: dict[int, list[LocationUpdate]] = {}
    for fix in fixes:
        by_employee.setdefault(fix.employee_id, []).append(fix)
    rows: list[SiteVisitRow] = []
    for employee_id, items in by_employee.items():
        for first, last in _visits(items):
            rows.append(
                SiteVisitRow(
                    site_id=first.site_id,
                    site_name=first.site.name if first.site else "Site",
                    employee_id=employee_id,
                    employee_name=employees[employee_id].full_name if employee_id in employees else "",
                    arrived_at=first.recorded_at,
                    left_at=last.recorded_at,
                    minutes=int((last.recorded_at - first.recorded_at).total_seconds() // 60),
                )
            )
    rows.sort(key=lambda r: r.arrived_at)
    return rows


def attendance(db: Session, day: date, tz_offset_minutes: int = 330) -> list[AttendanceRow]:
    fixes = _fixes(db, day, tz_offset_minutes)
    by_employee: dict[int, list[LocationUpdate]] = {}
    for fix in fixes:
        by_employee.setdefault(fix.employee_id, []).append(fix)
    employees = db.scalars(
        select(Employee).options(selectinload(Employee.team)).where(Employee.active.is_(True)).order_by(Employee.full_name)
    ).all()
    rows = []
    for employee in employees:
        items = by_employee.get(employee.id, [])
        visits = _visits(items)
        rows.append(
            AttendanceRow(
                employee_id=employee.id,
                employee_name=employee.full_name,
                team_name=employee.team.name if employee.team else None,
                first_seen=items[0].recorded_at if items else None,
                last_seen=items[-1].recorded_at if items else None,
                on_site_minutes=sum(int((b.recorded_at - a.recorded_at).total_seconds() // 60) for a, b in visits),
                fixes=len(items),
                sites=sorted({a.site.name for a, _ in visits if a.site}),
            )
        )
    return rows

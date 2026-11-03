"""Builds employee views (summary/detail) with their latest real fix and status."""
from __future__ import annotations

from collections import defaultdict
from datetime import datetime

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from ..models import Device, Employee, EmployeeStatus, LocationUpdate, utcnow
from ..schemas import DeviceOut, EmployeeDetail, EmployeeSummary, LocationOut, PermissionOut
from . import runtime_settings
from .status import compute_status


def location_out(update: LocationUpdate | None) -> LocationOut | None:
    if update is None:
        return None
    out = LocationOut.model_validate(update)
    out.site_name = update.site.name if update.site is not None else None
    return out


def device_out(device: Device) -> DeviceOut:
    out = DeviceOut.model_validate(device)
    out.has_push = bool(device.push_token)
    return out


def latest_locations(db: Session, employee_ids: list[int]) -> dict[int, LocationUpdate]:
    """Latest fix per employee using PostgreSQL DISTINCT ON."""
    if not employee_ids:
        return {}
    rows = db.scalars(
        select(LocationUpdate)
        .options(selectinload(LocationUpdate.site))
        .where(LocationUpdate.employee_id.in_(employee_ids))
        .order_by(LocationUpdate.employee_id, LocationUpdate.recorded_at.desc(), LocationUpdate.id.desc())
        .distinct(LocationUpdate.employee_id)
    ).all()
    return {row.employee_id: row for row in rows}


def _photo_version(employee: Employee) -> int:
    # Path embeds a timestamp; used by clients as a cache buster.
    if not employee.photo_path:
        return 0
    stem = employee.photo_path.rsplit("/", 1)[-1].split(".", 1)[0]
    return int(stem.rsplit("_", 1)[-1]) if "_" in stem and stem.rsplit("_", 1)[-1].isdigit() else 1


def _summary(
    employee: Employee,
    latest: LocationUpdate | None,
    now: datetime,
    offline_after: int,
) -> EmployeeSummary:
    permission = employee.permission
    status = compute_status(latest, permission, employee.devices, now, offline_after)
    return EmployeeSummary(
        id=employee.id,
        employee_code=employee.employee_code,
        full_name=employee.full_name,
        phone=employee.phone,
        role_title=employee.role_title,
        team_id=employee.team_id,
        team_name=employee.team.name if employee.team else None,
        team_color=employee.team.color if employee.team else None,
        has_photo=bool(employee.photo_path),
        photo_version=_photo_version(employee),
        active=employee.active,
        status=status,
        sharing_enabled=bool(permission and permission.sharing_enabled),
        device_paired=any(d.revoked_at is None for d in employee.devices),
        last_location=location_out(latest),
    )


def _query():
    return select(Employee).options(
        selectinload(Employee.team),
        selectinload(Employee.permission),
        selectinload(Employee.devices),
    )


def list_summaries(
    db: Session,
    *,
    team_id: int | None = None,
    status: EmployeeStatus | None = None,
    q: str | None = None,
    include_inactive: bool = False,
) -> list[EmployeeSummary]:
    stmt = _query().order_by(Employee.full_name)
    if not include_inactive:
        stmt = stmt.where(Employee.active.is_(True))
    if team_id is not None:
        stmt = stmt.where(Employee.team_id == team_id)
    if q:
        like = f"%{q.strip()}%"
        stmt = stmt.where(Employee.full_name.ilike(like) | Employee.employee_code.ilike(like))
    employees = db.scalars(stmt).all()
    latest = latest_locations(db, [e.id for e in employees])
    offline_after = runtime_settings.load(db).offline_after_minutes
    now = utcnow()
    summaries = [_summary(e, latest.get(e.id), now, offline_after) for e in employees]
    if status is not None:
        summaries = [s for s in summaries if s.status == status]
    return summaries


def summary(db: Session, employee: Employee) -> EmployeeSummary:
    latest = latest_locations(db, [employee.id]).get(employee.id)
    return _summary(employee, latest, utcnow(), runtime_settings.load(db).offline_after_minutes)


def get_employee(db: Session, employee_id: int) -> Employee | None:
    return db.scalar(_query().where(Employee.id == employee_id))


def detail(db: Session, employee: Employee) -> EmployeeDetail:
    base = summary(db, employee)
    permission = employee.permission
    return EmployeeDetail(
        **base.model_dump(),
        permission=PermissionOut.model_validate(permission) if permission else None,
        devices=[device_out(d) for d in sorted(employee.devices, key=lambda d: d.created_at, reverse=True)],
        history_enabled=bool(permission and permission.history_enabled),
    )


def count_by_status(summaries: list[EmployeeSummary]) -> dict[str, int]:
    counts: dict[str, int] = defaultdict(int)
    for s in summaries:
        counts[s.status.value] += 1
    return counts

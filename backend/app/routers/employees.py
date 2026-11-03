"""Employee management, photos, history, dashboard and live-map feed."""
from __future__ import annotations

import time
from datetime import datetime, timedelta

from fastapi import APIRouter, Depends, File, HTTPException, Query, Response, UploadFile, status
from fastapi.responses import FileResponse
from sqlalchemy import func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session, selectinload

from ..config import settings
from ..db import get_db
from ..models import (
    Employee,
    EmployeeStatus,
    LocationRequest,
    LocationUpdate,
    RequestStatus,
    Team,
    utcnow,
)
from ..realtime import ADMINS, hub
from ..schemas import (
    DashboardOut,
    EmployeeDetail,
    EmployeeIn,
    EmployeePatch,
    EmployeeSummary,
    LocationOut,
    StatusCounts,
    TeamStatus,
)
from ..security import current_device, require_admin
from ..services import directory

router = APIRouter(tags=["employees"])

_PHOTO_TYPES = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}
_MAX_PHOTO_BYTES = 3 * 1024 * 1024


def _get_or_404(db: Session, employee_id: int) -> Employee:
    employee = directory.get_employee(db, employee_id)
    if employee is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Employee not found.")
    return employee


def _check_team(db: Session, team_id: int | None) -> None:
    if team_id is not None and db.get(Team, team_id) is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Team does not exist.")


@router.get("/employees", response_model=list[EmployeeSummary], dependencies=[Depends(require_admin)])
def list_employees(
    team_id: int | None = None,
    status_filter: EmployeeStatus | None = Query(default=None, alias="status"),
    q: str | None = None,
    include_inactive: bool = False,
    db: Session = Depends(get_db),
) -> list[EmployeeSummary]:
    return directory.list_summaries(db, team_id=team_id, status=status_filter, q=q, include_inactive=include_inactive)


@router.post("/employees", response_model=EmployeeDetail, status_code=201, dependencies=[Depends(require_admin)])
def create_employee(body: EmployeeIn, db: Session = Depends(get_db)) -> EmployeeDetail:
    _check_team(db, body.team_id)
    employee = Employee(**body.model_dump())
    db.add(employee)
    try:
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "Another employee already uses this employee ID.") from exc
    return directory.detail(db, _get_or_404(db, employee.id))


@router.get("/employees/{employee_id}", response_model=EmployeeDetail, dependencies=[Depends(require_admin)])
def get_employee(employee_id: int, db: Session = Depends(get_db)) -> EmployeeDetail:
    return directory.detail(db, _get_or_404(db, employee_id))


@router.patch("/employees/{employee_id}", response_model=EmployeeDetail, dependencies=[Depends(require_admin)])
def update_employee(employee_id: int, body: EmployeePatch, db: Session = Depends(get_db)) -> EmployeeDetail:
    employee = _get_or_404(db, employee_id)
    changes = body.model_dump(exclude_unset=True)
    if "team_id" in changes:
        _check_team(db, changes["team_id"])
    for key, value in changes.items():
        setattr(employee, key, value)
    if changes.get("active") is False:
        for device in employee.devices:
            if device.revoked_at is None:
                device.revoked_at = utcnow()
                hub.publish_close(device.id)
    try:
        db.commit()
    except IntegrityError as exc:
        db.rollback()
        raise HTTPException(status.HTTP_409_CONFLICT, "Another employee already uses this employee ID.") from exc
    out = directory.detail(db, _get_or_404(db, employee_id))
    hub.publish([ADMINS], "employee.status", out.model_dump(mode="json", include=set(EmployeeSummary.model_fields)))
    return out


@router.delete("/employees/{employee_id}", status_code=204, response_class=Response, response_model=None, dependencies=[Depends(require_admin)])
def delete_employee(employee_id: int, db: Session = Depends(get_db)) -> None:
    """Hard delete: removes the employee and their location history."""
    employee = _get_or_404(db, employee_id)
    device_ids = [d.id for d in employee.devices]
    db.delete(employee)
    db.commit()
    for device_id in device_ids:
        hub.publish_close(device_id)
    hub.publish([ADMINS], "employee.deleted", {"id": employee_id})


@router.post("/employees/{employee_id}/photo", response_model=EmployeeDetail, dependencies=[Depends(require_admin)])
async def upload_photo(employee_id: int, file: UploadFile = File(...), db: Session = Depends(get_db)) -> EmployeeDetail:
    employee = _get_or_404(db, employee_id)
    ext = _PHOTO_TYPES.get(file.content_type or "")
    if ext is None:
        raise HTTPException(status.HTTP_415_UNSUPPORTED_MEDIA_TYPE, "Upload a JPEG, PNG or WebP image.")
    data = await file.read(_MAX_PHOTO_BYTES + 1)
    if len(data) > _MAX_PHOTO_BYTES:
        raise HTTPException(status.HTTP_413_REQUEST_ENTITY_TOO_LARGE, "Photos must be 3 MB or smaller.")
    settings.upload_dir.mkdir(parents=True, exist_ok=True)
    name = f"employee_{employee.id}_{int(time.time())}.{ext}"
    (settings.upload_dir / name).write_bytes(data)
    if employee.photo_path:
        (settings.upload_dir / employee.photo_path).unlink(missing_ok=True)
    employee.photo_path = name
    db.commit()
    return directory.detail(db, _get_or_404(db, employee_id))


@router.get("/employees/{employee_id}/photo", dependencies=[Depends(current_device)])
def get_photo(employee_id: int, db: Session = Depends(get_db)) -> FileResponse:
    employee = db.get(Employee, employee_id)
    if employee is None or not employee.photo_path:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No photo.")
    path = settings.upload_dir / employee.photo_path
    if not path.exists():
        raise HTTPException(status.HTTP_404_NOT_FOUND, "No photo.")
    return FileResponse(path, headers={"Cache-Control": "private, max-age=86400"})


@router.get("/employees/{employee_id}/history", response_model=list[LocationOut], dependencies=[Depends(require_admin)])
def history(
    employee_id: int,
    start: datetime | None = Query(default=None, alias="from"),
    end: datetime | None = Query(default=None, alias="to"),
    limit: int = Query(default=500, ge=1, le=5000),
    db: Session = Depends(get_db),
) -> list[LocationOut]:
    employee = _get_or_404(db, employee_id)
    if employee.permission is None or not employee.permission.history_enabled:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "This employee has not enabled location history.")
    end = end or utcnow()
    start = start or end - timedelta(hours=24)
    rows = db.scalars(
        select(LocationUpdate)
        .options(selectinload(LocationUpdate.site))
        .where(
            LocationUpdate.employee_id == employee_id,
            LocationUpdate.recorded_at >= start,
            LocationUpdate.recorded_at <= end,
        )
        .order_by(LocationUpdate.recorded_at)
        .limit(limit)
    ).all()
    return [directory.location_out(r) for r in rows]


def _counts(items: list[EmployeeSummary]) -> StatusCounts:
    c = directory.count_by_status(items)
    return StatusCounts(
        total=len(items),
        on_site=c.get("on_site", 0),
        in_transit=c.get("in_transit", 0),
        offline=c.get("offline", 0),
    )


@router.get("/dashboard", response_model=DashboardOut, dependencies=[Depends(require_admin)])
def dashboard(db: Session = Depends(get_db)) -> DashboardOut:
    summaries = directory.list_summaries(db)
    teams = db.scalars(select(Team).order_by(Team.name)).all()
    team_rows = [
        TeamStatus(team_id=t.id, team_name=t.name, color=t.color, counts=_counts([s for s in summaries if s.team_id == t.id]))
        for t in teams
    ]
    unassigned = [s for s in summaries if s.team_id is None]
    if unassigned:
        team_rows.append(TeamStatus(team_id=None, team_name="Unassigned", color="#A8A29E", counts=_counts(unassigned)))
    pending = db.scalar(
        select(func.count())
        .select_from(LocationRequest)
        .where(LocationRequest.status == RequestStatus.pending, LocationRequest.expires_at > utcnow())
    )
    return DashboardOut(
        counts=_counts(summaries),
        teams=team_rows,
        sharing_enabled=sum(1 for s in summaries if s.sharing_enabled),
        pending_requests=pending or 0,
        generated_at=utcnow(),
    )


@router.get("/map/employees", response_model=list[EmployeeSummary], dependencies=[Depends(require_admin)])
def map_employees(
    team_id: int | None = None,
    status_filter: EmployeeStatus | None = Query(default=None, alias="status"),
    db: Session = Depends(get_db),
) -> list[EmployeeSummary]:
    """Employees that have a real fix and either share continuously or answered a request."""
    items = directory.list_summaries(db, team_id=team_id, status=status_filter)
    return [
        s
        for s in items
        if s.last_location is not None and (s.sharing_enabled or s.last_location.source == "request")
    ]


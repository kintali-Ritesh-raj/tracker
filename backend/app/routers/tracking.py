"""Employee-side endpoints (own profile, consent, fixes) and location requests."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from ..db import get_db
from ..models import Device, DeviceRole, LocationPermission, LocationRequest, LocationUpdate, RequestStatus, utcnow
from ..realtime import ADMINS, hub
from ..schemas import (
    BatchResult,
    EmployeeSummary,
    FixBatch,
    LocationRequestIn,
    LocationRequestOut,
    PermissionIn,
    PermissionOut,
    RespondIn,
)
from ..security import current_device, require_admin, require_employee
from ..services import directory, requests
from ..services.locations import broadcast_employee, store_fixes

router = APIRouter(tags=["tracking"])


def _own_employee(db: Session, device: Device):
    employee = directory.get_employee(db, device.employee_id)
    if employee is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Employee not found.")
    return employee


@router.get("/me", response_model=EmployeeSummary)
def my_profile(device: Device = Depends(require_employee), db: Session = Depends(get_db)) -> EmployeeSummary:
    return directory.summary(db, _own_employee(db, device))


@router.get("/me/permission", response_model=PermissionOut)
def my_permission(device: Device = Depends(require_employee), db: Session = Depends(get_db)) -> PermissionOut:
    employee = _own_employee(db, device)
    if employee.permission is None:
        employee.permission = LocationPermission(employee_id=employee.id)
        db.commit()
    return PermissionOut.model_validate(employee.permission)


@router.put("/me/permission", response_model=PermissionOut)
def set_my_permission(
    body: PermissionIn, device: Device = Depends(require_employee), db: Session = Depends(get_db)
) -> PermissionOut:
    """Only the employee's own device can grant or withdraw location consent."""
    employee = _own_employee(db, device)
    permission = employee.permission or LocationPermission(employee_id=employee.id)
    if employee.permission is None:
        db.add(permission)
    if body.sharing_enabled and not permission.sharing_enabled:
        permission.consented_at = utcnow()
    permission.sharing_enabled = body.sharing_enabled
    permission.background_enabled = body.sharing_enabled and body.background_enabled
    permission.history_enabled = body.history_enabled
    permission.updated_at = utcnow()
    db.commit()
    db.refresh(employee)
    summary = directory.summary(db, employee)
    hub.publish([ADMINS], "employee.status", summary.model_dump(mode="json"))
    return PermissionOut.model_validate(permission)


@router.post("/locations", response_model=BatchResult)
def upload_locations(
    body: FixBatch, device: Device = Depends(require_employee), db: Session = Depends(get_db)
) -> BatchResult:
    employee = _own_employee(db, device)
    if employee.permission is None or not employee.permission.sharing_enabled:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Location sharing is turned off on this device.")
    stream = [f for f in body.fixes if f.source != "request"]
    accepted, errors = store_fixes(db, device, employee, stream)
    db.commit()
    summary = broadcast_employee(db, employee) if accepted else directory.summary(db, employee)
    return BatchResult(
        accepted=len(accepted),
        rejected=len(body.fixes) - len(accepted),
        latest=summary.last_location,
        status=summary.status,
        errors=sorted(set(errors)),
    )


@router.get("/me/location-requests", response_model=list[LocationRequestOut])
def my_requests(
    device: Device = Depends(require_employee),
    only_open: bool = Query(default=True, alias="open"),
    db: Session = Depends(get_db),
) -> list[LocationRequestOut]:
    stmt = (
        select(LocationRequest)
        .options(
            selectinload(LocationRequest.employee),
            selectinload(LocationRequest.location).selectinload(LocationUpdate.site),
        )
        .where(LocationRequest.employee_id == device.employee_id)
        .order_by(LocationRequest.created_at.desc())
        .limit(20)
    )
    if only_open:
        stmt = stmt.where(
            LocationRequest.expires_at > utcnow(),
            (LocationRequest.status == RequestStatus.pending)
            | ((LocationRequest.status == RequestStatus.approved) & LocationRequest.fulfilled_at.is_(None)),
        )
    return [requests.request_out(r) for r in db.scalars(stmt)]


@router.post("/location-requests", response_model=LocationRequestOut, status_code=201)
def create_request(
    body: LocationRequestIn, admin: Device = Depends(require_admin), db: Session = Depends(get_db)
) -> LocationRequestOut:
    employee = directory.get_employee(db, body.employee_id)
    if employee is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Employee not found.")
    return requests.create(db, admin, employee, body.reason)


@router.get("/location-requests", response_model=list[LocationRequestOut], dependencies=[Depends(require_admin)])
def list_requests(
    employee_id: int | None = None,
    limit: int = Query(default=30, ge=1, le=200),
    db: Session = Depends(get_db),
) -> list[LocationRequestOut]:
    stmt = (
        select(LocationRequest)
        .options(
            selectinload(LocationRequest.employee),
            selectinload(LocationRequest.location).selectinload(LocationUpdate.site),
        )
        .order_by(LocationRequest.created_at.desc())
        .limit(limit)
    )
    if employee_id is not None:
        stmt = stmt.where(LocationRequest.employee_id == employee_id)
    return [requests.request_out(r) for r in db.scalars(stmt)]


@router.get("/location-requests/{request_id}", response_model=LocationRequestOut)
def get_request(request_id: int, device: Device = Depends(current_device), db: Session = Depends(get_db)) -> LocationRequestOut:
    req = requests.load_request(db, request_id)
    if req is None or (device.role == DeviceRole.employee and req.employee_id != device.employee_id):
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Request not found.")
    return requests.request_out(req)


@router.post("/location-requests/{request_id}/respond", response_model=LocationRequestOut)
def respond(
    request_id: int, body: RespondIn, device: Device = Depends(require_employee), db: Session = Depends(get_db)
) -> LocationRequestOut:
    req = requests.load_request(db, request_id)
    if req is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Request not found.")
    return requests.respond(db, device, req, body.decision, body.fix)

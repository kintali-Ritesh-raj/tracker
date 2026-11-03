"""Device pairing, identity and revocation."""
from __future__ import annotations

from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import settings
from ..db import get_db
from ..models import Device, DeviceRole, Employee, LocationPermission, PairingCode, utcnow
from ..realtime import ADMINS, hub
from ..schemas import (
    DeviceOut,
    HeartbeatIn,
    MeOut,
    PairIn,
    PairingCodeIn,
    PairingCodeOut,
    PairOut,
    PermissionOut,
)
from ..security import (
    current_device,
    hash_secret,
    hash_token,
    new_device_token,
    new_pairing_code,
    pair_limiter,
    require_admin,
)
from ..services import directory

router = APIRouter(tags=["devices"])


def issue_pairing_code(
    db: Session, role: DeviceRole, employee_id: int | None, created_by: int | None
) -> PairingCodeOut:
    ttl = (
        timedelta(minutes=settings.admin_code_ttl_minutes)
        if role == DeviceRole.admin
        else timedelta(hours=settings.employee_code_ttl_hours)
    )
    code = new_pairing_code()
    row = PairingCode(
        code_hash=hash_secret(code),
        role=role,
        employee_id=employee_id,
        created_by_device_id=created_by,
        expires_at=utcnow() + ttl,
    )
    db.add(row)
    db.commit()
    return PairingCodeOut(code=code, role=role, employee_id=employee_id, expires_at=row.expires_at)


@router.post("/devices/pair", response_model=PairOut)
def pair(body: PairIn, request: Request, db: Session = Depends(get_db)) -> PairOut:
    pair_limiter.check(request.client.host if request.client else "unknown")
    code = db.scalar(select(PairingCode).where(PairingCode.code_hash == hash_secret(body.code)))
    now = utcnow()
    if code is None or code.used_at is not None or code.expires_at <= now:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "This pairing code is invalid or has expired.")

    employee = None
    if code.role == DeviceRole.employee:
        employee = db.get(Employee, code.employee_id)
        if employee is None or not employee.active:
            raise HTTPException(status.HTTP_400_BAD_REQUEST, "The employee for this code is no longer active.")
        # One phone per employee: pairing a new phone retires the old one.
        for old in employee.devices:
            if old.revoked_at is None:
                old.revoked_at = now
                hub.publish_close(old.id)
        if employee.permission is None:
            db.add(LocationPermission(employee_id=employee.id))

    token = new_device_token()
    device = Device(
        role=code.role,
        employee_id=code.employee_id,
        label=body.label,
        platform=body.platform,
        app_version=body.app_version,
        token_hash=hash_token(token),
        last_seen_at=now,
    )
    db.add(device)
    code.used_at = now
    db.commit()
    db.refresh(device)

    summary = None
    if employee is not None:
        db.refresh(employee)
        summary = directory.summary(db, employee)
        hub.publish([ADMINS], "employee.status", summary.model_dump(mode="json"))
    return PairOut(token=token, device=directory.device_out(device), role=device.role, employee=summary)


@router.get("/devices/me", response_model=MeOut)
def me(device: Device = Depends(current_device), db: Session = Depends(get_db)) -> MeOut:
    employee = directory.get_employee(db, device.employee_id) if device.employee_id else None
    return MeOut(
        device=directory.device_out(device),
        role=device.role,
        employee=directory.summary(db, employee) if employee else None,
        permission=PermissionOut.model_validate(employee.permission) if employee and employee.permission else None,
    )


@router.post("/devices/heartbeat", response_model=DeviceOut)
def heartbeat(body: HeartbeatIn, device: Device = Depends(current_device), db: Session = Depends(get_db)) -> DeviceOut:
    if body.push_token is not None:
        device.push_token = body.push_token or None
    if body.battery_level is not None:
        device.battery_level = body.battery_level
    if body.permission_state is not None:
        device.permission_state = body.permission_state
    if body.app_version:
        device.app_version = body.app_version
    device.last_seen_at = utcnow()
    db.commit()
    return directory.device_out(device)


@router.get("/devices", response_model=list[DeviceOut])
def list_devices(_: Device = Depends(require_admin), db: Session = Depends(get_db)) -> list[DeviceOut]:
    devices = db.scalars(select(Device).order_by(Device.created_at.desc())).all()
    return [directory.device_out(d) for d in devices]


@router.delete("/devices/{device_id}", status_code=status.HTTP_204_NO_CONTENT, response_class=Response, response_model=None)
def revoke_device(device_id: int, admin: Device = Depends(require_admin), db: Session = Depends(get_db)) -> None:
    device = db.get(Device, device_id)
    if device is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Device not found.")
    if device.id == admin.id:
        raise HTTPException(status.HTTP_409_CONFLICT, "You cannot revoke the device you are using.")
    if device.revoked_at is None:
        device.revoked_at = utcnow()
        db.commit()
    hub.publish_close(device.id)


@router.post("/pairing-codes", response_model=PairingCodeOut, status_code=status.HTTP_201_CREATED)
def create_pairing_code(
    body: PairingCodeIn, admin: Device = Depends(require_admin), db: Session = Depends(get_db)
) -> PairingCodeOut:
    if body.role == DeviceRole.employee:
        employee = db.get(Employee, body.employee_id) if body.employee_id else None
        if employee is None or not employee.active:
            raise HTTPException(status.HTTP_404_NOT_FOUND, "Choose an active employee to pair.")
    elif body.employee_id is not None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Admin codes are not tied to an employee.")
    return issue_pairing_code(db, body.role, body.employee_id, admin.id)

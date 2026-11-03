"""Location request lifecycle (docs/ARCHITECTURE.md §3)."""
from __future__ import annotations

from datetime import timedelta

from fastapi import HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from ..models import Device, Employee, LocationRequest, LocationUpdate, RequestStatus, utcnow
from ..realtime import ADMINS, employee_audience, hub
from ..schemas import Fix, LocationRequestOut
from . import push, runtime_settings
from .directory import location_out
from .locations import broadcast_employee, store_fixes


def request_out(req: LocationRequest) -> LocationRequestOut:
    now = utcnow()
    return LocationRequestOut(
        id=req.id,
        employee_id=req.employee_id,
        employee_name=req.employee.full_name,
        status=req.status,
        reason=req.reason,
        auto_approved=req.auto_approved,
        created_at=req.created_at,
        responded_at=req.responded_at,
        fulfilled_at=req.fulfilled_at,
        expires_at=req.expires_at,
        location=location_out(req.location),
        awaiting_fresh_fix=(
            req.status == RequestStatus.approved and req.fulfilled_at is None and now < req.expires_at
        ),
    )


def load_request(db: Session, request_id: int) -> LocationRequest | None:
    return db.scalar(
        select(LocationRequest)
        .options(
            selectinload(LocationRequest.employee),
            selectinload(LocationRequest.location).selectinload(LocationUpdate.site),
        )
        .where(LocationRequest.id == request_id)
    )


def _announce(db: Session, req: LocationRequest, event: str = "location_request.updated") -> LocationRequestOut:
    db.refresh(req)
    out = request_out(req)
    payload = out.model_dump(mode="json")
    hub.publish([ADMINS, employee_audience(req.employee_id)], event, payload)
    return out


def _latest_fix(db: Session, employee_id: int) -> LocationUpdate | None:
    return db.scalar(
        select(LocationUpdate)
        .where(LocationUpdate.employee_id == employee_id)
        .order_by(LocationUpdate.recorded_at.desc(), LocationUpdate.id.desc())
        .limit(1)
    )


def create(db: Session, admin: Device, employee: Employee, reason: str | None) -> LocationRequestOut:
    if not employee.active:
        raise HTTPException(status.HTTP_409_CONFLICT, "This employee is deactivated.")

    now = utcnow()
    existing = db.scalar(
        select(LocationRequest).where(
            LocationRequest.employee_id == employee.id,
            LocationRequest.status == RequestStatus.pending,
            LocationRequest.expires_at > now,
        )
    )
    if existing is not None:
        return request_out(load_request(db, existing.id))

    timeout = runtime_settings.load(db).request_timeout_seconds
    devices = [d for d in employee.devices if d.revoked_at is None]
    permission = employee.permission
    req = LocationRequest(
        employee_id=employee.id,
        requested_by_device_id=admin.id,
        reason=reason,
        created_at=now,
        expires_at=now + timedelta(seconds=timeout),
    )
    db.add(req)

    if not devices:
        req.status = RequestStatus.unavailable
        req.responded_at = now
        db.commit()
        return _announce(db, req)

    if permission is not None and permission.sharing_enabled:
        # Continuous sharing was already consented to: answer with the latest
        # available fix right away and ask the phone for a fresh one.
        latest = _latest_fix(db, employee.id)
        req.status = RequestStatus.approved
        req.auto_approved = True
        req.responded_at = now
        req.location_update_id = latest.id if latest else None
        db.commit()
        hub.publish([employee_audience(employee.id)], "location.refresh", {"request_id": req.id})
        for device in devices:
            push.send_data(device.push_token, {"type": "location_refresh", "request_id": str(req.id)})
        return _announce(db, req)

    req.status = RequestStatus.pending
    db.commit()
    out = _announce(db, req, "location_request.created")
    for device in devices:
        push.send_data(
            device.push_token,
            {"type": "location_request", "request_id": str(req.id)},
            title="Location requested",
            body="SLG management asked for your current location. Tap to approve or decline.",
        )
    return out


def respond(db: Session, device: Device, req: LocationRequest, decision: str, fix: Fix | None) -> LocationRequestOut:
    if req.employee_id != device.employee_id:
        raise HTTPException(status.HTTP_404_NOT_FOUND, "Request not found.")
    now = utcnow()
    awaiting_auto = req.status == RequestStatus.approved and req.auto_approved and req.fulfilled_at is None
    if req.status == RequestStatus.pending and req.expires_at <= now:
        req.status = RequestStatus.unavailable
        db.commit()
        _announce(db, req)
        raise HTTPException(status.HTTP_409_CONFLICT, "This request has expired.")
    if req.status != RequestStatus.pending and not awaiting_auto:
        raise HTTPException(status.HTTP_409_CONFLICT, f"This request is already {req.status.value}.")

    if decision == "decline":
        if awaiting_auto:
            raise HTTPException(status.HTTP_409_CONFLICT, "Pause location sharing to stop sending updates.")
        req.status = RequestStatus.declined
        req.responded_at = now
        db.commit()
        return _announce(db, req)

    if fix is None:
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, "Approving requires a location fix.")
    accepted, errors = store_fixes(db, device, req.employee, [fix.model_copy(update={"source": "request"})], request_id=req.id)
    if not accepted:
        db.rollback()
        raise HTTPException(status.HTTP_422_UNPROCESSABLE_ENTITY, errors[0] if errors else "Invalid fix.")
    req.status = RequestStatus.approved
    req.responded_at = req.responded_at or now
    req.fulfilled_at = now
    req.location_update_id = accepted[-1].id
    db.commit()
    broadcast_employee(db, req.employee)
    return _announce(db, req)


def expire_pending(db: Session) -> list[LocationRequestOut]:
    """Mark timed-out pending requests unavailable. Returns what changed."""
    now = utcnow()
    stale = db.scalars(
        select(LocationRequest)
        .options(selectinload(LocationRequest.employee), selectinload(LocationRequest.location))
        .where(LocationRequest.status == RequestStatus.pending, LocationRequest.expires_at <= now)
    ).all()
    for req in stale:
        req.status = RequestStatus.unavailable
        req.responded_at = now
    db.commit()
    return [request_out(r) for r in stale]

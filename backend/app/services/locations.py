"""Ingestion of GPS fixes from employee devices."""
from __future__ import annotations

from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.orm import Session

from ..config import settings
from ..models import Device, Employee, LocationUpdate, Site, utcnow
from ..realtime import ADMINS, hub
from ..schemas import EmployeeSummary, Fix
from . import directory
from .geocoding import reverse_geocode
from .status import match_site

MAX_FUTURE_SKEW = timedelta(minutes=2)
MAX_BACKLOG_AGE = timedelta(days=7)


def validate_fix(fix: Fix) -> str | None:
    """Returns a reason when the fix must not be stored as a real position."""
    now = utcnow()
    if fix.is_mocked:
        return "Mock locations are not accepted."
    if fix.recorded_at > now + MAX_FUTURE_SKEW:
        return "Fix timestamp is in the future; check the device clock."
    if fix.recorded_at < now - MAX_BACKLOG_AGE:
        return "Fix is older than 7 days."
    if fix.latitude == 0 and fix.longitude == 0:
        return "Null-island coordinates rejected."
    return None


def store_fixes(
    db: Session,
    device: Device,
    employee: Employee,
    fixes: list[Fix],
    *,
    request_id: int | None = None,
) -> tuple[list[LocationUpdate], list[str]]:
    sites = db.scalars(select(Site).where(Site.active.is_(True))).all()
    accepted: list[LocationUpdate] = []
    errors: list[str] = []
    for fix in sorted(fixes, key=lambda f: f.recorded_at):
        reason = validate_fix(fix)
        if reason:
            errors.append(reason)
            continue
        site = match_site(fix.latitude, fix.longitude, fix.accuracy_m, list(sites))
        update = LocationUpdate(
            employee_id=employee.id,
            device_id=device.id,
            latitude=fix.latitude,
            longitude=fix.longitude,
            accuracy_m=fix.accuracy_m,
            altitude_m=fix.altitude_m,
            speed_mps=fix.speed_mps,
            heading=fix.heading,
            recorded_at=fix.recorded_at,
            received_at=utcnow(),
            source=fix.source if request_id is None else "request",
            site_id=site.id if site else None,
            site=site,
            low_accuracy=fix.accuracy_m > settings.low_accuracy_threshold_m,
            request_id=request_id,
        )
        db.add(update)
        accepted.append(update)
    if accepted:
        newest = accepted[-1]
        newest.address = reverse_geocode(db, newest.latitude, newest.longitude)
    db.flush()
    return accepted, errors


def broadcast_employee(db: Session, employee: Employee) -> EmployeeSummary:
    db.refresh(employee)
    summary = directory.summary(db, employee)
    hub.publish([ADMINS], "location.updated", summary.model_dump(mode="json"))
    return summary

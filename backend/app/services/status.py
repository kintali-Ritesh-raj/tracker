"""Employee status rules and geofence matching (docs/ARCHITECTURE.md §2)."""
from __future__ import annotations

import math
from datetime import datetime, timedelta

from ..models import Device, EmployeeStatus, LocationPermission, LocationUpdate, Site

EARTH_RADIUS_M = 6_371_000.0


def distance_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    """Great-circle distance (haversine)."""
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lng2 - lng1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_RADIUS_M * math.asin(math.sqrt(a))


def match_site(latitude: float, longitude: float, accuracy_m: float, sites: list[Site]) -> Site | None:
    """Nearest active site whose geofence contains the fix.

    The fix's accuracy is allowed to extend the fence by up to 50 m so a slightly
    noisy reading at the gate still counts, but a 500 m cell-tower fix does not.
    """
    best: tuple[float, Site] | None = None
    for site in sites:
        if not site.active:
            continue
        d = distance_m(latitude, longitude, site.latitude, site.longitude)
        if d <= site.radius_m + min(accuracy_m, 50) and (best is None or d < best[0]):
            best = (d, site)
    return best[1] if best else None


def compute_status(
    latest: LocationUpdate | None,
    permission: LocationPermission | None,
    devices: list[Device],
    now: datetime,
    offline_after_minutes: int,
) -> EmployeeStatus:
    if latest is None:
        return EmployeeStatus.offline
    sharing = permission is not None and permission.sharing_enabled
    # A fix the employee handed over for an approved one-off request still counts
    # while it is fresh, even when continuous sharing is off.
    if not sharing and latest.source != "request":
        return EmployeeStatus.offline
    if not any(d.revoked_at is None for d in devices):
        return EmployeeStatus.offline
    if now - latest.recorded_at > timedelta(minutes=offline_after_minutes):
        return EmployeeStatus.offline
    return EmployeeStatus.on_site if latest.site_id is not None else EmployeeStatus.in_transit

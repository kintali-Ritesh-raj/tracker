"""Device-token authentication.

There are no user accounts or passwords. A phone becomes trusted by redeeming a
one-time pairing code, which yields a random device token. Only the SHA-256 hash of
tokens and codes is stored, so a database leak does not reveal usable credentials.
"""
from __future__ import annotations

import hashlib
import secrets
import time
from collections import defaultdict, deque
from datetime import datetime

from fastapi import Depends, HTTPException, Request, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from .config import settings
from .db import get_db
from .models import Device, DeviceRole, utcnow

# Unambiguous alphabet for codes typed by hand (no 0/O, 1/I/L).
_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"


def hash_secret(value: str) -> str:
    return hashlib.sha256(value.strip().upper().encode("utf-8")).hexdigest()


def hash_token(token: str) -> str:
    # Tokens are case-sensitive, so they are not normalised like pairing codes.
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def new_device_token() -> str:
    return secrets.token_urlsafe(32)


def new_pairing_code(length: int = 8) -> str:
    return "".join(secrets.choice(_CODE_ALPHABET) for _ in range(length))


def device_for_token(db: Session, token: str | None) -> Device | None:
    if not token:
        return None
    device = db.scalar(select(Device).where(Device.token_hash == hash_token(token)))
    if device is None or device.revoked_at is not None:
        return None
    if device.role == DeviceRole.employee and (
        device.employee is None or not device.employee.active
    ):
        return None
    return device


def _bearer(request: Request) -> str | None:
    header = request.headers.get("authorization", "")
    if header.lower().startswith("bearer "):
        return header[7:].strip()
    return None


def _touch(db: Session, device: Device) -> None:
    now = utcnow()
    # Avoid a write on every request; a minute of resolution is plenty.
    if device.last_seen_at is None or (now - device.last_seen_at).total_seconds() > 60:
        device.last_seen_at = now
        db.commit()


def current_device(request: Request, db: Session = Depends(get_db)) -> Device:
    device = device_for_token(db, _bearer(request))
    if device is None:
        raise HTTPException(
            status.HTTP_401_UNAUTHORIZED,
            "This device is not paired or has been revoked.",
            headers={"WWW-Authenticate": "Bearer"},
        )
    _touch(db, device)
    return device


def require_admin(device: Device = Depends(current_device)) -> Device:
    if device.role != DeviceRole.admin:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Admin device required.")
    return device


def require_employee(device: Device = Depends(current_device)) -> Device:
    if device.role != DeviceRole.employee or device.employee_id is None:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Employee device required.")
    return device


class RateLimiter:
    """Small in-memory sliding-window limiter for the unauthenticated pairing endpoint."""

    def __init__(self, limit: int, window_seconds: int = 60) -> None:
        self.limit = limit
        self.window = window_seconds
        self._hits: dict[str, deque[float]] = defaultdict(deque)

    def check(self, key: str) -> None:
        now = time.monotonic()
        hits = self._hits[key]
        while hits and now - hits[0] > self.window:
            hits.popleft()
        if len(hits) >= self.limit:
            raise HTTPException(
                status.HTTP_429_TOO_MANY_REQUESTS,
                "Too many pairing attempts. Wait a minute and try again.",
            )
        hits.append(now)

    def reset(self) -> None:
        self._hits.clear()


pair_limiter = RateLimiter(settings.pair_rate_limit_per_minute)


def is_expired(moment: datetime) -> bool:
    return moment <= utcnow()

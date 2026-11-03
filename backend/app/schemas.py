"""Pydantic request/response models (the API contract)."""
from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator

from .models import DeviceRole, EmployeeStatus, RequestStatus


class ORM(BaseModel):
    model_config = ConfigDict(from_attributes=True)


# ---------- Teams & sites ----------

class TeamIn(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    description: str | None = Field(default=None, max_length=255)
    color: str = Field(default="#F97316", pattern=r"^#[0-9A-Fa-f]{6}$")


class TeamPatch(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=80)
    description: str | None = Field(default=None, max_length=255)
    color: str | None = Field(default=None, pattern=r"^#[0-9A-Fa-f]{6}$")


class TeamOut(ORM):
    id: int
    name: str
    description: str | None
    color: str
    employee_count: int = 0


class SiteIn(BaseModel):
    name: str = Field(min_length=1, max_length=120)
    address: str | None = Field(default=None, max_length=255)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    radius_m: int = Field(default=150, ge=20, le=5000)
    active: bool = True


class SitePatch(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=120)
    address: str | None = Field(default=None, max_length=255)
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    radius_m: int | None = Field(default=None, ge=20, le=5000)
    active: bool | None = None


class SiteOut(ORM):
    id: int
    name: str
    address: str | None
    latitude: float
    longitude: float
    radius_m: int
    active: bool


# ---------- Locations ----------

class Fix(BaseModel):
    """A single GPS fix as reported by the device's fused location provider."""

    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)
    accuracy_m: float = Field(ge=0, le=100_000)
    altitude_m: float | None = None
    speed_mps: float | None = Field(default=None, ge=0, le=150)
    heading: float | None = Field(default=None, ge=0, le=360)
    recorded_at: datetime
    source: Literal["stream", "request", "manual"] = "stream"
    is_mocked: bool = False

    @field_validator("recorded_at")
    @classmethod
    def _tz(cls, value: datetime) -> datetime:
        if value.tzinfo is None:
            raise ValueError("recorded_at must include a timezone offset")
        return value

    @field_validator("speed_mps", "heading", mode="before")
    @classmethod
    def _negative_is_unknown(cls, value: float | None) -> float | None:
        # Android reports -1 / 0 when speed or bearing is unavailable.
        if value is not None and value < 0:
            return None
        return value


class FixBatch(BaseModel):
    fixes: list[Fix] = Field(min_length=1, max_length=500)


class LocationOut(ORM):
    id: int
    latitude: float
    longitude: float
    accuracy_m: float
    altitude_m: float | None
    speed_mps: float | None
    heading: float | None
    recorded_at: datetime
    received_at: datetime
    source: str
    site_id: int | None
    site_name: str | None = None
    address: str | None
    low_accuracy: bool


class BatchResult(BaseModel):
    accepted: int
    rejected: int
    latest: LocationOut | None
    status: EmployeeStatus
    errors: list[str] = []


# ---------- Employees ----------

class PermissionOut(ORM):
    sharing_enabled: bool
    background_enabled: bool
    history_enabled: bool
    consented_at: datetime | None
    updated_at: datetime


class PermissionIn(BaseModel):
    sharing_enabled: bool
    background_enabled: bool = False
    history_enabled: bool = True


class DeviceOut(ORM):
    id: int
    role: DeviceRole
    employee_id: int | None
    label: str | None
    platform: str | None
    app_version: str | None
    battery_level: int | None
    permission_state: dict | None
    has_push: bool = False
    last_seen_at: datetime | None
    revoked_at: datetime | None
    created_at: datetime


class EmployeeIn(BaseModel):
    employee_code: str = Field(min_length=1, max_length=32)
    full_name: str = Field(min_length=1, max_length=120)
    phone: str | None = Field(default=None, max_length=32)
    role_title: str | None = Field(default=None, max_length=80)
    team_id: int | None = None


class EmployeePatch(BaseModel):
    employee_code: str | None = Field(default=None, min_length=1, max_length=32)
    full_name: str | None = Field(default=None, min_length=1, max_length=120)
    phone: str | None = Field(default=None, max_length=32)
    role_title: str | None = Field(default=None, max_length=80)
    team_id: int | None = None
    active: bool | None = None


class EmployeeSummary(BaseModel):
    id: int
    employee_code: str
    full_name: str
    phone: str | None
    role_title: str | None
    team_id: int | None
    team_name: str | None
    team_color: str | None
    has_photo: bool
    photo_version: int = 0
    active: bool
    status: EmployeeStatus
    sharing_enabled: bool
    device_paired: bool
    last_location: LocationOut | None


class EmployeeDetail(EmployeeSummary):
    permission: PermissionOut | None
    devices: list[DeviceOut]
    history_enabled: bool


# ---------- Devices & pairing ----------

class PairIn(BaseModel):
    code: str = Field(min_length=6, max_length=16)
    label: str | None = Field(default=None, max_length=120)
    platform: str | None = Field(default=None, max_length=32)
    app_version: str | None = Field(default=None, max_length=32)


class PairOut(BaseModel):
    token: str
    device: DeviceOut
    role: DeviceRole
    employee: EmployeeSummary | None


class PairingCodeIn(BaseModel):
    role: DeviceRole
    employee_id: int | None = None


class PairingCodeOut(BaseModel):
    code: str
    role: DeviceRole
    employee_id: int | None
    expires_at: datetime


class HeartbeatIn(BaseModel):
    push_token: str | None = None
    battery_level: int | None = Field(default=None, ge=0, le=100)
    permission_state: dict | None = None
    app_version: str | None = Field(default=None, max_length=32)


class MeOut(BaseModel):
    device: DeviceOut
    role: DeviceRole
    employee: EmployeeSummary | None
    permission: PermissionOut | None


# ---------- Location requests ----------

class LocationRequestIn(BaseModel):
    employee_id: int
    reason: str | None = Field(default=None, max_length=255)


class RespondIn(BaseModel):
    decision: Literal["approve", "decline"]
    fix: Fix | None = None


class LocationRequestOut(BaseModel):
    id: int
    employee_id: int
    employee_name: str
    status: RequestStatus
    reason: str | None
    auto_approved: bool
    created_at: datetime
    responded_at: datetime | None
    fulfilled_at: datetime | None
    expires_at: datetime
    location: LocationOut | None
    awaiting_fresh_fix: bool = False


# ---------- Dashboard & reports ----------

class StatusCounts(BaseModel):
    total: int
    on_site: int
    in_transit: int
    offline: int


class TeamStatus(BaseModel):
    team_id: int | None
    team_name: str
    color: str
    counts: StatusCounts


class DashboardOut(BaseModel):
    counts: StatusCounts
    teams: list[TeamStatus]
    sharing_enabled: int
    pending_requests: int
    generated_at: datetime


class AttendanceRow(BaseModel):
    employee_id: int
    employee_name: str
    team_name: str | None
    first_seen: datetime | None
    last_seen: datetime | None
    on_site_minutes: int
    fixes: int
    sites: list[str]


class SiteVisitRow(BaseModel):
    site_id: int
    site_name: str
    employee_id: int
    employee_name: str
    arrived_at: datetime
    left_at: datetime
    minutes: int


class SettingsOut(BaseModel):
    offline_after_minutes: int = Field(ge=1, le=1440)
    request_timeout_seconds: int = Field(ge=30, le=3600)
    default_site_radius_m: int = Field(ge=20, le=5000)
    tracking_interval_seconds: int = Field(ge=15, le=3600)
    tracking_distance_filter_m: int = Field(ge=0, le=1000)
    history_retention_days: int = Field(ge=1, le=3650)

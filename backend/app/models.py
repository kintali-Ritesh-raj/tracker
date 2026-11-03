"""SQLAlchemy ORM models. See docs/ARCHITECTURE.md §4 for the schema overview."""
from __future__ import annotations

import enum
from datetime import datetime, timezone

from sqlalchemy import (
    BigInteger,
    Boolean,
    DateTime,
    Enum,
    Float,
    ForeignKey,
    Index,
    Integer,
    String,
    Text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .db import Base


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


class DeviceRole(str, enum.Enum):
    admin = "admin"
    employee = "employee"


class RequestStatus(str, enum.Enum):
    pending = "pending"
    approved = "approved"
    declined = "declined"
    unavailable = "unavailable"


class EmployeeStatus(str, enum.Enum):
    on_site = "on_site"
    in_transit = "in_transit"
    offline = "offline"


def _enum(cls: type[enum.Enum], name: str) -> Enum:
    return Enum(cls, name=name, values_callable=lambda e: [m.value for m in e])


class Team(Base):
    __tablename__ = "teams"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(80), unique=True)
    description: Mapped[str | None] = mapped_column(String(255))
    color: Mapped[str] = mapped_column(String(9), default="#F97316")
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

    employees: Mapped[list[Employee]] = relationship(back_populates="team")


class Site(Base):
    __tablename__ = "sites"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(120))
    address: Mapped[str | None] = mapped_column(String(255))
    latitude: Mapped[float] = mapped_column(Float)
    longitude: Mapped[float] = mapped_column(Float)
    radius_m: Mapped[int] = mapped_column(Integer, default=150)
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Employee(Base):
    __tablename__ = "employees"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    employee_code: Mapped[str] = mapped_column(String(32), unique=True)
    full_name: Mapped[str] = mapped_column(String(120))
    phone: Mapped[str | None] = mapped_column(String(32))
    role_title: Mapped[str | None] = mapped_column(String(80))
    team_id: Mapped[int | None] = mapped_column(ForeignKey("teams.id", ondelete="SET NULL"))
    photo_path: Mapped[str | None] = mapped_column(String(255))
    active: Mapped[bool] = mapped_column(Boolean, default=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

    team: Mapped[Team | None] = relationship(back_populates="employees")
    permission: Mapped[LocationPermission | None] = relationship(
        back_populates="employee", uselist=False, cascade="all, delete-orphan"
    )
    devices: Mapped[list[Device]] = relationship(back_populates="employee")


class Device(Base):
    __tablename__ = "devices"
    __table_args__ = (Index("ix_devices_employee_id", "employee_id"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    role: Mapped[DeviceRole] = mapped_column(_enum(DeviceRole, "device_role"))
    employee_id: Mapped[int | None] = mapped_column(ForeignKey("employees.id", ondelete="CASCADE"))
    label: Mapped[str | None] = mapped_column(String(120))
    token_hash: Mapped[str] = mapped_column(String(64), unique=True)
    platform: Mapped[str | None] = mapped_column(String(32))
    app_version: Mapped[str | None] = mapped_column(String(32))
    push_token: Mapped[str | None] = mapped_column(Text)
    battery_level: Mapped[int | None] = mapped_column(Integer)
    permission_state: Mapped[dict | None] = mapped_column(JSONB)
    last_seen_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

    employee: Mapped[Employee | None] = relationship(back_populates="devices")


class PairingCode(Base):
    __tablename__ = "pairing_codes"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    code_hash: Mapped[str] = mapped_column(String(64), unique=True)
    role: Mapped[DeviceRole] = mapped_column(_enum(DeviceRole, "device_role"))
    employee_id: Mapped[int | None] = mapped_column(ForeignKey("employees.id", ondelete="CASCADE"))
    created_by_device_id: Mapped[int | None] = mapped_column(
        ForeignKey("devices.id", ondelete="SET NULL")
    )
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    used_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class LocationPermission(Base):
    """The employee's consent record. Only the employee's own device may change it."""

    __tablename__ = "location_permissions"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    employee_id: Mapped[int] = mapped_column(
        ForeignKey("employees.id", ondelete="CASCADE"), unique=True
    )
    sharing_enabled: Mapped[bool] = mapped_column(Boolean, default=False)
    background_enabled: Mapped[bool] = mapped_column(Boolean, default=False)
    history_enabled: Mapped[bool] = mapped_column(Boolean, default=True)
    consented_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

    employee: Mapped[Employee] = relationship(back_populates="permission")


class LocationUpdate(Base):
    __tablename__ = "location_updates"
    __table_args__ = (Index("ix_location_updates_emp_time", "employee_id", "recorded_at"),)

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    employee_id: Mapped[int] = mapped_column(ForeignKey("employees.id", ondelete="CASCADE"))
    device_id: Mapped[int | None] = mapped_column(ForeignKey("devices.id", ondelete="SET NULL"))
    latitude: Mapped[float] = mapped_column(Float)
    longitude: Mapped[float] = mapped_column(Float)
    accuracy_m: Mapped[float] = mapped_column(Float)
    altitude_m: Mapped[float | None] = mapped_column(Float)
    speed_mps: Mapped[float | None] = mapped_column(Float)
    heading: Mapped[float | None] = mapped_column(Float)
    recorded_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    received_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    source: Mapped[str] = mapped_column(String(16), default="stream")
    site_id: Mapped[int | None] = mapped_column(ForeignKey("sites.id", ondelete="SET NULL"))
    address: Mapped[str | None] = mapped_column(String(255))
    low_accuracy: Mapped[bool] = mapped_column(Boolean, default=False)
    request_id: Mapped[int | None] = mapped_column(
        ForeignKey("location_requests.id", ondelete="SET NULL", use_alter=True, name="fk_location_updates_request_id")
    )

    site: Mapped[Site | None] = relationship()


class LocationRequest(Base):
    __tablename__ = "location_requests"
    __table_args__ = (
        Index("ix_location_requests_emp_time", "employee_id", "created_at"),
        Index("ix_location_requests_status_exp", "status", "expires_at"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    employee_id: Mapped[int] = mapped_column(ForeignKey("employees.id", ondelete="CASCADE"))
    requested_by_device_id: Mapped[int | None] = mapped_column(
        ForeignKey("devices.id", ondelete="SET NULL")
    )
    status: Mapped[RequestStatus] = mapped_column(
        _enum(RequestStatus, "request_status"), default=RequestStatus.pending
    )
    reason: Mapped[str | None] = mapped_column(String(255))
    auto_approved: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    responded_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    fulfilled_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    location_update_id: Mapped[int | None] = mapped_column(
        ForeignKey("location_updates.id", ondelete="SET NULL")
    )

    employee: Mapped[Employee] = relationship()
    location: Mapped[LocationUpdate | None] = relationship(foreign_keys=[location_update_id])


class GeocodeCache(Base):
    __tablename__ = "geocode_cache"

    key: Mapped[str] = mapped_column(String(32), primary_key=True)
    address: Mapped[str] = mapped_column(String(255))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class AppSetting(Base):
    __tablename__ = "app_settings"

    key: Mapped[str] = mapped_column(String(64), primary_key=True)
    value: Mapped[dict] = mapped_column(JSONB)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)

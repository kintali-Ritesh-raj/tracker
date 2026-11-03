"""Admin-editable runtime settings stored in `app_settings`, with env-var defaults."""
from __future__ import annotations

from sqlalchemy.orm import Session

from ..config import settings
from ..models import AppSetting, utcnow
from ..schemas import SettingsOut

_KEY = "general"


def defaults() -> SettingsOut:
    return SettingsOut(
        offline_after_minutes=settings.offline_after_minutes,
        request_timeout_seconds=settings.request_timeout_seconds,
        default_site_radius_m=settings.default_site_radius_m,
        tracking_interval_seconds=60,
        tracking_distance_filter_m=25,
        history_retention_days=90,
    )


def load(db: Session) -> SettingsOut:
    row = db.get(AppSetting, _KEY)
    base = defaults().model_dump()
    if row is not None:
        base.update({k: v for k, v in row.value.items() if k in base})
    return SettingsOut(**base)


def save(db: Session, values: SettingsOut) -> SettingsOut:
    row = db.get(AppSetting, _KEY)
    if row is None:
        row = AppSetting(key=_KEY, value={})
        db.add(row)
    row.value = values.model_dump()
    row.updated_at = utcnow()
    db.commit()
    return values

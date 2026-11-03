"""Runtime configuration, read from environment variables (or backend/.env)."""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent.parent


def _load_dotenv() -> None:
    env_file = BASE_DIR / ".env"
    if not env_file.exists():
        return
    for line in env_file.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key.strip(), value.strip().strip('"').strip("'"))


_load_dotenv()


def _int(name: str, default: int) -> int:
    return int(os.environ.get(name, default))


@dataclass(frozen=True)
class Settings:
    database_url: str = os.environ.get(
        "DATABASE_URL", "postgresql+psycopg://postgres@localhost:5432/slg_fieldtrack"
    )
    upload_dir: Path = Path(os.environ.get("UPLOAD_DIR", BASE_DIR / "uploads"))
    google_geocoding_api_key: str = os.environ.get("GOOGLE_GEOCODING_API_KEY", "")
    firebase_credentials_file: str = os.environ.get("FIREBASE_CREDENTIALS_FILE", "")
    cors_origins: str = os.environ.get("CORS_ORIGINS", "")
    # Status / request defaults; admins can override these at runtime via /settings.
    offline_after_minutes: int = _int("OFFLINE_AFTER_MINUTES", 15)
    request_timeout_seconds: int = _int("REQUEST_TIMEOUT_SECONDS", 120)
    default_site_radius_m: int = _int("DEFAULT_SITE_RADIUS_M", 150)
    low_accuracy_threshold_m: int = _int("LOW_ACCURACY_THRESHOLD_M", 100)
    admin_code_ttl_minutes: int = _int("ADMIN_CODE_TTL_MINUTES", 30)
    employee_code_ttl_hours: int = _int("EMPLOYEE_CODE_TTL_HOURS", 24)
    pair_rate_limit_per_minute: int = _int("PAIR_RATE_LIMIT_PER_MINUTE", 10)


settings = Settings()

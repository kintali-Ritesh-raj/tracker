from __future__ import annotations

import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

os.environ.setdefault(
    "DATABASE_URL", "postgresql+psycopg://postgres@localhost:5432/slg_fieldtrack_test"
)
os.environ["GOOGLE_GEOCODING_API_KEY"] = ""
os.environ["FIREBASE_CREDENTIALS_FILE"] = ""
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi.testclient import TestClient  # noqa: E402
from sqlalchemy import text  # noqa: E402

from app.db import Base, SessionLocal, engine  # noqa: E402
from app.main import app  # noqa: E402
from app.models import DeviceRole  # noqa: E402
from app.routers.devices import issue_pairing_code  # noqa: E402
from app.security import pair_limiter  # noqa: E402

# Test coordinates (Visakhapatnam). They exist only in the throwaway test database.
SITE = (17.7410, 83.3370)
FAR = (17.7900, 83.3800)


@pytest.fixture(scope="session", autouse=True)
def _schema():
    with engine.begin() as conn:
        conn.execute(text("DROP SCHEMA public CASCADE; CREATE SCHEMA public"))
    Base.metadata.create_all(engine)
    yield


@pytest.fixture(autouse=True)
def _clean():
    pair_limiter.reset()
    with engine.begin() as conn:
        tables = ", ".join(t.name for t in Base.metadata.sorted_tables)
        conn.execute(text(f"TRUNCATE {tables} RESTART IDENTITY CASCADE"))
    yield


@pytest.fixture
def client():
    with TestClient(app) as c:
        yield c


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def now() -> datetime:
    return datetime.now(timezone.utc)


def fix(lat: float, lng: float, *, ago: timedelta = timedelta(seconds=5), accuracy: float = 8.0, **extra) -> dict:
    return {
        "latitude": lat,
        "longitude": lng,
        "accuracy_m": accuracy,
        "recorded_at": (now() - ago).isoformat(),
        **extra,
    }


@pytest.fixture
def admin_token(client) -> str:
    with SessionLocal() as db:
        code = issue_pairing_code(db, DeviceRole.admin, None, None).code
    res = client.post("/api/v1/devices/pair", json={"code": code, "label": "Admin phone"})
    assert res.status_code == 200, res.text
    return res.json()["token"]


@pytest.fixture
def make_employee(client, admin_token):
    def _make(code: str = "SLG-001", name: str = "Ravi Kumar", team_id: int | None = None, pair: bool = True):
        res = client.post(
            "/api/v1/employees",
            json={"employee_code": code, "full_name": name, "role_title": "Cleaning Staff", "team_id": team_id, "phone": "+919000000000"},
            headers=auth(admin_token),
        )
        assert res.status_code == 201, res.text
        employee = res.json()
        token = None
        if pair:
            pc = client.post(
                "/api/v1/pairing-codes",
                json={"role": "employee", "employee_id": employee["id"]},
                headers=auth(admin_token),
            ).json()
            token = client.post("/api/v1/devices/pair", json={"code": pc["code"]}).json()["token"]
        return employee, token

    return _make


@pytest.fixture
def site(client, admin_token) -> dict:
    res = client.post(
        "/api/v1/sites",
        json={"name": "MVP Colony Block A", "latitude": SITE[0], "longitude": SITE[1], "radius_m": 150},
        headers=auth(admin_token),
    )
    assert res.status_code == 201
    return res.json()


def share(client, token: str, enabled: bool = True) -> None:
    res = client.put(
        "/api/v1/me/permission",
        json={"sharing_enabled": enabled, "background_enabled": enabled, "history_enabled": True},
        headers=auth(token),
    )
    assert res.status_code == 200, res.text

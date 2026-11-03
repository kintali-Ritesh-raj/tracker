"""Operator commands.

    python -m app.cli bootstrap-admin      # print a one-time admin pairing code
    python -m app.cli revoke-all-admins    # emergency: revoke every admin device
"""
from __future__ import annotations

import argparse

from sqlalchemy import update

from .db import SessionLocal
from .models import Device, DeviceRole, utcnow
from .routers.devices import issue_pairing_code


def bootstrap_admin() -> None:
    with SessionLocal() as db:
        code = issue_pairing_code(db, DeviceRole.admin, None, None)
    print("Admin pairing code:", code.code)
    print("Valid until:", code.expires_at.isoformat(), "(single use)")
    print("Open SLG FieldTrack on the admin phone, enter the server URL and this code.")


def revoke_all_admins() -> None:
    with SessionLocal() as db:
        result = db.execute(
            update(Device)
            .where(Device.role == DeviceRole.admin, Device.revoked_at.is_(None))
            .values(revoked_at=utcnow())
        )
        db.commit()
    print(f"Revoked {result.rowcount} admin device(s).")


def main() -> None:
    parser = argparse.ArgumentParser(prog="python -m app.cli")
    parser.add_argument("command", choices=["bootstrap-admin", "revoke-all-admins"])
    args = parser.parse_args()
    {"bootstrap-admin": bootstrap_admin, "revoke-all-admins": revoke_all_admins}[args.command]()


if __name__ == "__main__":
    main()

from conftest import auth


def test_admin_code_is_single_use(client):
    from app.db import SessionLocal
    from app.models import DeviceRole
    from app.routers.devices import issue_pairing_code

    with SessionLocal() as db:
        code = issue_pairing_code(db, DeviceRole.admin, None, None).code
    first = client.post("/api/v1/devices/pair", json={"code": code.lower()})
    assert first.status_code == 200
    assert first.json()["role"] == "admin"
    second = client.post("/api/v1/devices/pair", json={"code": code})
    assert second.status_code == 400


def test_invalid_code_and_missing_token(client):
    assert client.post("/api/v1/devices/pair", json={"code": "ZZZZZZZZ"}).status_code == 400
    assert client.get("/api/v1/dashboard").status_code == 401
    assert client.get("/api/v1/dashboard", headers=auth("nope")).status_code == 401


def test_pairing_is_rate_limited(client):
    codes = [client.post("/api/v1/devices/pair", json={"code": "ZZZZZZZZ"}).status_code for _ in range(12)]
    assert 429 in codes


def test_employee_pairing_and_role_separation(client, admin_token, make_employee):
    employee, token = make_employee()
    me = client.get("/api/v1/devices/me", headers=auth(token)).json()
    assert me["role"] == "employee"
    assert me["employee"]["id"] == employee["id"]
    # Employee devices cannot reach admin endpoints.
    assert client.get("/api/v1/employees", headers=auth(token)).status_code == 403
    assert client.post("/api/v1/location-requests", json={"employee_id": employee["id"]}, headers=auth(token)).status_code == 403
    # Admin devices cannot post fixes or change consent.
    assert client.put("/api/v1/me/permission", json={"sharing_enabled": True}, headers=auth(admin_token)).status_code == 403


def test_repairing_revokes_previous_phone(client, admin_token, make_employee):
    employee, old_token = make_employee()
    pc = client.post("/api/v1/pairing-codes", json={"role": "employee", "employee_id": employee["id"]}, headers=auth(admin_token)).json()
    new_token = client.post("/api/v1/devices/pair", json={"code": pc["code"]}).json()["token"]
    assert client.get("/api/v1/me", headers=auth(old_token)).status_code == 401
    assert client.get("/api/v1/me", headers=auth(new_token)).status_code == 200


def test_admin_can_revoke_device(client, admin_token, make_employee):
    employee, token = make_employee()
    devices = client.get(f"/api/v1/employees/{employee['id']}", headers=auth(admin_token)).json()["devices"]
    assert client.delete(f"/api/v1/devices/{devices[0]['id']}", headers=auth(admin_token)).status_code == 204
    assert client.get("/api/v1/me", headers=auth(token)).status_code == 401


def test_deactivated_employee_loses_access(client, admin_token, make_employee):
    employee, token = make_employee()
    client.patch(f"/api/v1/employees/{employee['id']}", json={"active": False}, headers=auth(admin_token))
    assert client.get("/api/v1/me", headers=auth(token)).status_code == 401

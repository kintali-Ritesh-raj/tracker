from datetime import timedelta

from sqlalchemy import update

from app.db import SessionLocal
from app.models import LocationRequest, utcnow
from app.services.requests import expire_pending
from conftest import FAR, SITE, auth, fix, share


def _receive(ws, event_type: str, limit: int = 10) -> dict:
    for _ in range(limit):
        msg = ws.receive_json()
        if msg["type"] == event_type:
            return msg["data"]
    raise AssertionError(f"no {event_type} event")


def test_websocket_rejects_bad_token(client):
    from starlette.websockets import WebSocketDisconnect

    try:
        with client.websocket_connect("/api/v1/ws?token=bad") as ws:
            ws.receive_json()
        raise AssertionError("should have been rejected")
    except WebSocketDisconnect as exc:
        assert exc.code == 4401


def test_admin_map_updates_live(client, admin_token, make_employee, site):
    employee, token = make_employee()
    share(client, token)
    with client.websocket_connect("/api/v1/ws", subprotocols=["bearer", admin_token]) as ws:
        assert ws.receive_json()["type"] == "hello"
        client.post("/api/v1/locations", json={"fixes": [fix(*SITE)]}, headers=auth(token))
        data = _receive(ws, "location.updated")
        assert data["id"] == employee["id"]
        assert data["status"] == "on_site"
        assert data["last_location"]["latitude"] == SITE[0]


def test_consented_sharing_returns_latest_and_asks_for_fresh_fix(client, admin_token, make_employee):
    employee, token = make_employee()
    share(client, token)
    client.post("/api/v1/locations", json={"fixes": [fix(*FAR, ago=timedelta(minutes=3))]}, headers=auth(token))

    with client.websocket_connect(f"/api/v1/ws?token={token}") as phone:
        phone.receive_json()  # hello
        req = client.post("/api/v1/location-requests", json={"employee_id": employee["id"]}, headers=auth(admin_token)).json()
        assert req["status"] == "approved"
        assert req["auto_approved"] is True
        assert req["awaiting_fresh_fix"] is True
        assert req["location"]["latitude"] == FAR[0]
        assert _receive(phone, "location.refresh")["request_id"] == req["id"]

    done = client.post(
        f"/api/v1/location-requests/{req['id']}/respond",
        json={"decision": "approve", "fix": fix(*SITE)},
        headers=auth(token),
    ).json()
    assert done["fulfilled_at"] is not None
    assert done["awaiting_fresh_fix"] is False
    assert done["location"]["latitude"] == SITE[0]


def test_request_needs_approval_without_consent(client, admin_token, make_employee):
    employee, token = make_employee()
    with client.websocket_connect("/api/v1/ws", subprotocols=["bearer", admin_token]) as admin_ws:
        admin_ws.receive_json()
        req = client.post("/api/v1/location-requests", json={"employee_id": employee["id"]}, headers=auth(admin_token)).json()
        assert req["status"] == "pending"

        inbox = client.get("/api/v1/me/location-requests", headers=auth(token)).json()
        assert [r["id"] for r in inbox] == [req["id"]]

        # A second tap while pending reuses the same request.
        again = client.post("/api/v1/location-requests", json={"employee_id": employee["id"]}, headers=auth(admin_token)).json()
        assert again["id"] == req["id"]

        # Approving without a fix is refused; approving with one fulfils it.
        assert client.post(f"/api/v1/location-requests/{req['id']}/respond", json={"decision": "approve"}, headers=auth(token)).status_code == 422
        done = client.post(
            f"/api/v1/location-requests/{req['id']}/respond",
            json={"decision": "approve", "fix": fix(*SITE)},
            headers=auth(token),
        ).json()
        assert done["status"] == "approved"
        assert done["location"]["latitude"] == SITE[0]
        updated = _receive(admin_ws, "location_request.updated")
        assert updated["id"] == req["id"]

    # The approved one-off fix is visible on the map even though sharing is off.
    markers = client.get("/api/v1/map/employees", headers=auth(admin_token)).json()
    assert [m["id"] for m in markers] == [employee["id"]]


def test_decline(client, admin_token, make_employee):
    employee, token = make_employee()
    req = client.post("/api/v1/location-requests", json={"employee_id": employee["id"]}, headers=auth(admin_token)).json()
    res = client.post(f"/api/v1/location-requests/{req['id']}/respond", json={"decision": "decline"}, headers=auth(token)).json()
    assert res["status"] == "declined"
    assert res["location"] is None
    again = client.post(f"/api/v1/location-requests/{req['id']}/respond", json={"decision": "decline"}, headers=auth(token))
    assert again.status_code == 409


def test_unpaired_employee_is_unavailable(client, admin_token, make_employee):
    employee, _ = make_employee(pair=False)
    req = client.post("/api/v1/location-requests", json={"employee_id": employee["id"]}, headers=auth(admin_token)).json()
    assert req["status"] == "unavailable"


def test_timeout_marks_unavailable(client, admin_token, make_employee):
    employee, token = make_employee()
    req = client.post("/api/v1/location-requests", json={"employee_id": employee["id"]}, headers=auth(admin_token)).json()
    with SessionLocal() as db:
        db.execute(update(LocationRequest).values(expires_at=utcnow() - timedelta(seconds=1)))
        db.commit()
        changed = expire_pending(db)
    assert [r.id for r in changed] == [req["id"]]
    res = client.get(f"/api/v1/location-requests/{req['id']}", headers=auth(admin_token)).json()
    assert res["status"] == "unavailable"
    late = client.post(f"/api/v1/location-requests/{req['id']}/respond", json={"decision": "approve", "fix": fix(*SITE)}, headers=auth(token))
    assert late.status_code == 409


def test_employee_cannot_answer_someone_elses_request(client, admin_token, make_employee):
    e1, _ = make_employee("E1", "Ravi Kumar")
    _, t2 = make_employee("E2", "Sita Devi")
    req = client.post("/api/v1/location-requests", json={"employee_id": e1["id"]}, headers=auth(admin_token)).json()
    res = client.post(f"/api/v1/location-requests/{req['id']}/respond", json={"decision": "decline"}, headers=auth(t2))
    assert res.status_code == 404

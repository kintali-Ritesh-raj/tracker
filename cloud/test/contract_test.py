"""End-to-end contract test for a running SLG FieldTrack backend.

Runs the same scenarios as backend/tests against a live server over HTTP and
WebSocket, so it validates the Cloudflare Worker (or the FastAPI app).

    python cloud/test/contract_test.py --base http://127.0.0.1:8787 --admin-code ABCD2345

The admin code comes from POST /api/v1/bootstrap-admin (Worker logs) or
`python -m app.cli bootstrap-admin` (FastAPI). Use a fresh database: the test
creates employees, teams and sites.
"""
from __future__ import annotations

import argparse
import asyncio
import json
import sys
import time
from datetime import datetime, timedelta, timezone

import httpx
import websockets

SITE = (17.7410, 83.3370)
FAR = (17.7900, 83.3800)
results: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, info: str = "") -> None:
    results.append((name, ok, info))
    print(("PASS " if ok else "FAIL ") + name + (f"  ({info})" if info and not ok else ""))


def fix(lat: float, lng: float, ago: float = 5, accuracy: float = 8, **extra) -> dict:
    t = datetime.now(timezone.utc) - timedelta(seconds=ago)
    return {"latitude": lat, "longitude": lng, "accuracy_m": accuracy, "recorded_at": t.isoformat(), **extra}


async def next_event(ws, wanted: str, timeout: float = 6) -> dict | None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            msg = json.loads(await asyncio.wait_for(ws.recv(), deadline - time.monotonic()))
        except (asyncio.TimeoutError, websockets.ConnectionClosed):
            return None
        if msg["type"] == wanted:
            return msg["data"]
    return None


async def main(base: str, admin_code: str, local_cron: bool) -> int:
    api = base.rstrip("/") + "/api/v1"
    ws_base = api.replace("http", "ws", 1) + "/ws"
    c = httpx.AsyncClient(base_url=api, timeout=20)

    r = await c.post("/devices/pair", json={"code": admin_code, "label": "contract admin"})
    check("admin pairs with code", r.status_code == 200 and r.json()["role"] == "admin", r.text)
    admin = r.json()["token"]
    A = {"Authorization": f"Bearer {admin}"}
    r = await c.post("/devices/pair", json={"code": admin_code})
    check("pairing code is single use", r.status_code == 400)
    check("no token -> 401", (await c.get("/dashboard")).status_code == 401)

    site = (await c.post("/sites", json={"name": "MVP Colony Block A", "latitude": SITE[0], "longitude": SITE[1], "radius_m": 150}, headers=A)).json()
    team = (await c.post("/teams", json={"name": "Housekeeping A"}, headers=A)).json()
    check("team created", team.get("employee_count") == 0, json.dumps(team))
    dup = await c.post("/teams", json={"name": "Housekeeping A"}, headers=A)
    check("duplicate team -> 409", dup.status_code == 409)

    async def employee(code: str, name: str, pair: bool = True):
        e = (await c.post("/employees", json={"employee_code": code, "full_name": name, "role_title": "Cleaning Staff", "team_id": team["id"], "phone": "+919000000000"}, headers=A)).json()
        tok = None
        if pair:
            pc = (await c.post("/pairing-codes", json={"role": "employee", "employee_id": e["id"]}, headers=A)).json()
            tok = (await c.post("/devices/pair", json={"code": pc["code"]})).json()["token"]
        return e, tok

    e1, t1 = await employee("E1", "Ravi Kumar")
    E1 = {"Authorization": f"Bearer {t1}"}
    check("employee detail shape", set(e1) >= {"permission", "devices", "history_enabled", "status", "last_location"}, ",".join(e1))
    check("employee cannot use admin API", (await c.get("/employees", headers=E1)).status_code == 403)
    check("admin cannot change consent", (await c.put("/me/permission", json={"sharing_enabled": True}, headers=A)).status_code == 403)
    check("fixes refused before consent", (await c.post("/locations", json={"fixes": [fix(*SITE)]}, headers=E1)).status_code == 403)

    async with websockets.connect(ws_base, subprotocols=["bearer", admin]) as aws:
        hello = json.loads(await aws.recv())
        check("admin websocket hello", hello["type"] == "hello" and hello["data"]["audience"] == "admins", json.dumps(hello))

        perm = (await c.put("/me/permission", json={"sharing_enabled": True, "background_enabled": True, "history_enabled": True}, headers=E1)).json()
        check("consent recorded", perm["sharing_enabled"] and perm["consented_at"] is not None, json.dumps(perm))

        res = (await c.post("/locations", json={"fixes": [fix(*SITE)]}, headers=E1)).json()
        check("on-site fix", res["accepted"] == 1 and res["status"] == "on_site" and res["latest"]["site_name"] == site["name"], json.dumps(res))
        ev = await next_event(aws, "location.updated")
        check("admin gets live location.updated", ev is not None and ev["id"] == e1["id"] and ev["status"] == "on_site", json.dumps(ev))

        res = (await c.post("/locations", json={"fixes": [fix(*FAR, speed_mps=8)]}, headers=E1)).json()
        check("in-transit fix", res["status"] == "in_transit", json.dumps(res))

        res = (await c.post("/locations", json={"fixes": [fix(*SITE, is_mocked=True), fix(*SITE, ago=-3600), fix(0.0, 0.0)]}, headers=E1)).json()
        check("mock/future/null-island rejected", res["accepted"] == 0 and res["rejected"] == 3, json.dumps(res))
        bad = await c.post("/locations", json={"fixes": [{"latitude": 1, "longitude": 1, "accuracy_m": 5, "recorded_at": "2026-01-01T00:00:00"}]}, headers=E1)
        check("naive timestamp -> 422", bad.status_code == 422, bad.text)

        await c.post("/locations", json={"fixes": [fix(*SITE, ago=3600)]}, headers=E1)
        detail = (await c.get(f"/employees/{e1['id']}", headers=A)).json()
        check("late backlog does not override newer fix", detail["last_location"]["latitude"] == FAR[0], json.dumps(detail["last_location"]))

        # Consented sharing: request auto-approves with latest and asks phone for fresh fix.
        async with websockets.connect(f"{ws_base}?token={t1}") as phone:
            await phone.recv()
            req = (await c.post("/location-requests", json={"employee_id": e1["id"]}, headers=A)).json()
            check("auto-approved request", req["status"] == "approved" and req["auto_approved"] and req["awaiting_fresh_fix"] and req["location"] is not None, json.dumps(req))
            refresh = await next_event(phone, "location.refresh")
            check("phone gets location.refresh", refresh is not None and refresh["request_id"] == req["id"], json.dumps(refresh))
        done = (await c.post(f"/location-requests/{req['id']}/respond", json={"decision": "approve", "fix": fix(*SITE)}, headers=E1)).json()
        check("fresh fix fulfils request", done["fulfilled_at"] is not None and not done["awaiting_fresh_fix"], json.dumps(done))

        # Without consent: pending -> approve with fix.
        e2, t2 = await employee("E2", "Sita Devi")
        E2 = {"Authorization": f"Bearer {t2}"}
        async with websockets.connect(f"{ws_base}?token={t2}") as phone2:
            await phone2.recv()
            req2 = (await c.post("/location-requests", json={"employee_id": e2["id"]}, headers=A)).json()
            check("request pending without consent", req2["status"] == "pending", json.dumps(req2))
            created = await next_event(phone2, "location_request.created")
            check("phone gets location_request.created", created is not None and created["id"] == req2["id"], json.dumps(created))
        again = (await c.post("/location-requests", json={"employee_id": e2["id"]}, headers=A)).json()
        check("second tap reuses pending request", again["id"] == req2["id"])
        inbox = (await c.get("/me/location-requests", headers=E2)).json()
        check("employee inbox lists request", [r["id"] for r in inbox] == [req2["id"]], json.dumps(inbox))
        no_fix = await c.post(f"/location-requests/{req2['id']}/respond", json={"decision": "approve"}, headers=E2)
        check("approve without fix -> 422", no_fix.status_code == 422)
        ok = (await c.post(f"/location-requests/{req2['id']}/respond", json={"decision": "approve", "fix": fix(*SITE)}, headers=E2)).json()
        check("approved with location", ok["status"] == "approved" and ok["location"]["latitude"] == SITE[0], json.dumps(ok))
        upd = await next_event(aws, "location_request.updated")
        check("admin gets location_request.updated", upd is not None, "")
        markers = (await c.get("/map/employees", headers=A)).json()
        check("one-off fix visible on map", {m["id"] for m in markers} == {e1["id"], e2["id"]}, json.dumps([m["id"] for m in markers]))

    # Decline + cross-employee + unpaired.
    e3, t3 = await employee("E3", "Arjun Rao")
    E3 = {"Authorization": f"Bearer {t3}"}
    req3 = (await c.post("/location-requests", json={"employee_id": e3["id"]}, headers=A)).json()
    check("other employee cannot answer", (await c.post(f"/location-requests/{req3['id']}/respond", json={"decision": "decline"}, headers=E1)).status_code == 404)
    dec = (await c.post(f"/location-requests/{req3['id']}/respond", json={"decision": "decline"}, headers=E3)).json()
    check("decline", dec["status"] == "declined", json.dumps(dec))
    check("double answer -> 409", (await c.post(f"/location-requests/{req3['id']}/respond", json={"decision": "decline"}, headers=E3)).status_code == 409)
    e4, _ = await employee("E4", "No Phone", pair=False)
    un = (await c.post("/location-requests", json={"employee_id": e4["id"]}, headers=A)).json()
    check("unpaired -> unavailable", un["status"] == "unavailable", json.dumps(un))

    # Dashboard, history, reports, settings.
    dash = (await c.get("/dashboard", headers=A)).json()
    check("dashboard counts", dash["counts"]["total"] == 4 and dash["counts"]["on_site"] >= 1, json.dumps(dash["counts"]))
    hist = await c.get(f"/employees/{e1['id']}/history", headers=A)
    check("history readable when enabled", hist.status_code == 200 and len(hist.json()) >= 3, hist.text[:200])
    await c.put("/me/permission", json={"sharing_enabled": True, "background_enabled": True, "history_enabled": False}, headers=E1)
    check("history blocked when disabled", (await c.get(f"/employees/{e1['id']}/history", headers=A)).status_code == 403)
    today = datetime.now(timezone.utc).date().isoformat()
    att = (await c.get(f"/reports/attendance?date={today}&tz_offset=0", headers=A)).json()
    check("attendance report", any(r["fixes"] > 0 for r in att), json.dumps(att)[:300])
    visits = (await c.get(f"/reports/site-visits?date={today}&tz_offset=0", headers=A)).json()
    check("site visits report", isinstance(visits, list) and len(visits) >= 1, json.dumps(visits)[:300])
    s = (await c.get("/settings", headers=E1)).json()
    s["request_timeout_seconds"] = 30
    check("settings update", (await c.put("/settings", json=s, headers=A)).json()["request_timeout_seconds"] == 30)

    # Photo upload and fetch.
    png = bytes.fromhex("89504e470d0a1a0a0000000d4948445200000001000000010806000000" "1f15c4890000000d49444154789c6360000002000100e221bc330000000049454e44ae426082")
    up = await c.post(f"/employees/{e1['id']}/photo", files={"file": ("p.png", png, "image/png")}, headers=A)
    check("photo upload", up.status_code == 200 and up.json()["has_photo"], up.text[:200])
    got = await c.get(f"/employees/{e1['id']}/photo", headers=E1)
    check("photo download", got.status_code == 200 and got.content == png, str(got.status_code))

    # Revoke closes the phone's socket with 4401 and the token stops working.
    async with websockets.connect(f"{ws_base}?token={t3}") as phone3:
        await phone3.recv()
        dev = (await c.get(f"/employees/{e3['id']}", headers=A)).json()["devices"][0]["id"]
        t0 = time.monotonic()
        rv = await c.delete(f"/devices/{dev}", headers=A)
        check("revoke is fast", rv.status_code == 204 and time.monotonic() - t0 < 3, f"{rv.status_code} {time.monotonic() - t0:.1f}s")
        # The phone must learn it was revoked: a device.revoked event and/or close code 4401.
        signal = None
        try:
            while signal is None:
                msg = json.loads(await asyncio.wait_for(phone3.recv(), 5))
                if msg["type"] == "device.revoked":
                    signal = "device.revoked"
        except websockets.ConnectionClosed as exc:
            signal = f"close {exc.rcvd.code}" if exc.rcvd else None
        except asyncio.TimeoutError:
            pass
        check("revoked phone is told on its socket", signal in ("device.revoked", "close 4401"), str(signal))
    check("revoked token -> 401", (await c.get("/me", headers=E3)).status_code == 401)
    try:
        async with websockets.connect(f"{ws_base}?token=bad") as bad_ws:
            await asyncio.wait_for(bad_ws.recv(), 5)
        closed = None
    except websockets.ConnectionClosed as exc:
        closed = exc.rcvd.code if exc.rcvd else None
    except Exception as exc:  # noqa: BLE001
        closed = repr(exc)
    check("bad websocket token -> 4401", closed == 4401, str(closed))

    if local_cron:
        # request_timeout_seconds was set to 30 above; wrangler dev --test-scheduled exposes the cron.
        e5, _ = await employee("E5", "Timeout Case")
        req5 = (await c.post("/location-requests", json={"employee_id": e5["id"]}, headers=A)).json()
        await asyncio.sleep(32)
        await httpx.AsyncClient().get(base.rstrip("/") + "/__scheduled", params={"cron": "* * * * *"})
        st = (await c.get(f"/location-requests/{req5['id']}", headers=A)).json()["status"]
        check("cron expires unanswered request -> unavailable", st == "unavailable", st)

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} checks passed")
    await c.aclose()
    return 1 if failed else 0


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--base", default="http://127.0.0.1:8787")
    p.add_argument("--admin-code", required=True)
    p.add_argument("--local-cron", action="store_true", help="also test request expiry via wrangler dev --test-scheduled")
    a = p.parse_args()
    sys.exit(asyncio.run(main(a.base, a.admin_code, a.local_cron)))

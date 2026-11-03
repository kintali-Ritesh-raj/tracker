from datetime import timedelta

from conftest import FAR, SITE, auth, fix, share


def test_fixes_rejected_until_employee_consents(client, make_employee):
    _, token = make_employee()
    res = client.post("/api/v1/locations", json={"fixes": [fix(*SITE)]}, headers=auth(token))
    assert res.status_code == 403


def test_on_site_and_in_transit(client, admin_token, make_employee, site):
    employee, token = make_employee()
    share(client, token)

    res = client.post("/api/v1/locations", json={"fixes": [fix(*SITE)]}, headers=auth(token)).json()
    assert res["accepted"] == 1
    assert res["status"] == "on_site"
    assert res["latest"]["site_name"] == site["name"]

    res = client.post("/api/v1/locations", json={"fixes": [fix(*FAR, speed_mps=8)]}, headers=auth(token)).json()
    assert res["status"] == "in_transit"

    detail = client.get(f"/api/v1/employees/{employee['id']}", headers=auth(admin_token)).json()
    assert detail["last_location"]["latitude"] == FAR[0]
    assert detail["last_location"]["accuracy_m"] == 8.0


def test_invalid_fixes_are_never_stored(client, make_employee):
    _, token = make_employee()
    share(client, token)
    res = client.post(
        "/api/v1/locations",
        json={
            "fixes": [
                fix(*SITE, is_mocked=True),
                fix(*SITE, ago=-timedelta(hours=1)),
                fix(0.0, 0.0),
            ]
        },
        headers=auth(token),
    ).json()
    assert res["accepted"] == 0
    assert res["rejected"] == 3
    assert res["latest"] is None
    assert res["status"] == "offline"


def test_offline_backlog_does_not_override_newer_fix(client, admin_token, make_employee):
    employee, token = make_employee()
    share(client, token)
    client.post("/api/v1/locations", json={"fixes": [fix(*FAR, ago=timedelta(seconds=10))]}, headers=auth(token))
    # A queued fix from an hour ago arrives late after reconnecting.
    client.post("/api/v1/locations", json={"fixes": [fix(*SITE, ago=timedelta(hours=1))]}, headers=auth(token))
    detail = client.get(f"/api/v1/employees/{employee['id']}", headers=auth(admin_token)).json()
    assert detail["last_location"]["latitude"] == FAR[0]


def test_stale_fix_means_offline_and_low_accuracy_flag(client, admin_token, make_employee):
    employee, token = make_employee()
    share(client, token)
    res = client.post(
        "/api/v1/locations", json={"fixes": [fix(*SITE, ago=timedelta(minutes=40), accuracy=250)]}, headers=auth(token)
    ).json()
    assert res["status"] == "offline"
    assert res["latest"]["low_accuracy"] is True


def test_pausing_sharing_takes_employee_off_the_map(client, admin_token, make_employee):
    employee, token = make_employee()
    share(client, token)
    client.post("/api/v1/locations", json={"fixes": [fix(*SITE)]}, headers=auth(token))
    assert len(client.get("/api/v1/map/employees", headers=auth(admin_token)).json()) == 1
    share(client, token, enabled=False)
    assert client.get("/api/v1/map/employees", headers=auth(admin_token)).json() == []
    assert client.get(f"/api/v1/employees/{employee['id']}", headers=auth(admin_token)).json()["status"] == "offline"


def test_employee_without_fix_has_no_marker(client, admin_token, make_employee):
    _, token = make_employee()
    share(client, token)
    assert client.get("/api/v1/map/employees", headers=auth(admin_token)).json() == []


def test_dashboard_and_team_breakdown(client, admin_token, make_employee, site):
    team = client.post("/api/v1/teams", json={"name": "Housekeeping A"}, headers=auth(admin_token)).json()
    _, t1 = make_employee("E1", "Ravi Kumar", team["id"])
    _, t2 = make_employee("E2", "Sita Devi", team["id"])
    make_employee("E3", "Unpaired Person", pair=False)
    share(client, t1)
    share(client, t2)
    client.post("/api/v1/locations", json={"fixes": [fix(*SITE)]}, headers=auth(t1))
    client.post("/api/v1/locations", json={"fixes": [fix(*FAR)]}, headers=auth(t2))
    dash = client.get("/api/v1/dashboard", headers=auth(admin_token)).json()
    assert dash["counts"] == {"total": 3, "on_site": 1, "in_transit": 1, "offline": 1}
    team_row = next(t for t in dash["teams"] if t["team_id"] == team["id"])
    assert team_row["counts"]["total"] == 2
    on_site = client.get("/api/v1/map/employees?status=on_site", headers=auth(admin_token)).json()
    assert [e["employee_code"] for e in on_site] == ["E1"]


def test_history_respects_employee_choice(client, admin_token, make_employee):
    employee, token = make_employee()
    share(client, token)
    client.post("/api/v1/locations", json={"fixes": [fix(*SITE), fix(*FAR, ago=timedelta(seconds=1))]}, headers=auth(token))
    hist = client.get(f"/api/v1/employees/{employee['id']}/history", headers=auth(admin_token))
    assert hist.status_code == 200 and len(hist.json()) == 2
    client.put(
        "/api/v1/me/permission",
        json={"sharing_enabled": True, "background_enabled": True, "history_enabled": False},
        headers=auth(token),
    )
    assert client.get(f"/api/v1/employees/{employee['id']}/history", headers=auth(admin_token)).status_code == 403


def test_attendance_report(client, admin_token, make_employee, site):
    from datetime import datetime, timezone

    _, token = make_employee()
    share(client, token)
    client.post(
        "/api/v1/locations",
        json={"fixes": [fix(*SITE, ago=timedelta(minutes=12)), fix(*SITE, ago=timedelta(minutes=2))]},
        headers=auth(token),
    )
    today = datetime.now(timezone.utc).date().isoformat()
    rows = client.get(f"/api/v1/reports/attendance?date={today}&tz_offset=0", headers=auth(admin_token)).json()
    assert rows[0]["fixes"] == 2
    assert rows[0]["on_site_minutes"] == 10
    assert rows[0]["sites"] == [site["name"]]
    visits = client.get(f"/api/v1/reports/site-visits?date={today}&tz_offset=0", headers=auth(admin_token)).json()
    assert len(visits) == 1

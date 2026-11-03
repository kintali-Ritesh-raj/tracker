import threading

from starlette.websockets import WebSocketDisconnect

from conftest import auth


def test_revoking_connected_phone_closes_its_socket(client, admin_token, make_employee):
    employee, token = make_employee()
    devices = client.get(f"/api/v1/employees/{employee['id']}", headers=auth(admin_token)).json()["devices"]
    with client.websocket_connect(f"/api/v1/ws?token={token}") as phone:
        assert phone.receive_json()["type"] == "hello"
        result = {}
        t = threading.Thread(target=lambda: result.update(
            code=client.delete(f"/api/v1/devices/{devices[0]['id']}", headers=auth(admin_token)).status_code))
        t.start()
        t.join(timeout=8)
        assert not t.is_alive(), "revoke request hung"
        assert result["code"] == 204
        try:
            while True:
                phone.receive_json()
        except WebSocketDisconnect as exc:
            assert exc.code == 4401

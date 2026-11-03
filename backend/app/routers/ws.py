"""Realtime channel. Admin devices receive map/request events; employee devices receive
requests addressed to them."""
from __future__ import annotations

import asyncio
import contextlib

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from starlette.concurrency import run_in_threadpool

from ..db import SessionLocal
from ..models import DeviceRole
from ..realtime import ADMINS, employee_audience, hub
from ..security import device_for_token

router = APIRouter()

PING_INTERVAL_SECONDS = 25


def _authenticate(token: str | None) -> tuple[int, str] | None:
    with SessionLocal() as db:
        device = device_for_token(db, token)
        if device is None:
            return None
        audience = ADMINS if device.role == DeviceRole.admin else employee_audience(device.employee_id)
        return device.id, audience


def _token_from(websocket: WebSocket) -> tuple[str | None, str | None]:
    """Token from `Sec-WebSocket-Protocol: bearer, <token>` (preferred) or `?token=`."""
    protocols = [p.strip() for p in websocket.headers.get("sec-websocket-protocol", "").split(",") if p.strip()]
    if len(protocols) == 2 and protocols[0].lower() == "bearer":
        return protocols[1], "bearer"
    return websocket.query_params.get("token"), None


@router.websocket("/ws")
async def realtime(websocket: WebSocket) -> None:
    token, subprotocol = _token_from(websocket)
    identity = await run_in_threadpool(_authenticate, token)
    if identity is None:
        await websocket.close(code=4401, reason="Unauthorized")
        return
    device_id, audience = identity
    await websocket.accept(subprotocol=subprotocol)
    conn = await hub.register(websocket, device_id, audience)
    await hub.send(conn, {"type": "hello", "data": {"device_id": device_id, "audience": audience}})

    async def keepalive() -> None:
        while True:
            await asyncio.sleep(PING_INTERVAL_SECONDS)
            if not await hub.send(conn, {"type": "ping", "data": {}}):
                return

    pinger = asyncio.create_task(keepalive())
    try:
        while True:
            # Clients only send pongs; anything else is ignored.
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        pinger.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await pinger
        hub.unregister(conn)

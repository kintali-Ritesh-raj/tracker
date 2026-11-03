"""WebSocket connection hub.

Route handlers are synchronous (they run in Starlette's worker threads), so they call
`hub.publish(...)`, which hops back onto the event loop with `anyio.from_thread`.
Async code (the WebSocket endpoint, the expiry sweeper) awaits `hub.dispatch(...)`.
"""
from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field
from typing import Any

import anyio.from_thread
from fastapi import WebSocket

log = logging.getLogger(__name__)

ADMINS = "admins"


def employee_audience(employee_id: int) -> str:
    return f"employee:{employee_id}"


@dataclass(eq=False)
class Connection:
    websocket: WebSocket
    device_id: int
    audience: str
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)


class Hub:
    def __init__(self) -> None:
        self._connections: set[Connection] = set()
        # Strong references so fire-and-forget tasks are not garbage collected.
        self._tasks: set[asyncio.Task] = set()

    async def register(self, websocket: WebSocket, device_id: int, audience: str) -> Connection:
        conn = Connection(websocket, device_id, audience)
        self._connections.add(conn)
        return conn

    def unregister(self, conn: Connection) -> None:
        self._connections.discard(conn)

    def is_connected(self, audience: str) -> bool:
        return any(c.audience == audience for c in self._connections)

    async def send(self, conn: Connection, message: dict[str, Any]) -> bool:
        try:
            async with conn.lock:
                await asyncio.wait_for(conn.websocket.send_json(message), timeout=5)
            return True
        except Exception:  # noqa: BLE001 — any send failure means the socket is dead
            self.unregister(conn)
            return False

    async def dispatch(self, audiences: list[str], event: str, data: dict[str, Any]) -> int:
        message = {"type": event, "data": data}
        targets = [c for c in list(self._connections) if c.audience in audiences]
        results = await asyncio.gather(*(self.send(c, message) for c in targets))
        return sum(results)

    async def close_device(self, device_id: int) -> None:
        for conn in [c for c in list(self._connections) if c.device_id == device_id]:
            self.unregister(conn)
            try:
                await conn.websocket.close(code=4401, reason="Device revoked")
            except Exception:  # noqa: BLE001
                pass

    def publish(self, audiences: list[str], event: str, data: dict[str, Any]) -> None:
        """Thread-safe fire from synchronous route handlers."""
        try:
            anyio.from_thread.run(self.dispatch, audiences, event, data)
        except RuntimeError:
            # Not inside an anyio worker thread (e.g. CLI scripts) — nobody to notify.
            log.debug("Skipped realtime publish of %s outside the event loop", event)

    def publish_close(self, device_id: int) -> None:
        try:
            anyio.from_thread.run(self.close_device, device_id)
        except RuntimeError:
            pass


hub = Hub()

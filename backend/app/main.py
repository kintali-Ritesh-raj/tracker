"""FastAPI application entrypoint: `uvicorn app.main:app`."""
from __future__ import annotations

import asyncio
import contextlib
import logging
from collections.abc import AsyncIterator

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.concurrency import run_in_threadpool

from .config import settings
from .db import SessionLocal
from .realtime import ADMINS, employee_audience, hub
from .routers import admin, catalog, devices, employees, tracking, ws
from .services import push
from .services.requests import expire_pending

log = logging.getLogger("slg")

API_PREFIX = "/api/v1"
SWEEP_INTERVAL_SECONDS = 10


def _sweep() -> list[dict]:
    with SessionLocal() as db:
        return [r.model_dump(mode="json") for r in expire_pending(db)]


async def _request_sweeper() -> None:
    """Moves timed-out pending location requests to `unavailable`."""
    while True:
        await asyncio.sleep(SWEEP_INTERVAL_SECONDS)
        try:
            for payload in await run_in_threadpool(_sweep):
                await hub.dispatch(
                    [ADMINS, employee_audience(payload["employee_id"])], "location_request.updated", payload
                )
        except Exception:  # noqa: BLE001 — keep the sweeper alive
            log.exception("Request sweeper failed")


@contextlib.asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    settings.upload_dir.mkdir(parents=True, exist_ok=True)
    if not push.push_enabled():
        log.warning("FCM disabled: set FIREBASE_CREDENTIALS_FILE to push to backgrounded phones.")
    if not settings.google_geocoding_api_key:
        log.warning("Geocoding disabled: set GOOGLE_GEOCODING_API_KEY for readable addresses.")
    task = asyncio.create_task(_request_sweeper())
    try:
        yield
    finally:
        task.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task


app = FastAPI(title="SLG FieldTrack API", version="1.0.0", lifespan=lifespan)

if settings.cors_origins:
    app.add_middleware(
        CORSMiddleware,
        allow_origins=[o.strip() for o in settings.cors_origins.split(",")],
        allow_methods=["*"],
        allow_headers=["*"],
    )

for module in (devices, catalog, employees, tracking, admin, ws):
    app.include_router(module.router, prefix=API_PREFIX)


@app.get(f"{API_PREFIX}/health")
def health() -> dict[str, object]:
    return {"status": "ok", "push": push.push_enabled(), "geocoding": bool(settings.google_geocoding_api_key)}

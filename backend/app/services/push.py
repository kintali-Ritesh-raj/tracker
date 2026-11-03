"""Firebase Cloud Messaging. Optional: without credentials, pushes are skipped and the
system relies on WebSockets (requests to unreachable devices become `unavailable`)."""
from __future__ import annotations

import logging
from functools import lru_cache

from ..config import settings

log = logging.getLogger(__name__)


@lru_cache(maxsize=1)
def _messaging():
    if not settings.firebase_credentials_file:
        return None
    try:
        import firebase_admin
        from firebase_admin import credentials, messaging

        if not firebase_admin._apps:  # noqa: SLF001 — documented way to check init
            firebase_admin.initialize_app(credentials.Certificate(settings.firebase_credentials_file))
        return messaging
    except Exception as exc:  # noqa: BLE001
        log.error("Firebase initialisation failed: %s", exc)
        return None


def push_enabled() -> bool:
    return _messaging() is not None


def send_data(token: str | None, data: dict[str, str], title: str | None = None, body: str | None = None) -> bool:
    """Send a high-priority data message. Returns True when FCM accepted it."""
    messaging = _messaging()
    if messaging is None or not token:
        return False
    notification = (
        messaging.AndroidNotification(title=title, body=body, channel_id="location_requests")
        if title
        else None
    )
    message = messaging.Message(
        token=token,
        data=data,
        android=messaging.AndroidConfig(priority="high", ttl=300, notification=notification),
    )
    try:
        messaging.send(message)
        return True
    except Exception as exc:  # noqa: BLE001
        log.warning("FCM send failed: %s", exc)
        return False

"""Reverse geocoding through the Google Geocoding API, cached on a ~11 m grid."""
from __future__ import annotations

import logging

import httpx
from sqlalchemy.orm import Session

from ..config import settings
from ..models import GeocodeCache

log = logging.getLogger(__name__)

_URL = "https://maps.googleapis.com/maps/api/geocode/json"


def cache_key(latitude: float, longitude: float) -> str:
    return f"{latitude:.4f},{longitude:.4f}"


def _lookup(latitude: float, longitude: float) -> str | None:
    if not settings.google_geocoding_api_key:
        return None
    try:
        response = httpx.get(
            _URL,
            params={
                "latlng": f"{latitude},{longitude}",
                "key": settings.google_geocoding_api_key,
                "result_type": "street_address|premise|route|sublocality|locality",
            },
            timeout=4.0,
        )
        payload = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        log.warning("Geocoding request failed: %s", exc)
        return None
    if payload.get("status") != "OK" or not payload.get("results"):
        if payload.get("status") not in ("OK", "ZERO_RESULTS"):
            log.warning("Geocoding error: %s %s", payload.get("status"), payload.get("error_message"))
        return None
    return payload["results"][0].get("formatted_address", "")[:255] or None


def reverse_geocode(db: Session, latitude: float, longitude: float) -> str | None:
    key = cache_key(latitude, longitude)
    cached = db.get(GeocodeCache, key)
    if cached is not None:
        return cached.address
    address = _lookup(latitude, longitude)
    if address:
        db.merge(GeocodeCache(key=key, address=address))
    return address

# SLG FieldTrack — Architecture

SLG FieldTrack lets SLG Housekeeping & Facility Services management see where field
employees are working, check their current location and request fresh GPS fixes.

```
┌────────────────────────────┐        HTTPS / WSS        ┌──────────────────────────┐
│ Flutter app (one codebase) │ ────────────────────────▶ │ FastAPI backend          │
│  • Admin mode              │ ◀──────────────────────── │  • REST  /api/v1/...     │
│  • Employee mode           │      WebSocket events     │  • WS    /api/v1/ws      │
└────────────┬───────────────┘                           │  • Expiry sweeper task   │
             │ FCM push (data)                           └──────┬─────────┬─────────┘
             ▼                                                  │         │
     Firebase Cloud Messaging ◀────── firebase-admin ───────────┘         │
                                                                          ▼
                       Google Geocoding API ◀── reverse geocode ──  PostgreSQL
```

## 1. Apps

A single Flutter app ships two interfaces. The role is decided by the pairing code the
device redeems, never by the user picking it:

| Mode     | Paired by                      | Screens                                                                 |
|----------|--------------------------------|-------------------------------------------------------------------------|
| Admin    | Bootstrap code (server CLI) or a code issued by another admin | Dashboard, Live Map, Employees, Employee Details, Request Location, Reports, More/Settings, management screens |
| Employee | Code issued by an admin for that employee | Sharing home (consent toggles, status, last fix), incoming request approve/decline, permissions health |

### Authentication without a login screen — device authorization

1. On first deploy the operator runs `python -m app.cli bootstrap-admin` on the server.
   It prints a one-time 8-character admin pairing code (valid 30 minutes).
2. The admin phone enters the server URL + code → `POST /api/v1/devices/pair`.
   The server returns a random 256-bit **device token** once; only its SHA-256 hash
   is stored. The phone keeps the token in Android Keystore-backed secure storage.
3. The admin creates employees and taps *Pair device* → server issues a one-time
   employee pairing code bound to that employee (valid 24 h).
4. The employee phone redeems it the same way and receives an employee-scoped token.
5. Every REST call and the WebSocket carry `Authorization: Bearer <token>`.
   Admin endpoints require `role=admin`. Tokens are revocable per device
   (`DELETE /devices/{id}`), which immediately disconnects the socket.

There are no passwords and no sign-up. Losing a phone = revoke its device.

### Transport security

* Production runs behind TLS (nginx/Caddy) — the app refuses plain `http://` for
  non-local hosts unless built with `--dart-define=ALLOW_INSECURE=true` (development).
* Pairing endpoint is rate-limited per IP; codes are single-use and expire.
* Server keys (Geocoding, Firebase service account) live only on the backend.

## 2. Location pipeline

```
Employee phone                                    Backend                          Admin phones
──────────────                                    ───────                          ────────────
geolocator stream (Android Fused Location)
  ├─ foreground service + ongoing notification
  ├─ distanceFilter 25 m / interval 60 s
  ▼
Outbox (SharedPreferences, max 500 fixes)
  ▼ batch POST /locations (when online)  ─────▶  validate (accuracy, timestamp, range)
                                                 store location_updates
                                                 compute status (site geofence/speed)
                                                 reverse geocode (cached, ~50 m grid)
                                                 broadcast `location.updated` ───────▶ map marker moves
```

* **Poor GPS** – fixes with accuracy worse than 100 m are stored but flagged
  `low_accuracy`; the admin UI shows the accuracy circle and a "weak signal" chip.
* **No internet** – fixes queue in the outbox with their original timestamps and
  are flushed in order on reconnect (`connectivity_plus`). The server orders by
  `recorded_at`, so late fixes never overwrite newer positions.
* **Battery restrictions** – the employee home screen checks
  `ignoreBatteryOptimizations`, background-location permission and location
  services, and shows a fix-it row for each failing check. The device also sends a
  heartbeat (`POST /devices/heartbeat`) with battery level and permission state.
* **Offline devices** – status becomes `offline` when the last fix is older than
  `OFFLINE_AFTER_MINUTES` (default 15) or sharing is paused. The UI always shows
  "Last updated N min ago"; it never invents a position. An employee without any
  real fix has no marker and shows "No location yet".

### Status rules (server-side, `app/services/status.py`)

| Status     | Rule                                                                                  |
|------------|---------------------------------------------------------------------------------------|
| on_site    | Latest fix is fresh and inside any active site's geofence (`radius_m`, default 150 m) |
| in_transit | Latest fix is fresh and outside every site                                             |
| offline    | No fix, fix older than threshold, sharing disabled, or device revoked                  |

## 3. Location requests

```
Admin taps "Send Request"
   POST /location-requests {employee_id}
        │
        ├─ employee has continuous sharing consent?
        │     yes → status=approved, response includes latest fix immediately,
        │           device is pushed a silent `refresh` to obtain a fresh fix
        │     no  → status=pending, push "Location requested by <admin>"
        │
        ├─ no paired device / no push token and socket not connected → unavailable
        │
Employee phone (FCM or socket) → Approve / Decline
   POST /location-requests/{id}/respond {decision, location?}
        │  approve → one-shot high-accuracy fix attached → status=approved, fulfilled_at
        │  decline → status=declined
        ▼
Broadcast `location_request.updated` (+ `location.updated`) to admins
Pending requests older than REQUEST_TIMEOUT_SECONDS (120) → unavailable (sweeper)
```

## 4. Database schema (PostgreSQL)

| Table                | Key columns                                                                                                   |
|----------------------|---------------------------------------------------------------------------------------------------------------|
| teams                | id, name (unique), description, color, created_at                                                             |
| sites                | id, name, address, latitude, longitude, radius_m, active, created_at                                          |
| employees            | id, employee_code (unique), full_name, phone, role_title, team_id→teams, photo_path, active, created_at        |
| devices              | id, role (admin/employee), employee_id→employees (null for admin), label, token_hash (unique), platform, app_version, push_token, battery_level, permission_state (jsonb), last_seen_at, revoked_at, created_at |
| pairing_codes        | id, code_hash (unique), role, employee_id, created_by_device_id, expires_at, used_at                          |
| location_permissions | id, employee_id (unique)→employees, sharing_enabled, background_enabled, history_enabled, consented_at, updated_at |
| location_updates     | id (bigserial), employee_id, device_id, latitude, longitude, accuracy_m, altitude_m, speed_mps, heading, recorded_at, received_at, source (stream/request/manual), site_id, address, low_accuracy, request_id |
| location_requests    | id, employee_id, requested_by_device_id, status (pending/approved/declined/unavailable), message, created_at, responded_at, fulfilled_at, location_update_id, expires_at |
| geocode_cache        | key (lat/lng rounded 4 dp), address, created_at                                                               |
| app_settings         | key (pk), value (jsonb), updated_at                                                                           |

Indexes: `location_updates(employee_id, recorded_at desc)`, `location_requests(employee_id, created_at desc)`,
`location_requests(status, expires_at)`, `devices(employee_id)`.

## 5. REST API (`/api/v1`, JSON, bearer device token)

| Method & path                              | Role     | Purpose                                         |
|--------------------------------------------|----------|-------------------------------------------------|
| POST   /devices/pair                       | none     | Redeem pairing code → `{token, device, role, employee}` |
| GET    /devices/me                         | any      | Current device + role                            |
| POST   /devices/heartbeat                  | any      | push_token, battery, permission state            |
| GET    /devices                            | admin    | List devices                                     |
| DELETE /devices/{id}                       | admin    | Revoke device                                    |
| POST   /pairing-codes                      | admin    | Issue code `{role, employee_id?}`                |
| GET/POST /teams, PATCH/DELETE /teams/{id}  | admin    | Team CRUD                                        |
| GET/POST /sites, PATCH/DELETE /sites/{id}  | admin    | Site CRUD                                        |
| GET/POST /employees                        | admin    | List (filters: team_id, status, q) / create      |
| GET/PATCH/DELETE /employees/{id}           | admin    | Detail incl. latest location, permission, device |
| POST   /employees/{id}/photo               | admin    | Multipart photo upload                           |
| GET    /employees/{id}/photo               | any auth | Photo bytes                                      |
| GET    /employees/{id}/history?from&to     | admin    | Location history (only if history_enabled)       |
| GET    /dashboard                          | admin    | Counts + team-wise status                        |
| GET    /map/employees?team_id&status       | admin    | Markers: sharing employees with real fixes       |
| POST   /locations                          | employee | Batch of fixes `{fixes:[...]}`                   |
| GET/PUT /me/permission                     | employee | Read / update own consent                        |
| GET    /me                                 | employee | Own profile, status, last fix                    |
| GET    /me/location-requests?status=pending| employee | Incoming requests                                |
| POST   /location-requests                  | admin    | Create request                                   |
| GET    /location-requests?employee_id      | admin    | Recent requests                                  |
| GET    /location-requests/{id}             | admin/emp| Single request                                   |
| POST   /location-requests/{id}/respond     | employee | `{decision: approve|decline, fix?}`             |
| GET    /reports/attendance?date            | admin    | First/last seen, on-site minutes per employee    |
| GET    /reports/site-visits?date           | admin    | Visits per site                                  |
| GET/PUT /settings                          | admin    | Offline threshold, request timeout, intervals    |
| GET    /health                             | none     | Liveness                                         |

Errors: `{"detail": "<human message>"}` with standard status codes.

## 6. WebSocket (`/api/v1/ws`, token via `Sec-WebSocket-Protocol` or `?token=`)

Server → client messages are `{"type": "...", "data": {...}}`.

| Event                       | Audience            | Payload                                   |
|-----------------------------|---------------------|-------------------------------------------|
| `location.updated`          | admins              | employee_id, location, status             |
| `employee.status`           | admins              | employee_id, status, sharing_enabled      |
| `location_request.created`  | target employee     | request                                    |
| `location_request.updated`  | admins + employee   | request                                    |
| `location.refresh`          | target employee     | request_id (consented sharing → fresh fix)|
| `ping`                      | all                 | — (client answers `pong`; 30 s keep-alive)|

## 7. Push (FCM data messages)

`location_request` (needs approval), `location_refresh` (silent; app wakes the
foreground service for a one-shot fix). FCM is optional: without
`FIREBASE_CREDENTIALS_FILE` the server relies on WebSockets and requests to devices
that are not connected become `unavailable` after the timeout.

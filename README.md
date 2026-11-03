# SLG FieldTrack

Employee location tracking for **SLG Housekeeping & Facility Services**. Management
sees where field staff are working on a live map, checks each person's current
location, and requests a fresh GPS fix. Every position comes from an employee who
consented, either by turning on sharing or by approving a specific request.

| Part | Stack | Folder |
|------|-------|--------|
| Mobile app (admin + employee modes) | Flutter 3.41, Google Maps SDK, geolocator (Android Fused Location), FCM | [`app/`](app) |
| Backend API + realtime | Python FastAPI, SQLAlchemy 2, WebSockets | [`backend/`](backend) |
| Database | PostgreSQL 14+ (Alembic migrations) | [`backend/migrations`](backend/migrations) |

Architecture, schema, API and WebSocket contracts: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

---

## 1. Backend

```bash
cd backend
python -m venv .venv
.venv/Scripts/activate          # Windows  (macOS/Linux: source .venv/bin/activate)
pip install -r requirements.txt
cp .env.example .env            # then edit DATABASE_URL and keys
createdb slg_fieldtrack
alembic upgrade head
uvicorn app.main:app --host 0.0.0.0 --port 8000
```

### Keys and services

| Setting | Needed for | Where it comes from |
|---------|-----------|---------------------|
| `GOOGLE_GEOCODING_API_KEY` | Readable addresses on Employee Details | Google Cloud → a **server** key with the Geocoding API enabled |
| `FIREBASE_CREDENTIALS_FILE` | Waking phones that are closed or in the background | Firebase console → Project settings → Service accounts → private key JSON |

Both are optional. Without geocoding the app shows coordinates and "Address
unavailable". Without FCM, requests reach phones only while the app is open; others
become **Unavailable** after the timeout.

### Production checklist

* Serve behind TLS (Caddy or nginx). The app refuses `http://` except on a local network.
* Run one uvicorn worker per process; the realtime hub is in-memory. Scale with
  sticky sessions or move the hub to Redis pub/sub.
* Keep `backend/.env`, `uploads/` and the Firebase JSON out of git (already ignored).
* Back up PostgreSQL; `location_updates` grows by roughly one row per employee per minute while sharing is on.

### First admin phone (no login screen)

```bash
python -m app.cli bootstrap-admin
```

This prints a single-use code that is valid for 30 minutes. Enter it with the server
address on the admin phone. That admin can then pair more admin phones (More →
Paired Devices) and every employee phone (employee profile → Pair a phone). Lost a
phone? Revoke it from another admin phone. In an emergency, run
`python -m app.cli revoke-all-admins` and bootstrap again.

### Tests

```bash
createdb slg_fieldtrack_test
cd backend && .venv/Scripts/python -m pytest -q
```

The 26 tests cover pairing and role separation, revocation, fix validation (mock,
future and null-island fixes are rejected), late offline batches, geofence status,
history consent, reports, live WebSocket updates, and every location-request state.

---

## 2. Mobile app

```bash
cd app
flutter pub get
```

1. **Google Maps key.** Add it to `app/android/secrets.properties` (git-ignored; Flutter rewrites `local.properties` on each build):
   ```
   MAPS_API_KEY=AIza...your Android-restricted Maps SDK key
   ```
2. **Firebase (optional, recommended).** Register an Android app with package
   `com.slg.fieldtrack` and put `google-services.json` in `app/android/app/`. The
   build applies the Google Services plugin only when that file exists.
3. Run on a phone:
   ```bash
   flutter run --dart-define=SERVER_URL=https://track.your-domain.in
   ```
   For a LAN dev server: `--dart-define=SERVER_URL=http://192.168.1.20:8000`.
   Debug builds allow cleartext traffic; release builds do not.
4. Release build: add a signing config (`android/key.properties`), then run
   `flutter build apk --release` or `flutter build appbundle`.

### How each mode works

**Admin mode** has five tabs, as in the design:
* **Home**: greeting, On Site / In Transit / Offline counts, quick actions and team status.
* **Map**: photo markers ringed in status colour, status and team filters, zoom, recenter and map style, site geofences, an accuracy circle, and the last-updated time.
* **Employees**: search and filters, then Employee Details with ID, team, address, latitude/longitude, accuracy, last update, sharing status, Call, Message and View on Map.
* **Reports**: attendance and site visits for any day.
* **More**: employees, teams, sites, settings, permissions, devices and about.

**Employee mode:**
* One switch to share location, behind a plain-language consent dialog.
* A foreground-service notification stays visible while sharing.
* A checklist covers location on, "Allow all the time", precise location, notifications and battery restriction.
* Fixes queue offline and upload in order when the phone reconnects.
* Location requests show as an Approve / Decline sheet. With continuous sharing already on, a request is answered automatically with a fresh fix.

### Things only a real phone can verify

These flows are covered by backend tests and a live server smoke test. GPS
behaviour itself needs a physical Android phone:

* Background updates with the screen off for 30+ minutes (with and without battery restriction).
* Airplane mode for 10 minutes while walking. The fixes should arrive in order on reconnect, and the map should not jump backwards.
* Indoor or basement weak GPS: the "Waiting for GPS" state and accuracy warnings.
* FCM request while the app is swiped away. Note that Android stops the foreground
  service when the user force-stops the app; sharing resumes when they reopen it.

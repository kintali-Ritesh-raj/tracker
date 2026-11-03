# SLG FieldTrack on Cloudflare

The production backend and the APK download page run as one Cloudflare Worker
(`tracker`) on the **free** Workers plan.

| Piece | Cloudflare product | Where |
|-------|--------------------|-------|
| REST API `/api/v1/*` | Worker (TypeScript, Hono) | `cloud/src/index.ts` |
| Database | D1 (SQLite) `slg-fieldtrack` | schema in `cloud/src/db.ts`, created on first request |
| Realtime WebSocket `/api/v1/ws` | Durable Object `Hub` (hibernating sockets) | `cloud/src/hub.ts` |
| Request expiry | Cron trigger, every minute | `scheduled()` in `index.ts` |
| Download page + APKs | Static assets | `cloud/public/` |

The API contract is identical to the FastAPI backend in `backend/`, so the
Android app works against either. The FastAPI version is kept for self-hosting
on a server with PostgreSQL.

**Live:** https://tracker.riteshrajkintali.workers.dev

## Deploys

Workers Builds is connected to `kintali-Ritesh-raj/tracker`. Every push to `main`
runs `npx wrangler deploy` using `wrangler.jsonc` at the repo root.

## First admin phone

1. Run `curl -X POST https://tracker.riteshrajkintali.workers.dev/api/v1/bootstrap-admin`.
   This works only while no admin phone is paired.
2. In the Cloudflare dashboard, open **Workers & Pages → tracker → Observability → Logs**
   and find the line `SLG FieldTrack admin pairing code: XXXXXXXX`. Only the account owner can see it.
3. Install the app from the download page and enter that code. Pair everyone else from inside the app.

## Optional secrets

Set these in **tracker → Settings → Variables and secrets**:

| Secret | Enables |
|--------|---------|
| `GOOGLE_GEOCODING_API_KEY` | Readable addresses (server key with the Geocoding API enabled) |
| `FIREBASE_SERVICE_ACCOUNT` | Push to closed phones (full service-account JSON); the app also needs `google-services.json` |

## Publishing a new app version

```bash
cd app
# bump `version:` in pubspec.yaml first
flutter build apk --release --split-per-abi --dart-define=SERVER_URL=https://tracker.riteshrajkintali.workers.dev
```

Copy `app-arm64-v8a-release.apk` and `app-armeabi-v7a-release.apk` into
`cloud/public/download/`, then update the file names, sizes and checksums in
`cloud/public/index.html`. Each file must stay under 25 MiB. Release builds are
signed with `app/android/upload-keystore.jks` (git-ignored). **Back that file and
`app/android/key.properties` up.** Without them, phones can't update the app in place.

## Local development and tests

```bash
npm install
npx wrangler dev --port 8787 --test-scheduled
curl -X POST http://127.0.0.1:8787/api/v1/bootstrap-admin     # code appears in the wrangler output
python cloud/test/contract_test.py --admin-code <CODE> --local-cron
```

The contract test makes 45 checks over HTTP and WebSocket. It covers pairing,
roles, revocation, fix validation, geofence status, live events, every
location-request state including cron expiry, history consent, reports, settings
and photos. To start over with an empty database, delete `.wrangler/state`.

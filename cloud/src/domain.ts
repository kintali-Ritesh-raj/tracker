// Core domain logic, ported from backend/app/services/*. Response shapes match
// backend/app/schemas.py exactly so the Flutter app works against either backend.

import type { DeviceRow } from './auth';
import { type Env, type Waiter, all, first, insert, isoAfter, nowIso, run } from './db';
import { ADMINS, employeeAudience, publish } from './hub';
import { fail, toBool } from './http';
import { sendPush } from './push';

// ---------------------------------------------------------------- settings

export interface Settings {
  offline_after_minutes: number;
  request_timeout_seconds: number;
  default_site_radius_m: number;
  tracking_interval_seconds: number;
  tracking_distance_filter_m: number;
  history_retention_days: number;
}

export const SETTINGS_LIMITS: Record<keyof Settings, [number, number]> = {
  offline_after_minutes: [1, 1440],
  request_timeout_seconds: [30, 3600],
  default_site_radius_m: [20, 5000],
  tracking_interval_seconds: [15, 3600],
  tracking_distance_filter_m: [0, 1000],
  history_retention_days: [1, 3650],
};

export async function loadSettings(env: Env): Promise<Settings> {
  const base: Settings = {
    offline_after_minutes: Number(env.OFFLINE_AFTER_MINUTES || 15),
    request_timeout_seconds: Number(env.REQUEST_TIMEOUT_SECONDS || 120),
    default_site_radius_m: Number(env.DEFAULT_SITE_RADIUS_M || 150),
    tracking_interval_seconds: 60,
    tracking_distance_filter_m: 25,
    history_retention_days: 90,
  };
  const row = await first<{ value: string }>(env.DB, `SELECT value FROM app_settings WHERE key = 'general'`);
  if (row) {
    const saved = JSON.parse(row.value) as Partial<Settings>;
    for (const key of Object.keys(base) as (keyof Settings)[]) {
      if (typeof saved[key] === 'number') base[key] = saved[key]!;
    }
  }
  return base;
}

// ---------------------------------------------------------------- status

export type Status = 'on_site' | 'in_transit' | 'offline';

export interface SiteRow {
  id: number;
  name: string;
  address: string | null;
  latitude: number;
  longitude: number;
  radius_m: number;
  active: number;
  created_at: string;
}

export function distanceM(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const rad = Math.PI / 180;
  const p1 = lat1 * rad;
  const p2 = lat2 * rad;
  const dp = p2 - p1;
  const dl = (lng2 - lng1) * rad;
  const a = Math.sin(dp / 2) ** 2 + Math.cos(p1) * Math.cos(p2) * Math.sin(dl / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.sqrt(a));
}

/** Nearest active site whose geofence contains the fix (accuracy may extend it by up to 50 m). */
export function matchSite(lat: number, lng: number, accuracy: number, sites: SiteRow[]): SiteRow | null {
  let best: [number, SiteRow] | null = null;
  for (const site of sites) {
    if (!site.active) continue;
    const d = distanceM(lat, lng, site.latitude, site.longitude);
    if (d <= site.radius_m + Math.min(accuracy, 50) && (!best || d < best[0])) best = [d, site];
  }
  return best ? best[1] : null;
}

// ---------------------------------------------------------------- rows & views

export interface LocationRow {
  id: number;
  employee_id: number;
  latitude: number;
  longitude: number;
  accuracy_m: number;
  altitude_m: number | null;
  speed_mps: number | null;
  heading: number | null;
  recorded_at: string;
  received_at: string;
  source: string;
  site_id: number | null;
  site_name: string | null;
  address: string | null;
  low_accuracy: number;
}

interface EmployeeRow {
  id: number;
  employee_code: string;
  full_name: string;
  phone: string | null;
  role_title: string | null;
  team_id: number | null;
  team_name: string | null;
  team_color: string | null;
  active: number;
  photo_version: number | null;
  sharing_enabled: number | null;
  background_enabled: number | null;
  history_enabled: number | null;
  consented_at: string | null;
  permission_updated_at: string | null;
  active_devices: number;
}

const EMPLOYEE_SELECT = `
  SELECT e.id, e.employee_code, e.full_name, e.phone, e.role_title, e.team_id, e.active,
         t.name AS team_name, t.color AS team_color,
         ph.version AS photo_version,
         p.sharing_enabled, p.background_enabled, p.history_enabled, p.consented_at,
         p.updated_at AS permission_updated_at,
         (SELECT COUNT(*) FROM devices d WHERE d.employee_id = e.id AND d.revoked_at IS NULL) AS active_devices
    FROM employees e
    LEFT JOIN teams t ON t.id = e.team_id
    LEFT JOIN employee_photos ph ON ph.employee_id = e.id
    LEFT JOIN location_permissions p ON p.employee_id = e.id`;

const LOCATION_SELECT = `
  SELECT lu.id, lu.employee_id, lu.latitude, lu.longitude, lu.accuracy_m, lu.altitude_m, lu.speed_mps,
         lu.heading, lu.recorded_at, lu.received_at, lu.source, lu.site_id, s.name AS site_name,
         lu.address, lu.low_accuracy
    FROM location_updates lu LEFT JOIN sites s ON s.id = lu.site_id`;

export function locationOut(row: LocationRow | null) {
  if (!row) return null;
  return {
    id: row.id,
    latitude: row.latitude,
    longitude: row.longitude,
    accuracy_m: row.accuracy_m,
    altitude_m: row.altitude_m,
    speed_mps: row.speed_mps,
    heading: row.heading,
    recorded_at: row.recorded_at,
    received_at: row.received_at,
    source: row.source,
    site_id: row.site_id,
    site_name: row.site_name,
    address: row.address,
    low_accuracy: toBool(row.low_accuracy),
  };
}

export async function getLocation(env: Env, id: number | null): Promise<LocationRow | null> {
  if (id === null) return null;
  return first<LocationRow>(env.DB, `${LOCATION_SELECT} WHERE lu.id = ?`, id);
}

/** Latest fix per employee, one indexed lookup each. */
async function latestLocations(env: Env, employeeIds: number[]): Promise<Map<number, LocationRow>> {
  const map = new Map<number, LocationRow>();
  if (employeeIds.length === 0) return map;
  // D1 caps bound parameters per query, so look up in chunks.
  for (let i = 0; i < employeeIds.length; i += 90) {
    const chunk = employeeIds.slice(i, i + 90);
    const rows = await all<LocationRow>(
      env.DB,
      `${LOCATION_SELECT}
        WHERE lu.id IN (
          SELECT (SELECT x.id FROM location_updates x WHERE x.employee_id = e.id
                   ORDER BY x.recorded_at DESC, x.id DESC LIMIT 1)
            FROM employees e WHERE e.id IN (${chunk.map(() => '?').join(',')}))`,
      ...chunk,
    );
    for (const r of rows) map.set(r.employee_id, r);
  }
  return map;
}

export function computeStatus(
  latest: LocationRow | null,
  sharing: boolean,
  activeDevices: number,
  offlineAfterMinutes: number,
): Status {
  if (!latest) return 'offline';
  // A fix handed over for an approved one-off request still counts while fresh.
  if (!sharing && latest.source !== 'request') return 'offline';
  if (activeDevices === 0) return 'offline';
  if (Date.now() - Date.parse(latest.recorded_at) > offlineAfterMinutes * 60_000) return 'offline';
  return latest.site_id !== null ? 'on_site' : 'in_transit';
}

function summary(e: EmployeeRow, latest: LocationRow | null, offlineAfter: number) {
  const sharing = toBool(e.sharing_enabled);
  return {
    id: e.id,
    employee_code: e.employee_code,
    full_name: e.full_name,
    phone: e.phone,
    role_title: e.role_title,
    team_id: e.team_id,
    team_name: e.team_name,
    team_color: e.team_color,
    has_photo: e.photo_version !== null,
    photo_version: e.photo_version ?? 0,
    active: toBool(e.active),
    status: computeStatus(latest, sharing, e.active_devices, offlineAfter),
    sharing_enabled: sharing,
    device_paired: e.active_devices > 0,
    last_location: locationOut(latest),
  };
}

export type EmployeeSummary = ReturnType<typeof summary>;

export async function listSummaries(
  env: Env,
  opts: { teamId?: number | null; status?: Status | null; q?: string | null; includeInactive?: boolean } = {},
): Promise<EmployeeSummary[]> {
  const where: string[] = [];
  const params: unknown[] = [];
  if (!opts.includeInactive) where.push('e.active = 1');
  if (opts.teamId) {
    where.push('e.team_id = ?');
    params.push(opts.teamId);
  }
  if (opts.q) {
    where.push('(e.full_name LIKE ? OR e.employee_code LIKE ?)');
    params.push(`%${opts.q}%`, `%${opts.q}%`);
  }
  const sql = `${EMPLOYEE_SELECT} ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY e.full_name COLLATE NOCASE`;
  const rows = await all<EmployeeRow>(env.DB, sql, ...params);
  const latest = await latestLocations(env, rows.map((r) => r.id));
  const offlineAfter = (await loadSettings(env)).offline_after_minutes;
  const out = rows.map((r) => summary(r, latest.get(r.id) ?? null, offlineAfter));
  return opts.status ? out.filter((s) => s.status === opts.status) : out;
}

export async function getSummary(env: Env, employeeId: number): Promise<EmployeeSummary | null> {
  const row = await first<EmployeeRow>(env.DB, `${EMPLOYEE_SELECT} WHERE e.id = ?`, employeeId);
  if (!row) return null;
  const latest = (await latestLocations(env, [row.id])).get(row.id) ?? null;
  return summary(row, latest, (await loadSettings(env)).offline_after_minutes);
}

export function deviceOut(d: DeviceRow) {
  return {
    id: d.id,
    role: d.role,
    employee_id: d.employee_id,
    label: d.label,
    platform: d.platform,
    app_version: d.app_version,
    battery_level: d.battery_level,
    permission_state: d.permission_state ? JSON.parse(d.permission_state) : null,
    has_push: Boolean(d.push_token),
    last_seen_at: d.last_seen_at,
    revoked_at: d.revoked_at,
    created_at: d.created_at,
  };
}

interface PermissionRow {
  sharing_enabled: number;
  background_enabled: number;
  history_enabled: number;
  consented_at: string | null;
  updated_at: string;
}

export function permissionOut(p: PermissionRow | null) {
  if (!p) return null;
  return {
    sharing_enabled: toBool(p.sharing_enabled),
    background_enabled: toBool(p.background_enabled),
    history_enabled: toBool(p.history_enabled),
    consented_at: p.consented_at,
    updated_at: p.updated_at,
  };
}

export async function getPermission(env: Env, employeeId: number): Promise<PermissionRow | null> {
  return first<PermissionRow>(env.DB, `SELECT * FROM location_permissions WHERE employee_id = ?`, employeeId);
}

export async function getDetail(env: Env, employeeId: number) {
  const base = await getSummary(env, employeeId);
  if (!base) return fail(404, 'Employee not found.');
  const permission = await getPermission(env, employeeId);
  const devices = await all<DeviceRow>(env.DB, `SELECT * FROM devices WHERE employee_id = ? ORDER BY created_at DESC`, employeeId);
  return {
    ...base,
    permission: permissionOut(permission),
    devices: devices.map(deviceOut),
    history_enabled: toBool(permission?.history_enabled),
  };
}

export function broadcastEmployee(env: Env, ctx: Waiter, s: EmployeeSummary, event = 'location.updated'): void {
  publish(env, ctx, [ADMINS], event, s);
}

// ---------------------------------------------------------------- geocoding

async function reverseGeocode(env: Env, lat: number, lng: number): Promise<string | null> {
  const key = `${lat.toFixed(4)},${lng.toFixed(4)}`;
  const cached = await first<{ address: string }>(env.DB, `SELECT address FROM geocode_cache WHERE key = ?`, key);
  if (cached) return cached.address;
  if (!env.GOOGLE_GEOCODING_API_KEY) return null;
  try {
    const url = new URL('https://maps.googleapis.com/maps/api/geocode/json');
    url.searchParams.set('latlng', `${lat},${lng}`);
    url.searchParams.set('key', env.GOOGLE_GEOCODING_API_KEY);
    url.searchParams.set('result_type', 'street_address|premise|route|sublocality|locality');
    const res = await fetch(url, { signal: AbortSignal.timeout(4000) });
    const payload = (await res.json()) as { status: string; results?: { formatted_address?: string }[] };
    const address = payload.status === 'OK' ? payload.results?.[0]?.formatted_address?.slice(0, 255) : undefined;
    if (!address) return null;
    await run(env.DB, `INSERT OR REPLACE INTO geocode_cache (key, address, created_at) VALUES (?, ?, ?)`, key, address, nowIso());
    return address;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------- fixes

export interface Fix {
  latitude: number;
  longitude: number;
  accuracy_m: number;
  altitude_m: number | null;
  speed_mps: number | null;
  heading: number | null;
  recorded_at: string;
  source: 'stream' | 'request' | 'manual';
  is_mocked: boolean;
}

const TZ_SUFFIX = /([zZ]|[+-]\d{2}:?\d{2})$/;

/** Parses one fix; throws 422 for malformed input (same rules as the pydantic Fix). */
export function parseFix(raw: unknown): Fix {
  if (!raw || typeof raw !== 'object') return fail(422, 'Each fix must be an object.');
  const f = raw as Record<string, unknown>;
  const num = (k: string, min: number, max: number, required = true): number | null => {
    const v = f[k];
    if (v === undefined || v === null) return required ? fail(422, `fix.${k} is required.`) : null;
    if (typeof v !== 'number' || !Number.isFinite(v) || v < min || v > max) return fail(422, `fix.${k} is out of range.`);
    return v;
  };
  // Android reports -1 when speed or bearing is unknown.
  const optional = (k: string, max: number): number | null => {
    const v = f[k];
    if (typeof v === 'number' && v < 0) return null;
    return num(k, 0, max, false);
  };
  const recorded = f.recorded_at;
  if (typeof recorded !== 'string' || !TZ_SUFFIX.test(recorded) || Number.isNaN(Date.parse(recorded))) {
    fail(422, 'fix.recorded_at must be an ISO timestamp with a timezone offset.');
  }
  const source = f.source ?? 'stream';
  if (source !== 'stream' && source !== 'request' && source !== 'manual') fail(422, 'fix.source is invalid.');
  return {
    latitude: num('latitude', -90, 90)!,
    longitude: num('longitude', -180, 180)!,
    accuracy_m: num('accuracy_m', 0, 100_000)!,
    altitude_m: typeof f.altitude_m === 'number' && Number.isFinite(f.altitude_m) ? f.altitude_m : null,
    speed_mps: optional('speed_mps', 150),
    heading: optional('heading', 360),
    recorded_at: new Date(recorded as string).toISOString(),
    source: source as Fix['source'],
    is_mocked: f.is_mocked === true,
  };
}

/** Returns a reason when the fix must not be stored as a real position. */
function rejectReason(fix: Fix): string | null {
  const t = Date.parse(fix.recorded_at);
  if (fix.is_mocked) return 'Mock locations are not accepted.';
  if (t > Date.now() + 2 * 60_000) return 'Fix timestamp is in the future; check the device clock.';
  if (t < Date.now() - 7 * 86_400_000) return 'Fix is older than 7 days.';
  if (fix.latitude === 0 && fix.longitude === 0) return 'Null-island coordinates rejected.';
  return null;
}

export async function storeFixes(
  env: Env,
  device: DeviceRow,
  employeeId: number,
  fixes: Fix[],
  requestId: number | null = null,
): Promise<{ accepted: number[]; errors: string[] }> {
  const sites = await all<SiteRow>(env.DB, `SELECT * FROM sites WHERE active = 1`);
  const lowAccuracy = Number(env.LOW_ACCURACY_THRESHOLD_M || 100);
  const sorted = [...fixes].sort((a, b) => a.recorded_at.localeCompare(b.recorded_at));
  const accepted: number[] = [];
  const errors: string[] = [];
  const valid = sorted.filter((fix) => {
    const reason = rejectReason(fix);
    if (reason) errors.push(reason);
    return !reason;
  });
  for (let i = 0; i < valid.length; i++) {
    const fix = valid[i];
    const site = matchSite(fix.latitude, fix.longitude, fix.accuracy_m, sites);
    // Only the newest fix of a batch is geocoded to save API calls.
    const address = i === valid.length - 1 ? await reverseGeocode(env, fix.latitude, fix.longitude) : null;
    const id = await insert(
      env.DB,
      `INSERT INTO location_updates (employee_id, device_id, latitude, longitude, accuracy_m, altitude_m, speed_mps,
         heading, recorded_at, received_at, source, site_id, address, low_accuracy, request_id)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      employeeId,
      device.id,
      fix.latitude,
      fix.longitude,
      fix.accuracy_m,
      fix.altitude_m,
      fix.speed_mps,
      fix.heading,
      fix.recorded_at,
      nowIso(),
      requestId === null ? fix.source : 'request',
      site?.id ?? null,
      address,
      fix.accuracy_m > lowAccuracy ? 1 : 0,
      requestId,
    );
    accepted.push(id);
  }
  return { accepted, errors };
}

// ---------------------------------------------------------------- location requests

interface RequestRow {
  id: number;
  employee_id: number;
  employee_name: string;
  status: 'pending' | 'approved' | 'declined' | 'unavailable';
  reason: string | null;
  auto_approved: number;
  created_at: string;
  responded_at: string | null;
  fulfilled_at: string | null;
  expires_at: string;
  location_update_id: number | null;
}

const REQUEST_SELECT = `
  SELECT r.*, e.full_name AS employee_name
    FROM location_requests r JOIN employees e ON e.id = r.employee_id`;

export async function requestOut(env: Env, r: RequestRow) {
  return {
    id: r.id,
    employee_id: r.employee_id,
    employee_name: r.employee_name,
    status: r.status,
    reason: r.reason,
    auto_approved: toBool(r.auto_approved),
    created_at: r.created_at,
    responded_at: r.responded_at,
    fulfilled_at: r.fulfilled_at,
    expires_at: r.expires_at,
    location: locationOut(await getLocation(env, r.location_update_id)),
    awaiting_fresh_fix: r.status === 'approved' && r.fulfilled_at === null && Date.parse(r.expires_at) > Date.now(),
  };
}

export async function loadRequest(env: Env, id: number): Promise<RequestRow | null> {
  return first<RequestRow>(env.DB, `${REQUEST_SELECT} WHERE r.id = ?`, id);
}

export async function listRequests(env: Env, where: string, params: unknown[], limit: number) {
  const rows = await all<RequestRow>(env.DB, `${REQUEST_SELECT} ${where} ORDER BY r.created_at DESC LIMIT ${limit}`, ...params);
  return Promise.all(rows.map((r) => requestOut(env, r)));
}

async function announce(env: Env, ctx: Waiter, id: number, event = 'location_request.updated') {
  const out = await requestOut(env, (await loadRequest(env, id))!);
  publish(env, ctx, [ADMINS, employeeAudience(out.employee_id)], event, out);
  return out;
}

export async function createRequest(env: Env, ctx: Waiter, admin: DeviceRow, employeeId: number, reason: string | null) {
  const employee = await first<{ active: number }>(env.DB, `SELECT active FROM employees WHERE id = ?`, employeeId);
  if (!employee) fail(404, 'Employee not found.');
  if (!employee!.active) fail(409, 'This employee is deactivated.');

  const now = nowIso();
  const existing = await first<RequestRow>(
    env.DB,
    `${REQUEST_SELECT} WHERE r.employee_id = ? AND r.status = 'pending' AND r.expires_at > ?`,
    employeeId,
    now,
  );
  if (existing) return requestOut(env, existing);

  const timeout = (await loadSettings(env)).request_timeout_seconds;
  const expires = isoAfter(timeout * 1000);
  const devices = await all<DeviceRow>(env.DB, `SELECT * FROM devices WHERE employee_id = ? AND revoked_at IS NULL`, employeeId);
  const permission = await getPermission(env, employeeId);

  if (devices.length === 0) {
    const id = await insert(
      env.DB,
      `INSERT INTO location_requests (employee_id, requested_by_device_id, status, reason, created_at, responded_at, expires_at)
       VALUES (?, ?, 'unavailable', ?, ?, ?, ?)`,
      employeeId, admin.id, reason, now, now, expires,
    );
    return announce(env, ctx, id);
  }

  if (permission && toBool(permission.sharing_enabled)) {
    // Continuous sharing was consented to: answer with the latest fix now and
    // ask the phone for a fresh one.
    const latest = await first<{ id: number }>(
      env.DB,
      `SELECT id FROM location_updates WHERE employee_id = ? ORDER BY recorded_at DESC, id DESC LIMIT 1`,
      employeeId,
    );
    const id = await insert(
      env.DB,
      `INSERT INTO location_requests (employee_id, requested_by_device_id, status, reason, auto_approved, created_at,
         responded_at, expires_at, location_update_id)
       VALUES (?, ?, 'approved', ?, 1, ?, ?, ?, ?)`,
      employeeId, admin.id, reason, now, now, expires, latest?.id ?? null,
    );
    publish(env, ctx, [employeeAudience(employeeId)], 'location.refresh', { request_id: id });
    for (const d of devices) ctx.waitUntil(sendPush(env, d.push_token, { type: 'location_refresh', request_id: String(id) }));
    return announce(env, ctx, id);
  }

  const id = await insert(
    env.DB,
    `INSERT INTO location_requests (employee_id, requested_by_device_id, status, reason, created_at, expires_at)
     VALUES (?, ?, 'pending', ?, ?, ?)`,
    employeeId, admin.id, reason, now, expires,
  );
  const out = await announce(env, ctx, id, 'location_request.created');
  for (const d of devices) {
    ctx.waitUntil(
      sendPush(env, d.push_token, { type: 'location_request', request_id: String(id) }, {
        title: 'Location requested',
        body: 'SLG management asked for your current location. Tap to approve or decline.',
      }),
    );
  }
  return out;
}

export async function respondRequest(
  env: Env,
  ctx: Waiter,
  device: DeviceRow,
  req: RequestRow,
  decision: 'approve' | 'decline',
  fix: Fix | null,
) {
  if (req.employee_id !== device.employee_id) fail(404, 'Request not found.');
  const now = nowIso();
  const awaitingAuto = req.status === 'approved' && toBool(req.auto_approved) && req.fulfilled_at === null;
  if (req.status === 'pending' && req.expires_at <= now) {
    await run(env.DB, `UPDATE location_requests SET status = 'unavailable', responded_at = ? WHERE id = ?`, now, req.id);
    await announce(env, ctx, req.id);
    fail(409, 'This request has expired.');
  }
  if (req.status !== 'pending' && !awaitingAuto) fail(409, `This request is already ${req.status}.`);

  if (decision === 'decline') {
    if (awaitingAuto) fail(409, 'Pause location sharing to stop sending updates.');
    await run(env.DB, `UPDATE location_requests SET status = 'declined', responded_at = ? WHERE id = ?`, now, req.id);
    return announce(env, ctx, req.id);
  }

  if (!fix) fail(422, 'Approving requires a location fix.');
  const { accepted, errors } = await storeFixes(env, device, req.employee_id, [{ ...fix!, source: 'request' }], req.id);
  if (accepted.length === 0) fail(422, errors[0] ?? 'Invalid fix.');
  await run(
    env.DB,
    `UPDATE location_requests SET status = 'approved', responded_at = COALESCE(responded_at, ?), fulfilled_at = ?,
       location_update_id = ? WHERE id = ?`,
    now, now, accepted[accepted.length - 1], req.id,
  );
  const s = await getSummary(env, req.employee_id);
  if (s) broadcastEmployee(env, ctx, s);
  return announce(env, ctx, req.id);
}

/** Cron: mark timed-out pending requests unavailable. */
export async function expirePending(env: Env, ctx: Waiter): Promise<number> {
  const now = nowIso();
  const stale = await all<{ id: number }>(
    env.DB,
    `SELECT id FROM location_requests WHERE status = 'pending' AND expires_at <= ?`,
    now,
  );
  for (const { id } of stale) {
    await run(env.DB, `UPDATE location_requests SET status = 'unavailable', responded_at = ? WHERE id = ?`, now, id);
    await announce(env, ctx, id);
  }
  return stale.length;
}

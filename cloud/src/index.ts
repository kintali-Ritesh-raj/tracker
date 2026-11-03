// SLG FieldTrack API on Cloudflare Workers. Same contract as the FastAPI backend
// (docs/ARCHITECTURE.md §5–6), served under /api/v1. Everything else falls through
// to the static download page in cloud/public.

import { Hono, type Context } from 'hono';

import {
  authenticate,
  checkPairRateLimit,
  deviceForToken,
  type DeviceRow,
  hashCode,
  hashToken,
  newDeviceToken,
  newPairingCode,
  requireAdmin,
  requireEmployee,
} from './auth';
import { type Env, all, first, insert, isoAfter, migrate, nowIso, run } from './db';
import {
  SETTINGS_LIMITS,
  type Settings,
  type Status,
  broadcastEmployee,
  createRequest,
  deviceOut,
  expirePending,
  getDetail,
  getPermission,
  getSummary,
  listRequests,
  listSummaries,
  loadRequest,
  loadSettings,
  locationOut,
  type LocationRow,
  parseFix,
  permissionOut,
  requestOut,
  respondRequest,
  storeFixes,
} from './domain';
import { ApiError, Body, fail, toBool } from './http';
import { ADMINS, closeDevice, employeeAudience, Hub, hubFetch, publish } from './hub';
import { pushEnabled } from './push';
import { attendance, siteVisits } from './reports';

export { Hub };

type Ctx = Context<{ Bindings: Env; Variables: { device: DeviceRow } }>;

const app = new Hono<{ Bindings: Env; Variables: { device: DeviceRow } }>().basePath('/api/v1');

const STATUSES: Status[] = ['on_site', 'in_transit', 'offline'];
const HEX_COLOR = /^#[0-9A-Fa-f]{6}$/;
const PHOTO_TYPES = new Set(['image/jpeg', 'image/png', 'image/webp']);
const MAX_PHOTO_BYTES = 1_500_000; // D1 rows are capped at 2 MB

app.onError((err, c) => {
  if (err instanceof ApiError) return c.json({ detail: err.message }, err.status as 400);
  console.error(err);
  return c.json({ detail: 'Something went wrong on the server.' }, 500);
});

app.use('*', async (c, next) => {
  await migrate(c.env.DB);
  await next();
});

// Auth helpers per route group.
const anyDevice = async (c: Ctx, next: () => Promise<void>) => {
  c.set('device', await authenticate(c.env, c.req.raw, c.executionCtx));
  await next();
};
const admin = async (c: Ctx, next: () => Promise<void>) => {
  const device = await authenticate(c.env, c.req.raw, c.executionCtx);
  requireAdmin(device);
  c.set('device', device);
  await next();
};
const employee = async (c: Ctx, next: () => Promise<void>) => {
  const device = await authenticate(c.env, c.req.raw, c.executionCtx);
  requireEmployee(device);
  c.set('device', device);
  await next();
};

const intParam = (value: string | undefined): number => {
  const n = Number(value);
  if (!Number.isInteger(n) || n <= 0) fail(404, 'Not found.');
  return n;
};
const clientIp = (c: Ctx) => c.req.header('cf-connecting-ip') ?? 'local';

// ================================================================ health & bootstrap

app.get('/health', (c) =>
  c.json({ status: 'ok', push: pushEnabled(c.env), geocoding: Boolean(c.env.GOOGLE_GEOCODING_API_KEY), runtime: 'cloudflare-workers' }),
);

/**
 * First admin phone. While no admin device is paired, this issues a one-time
 * admin code and writes it ONLY to the Worker logs (Cloudflare dashboard →
 * tracker → Observability → Logs), which only the account owner can read.
 */
app.post('/bootstrap-admin', async (c) => {
  await checkPairRateLimit(c.env, clientIp(c));
  const admins = await first<{ n: number }>(c.env.DB, `SELECT COUNT(*) AS n FROM devices WHERE role = 'admin' AND revoked_at IS NULL`);
  if ((admins?.n ?? 0) > 0) fail(409, 'An admin phone is already paired. Ask that admin for a code (More → Paired Devices).');
  const code = await issuePairingCode(c.env, 'admin', null, null);
  console.log(`SLG FieldTrack admin pairing code: ${code.code} (valid until ${code.expires_at})`);
  return c.json({ detail: 'An admin pairing code was written to the Worker logs in the Cloudflare dashboard.' });
});

// ================================================================ devices & pairing

async function issuePairingCode(env: Env, role: 'admin' | 'employee', employeeId: number | null, createdBy: number | null) {
  const ttl = role === 'admin' ? 30 * 60_000 : 24 * 3_600_000;
  const code = newPairingCode();
  const expires = isoAfter(ttl);
  await insert(
    env.DB,
    `INSERT INTO pairing_codes (code_hash, role, employee_id, created_by_device_id, expires_at, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
    await hashCode(code),
    role,
    employeeId,
    createdBy,
    expires,
    nowIso(),
  );
  return { code, role, employee_id: employeeId, expires_at: expires };
}

app.post('/devices/pair', async (c) => {
  await checkPairRateLimit(c.env, clientIp(c));
  const body = await Body.from(c.req.raw);
  const codeText = body.str('code', { required: true, min: 6, max: 16 })!;
  const label = body.str('label', { max: 120 });
  const platform = body.str('platform', { max: 32 });
  const appVersion = body.str('app_version', { max: 32 });

  const code = await first<{ id: number; role: 'admin' | 'employee'; employee_id: number | null; expires_at: string; used_at: string | null }>(
    c.env.DB,
    `SELECT * FROM pairing_codes WHERE code_hash = ?`,
    await hashCode(codeText),
  );
  const now = nowIso();
  if (!code || code.used_at || code.expires_at <= now) fail(400, 'This pairing code is invalid or has expired.');

  if (code!.role === 'employee') {
    const emp = await first<{ active: number }>(c.env.DB, `SELECT active FROM employees WHERE id = ?`, code!.employee_id);
    if (!emp || !emp.active) fail(400, 'The employee for this code is no longer active.');
    // One phone per employee: pairing a new phone retires the old one.
    const old = await all<{ id: number }>(c.env.DB, `SELECT id FROM devices WHERE employee_id = ? AND revoked_at IS NULL`, code!.employee_id);
    await run(c.env.DB, `UPDATE devices SET revoked_at = ? WHERE employee_id = ? AND revoked_at IS NULL`, now, code!.employee_id);
    for (const d of old) closeDevice(c.env, c.executionCtx, d.id);
    await run(
      c.env.DB,
      `INSERT OR IGNORE INTO location_permissions (employee_id, updated_at) VALUES (?, ?)`,
      code!.employee_id,
      now,
    );
  }

  // Mark the code used first so a concurrent redeem cannot reuse it.
  const claimed = await run(c.env.DB, `UPDATE pairing_codes SET used_at = ? WHERE id = ? AND used_at IS NULL`, now, code!.id);
  if (!claimed.meta.changes) fail(400, 'This pairing code is invalid or has expired.');

  const token = newDeviceToken();
  const deviceId = await insert(
    c.env.DB,
    `INSERT INTO devices (role, employee_id, label, token_hash, platform, app_version, last_seen_at, created_at)
     VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
    code!.role,
    code!.employee_id,
    label,
    await hashToken(token),
    platform,
    appVersion,
    now,
    now,
  );
  const device = (await first<DeviceRow>(c.env.DB, `SELECT * FROM devices WHERE id = ?`, deviceId))!;
  let employeeSummary = null;
  if (code!.employee_id !== null) {
    employeeSummary = await getSummary(c.env, code!.employee_id);
    if (employeeSummary) broadcastEmployee(c.env, c.executionCtx, employeeSummary, 'employee.status');
  }
  return c.json({ token, device: deviceOut(device), role: device.role, employee: employeeSummary });
});

app.get('/devices/me', anyDevice, async (c) => {
  const device = c.get('device');
  const empId = device.employee_id;
  return c.json({
    device: deviceOut(device),
    role: device.role,
    employee: empId ? await getSummary(c.env, empId) : null,
    permission: empId ? permissionOut(await getPermission(c.env, empId)) : null,
  });
});

app.post('/devices/heartbeat', anyDevice, async (c) => {
  const device = c.get('device');
  const body = await Body.from(c.req.raw);
  const sets: string[] = ['last_seen_at = ?'];
  const params: unknown[] = [nowIso()];
  if (body.has('push_token')) {
    sets.push('push_token = ?');
    params.push(body.str('push_token', { max: 4096 }) || null);
  }
  const battery = body.num('battery_level', { min: 0, max: 100, int: true });
  if (battery !== null) {
    sets.push('battery_level = ?');
    params.push(battery);
  }
  const state = body.raw('permission_state');
  if (state && typeof state === 'object') {
    sets.push('permission_state = ?');
    params.push(JSON.stringify(state).slice(0, 4000));
  }
  const version = body.str('app_version', { max: 32 });
  if (version) {
    sets.push('app_version = ?');
    params.push(version);
  }
  await run(c.env.DB, `UPDATE devices SET ${sets.join(', ')} WHERE id = ?`, ...params, device.id);
  return c.json(deviceOut((await first<DeviceRow>(c.env.DB, `SELECT * FROM devices WHERE id = ?`, device.id))!));
});

app.get('/devices', admin, async (c) => {
  const devices = await all<DeviceRow>(c.env.DB, `SELECT * FROM devices ORDER BY created_at DESC`);
  return c.json(devices.map(deviceOut));
});

app.delete('/devices/:id', admin, async (c) => {
  const id = intParam(c.req.param('id'));
  if (id === c.get('device').id) fail(409, 'You cannot revoke the device you are using.');
  const device = await first<{ id: number }>(c.env.DB, `SELECT id FROM devices WHERE id = ?`, id);
  if (!device) fail(404, 'Device not found.');
  await run(c.env.DB, `UPDATE devices SET revoked_at = COALESCE(revoked_at, ?) WHERE id = ?`, nowIso(), id);
  closeDevice(c.env, c.executionCtx, id);
  return c.body(null, 204);
});

app.post('/pairing-codes', admin, async (c) => {
  const body = await Body.from(c.req.raw);
  const role = body.oneOf('role', ['admin', 'employee'] as const);
  const employeeId = body.num('employee_id', { min: 1, max: Number.MAX_SAFE_INTEGER, int: true });
  if (role === 'employee') {
    const emp = employeeId ? await first<{ active: number }>(c.env.DB, `SELECT active FROM employees WHERE id = ?`, employeeId) : null;
    if (!emp || !emp.active) fail(404, 'Choose an active employee to pair.');
  } else if (employeeId !== null) {
    fail(422, 'Admin codes are not tied to an employee.');
  }
  return c.json(await issuePairingCode(c.env, role, employeeId, c.get('device').id), 201);
});

// ================================================================ teams & sites

const teamOut = async (env: Env, id: number) =>
  first(
    env.DB,
    `SELECT t.id, t.name, t.description, t.color,
            (SELECT COUNT(*) FROM employees e WHERE e.team_id = t.id AND e.active = 1) AS employee_count
       FROM teams t WHERE t.id = ?`,
    id,
  );

const uniqueGuard = async <T>(fn: () => Promise<T>, message: string): Promise<T> => {
  try {
    return await fn();
  } catch (err) {
    if (String(err).includes('UNIQUE')) fail(409, message);
    throw err;
  }
};

app.get('/teams', admin, async (c) =>
  c.json(
    await all(
      c.env.DB,
      `SELECT t.id, t.name, t.description, t.color,
              (SELECT COUNT(*) FROM employees e WHERE e.team_id = t.id AND e.active = 1) AS employee_count
         FROM teams t ORDER BY t.name COLLATE NOCASE`,
    ),
  ),
);

app.post('/teams', admin, async (c) => {
  const body = await Body.from(c.req.raw);
  const name = body.str('name', { required: true, max: 80 });
  const description = body.str('description', { max: 255 });
  const color = body.str('color', { max: 7, pattern: HEX_COLOR }) ?? '#F97316';
  const id = await uniqueGuard(
    () => insert(c.env.DB, `INSERT INTO teams (name, description, color, created_at) VALUES (?, ?, ?, ?)`, name, description, color, nowIso()),
    'A team with this name already exists.',
  );
  return c.json(await teamOut(c.env, id), 201);
});

app.patch('/teams/:id', admin, async (c) => {
  const id = intParam(c.req.param('id'));
  if (!(await teamOut(c.env, id))) fail(404, 'Team not found.');
  const body = await Body.from(c.req.raw);
  const sets: string[] = [];
  const params: unknown[] = [];
  if (body.has('name')) sets.push('name = ?'), params.push(body.str('name', { required: true, max: 80 }));
  if (body.has('description')) sets.push('description = ?'), params.push(body.str('description', { max: 255 }));
  if (body.has('color')) sets.push('color = ?'), params.push(body.str('color', { required: true, max: 7, pattern: HEX_COLOR }));
  if (sets.length) {
    await uniqueGuard(() => run(c.env.DB, `UPDATE teams SET ${sets.join(', ')} WHERE id = ?`, ...params, id), 'A team with this name already exists.');
  }
  return c.json(await teamOut(c.env, id));
});

app.delete('/teams/:id', admin, async (c) => {
  const res = await run(c.env.DB, `DELETE FROM teams WHERE id = ?`, intParam(c.req.param('id')));
  if (!res.meta.changes) fail(404, 'Team not found.');
  return c.body(null, 204);
});

const siteOut = (s: Record<string, unknown> | null) => (s ? { ...s, active: toBool(s.active) } : null);

// Sites are readable by employees too so the phone can show which site it is at.
app.get('/sites', anyDevice, async (c) =>
  c.json((await all<Record<string, unknown>>(c.env.DB, `SELECT id, name, address, latitude, longitude, radius_m, active FROM sites ORDER BY name COLLATE NOCASE`)).map(siteOut)),
);

function siteFields(body: Body, partial: boolean) {
  const fields: [string, unknown][] = [];
  const add = (key: string, read: () => unknown) => {
    if (!partial || body.has(key)) fields.push([key, read()]);
  };
  add('name', () => body.str('name', { required: true, max: 120 }));
  add('address', () => body.str('address', { max: 255 }));
  add('latitude', () => body.num('latitude', { required: true, min: -90, max: 90 }));
  add('longitude', () => body.num('longitude', { required: true, min: -180, max: 180 }));
  add('radius_m', () => body.num('radius_m', { min: 20, max: 5000, int: true }) ?? 150);
  add('active', () => (body.bool('active', true) ? 1 : 0));
  return fields;
}

const loadSite = (env: Env, id: number) =>
  first<Record<string, unknown>>(env.DB, `SELECT id, name, address, latitude, longitude, radius_m, active FROM sites WHERE id = ?`, id);

app.post('/sites', admin, async (c) => {
  const fields = siteFields(await Body.from(c.req.raw), false);
  const id = await insert(
    c.env.DB,
    `INSERT INTO sites (${fields.map(([k]) => k).join(', ')}, created_at) VALUES (${fields.map(() => '?').join(', ')}, ?)`,
    ...fields.map(([, v]) => v),
    nowIso(),
  );
  return c.json(siteOut(await loadSite(c.env, id)), 201);
});

app.patch('/sites/:id', admin, async (c) => {
  const id = intParam(c.req.param('id'));
  if (!(await loadSite(c.env, id))) fail(404, 'Site not found.');
  const fields = siteFields(await Body.from(c.req.raw), true);
  if (fields.length) {
    await run(c.env.DB, `UPDATE sites SET ${fields.map(([k]) => `${k} = ?`).join(', ')} WHERE id = ?`, ...fields.map(([, v]) => v), id);
  }
  return c.json(siteOut(await loadSite(c.env, id)));
});

app.delete('/sites/:id', admin, async (c) => {
  const res = await run(c.env.DB, `DELETE FROM sites WHERE id = ?`, intParam(c.req.param('id')));
  if (!res.meta.changes) fail(404, 'Site not found.');
  return c.body(null, 204);
});

// ================================================================ employees

const statusParam = (v: string | undefined): Status | null => {
  if (!v) return null;
  if (!STATUSES.includes(v as Status)) fail(422, 'status must be on_site, in_transit or offline.');
  return v as Status;
};

app.get('/employees', admin, async (c) =>
  c.json(
    await listSummaries(c.env, {
      teamId: c.req.query('team_id') ? Number(c.req.query('team_id')) : null,
      status: statusParam(c.req.query('status')),
      q: c.req.query('q')?.trim() || null,
      includeInactive: c.req.query('include_inactive') === 'true',
    }),
  ),
);

async function checkTeam(env: Env, teamId: number | null) {
  if (teamId !== null && !(await first(env.DB, `SELECT id FROM teams WHERE id = ?`, teamId))) fail(422, 'Team does not exist.');
}

app.post('/employees', admin, async (c) => {
  const body = await Body.from(c.req.raw);
  const code = body.str('employee_code', { required: true, max: 32 });
  const name = body.str('full_name', { required: true, max: 120 });
  const phone = body.str('phone', { max: 32 });
  const role = body.str('role_title', { max: 80 });
  const teamId = body.num('team_id', { min: 1, max: Number.MAX_SAFE_INTEGER, int: true });
  await checkTeam(c.env, teamId);
  const id = await uniqueGuard(
    () =>
      insert(
        c.env.DB,
        `INSERT INTO employees (employee_code, full_name, phone, role_title, team_id, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
        code, name, phone, role, teamId, nowIso(),
      ),
    'Another employee already uses this employee ID.',
  );
  return c.json(await getDetail(c.env, id), 201);
});

app.get('/employees/:id', admin, async (c) => c.json(await getDetail(c.env, intParam(c.req.param('id')))));

app.patch('/employees/:id', admin, async (c) => {
  const id = intParam(c.req.param('id'));
  await getDetail(c.env, id); // 404 if missing
  const body = await Body.from(c.req.raw);
  const sets: string[] = [];
  const params: unknown[] = [];
  const add = (col: string, value: unknown) => (sets.push(`${col} = ?`), params.push(value));
  if (body.has('employee_code')) add('employee_code', body.str('employee_code', { required: true, max: 32 }));
  if (body.has('full_name')) add('full_name', body.str('full_name', { required: true, max: 120 }));
  if (body.has('phone')) add('phone', body.str('phone', { max: 32 }));
  if (body.has('role_title')) add('role_title', body.str('role_title', { max: 80 }));
  if (body.has('team_id')) {
    const teamId = body.num('team_id', { min: 1, max: Number.MAX_SAFE_INTEGER, int: true });
    await checkTeam(c.env, teamId);
    add('team_id', teamId);
  }
  let deactivating = false;
  if (body.has('active')) {
    const active = body.bool('active');
    deactivating = !active;
    add('active', active ? 1 : 0);
  }
  if (sets.length) {
    await uniqueGuard(() => run(c.env.DB, `UPDATE employees SET ${sets.join(', ')} WHERE id = ?`, ...params, id), 'Another employee already uses this employee ID.');
  }
  if (deactivating) {
    const devices = await all<{ id: number }>(c.env.DB, `SELECT id FROM devices WHERE employee_id = ? AND revoked_at IS NULL`, id);
    await run(c.env.DB, `UPDATE devices SET revoked_at = ? WHERE employee_id = ? AND revoked_at IS NULL`, nowIso(), id);
    for (const d of devices) closeDevice(c.env, c.executionCtx, d.id);
  }
  const detail = await getDetail(c.env, id);
  const { permission: _p, devices: _d, history_enabled: _h, ...summary } = detail;
  publish(c.env, c.executionCtx, [ADMINS], 'employee.status', summary);
  return c.json(detail);
});

app.delete('/employees/:id', admin, async (c) => {
  const id = intParam(c.req.param('id'));
  const devices = await all<{ id: number }>(c.env.DB, `SELECT id FROM devices WHERE employee_id = ?`, id);
  const res = await run(c.env.DB, `DELETE FROM employees WHERE id = ?`, id);
  if (!res.meta.changes) fail(404, 'Employee not found.');
  for (const d of devices) closeDevice(c.env, c.executionCtx, d.id);
  publish(c.env, c.executionCtx, [ADMINS], 'employee.deleted', { id });
  return c.body(null, 204);
});

app.post('/employees/:id/photo', admin, async (c) => {
  const id = intParam(c.req.param('id'));
  await getDetail(c.env, id);
  const form = await c.req.parseBody();
  const file = form['file'];
  if (!(file instanceof File)) return fail(422, 'Attach the photo as "file".');
  if (!PHOTO_TYPES.has(file.type)) fail(415, 'Upload a JPEG, PNG or WebP image.');
  if (file.size > MAX_PHOTO_BYTES) fail(413, 'Photos must be 1.5 MB or smaller.');
  await run(
    c.env.DB,
    `INSERT OR REPLACE INTO employee_photos (employee_id, content_type, data, version) VALUES (?, ?, ?, ?)`,
    id,
    file.type,
    await file.arrayBuffer(),
    Math.floor(Date.now() / 1000),
  );
  return c.json(await getDetail(c.env, id));
});

app.get('/employees/:id/photo', anyDevice, async (c) => {
  const photo = await first<{ content_type: string; data: ArrayBuffer | number[] }>(
    c.env.DB,
    `SELECT content_type, data FROM employee_photos WHERE employee_id = ?`,
    intParam(c.req.param('id')),
  );
  if (!photo) fail(404, 'No photo.');
  const bytes = photo!.data instanceof ArrayBuffer ? new Uint8Array(photo!.data) : new Uint8Array(photo!.data);
  return new Response(bytes, { headers: { 'Content-Type': photo!.content_type, 'Cache-Control': 'private, max-age=86400' } });
});

app.get('/employees/:id/history', admin, async (c) => {
  const id = intParam(c.req.param('id'));
  await getDetail(c.env, id);
  const permission = await getPermission(c.env, id);
  if (!permission || !toBool(permission.history_enabled)) fail(403, 'This employee has not enabled location history.');
  const end = c.req.query('to') ? new Date(c.req.query('to')!).toISOString() : nowIso();
  const start = c.req.query('from') ? new Date(c.req.query('from')!).toISOString() : new Date(Date.parse(end) - 86_400_000).toISOString();
  const limit = Math.min(Math.max(Number(c.req.query('limit') ?? 500), 1), 5000);
  const rows = await all<LocationRow>(
    c.env.DB,
    `SELECT lu.*, s.name AS site_name FROM location_updates lu LEFT JOIN sites s ON s.id = lu.site_id
      WHERE lu.employee_id = ? AND lu.recorded_at >= ? AND lu.recorded_at <= ?
      ORDER BY lu.recorded_at LIMIT ${limit}`,
    id, start, end,
  );
  return c.json(rows.map(locationOut));
});

// ================================================================ dashboard & map

const counts = (items: { status: Status }[]) => ({
  total: items.length,
  on_site: items.filter((s) => s.status === 'on_site').length,
  in_transit: items.filter((s) => s.status === 'in_transit').length,
  offline: items.filter((s) => s.status === 'offline').length,
});

app.get('/dashboard', admin, async (c) => {
  const summaries = await listSummaries(c.env);
  const teams = await all<{ id: number; name: string; color: string }>(c.env.DB, `SELECT id, name, color FROM teams ORDER BY name COLLATE NOCASE`);
  const rows = teams.map((t) => ({ team_id: t.id, team_name: t.name, color: t.color, counts: counts(summaries.filter((s) => s.team_id === t.id)) }));
  const unassigned = summaries.filter((s) => s.team_id === null);
  if (unassigned.length) rows.push({ team_id: null as unknown as number, team_name: 'Unassigned', color: '#A8A29E', counts: counts(unassigned) });
  const pending = await first<{ n: number }>(
    c.env.DB,
    `SELECT COUNT(*) AS n FROM location_requests WHERE status = 'pending' AND expires_at > ?`,
    nowIso(),
  );
  return c.json({
    counts: counts(summaries),
    teams: rows,
    sharing_enabled: summaries.filter((s) => s.sharing_enabled).length,
    pending_requests: pending?.n ?? 0,
    generated_at: nowIso(),
  });
});

app.get('/map/employees', admin, async (c) => {
  const items = await listSummaries(c.env, {
    teamId: c.req.query('team_id') ? Number(c.req.query('team_id')) : null,
    status: statusParam(c.req.query('status')),
  });
  // Only real fixes: employees that share continuously or answered a request.
  return c.json(items.filter((s) => s.last_location && (s.sharing_enabled || s.last_location.source === 'request')));
});

// ================================================================ employee self-service

app.get('/me', employee, async (c) => {
  const s = await getSummary(c.env, c.get('device').employee_id!);
  return s ? c.json(s) : fail(404, 'Employee not found.');
});

app.get('/me/permission', employee, async (c) => {
  const id = c.get('device').employee_id!;
  await run(c.env.DB, `INSERT OR IGNORE INTO location_permissions (employee_id, updated_at) VALUES (?, ?)`, id, nowIso());
  return c.json(permissionOut(await getPermission(c.env, id)));
});

/** Only the employee's own device can grant or withdraw location consent. */
app.put('/me/permission', employee, async (c) => {
  const id = c.get('device').employee_id!;
  const body = await Body.from(c.req.raw);
  const sharing = body.bool('sharing_enabled');
  const background = sharing && body.bool('background_enabled', false);
  const history = body.bool('history_enabled', true);
  const now = nowIso();
  const current = await getPermission(c.env, id);
  const consentedAt = sharing && !toBool(current?.sharing_enabled) ? now : (current?.consented_at ?? null);
  await run(
    c.env.DB,
    `INSERT INTO location_permissions (employee_id, sharing_enabled, background_enabled, history_enabled, consented_at, updated_at)
     VALUES (?, ?, ?, ?, ?, ?)
     ON CONFLICT(employee_id) DO UPDATE SET sharing_enabled = excluded.sharing_enabled,
       background_enabled = excluded.background_enabled, history_enabled = excluded.history_enabled,
       consented_at = excluded.consented_at, updated_at = excluded.updated_at`,
    id, sharing ? 1 : 0, background ? 1 : 0, history ? 1 : 0, consentedAt, now,
  );
  const s = await getSummary(c.env, id);
  if (s) broadcastEmployee(c.env, c.executionCtx, s, 'employee.status');
  return c.json(permissionOut(await getPermission(c.env, id)));
});

app.post('/locations', employee, async (c) => {
  const device = c.get('device');
  const id = device.employee_id!;
  const permission = await getPermission(c.env, id);
  if (!permission || !toBool(permission.sharing_enabled)) fail(403, 'Location sharing is turned off on this device.');
  const body = await Body.from(c.req.raw);
  const raw = body.raw('fixes');
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > 500) fail(422, 'fixes must contain 1 to 500 items.');
  const fixes = (raw as unknown[]).map(parseFix);
  const stream = fixes.filter((f) => f.source !== 'request');
  const { accepted, errors } = await storeFixes(c.env, device, id, stream);
  const s = (await getSummary(c.env, id))!;
  if (accepted.length) broadcastEmployee(c.env, c.executionCtx, s);
  return c.json({
    accepted: accepted.length,
    rejected: fixes.length - accepted.length,
    latest: s.last_location,
    status: s.status,
    errors: [...new Set(errors)].sort(),
  });
});

app.get('/me/location-requests', employee, async (c) => {
  const id = c.get('device').employee_id!;
  const open = c.req.query('open') !== 'false';
  const where = open
    ? `WHERE r.employee_id = ? AND r.expires_at > ? AND (r.status = 'pending' OR (r.status = 'approved' AND r.fulfilled_at IS NULL))`
    : `WHERE r.employee_id = ?`;
  return c.json(await listRequests(c.env, where, open ? [id, nowIso()] : [id], 20));
});

// ================================================================ location requests

app.post('/location-requests', admin, async (c) => {
  const body = await Body.from(c.req.raw);
  const employeeId = body.num('employee_id', { required: true, min: 1, max: Number.MAX_SAFE_INTEGER, int: true })!;
  const reason = body.str('reason', { max: 255 });
  return c.json(await createRequest(c.env, c.executionCtx, c.get('device'), employeeId, reason), 201);
});

app.get('/location-requests', admin, async (c) => {
  const employeeId = c.req.query('employee_id');
  const limit = Math.min(Math.max(Number(c.req.query('limit') ?? 30), 1), 200);
  return c.json(
    employeeId
      ? await listRequests(c.env, `WHERE r.employee_id = ?`, [Number(employeeId)], limit)
      : await listRequests(c.env, '', [], limit),
  );
});

app.get('/location-requests/:id', anyDevice, async (c) => {
  const device = c.get('device');
  const req = await loadRequest(c.env, intParam(c.req.param('id')));
  if (!req || (device.role === 'employee' && req.employee_id !== device.employee_id)) fail(404, 'Request not found.');
  return c.json(await requestOut(c.env, req!));
});

app.post('/location-requests/:id/respond', employee, async (c) => {
  const req = await loadRequest(c.env, intParam(c.req.param('id')));
  if (!req) fail(404, 'Request not found.');
  const body = await Body.from(c.req.raw);
  const decision = body.oneOf('decision', ['approve', 'decline'] as const);
  const rawFix = body.raw('fix');
  const fix = rawFix === undefined || rawFix === null ? null : parseFix(rawFix);
  return c.json(await respondRequest(c.env, c.executionCtx, c.get('device'), req!, decision, fix));
});

// ================================================================ reports & settings

const dayQuery = (c: Ctx): [string, number] => {
  const day = c.req.query('date') ?? '';
  if (!/^\d{4}-\d{2}-\d{2}$/.test(day)) fail(422, 'date must be YYYY-MM-DD.');
  const tz = Number(c.req.query('tz_offset') ?? 330); // IST by default
  if (!Number.isInteger(tz) || tz < -720 || tz > 840) fail(422, 'tz_offset must be minutes between -720 and 840.');
  return [day, tz];
};

app.get('/reports/attendance', admin, async (c) => c.json(await attendance(c.env, ...dayQuery(c))));
app.get('/reports/site-visits', admin, async (c) => c.json(await siteVisits(c.env, ...dayQuery(c))));

// Employees read settings too: the phone uses the tracking interval and distance filter.
app.get('/settings', anyDevice, async (c) => c.json(await loadSettings(c.env)));

app.put('/settings', admin, async (c) => {
  const body = await Body.from(c.req.raw);
  const values = {} as Settings;
  for (const [key, [min, max]] of Object.entries(SETTINGS_LIMITS) as [keyof Settings, [number, number]][]) {
    values[key] = body.num(key, { required: true, min, max, int: true })!;
  }
  await run(
    c.env.DB,
    `INSERT INTO app_settings (key, value, updated_at) VALUES ('general', ?, ?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at`,
    JSON.stringify(values),
    nowIso(),
  );
  return c.json(values);
});

// ================================================================ realtime

/** Token via `Sec-WebSocket-Protocol: bearer, <token>` (preferred) or `?token=`. */
app.get('/ws', async (c) => {
  if (c.req.header('upgrade')?.toLowerCase() !== 'websocket') fail(426, 'Expected a WebSocket upgrade.');
  const protocols = (c.req.header('sec-websocket-protocol') ?? '')
    .split(',')
    .map((p) => p.trim())
    .filter(Boolean);
  const viaProtocol = protocols.length === 2 && protocols[0].toLowerCase() === 'bearer';
  const token = viaProtocol ? protocols[1] : c.req.query('token');
  const device = await deviceForToken(c.env, token);
  if (!device) {
    // Accept then close with 4401 so the app knows retrying is pointless.
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    server.accept();
    server.close(4401, 'Unauthorized');
    return new Response(null, { status: 101, webSocket: client, headers: viaProtocol ? { 'Sec-WebSocket-Protocol': 'bearer' } : {} });
  }
  const headers = new Headers(c.req.raw.headers);
  headers.set('x-audience', device.role === 'admin' ? ADMINS : employeeAudience(device.employee_id!));
  headers.set('x-device-id', String(device.id));
  if (viaProtocol) headers.set('x-subprotocol', 'bearer');
  return hubFetch(c.env, new Request('https://hub/connect', { headers }));
});

app.notFound((c) => c.json({ detail: 'Not found.' }, 404));

export default {
  fetch: app.fetch,

  async scheduled(_event: ScheduledController, env: Env, ctx: ExecutionContext) {
    await migrate(env.DB);
    await expirePending(env, ctx);
    await run(env.DB, `DELETE FROM pair_attempts WHERE at < ?`, new Date(Date.now() - 3_600_000).toISOString());
  },
} satisfies ExportedHandler<Env>;

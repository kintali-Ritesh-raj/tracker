// Device-token authentication (no accounts or passwords). A phone redeems a
// one-time pairing code for a random device token; only SHA-256 hashes of
// codes and tokens are stored. Mirrors backend/app/security.py.

import { type Env, type Waiter, first, nowIso, run } from './db';
import { fail } from './http';

// Unambiguous alphabet for codes typed by hand (no 0/O, 1/I/L).
const CODE_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

export interface DeviceRow {
  id: number;
  role: 'admin' | 'employee';
  employee_id: number | null;
  label: string | null;
  token_hash: string;
  platform: string | null;
  app_version: string | null;
  push_token: string | null;
  battery_level: number | null;
  permission_state: string | null;
  last_seen_at: string | null;
  revoked_at: string | null;
  created_at: string;
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export const hashCode = (code: string) => sha256(code.trim().toUpperCase());
// Tokens are case-sensitive, so they are not normalised like pairing codes.
export const hashToken = (token: string) => sha256(token);

function randomBytes(n: number): Uint8Array {
  const bytes = new Uint8Array(n);
  crypto.getRandomValues(bytes);
  return bytes;
}

export function newDeviceToken(): string {
  return btoa(String.fromCharCode(...randomBytes(32)))
    .replace(/\+/g, '-')
    .replace(/\//g, '_')
    .replace(/=+$/, '');
}

export function newPairingCode(length = 8): string {
  // Rejection sampling keeps the distribution uniform.
  const out: string[] = [];
  while (out.length < length) {
    for (const b of randomBytes(length * 2)) {
      if (b < 248 && out.length < length) out.push(CODE_ALPHABET[b % CODE_ALPHABET.length]);
    }
  }
  return out.join('');
}

export async function deviceForToken(env: Env, token: string | null | undefined): Promise<DeviceRow | null> {
  if (!token) return null;
  const device = await first<DeviceRow & { employee_active: number | null }>(
    env.DB,
    `SELECT d.*, e.active AS employee_active
       FROM devices d LEFT JOIN employees e ON e.id = d.employee_id
      WHERE d.token_hash = ?`,
    await hashToken(token),
  );
  if (!device || device.revoked_at) return null;
  if (device.role === 'employee' && device.employee_active !== 1) return null;
  return device;
}

export function bearer(req: Request): string | null {
  const header = req.headers.get('authorization') ?? '';
  return header.toLowerCase().startsWith('bearer ') ? header.slice(7).trim() : null;
}

export async function authenticate(env: Env, req: Request, ctx: Waiter): Promise<DeviceRow> {
  const device = await deviceForToken(env, bearer(req));
  if (!device) fail(401, 'This device is not paired or has been revoked.');
  // Avoid a write on every request; a minute of resolution is plenty.
  const last = device!.last_seen_at ? Date.parse(device!.last_seen_at) : 0;
  if (Date.now() - last > 60_000) {
    ctx.waitUntil(run(env.DB, `UPDATE devices SET last_seen_at = ? WHERE id = ?`, nowIso(), device!.id));
  }
  return device!;
}

export function requireAdmin(device: DeviceRow): void {
  if (device.role !== 'admin') fail(403, 'Admin device required.');
}

export function requireEmployee(device: DeviceRow): number {
  if (device.role !== 'employee' || device.employee_id === null) fail(403, 'Employee device required.');
  return device.employee_id!;
}

/** Sliding one-minute window per client IP, stored in D1 so it holds across isolates. */
export async function checkPairRateLimit(env: Env, ip: string): Promise<void> {
  const limit = Number(env.PAIR_RATE_LIMIT_PER_MINUTE || 10);
  const since = new Date(Date.now() - 60_000).toISOString();
  const row = await first<{ n: number }>(env.DB, `SELECT COUNT(*) AS n FROM pair_attempts WHERE ip = ? AND at > ?`, ip, since);
  if ((row?.n ?? 0) >= limit) fail(429, 'Too many pairing attempts. Wait a minute and try again.');
  await run(env.DB, `INSERT INTO pair_attempts (ip, at) VALUES (?, ?)`, ip, nowIso());
}

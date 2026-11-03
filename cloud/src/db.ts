// D1 (SQLite) schema and small query helpers. Mirrors backend/app/models.py.
// Timestamps are stored as UTC ISO-8601 strings (Date#toISOString), which sort
// lexicographically, so comparisons work directly in SQL.

/** The part of the execution context we use; Hono and Workers types differ on the rest. */
export interface Waiter {
  waitUntil(promise: Promise<unknown>): void;
}

export interface Env {
  DB: D1Database;
  HUB: DurableObjectNamespace;
  ASSETS: Fetcher;
  OFFLINE_AFTER_MINUTES: string;
  REQUEST_TIMEOUT_SECONDS: string;
  DEFAULT_SITE_RADIUS_M: string;
  LOW_ACCURACY_THRESHOLD_M: string;
  PAIR_RATE_LIMIT_PER_MINUTE: string;
  GOOGLE_GEOCODING_API_KEY?: string;
  FIREBASE_SERVICE_ACCOUNT?: string;
}

export const SCHEMA_VERSION = 1;

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS teams (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     name TEXT NOT NULL UNIQUE,
     description TEXT,
     color TEXT NOT NULL DEFAULT '#F97316',
     created_at TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS sites (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     name TEXT NOT NULL,
     address TEXT,
     latitude REAL NOT NULL,
     longitude REAL NOT NULL,
     radius_m INTEGER NOT NULL DEFAULT 150,
     active INTEGER NOT NULL DEFAULT 1,
     created_at TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS employees (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     employee_code TEXT NOT NULL UNIQUE,
     full_name TEXT NOT NULL,
     phone TEXT,
     role_title TEXT,
     team_id INTEGER REFERENCES teams(id) ON DELETE SET NULL,
     active INTEGER NOT NULL DEFAULT 1,
     created_at TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS employee_photos (
     employee_id INTEGER PRIMARY KEY REFERENCES employees(id) ON DELETE CASCADE,
     content_type TEXT NOT NULL,
     data BLOB NOT NULL,
     version INTEGER NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS devices (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     role TEXT NOT NULL CHECK (role IN ('admin', 'employee')),
     employee_id INTEGER REFERENCES employees(id) ON DELETE CASCADE,
     label TEXT,
     token_hash TEXT NOT NULL UNIQUE,
     platform TEXT,
     app_version TEXT,
     push_token TEXT,
     battery_level INTEGER,
     permission_state TEXT,
     last_seen_at TEXT,
     revoked_at TEXT,
     created_at TEXT NOT NULL)`,
  `CREATE INDEX IF NOT EXISTS ix_devices_employee_id ON devices(employee_id)`,
  `CREATE TABLE IF NOT EXISTS pairing_codes (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     code_hash TEXT NOT NULL UNIQUE,
     role TEXT NOT NULL,
     employee_id INTEGER REFERENCES employees(id) ON DELETE CASCADE,
     created_by_device_id INTEGER REFERENCES devices(id) ON DELETE SET NULL,
     expires_at TEXT NOT NULL,
     used_at TEXT,
     created_at TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS location_permissions (
     employee_id INTEGER PRIMARY KEY REFERENCES employees(id) ON DELETE CASCADE,
     sharing_enabled INTEGER NOT NULL DEFAULT 0,
     background_enabled INTEGER NOT NULL DEFAULT 0,
     history_enabled INTEGER NOT NULL DEFAULT 1,
     consented_at TEXT,
     updated_at TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS location_requests (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     employee_id INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
     requested_by_device_id INTEGER REFERENCES devices(id) ON DELETE SET NULL,
     status TEXT NOT NULL CHECK (status IN ('pending', 'approved', 'declined', 'unavailable')),
     reason TEXT,
     auto_approved INTEGER NOT NULL DEFAULT 0,
     created_at TEXT NOT NULL,
     responded_at TEXT,
     fulfilled_at TEXT,
     expires_at TEXT NOT NULL,
     location_update_id INTEGER)`,
  `CREATE INDEX IF NOT EXISTS ix_location_requests_emp_time ON location_requests(employee_id, created_at)`,
  `CREATE INDEX IF NOT EXISTS ix_location_requests_status_exp ON location_requests(status, expires_at)`,
  `CREATE TABLE IF NOT EXISTS location_updates (
     id INTEGER PRIMARY KEY AUTOINCREMENT,
     employee_id INTEGER NOT NULL REFERENCES employees(id) ON DELETE CASCADE,
     device_id INTEGER REFERENCES devices(id) ON DELETE SET NULL,
     latitude REAL NOT NULL,
     longitude REAL NOT NULL,
     accuracy_m REAL NOT NULL,
     altitude_m REAL,
     speed_mps REAL,
     heading REAL,
     recorded_at TEXT NOT NULL,
     received_at TEXT NOT NULL,
     source TEXT NOT NULL DEFAULT 'stream',
     site_id INTEGER REFERENCES sites(id) ON DELETE SET NULL,
     address TEXT,
     low_accuracy INTEGER NOT NULL DEFAULT 0,
     request_id INTEGER REFERENCES location_requests(id) ON DELETE SET NULL)`,
  `CREATE INDEX IF NOT EXISTS ix_location_updates_emp_time ON location_updates(employee_id, recorded_at)`,
  `CREATE INDEX IF NOT EXISTS ix_location_updates_time ON location_updates(recorded_at)`,
  `CREATE TABLE IF NOT EXISTS geocode_cache (key TEXT PRIMARY KEY, address TEXT NOT NULL, created_at TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS app_settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS pair_attempts (ip TEXT NOT NULL, at TEXT NOT NULL)`,
  `CREATE INDEX IF NOT EXISTS ix_pair_attempts ON pair_attempts(ip, at)`,
];

let migrated = false;

/** Creates tables on first use in each isolate; idempotent and cheap after that. */
export async function migrate(db: D1Database): Promise<void> {
  if (migrated) return;
  const row = await db
    .prepare(`SELECT version FROM schema_version LIMIT 1`)
    .first<{ version: number }>()
    .catch(() => null);
  if (!row || row.version < SCHEMA_VERSION) {
    await db.batch(SCHEMA.map((sql) => db.prepare(sql)));
    await db.batch([
      db.prepare(`DELETE FROM schema_version`),
      db.prepare(`INSERT INTO schema_version (version) VALUES (?)`).bind(SCHEMA_VERSION),
    ]);
  }
  migrated = true;
}

export const nowIso = (): string => new Date().toISOString();

export const isoAfter = (ms: number): string => new Date(Date.now() + ms).toISOString();

export async function all<T>(db: D1Database, sql: string, ...params: unknown[]): Promise<T[]> {
  const res = await db.prepare(sql).bind(...params).all<T>();
  return res.results ?? [];
}

export async function first<T>(db: D1Database, sql: string, ...params: unknown[]): Promise<T | null> {
  return db.prepare(sql).bind(...params).first<T>();
}

export async function run(db: D1Database, sql: string, ...params: unknown[]): Promise<D1Result> {
  return db.prepare(sql).bind(...params).run();
}

/** Insert and return the new row id. */
export async function insert(db: D1Database, sql: string, ...params: unknown[]): Promise<number> {
  const res = await run(db, sql, ...params);
  return Number(res.meta.last_row_id);
}

// Attendance and site-visit reports derived from stored fixes (backend/app/services/reports.py).

import { type Env, all } from './db';

// A gap longer than this between two fixes at the same site splits the visit.
const VISIT_GAP_MS = 20 * 60_000;

interface Fix {
  employee_id: number;
  recorded_at: string;
  site_id: number | null;
  site_name: string | null;
}

function dayBounds(day: string, tzOffsetMinutes: number): [string, string] {
  const [y, m, d] = day.split('-').map(Number);
  const start = Date.UTC(y, m - 1, d) - tzOffsetMinutes * 60_000;
  return [new Date(start).toISOString(), new Date(start + 86_400_000).toISOString()];
}

async function fixesByEmployee(env: Env, day: string, tz: number): Promise<Map<number, Fix[]>> {
  const [start, end] = dayBounds(day, tz);
  const rows = await all<Fix>(
    env.DB,
    `SELECT lu.employee_id, lu.recorded_at, lu.site_id, s.name AS site_name
       FROM location_updates lu LEFT JOIN sites s ON s.id = lu.site_id
      WHERE lu.recorded_at >= ? AND lu.recorded_at < ?
      ORDER BY lu.employee_id, lu.recorded_at`,
    start,
    end,
  );
  const map = new Map<number, Fix[]>();
  for (const r of rows) {
    if (!map.has(r.employee_id)) map.set(r.employee_id, []);
    map.get(r.employee_id)!.push(r);
  }
  return map;
}

/** Group consecutive same-site fixes into [first, last] pairs. */
function visits(fixes: Fix[]): [Fix, Fix][] {
  const out: [Fix, Fix][] = [];
  let first: Fix | null = null;
  let last: Fix | null = null;
  for (const fix of fixes) {
    if (first && last && fix.site_id === first.site_id && Date.parse(fix.recorded_at) - Date.parse(last.recorded_at) <= VISIT_GAP_MS) {
      last = fix;
      continue;
    }
    if (first && last && first.site_id !== null) out.push([first, last]);
    first = last = fix;
  }
  if (first && last && first.site_id !== null) out.push([first, last]);
  return out;
}

const minutesBetween = (a: Fix, b: Fix) => Math.floor((Date.parse(b.recorded_at) - Date.parse(a.recorded_at)) / 60_000);

export async function attendance(env: Env, day: string, tz: number) {
  const byEmployee = await fixesByEmployee(env, day, tz);
  const employees = await all<{ id: number; full_name: string; team_name: string | null }>(
    env.DB,
    `SELECT e.id, e.full_name, t.name AS team_name FROM employees e LEFT JOIN teams t ON t.id = e.team_id
      WHERE e.active = 1 ORDER BY e.full_name COLLATE NOCASE`,
  );
  return employees.map((e) => {
    const items = byEmployee.get(e.id) ?? [];
    const v = visits(items);
    return {
      employee_id: e.id,
      employee_name: e.full_name,
      team_name: e.team_name,
      first_seen: items[0]?.recorded_at ?? null,
      last_seen: items[items.length - 1]?.recorded_at ?? null,
      on_site_minutes: v.reduce((sum, [a, b]) => sum + minutesBetween(a, b), 0),
      fixes: items.length,
      sites: [...new Set(v.map(([a]) => a.site_name).filter((n): n is string => Boolean(n)))].sort(),
    };
  });
}

export async function siteVisits(env: Env, day: string, tz: number) {
  const byEmployee = await fixesByEmployee(env, day, tz);
  const names = new Map(
    (await all<{ id: number; full_name: string }>(env.DB, `SELECT id, full_name FROM employees`)).map((e) => [e.id, e.full_name]),
  );
  const rows = [];
  for (const [employeeId, items] of byEmployee) {
    for (const [a, b] of visits(items)) {
      rows.push({
        site_id: a.site_id!,
        site_name: a.site_name ?? 'Site',
        employee_id: employeeId,
        employee_name: names.get(employeeId) ?? '',
        arrived_at: a.recorded_at,
        left_at: b.recorded_at,
        minutes: minutesBetween(a, b),
      });
    }
  }
  return rows.sort((x, y) => x.arrived_at.localeCompare(y.arrived_at));
}

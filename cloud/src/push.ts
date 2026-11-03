// Firebase Cloud Messaging (HTTP v1). Optional: without the
// FIREBASE_SERVICE_ACCOUNT secret, pushes are skipped and phones are reached
// over the WebSocket while the app is open.

import type { Env } from './db';

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
}

let cached: { token: string; expires: number } | null = null;

const b64url = (bytes: ArrayBuffer | Uint8Array | string): string => {
  const raw = typeof bytes === 'string' ? bytes : String.fromCharCode(...new Uint8Array(bytes as ArrayBuffer));
  return btoa(raw).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
};

async function accessToken(sa: ServiceAccount): Promise<string> {
  if (cached && cached.expires > Date.now() + 60_000) return cached.token;
  const now = Math.floor(Date.now() / 1000);
  const header = b64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = b64url(
    JSON.stringify({
      iss: sa.client_email,
      scope: 'https://www.googleapis.com/auth/firebase.messaging',
      aud: 'https://oauth2.googleapis.com/token',
      iat: now,
      exp: now + 3600,
    }),
  );
  const pem = sa.private_key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, ['sign']);
  const signature = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, new TextEncoder().encode(`${header}.${claims}`));
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${header}.${claims}.${b64url(signature)}`,
    }),
  });
  const body = (await res.json()) as { access_token?: string; expires_in?: number };
  if (!body.access_token) throw new Error('FCM auth failed');
  cached = { token: body.access_token, expires: Date.now() + (body.expires_in ?? 3600) * 1000 };
  return cached.token;
}

export const pushEnabled = (env: Env): boolean => Boolean(env.FIREBASE_SERVICE_ACCOUNT);

/** Sends a high-priority data message. Returns true when FCM accepted it. */
export async function sendPush(
  env: Env,
  token: string | null,
  data: Record<string, string>,
  notification?: { title: string; body: string },
): Promise<boolean> {
  if (!env.FIREBASE_SERVICE_ACCOUNT || !token) return false;
  try {
    const sa = JSON.parse(env.FIREBASE_SERVICE_ACCOUNT) as ServiceAccount;
    const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${await accessToken(sa)}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        message: {
          token,
          data,
          android: {
            priority: 'high',
            ttl: '300s',
            ...(notification ? { notification: { ...notification, channel_id: 'location_requests' } } : {}),
          },
        },
      }),
    });
    if (!res.ok) console.warn('FCM send failed', res.status, await res.text());
    return res.ok;
  } catch (err) {
    console.warn('FCM send failed', err);
    return false;
  }
}

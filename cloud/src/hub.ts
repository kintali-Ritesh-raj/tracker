// Realtime hub: one Durable Object instance holds every WebSocket, tagged by
// audience ("admins" or "employee:<id>") and by device ("device:<id>").
// Uses the hibernation API, so idle sockets cost nothing.

import { DurableObject } from 'cloudflare:workers';

import type { Env, Waiter } from './db';

export const ADMINS = 'admins';
export const employeeAudience = (id: number) => `employee:${id}`;

export interface PublishMessage {
  audiences: string[];
  type: string;
  data: unknown;
}

export class Hub extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === '/connect') return this.acceptSocket(request);
    return new Response('Not found', { status: 404 });
  }

  private acceptSocket(request: Request): Response {
    const audience = request.headers.get('x-audience')!;
    const deviceId = request.headers.get('x-device-id')!;
    const protocol = request.headers.get('x-subprotocol');
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [audience, `device:${deviceId}`]);
    server.send(JSON.stringify({ type: 'hello', data: { device_id: Number(deviceId), audience } }));
    const headers = protocol ? { 'Sec-WebSocket-Protocol': protocol } : undefined;
    return new Response(null, { status: 101, webSocket: client, headers });
  }

  /** RPC: fan a message out to every socket in the given audiences. */
  async publish(message: PublishMessage): Promise<number> {
    const frame = JSON.stringify({ type: message.type, data: message.data });
    let sent = 0;
    for (const audience of new Set(message.audiences)) {
      for (const ws of this.ctx.getWebSockets(audience)) {
        try {
          ws.send(frame);
          sent++;
        } catch {
          // Dead socket; the runtime will deliver webSocketClose.
        }
      }
    }
    return sent;
  }

  /**
   * RPC: disconnect a revoked device. The explicit event comes first because a
   * server-initiated close frame on a hibernatable socket is not always
   * delivered (observed in local workerd); the app treats either as revocation.
   */
  async closeDevice(deviceId: number): Promise<void> {
    for (const ws of this.ctx.getWebSockets(`device:${deviceId}`)) {
      try {
        ws.send(JSON.stringify({ type: 'device.revoked', data: {} }));
        ws.close(4401, 'Device revoked');
      } catch {
        // Already closed.
      }
    }
  }

  async isConnected(audience: string): Promise<boolean> {
    return this.ctx.getWebSockets(audience).length > 0;
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    // Clients only send {"type":"pong"}; answer app-level pings for older builds.
    if (typeof message === 'string' && message.includes('"ping"')) ws.send(JSON.stringify({ type: 'pong', data: {} }));
  }

  async webSocketClose(ws: WebSocket, code: number, reason: string): Promise<void> {
    try {
      ws.close(code === 1005 ? 1000 : code, reason);
    } catch {
      // Already closed.
    }
  }
}

const hubStub = (env: Env) => env.HUB.get(env.HUB.idFromName('global')) as unknown as DurableObjectStub<Hub>;

/** Fire-and-forget publish so a slow socket never delays the HTTP response. */
export function publish(env: Env, ctx: Waiter, audiences: string[], type: string, data: unknown): void {
  ctx.waitUntil(hubStub(env).publish({ audiences, type, data }).catch(() => 0));
}

export function closeDevice(env: Env, ctx: Waiter, deviceId: number): void {
  ctx.waitUntil(hubStub(env).closeDevice(deviceId).catch(() => undefined));
}

export function hubFetch(env: Env, request: Request): Promise<Response> {
  return hubStub(env).fetch(request);
}

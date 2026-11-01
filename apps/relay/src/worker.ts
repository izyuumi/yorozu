/// <reference types="@cloudflare/workers-types" />
import {
  ACTIVITY_PUSH_PER_MINUTE,
  activityPayload,
  alertPayload,
  allowFrame,
  allowNotify,
  AUTH_TIMEOUT_MS,
  parseAck,
  parseActivityPush,
  parseActivityToken,
  BACKGROUND_CLASSES,
  BACKGROUND_INTERVAL_MS,
  backgroundPayload,
  SILENT_CLASS,
  BUFFER_TTL_MS,
  CLOSE_BAD_SIGNATURE,
  CLOSE_POLICY,
  CLOSE_PROTOCOL,
  CLOSE_RATE_LIMIT,
  dropCount,
  evictions,
  frameWire,
  isRoomId,
  MAX_PAYLOAD_BYTES,
  PHONE_BUFFER_CAP_BYTES,
  MAX_TOKENS_PER_ROOM,
  newBucket,
  NOTIFY_PER_MINUTE,
  parseDevices,
  parseEnvelope,
  parseFrames,
  parseJoin,
  parseNotify,
  parsePush,
  parseRegister,
  parseRevoke,
  PING,
  positiveLimit,
  PONG,
  safeReason,
  TOKEN_TTL_MS,
  type ActivityPush,
  type Bucket,
  type Notify,
  type NotifyWindow,
} from "./protocol.js";
import * as apns from "./apns.js";
import { isMailboxId, MAX_LETTER_BYTES } from "./mailbox.js";

export interface Env extends apns.ApnsEnv {
  ROOM: DurableObjectNamespace;
  MAILBOX: DurableObjectNamespace;
  CONNECT_LIMIT?: RateLimit;
  RELAY_MAX_TOKENS_PER_ROOM?: string;
  RELAY_NOTIFY_PER_MINUTE?: string;
  RELAY_ACTIVITY_PER_MINUTE?: string;
}

const ED25519 = { name: "Ed25519" } as const;

function fromBase64Url(s: string): Uint8Array {
  const bin = atob(s.replace(/-/g, "+").replace(/_/g, "/"));
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

function toBase64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

async function roomId(macPublicKey: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", fromBase64Url(macPublicKey));
  return toBase64Url(new Uint8Array(digest));
}

const randomToken = (): string => toBase64Url(crypto.getRandomValues(new Uint8Array(32)));

function send(ws: WebSocket, raw: string): void {
  try {
    ws.send(raw);
  } catch {
  }
}

function log(ev: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ ev, ...fields }));
}

const roleOf = (ws: WebSocket): Conn["role"] =>
  (ws.deserializeAttachment() as Conn | null)?.role ?? null;

type Conn = {
  nonce: string;
  room: string;
  role: "mac" | "phone" | null;
  key: string | null;
  bucket?: Bucket;
  since?: number;
  sentBytes?: number;
  ackedBytes?: number;
};

type Buffered = { raw: string; bytes: number; at: number; seq: number };

const bufferKey = (seq: number): string => `b:${String(seq).padStart(16, "0")}`;

const devicePrefix = "p:";

const pushPrefix = "push:";

type PushRecord = {
  deviceToken: string;
  backgroundAt?: number;
  sandbox?: boolean;
};

const tokenPrefix = "t:";

/** A device's Live Activity push token, registered by the host; the activity's content never stays here. */
const activityPrefix = "activity:";

type ActivityRecord = { token: string; sandbox?: boolean };

export class Room implements DurableObject {
  private tail: Promise<unknown> = Promise.resolve();
  /** Activity pushes in the order the host sent them, apart from the frame queue so APNs never delays a frame. */
  private activityTail: Promise<unknown> = Promise.resolve();
  private keys = new Map<string, Promise<CryptoKey>>();
  private backgroundPending = new Set<string>();

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {
    this.state.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
  }

  async fetch(request: Request): Promise<Response> {
    const room = new URL(request.url).searchParams.get("room")!;
    const { 0: client, 1: server } = new WebSocketPair();
    this.state.acceptWebSocket(server);
    const nonce = randomToken();
    const now = Date.now();
    server.serializeAttachment({ nonce, room, role: null, key: null, bucket: newBucket(now), since: now } satisfies Conn);
    server.send(JSON.stringify({ type: "nonce", nonce }));
    await this.alarmBy(now + AUTH_TIMEOUT_MS);
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws: WebSocket, data: string | ArrayBuffer): Promise<void> {
    const done = this.tail
      .then(() => this.handle(ws, data))
      .catch((error: unknown) => log("error", { role: roleOf(ws), error: String(error) }));
    this.tail = done;
    return done;
  }

  webSocketClose(ws: WebSocket, code: number, reason: string, wasClean: boolean): void {
    const conn = ws.deserializeAttachment() as Conn | null;
    log("close", { role: conn?.role ?? null, code, reason: safeReason(reason), wasClean });
    if (conn?.role === "mac" && !this.sockets("mac").some((other) => other !== ws)) {
      this.notifyOwner(false);
    }
    if (conn?.role === "phone") this.notifyPhones(ws);
  }

  webSocketError(ws: WebSocket, error: unknown): void {
    log("error", { role: roleOf(ws), error: String(error) });
  }

  private drop(ws: WebSocket, code: number, reason: string): void {
    log("drop", { role: roleOf(ws), code, reason });
    ws.close(code, reason);
  }

  private sweepUnauthenticated(now: number): number {
    let next = Infinity;
    for (const ws of this.state.getWebSockets()) {
      const conn = ws.deserializeAttachment() as Conn | null;
      if (!conn || conn.role !== null) continue;
      const deadline = (conn.since ?? now) + AUTH_TIMEOUT_MS;
      if (now >= deadline) this.drop(ws, CLOSE_POLICY, "auth timeout");
      else next = Math.min(next, deadline);
    }
    return next;
  }

  async alarm(): Promise<void> {
    const now = Date.now();
    const storage = this.state.storage;
    const authDue = this.sweepUnauthenticated(now);
    await this.trim(now);
    const tokens = await storage.transaction(async (storage) => {
      const tokens = await storage.list<number>({ prefix: tokenPrefix });
      const expired = [...tokens].filter(([, expiresAt]) => now > expiresAt).map(([key]) => key);
      if (expired.length > 0) await storage.delete(expired);
      const order = ((await storage.get<string[]>("token-order")) ?? [])
        .filter((key) => (tokens.get(key) ?? -Infinity) >= now);
      if (order.length > 0) await storage.put("token-order", order);
      else await storage.delete("token-order");
      return tokens;
    });
    const remaining = await storage.list({ prefix: "b:", limit: 1 });
    const next = Math.min(
      authDue,
      remaining.size > 0 ? now + BUFFER_TTL_MS : Infinity,
      ...[...tokens.values()].filter((expiresAt) => expiresAt >= now).map((expiresAt) => expiresAt + 1),
    );
    if (next !== Infinity) await storage.setAlarm(next);
  }

  private async alarmBy(at: number): Promise<void> {
    const scheduled = await this.state.storage.getAlarm();
    if (scheduled === null || scheduled > at) await this.state.storage.setAlarm(at);
  }

  private async mint(now: number): Promise<{ token: string; expiresAt: number }> {
    const token = randomToken();
    const expiresAt = now + TOKEN_TTL_MS;
    const cap = positiveLimit(this.env.RELAY_MAX_TOKENS_PER_ROOM, MAX_TOKENS_PER_ROOM);
    await this.state.storage.transaction(async (storage) => {
      const tokens = await storage.list<number>({ prefix: tokenPrefix });
      const order = (await storage.get<string[]>("token-order")) ?? [];
      const legacy = [...tokens].filter(([key, at]) => at >= now && !order.includes(key))
        .sort(([, a], [, b]) => a - b).map(([key]) => key);
      const live = [...legacy, ...order.filter((key) => (tokens.get(key) ?? -Infinity) >= now)];
      const drop = [...tokens].filter(([, at]) => now > at).map(([key]) => key);
      drop.push(...live.splice(0, Math.max(0, live.length - cap + 1)));
      if (drop.length > 0) await storage.delete(drop);
      await storage.put(tokenPrefix + token, expiresAt);
      await storage.put("token-order", [...live, tokenPrefix + token]);
    });
    await this.alarmBy(expiresAt + 1);
    return { token, expiresAt };
  }

  private async reserveNotify(now: number, key: string, limit: number): Promise<boolean> {
    return this.state.storage.transaction(async (storage) => {
      const window = (await storage.get<NotifyWindow>(key)) ?? { count: 0, startedAt: now };
      if (!allowNotify(window, now, limit)) return false;
      await storage.put(key, window);
      return true;
    });
  }

  private sockets(role: "mac" | "phone"): WebSocket[] {
    return this.state
      .getWebSockets()
      .filter((ws) => (ws.deserializeAttachment() as Conn | null)?.role === role);
  }

  private mac(): WebSocket | null {
    return this.sockets("mac").find((ws) => ws.readyState === WebSocket.OPEN) ?? null;
  }

  private ownerOnline(): boolean {
    return this.mac() !== null;
  }

  private key(pubkey: string): Promise<CryptoKey> {
    let key = this.keys.get(pubkey);
    if (!key) {
      key = crypto.subtle.importKey("raw", fromBase64Url(pubkey), ED25519, false, ["verify"]);
      this.keys.set(pubkey, key);
    }
    return key;
  }

  private async verify(data: string, signature: string, pubkey: string): Promise<boolean> {
    try {
      const key = await this.key(pubkey);
      return await crypto.subtle.verify(
        ED25519,
        key,
        fromBase64Url(signature),
        new TextEncoder().encode(data),
      );
    } catch {
      return false;
    }
  }

  private notifyOwner(online: boolean): void {
    const raw = JSON.stringify({ type: "owner", online });
    for (const phone of this.sockets("phone")) send(phone, raw);
  }

  private phoneCount(leaving?: WebSocket): number {
    return this.sockets("phone").filter((ws) => ws !== leaving).length;
  }

  private notifyPhones(leaving?: WebSocket): void {
    const mac = this.mac();
    if (mac) send(mac, JSON.stringify({ type: "phones", count: this.phoneCount(leaving) }));
  }

  private sendPhone(ws: WebSocket, frame: { payload: string; sig: string }): void {
    if (ws.readyState !== WebSocket.OPEN) return;
    const conn = ws.deserializeAttachment() as Conn;
    const sent = conn.sentBytes ?? 0;
    const acked = conn.ackedBytes ?? 0;
    const raw = frameWire(frame);
    const next = sent + new TextEncoder().encode(raw).byteLength + 32;
    if (!Number.isSafeInteger(next) || next - acked > PHONE_BUFFER_CAP_BYTES) {
      log("slow-phone", { unackedBytes: sent - acked });
      this.drop(ws, 1013, "slow receiver");
      return;
    }
    ws.serializeAttachment({ ...conn, sentBytes: next } satisfies Conn);
    send(ws, JSON.stringify({ ...frame, type: "frame", flowBytes: next }));
  }

  private async entries(): Promise<[string, Buffered][]> {
    return [...(await this.state.storage.list<Buffered>({ prefix: "b:" }))];
  }

  private async trim(now: number): Promise<void> {
    const entries = await this.entries();
    const drop = dropCount(
      entries.map(([, entry]) => entry),
      now,
    );
    if (drop > 0) {
      log("buffer-trim", { dropped: drop, kept: entries.length - drop });
      await this.state.storage.delete(entries.slice(0, drop).map(([key]) => key));
    }
  }

  private async buffer(raw: string, now: number): Promise<void> {
    const storage = this.state.storage;
    const seq = (await storage.get<number>("seq")) ?? 0;
    await storage.put(bufferKey(seq), {
      raw,
      bytes: new TextEncoder().encode(raw).length,
      at: now,
      seq,
    } satisfies Buffered);
    await storage.put("seq", seq + 1);
    await this.trim(now);
    await this.alarmBy(now + BUFFER_TTL_MS);
  }

  private async drain(mac: WebSocket, now: number): Promise<void> {
    await this.trim(now);
    const entries = await this.entries();
    if (entries.length === 0) return;
    log("drain", { count: entries.length });
    for (const [, entry] of entries) {
      send(mac, JSON.stringify({ ...(JSON.parse(entry.raw) as object), seq: entry.seq }));
    }
  }

  private async ack(seq: number): Promise<void> {
    const entries = await this.entries();
    const done = entries.filter(([, entry]) => entry.seq <= seq).map(([key]) => key);
    if (done.length > 0) await this.state.storage.delete(done);
  }

  private async remember(pubkey: string, now: number): Promise<void> {
    const known = [...(await this.state.storage.list<number>({ prefix: devicePrefix }))].map(
      ([key, at]): [string, number] => [key.slice(devicePrefix.length), at],
    );
    const drop = evictions(known, pubkey);
    await this.forget(drop);
    await this.state.storage.put(devicePrefix + pubkey, now);
  }

  private async forget(pubkeys: readonly string[]): Promise<void> {
    if (pubkeys.length === 0) return;
    await this.state.storage.delete(pubkeys.map((key) => devicePrefix + key));
    await this.state.storage.delete(pubkeys.map((key) => pushPrefix + key));
    await this.state.storage.delete(pubkeys.map((key) => activityPrefix + key));
    const gone = new Set(pubkeys);
    for (const phone of this.sockets("phone")) {
      const key = (phone.deserializeAttachment() as Conn | null)?.key;
      if (key && gone.has(key)) this.drop(phone, CLOSE_PROTOCOL, "revoked");
    }
  }

  private async push(
    request: apns.ApnsRequest,
    now: number,
    sandbox = false,
  ): Promise<{ code: number; reason?: string; sandbox: boolean } | null> {
    try {
      let result = await apns.send(this.env, request, now, sandbox);
      if (apns.misaddressed(result)) {
        sandbox = !sandbox;
        result = await apns.send(this.env, request, now, sandbox);
      }
      const { status: code, reason } = result;
      if (code < 200 || code >= 300) log("apns", { pushType: request.pushType, code, reason, sandbox });
      return { code, ...(reason ? { reason } : {}), sandbox };
    } catch (error) {
      log("apns", { pushType: request.pushType, error: String(error) });
      return null;
    }
  }

  private async recordPush(
    key: string,
    token: string,
    result: { code: number; sandbox: boolean },
    backgroundAt?: number,
  ): Promise<PushRecord | undefined> {
    return this.state.storage.transaction(async (storage) => {
      const current = await storage.get<PushRecord>(key);
      if (current?.deviceToken !== token) return;
      if (apns.gone(result.code)) {
        await storage.delete(key);
        return;
      }
      if (result.code >= 200 && result.code < 300) {
        const changed = result.sandbox !== (current.sandbox ?? false);
        if (changed) current.sandbox = result.sandbox;
        if (backgroundAt !== undefined) {
          current.backgroundAt = Math.max(current.backgroundAt ?? 0, backgroundAt);
        }
        if (changed || backgroundAt !== undefined) await storage.put(key, current);
      }
      return current;
    });
  }

  private async wake(notify: Notify, now: number): Promise<void> {
    if (!apns.configured(this.env)) return;

    const watching = new Set(
      this.sockets("phone")
        .map((ws) => (ws.deserializeAttachment() as Conn | null)?.key)
        .filter((key): key is string => key !== null && key !== undefined),
    );
    const named = notify.devices ? new Set(notify.devices.map((key) => pushPrefix + key)) : null;
    const records = [...(await this.state.storage.list<PushRecord>({ prefix: pushPrefix }))]
      .filter(([key]) => !named || named.has(key));
    await Promise.all(
      records.map(([key, record]) => this.wakeDevice(key, record, notify, now, watching)),
    );
  }

  private async wakeDevice(
    key: string,
    record: PushRecord,
    notify: Notify,
    now: number,
    watching: ReadonlySet<string>,
  ): Promise<void> {
    const deviceKey = key.slice(pushPrefix.length);
    if (notify.class === SILENT_CLASS) return this.wakeSilently(key, record, now, watching);
    const alert = await this.push({
      token: record.deviceToken,
      payload: alertPayload(
        notify.class,
        notify.threadRef,
        notify.eventRef,
        notify.previews?.[deviceKey],
        notify.actions === true,
      ),
      pushType: "alert",
    }, now, record.sandbox ?? false);
    if (alert === null) return;

    const background = !watching.has(deviceKey)
      && BACKGROUND_CLASSES.includes(notify.class)
      && !this.backgroundPending.has(key);
    if (background) this.backgroundPending.add(key);
    try {
      const current = await this.recordPush(key, record.deviceToken, alert);
      if (!current || !background || now - (current.backgroundAt ?? 0) < BACKGROUND_INTERVAL_MS) return;
      const silent = await this.push({
        token: current.deviceToken,
        payload: backgroundPayload(),
        pushType: "background",
        priority: 5,
      }, now, current.sandbox ?? false);
      if (silent) await this.recordPush(key, current.deviceToken, silent, now);
    } finally {
      if (background) this.backgroundPending.delete(key);
    }
  }

  private async wakeSilently(key: string, record: PushRecord, now: number, watching: ReadonlySet<string>): Promise<void> {
    if (watching.has(key.slice(pushPrefix.length))) return;
    const silent = await this.push({
      token: record.deviceToken,
      payload: backgroundPayload(),
      pushType: "background",
      priority: 5,
    }, now, record.sandbox ?? false);
    if (silent) await this.recordPush(key, record.deviceToken, silent, now);
  }

  private async registerActivity(device: string, token: string | undefined): Promise<void> {
    const key = activityPrefix + device;
    if (token === undefined) {
      await this.state.storage.delete(key);
      return;
    }
    const current = await this.state.storage.get<ActivityRecord>(key);
    if (current?.token === token) return;
    if ((await this.state.storage.get<number>(devicePrefix + device)) === undefined) return;
    // An activity token lives in the same APNs environment as the device's own token.
    const sandbox = (await this.state.storage.get<PushRecord>(pushPrefix + device))?.sandbox;
    await this.state.storage.put(key, { token, ...(sandbox ? { sandbox } : {}) } satisfies ActivityRecord);
  }

  private async pushActivity(push: ActivityPush, now: number): Promise<void> {
    if (!apns.configured(this.env)) return;
    const key = activityPrefix + push.device;
    const record = await this.state.storage.get<ActivityRecord>(key);
    if (!record) return;
    const result = await this.push({
      token: record.token,
      payload: activityPayload(push, now),
      pushType: "liveactivity",
      priority: push.priority,
    }, now, record.sandbox ?? false);
    if (result === null) return;
    const dead = apns.dead({ status: result.code, ...(result.reason ? { reason: result.reason } : {}) });
    const ok = result.code >= 200 && result.code < 300;
    const forgotten = await this.state.storage.transaction(async (storage) => {
      const current = await storage.get<ActivityRecord>(key);
      if (current?.token !== record.token) return false;
      if (dead || (ok && push.event === "end")) {
        await storage.delete(key);
        return dead;
      }
      if (ok && result.sandbox !== (current.sandbox ?? false)) {
        await storage.put(key, { token: current.token, ...(result.sandbox ? { sandbox: true } : {}) } satisfies ActivityRecord);
      }
      return false;
    });
    const mac = forgotten ? this.mac() : null;
    if (mac) send(mac, JSON.stringify({ type: "activityGone", device: push.device }));
  }

  private async handle(ws: WebSocket, data: string | ArrayBuffer): Promise<void> {
    if (ws.readyState !== WebSocket.OPEN) return;
    const bytes = typeof data === "string" ? new TextEncoder().encode(data).byteLength : data.byteLength;
    if (bytes > MAX_PAYLOAD_BYTES) return this.drop(ws, 1009, "message too big");
    const raw = typeof data === "string" ? data : new TextDecoder().decode(data);
    const now = Date.now();
    const conn = ws.deserializeAttachment() as Conn;
    const storage = this.state.storage;

    const bucket = conn.bucket ?? newBucket(now);
    if (!allowFrame(bucket, now)) return this.drop(ws, CLOSE_RATE_LIMIT, "rate limit");
    conn.bucket = bucket;
    ws.serializeAttachment(conn);

    const msg = parseEnvelope(raw);
    if (!msg) return this.drop(ws, CLOSE_PROTOCOL, "bad json");

    switch (msg.type) {
      case "register": {
        const register = parseRegister(msg);
        if (!register) return this.drop(ws, CLOSE_PROTOCOL, "bad register");
        const { pubkey, nonceSig } = register;
        let id: string;
        try {
          id = await roomId(pubkey);
        } catch {
          return this.drop(ws, CLOSE_PROTOCOL, "bad pubkey");
        }
        const owner = (await storage.get<string>("owner")) ?? null;
        if (id !== conn.room || (owner !== null && owner !== pubkey)) {
          return this.drop(ws, CLOSE_PROTOCOL, "wrong room");
        }
        if (!(await this.verify(conn.nonce, nonceSig, pubkey))) {
          return this.drop(ws, CLOSE_BAD_SIGNATURE, "bad challenge");
        }
        if (owner === null) await storage.put("owner", pubkey);
        for (const stale of this.sockets("mac")) {
          if (stale !== ws) this.drop(stale, CLOSE_PROTOCOL, "replaced");
        }
        ws.serializeAttachment({ ...conn, role: "mac", key: pubkey } satisfies Conn);
        ws.send(JSON.stringify({
          type: "registered",
          roomId: id,
          phones: this.phoneCount(),
          ...(apns.configured(this.env) ? { liveActivity: true } : {}),
        }));
        log("registered", { phones: this.sockets("phone").length });
        this.notifyOwner(true);
        return await this.drain(ws, now);
      }

      case "ack": {
        if (conn.role !== "mac") return this.drop(ws, CLOSE_PROTOCOL, "not registered");
        const ack = parseAck(msg);
        if (!ack) return this.drop(ws, CLOSE_PROTOCOL, "bad ack");
        return await this.ack(ack.seq);
      }

      case "flowAck": {
        if (conn.role !== "phone") return this.drop(ws, CLOSE_PROTOCOL, "not joined");
        const bytes = Number(msg.bytes);
        const sent = conn.sentBytes ?? 0;
        const acked = conn.ackedBytes ?? 0;
        if (typeof msg.bytes !== "string" || !/^(0|[1-9][0-9]*)$/.test(msg.bytes)
          || !Number.isSafeInteger(bytes) || bytes > sent) {
          return this.drop(ws, CLOSE_PROTOCOL, "bad flow ack");
        }
        if (bytes > acked) ws.serializeAttachment({ ...conn, ackedBytes: bytes } satisfies Conn);
        return;
      }

      case "ping":
        return void ws.send(PONG);

      case "owner": {
        if (conn.role !== "phone") return this.drop(ws, CLOSE_PROTOCOL, "not joined");
        return void ws.send(JSON.stringify({ type: "owner", online: this.ownerOnline() }));
      }

      case "mint": {
        if (conn.role !== "mac") return this.drop(ws, CLOSE_PROTOCOL, "not registered");
        const { token, expiresAt } = await this.mint(now);
        ws.send(JSON.stringify({ type: "token", token, expiresAt }));
        return;
      }

      case "revoke": {
        if (conn.role !== "mac") return this.drop(ws, CLOSE_PROTOCOL, "not registered");
        const revoke = parseRevoke(msg);
        if (!revoke) return this.drop(ws, CLOSE_PROTOCOL, "bad revoke");
        return await this.forget([revoke.pubkey]);
      }

      case "devices": {
        if (conn.role !== "mac") return this.drop(ws, CLOSE_PROTOCOL, "not registered");
        const announced = parseDevices(msg);
        if (!announced) return this.drop(ws, CLOSE_PROTOCOL, "bad devices");
        const keep = new Set(announced.devices);
        for (const phone of this.sockets("phone")) {
          const key = (phone.deserializeAttachment() as Conn | null)?.key;
          if (key) keep.add(key);
        }
        const known = new Set(
          [...(await storage.list<number>({ prefix: devicePrefix })).keys()].map((key) =>
            key.slice(devicePrefix.length),
          ),
        );
        for (const pubkey of keep) {
          if (!known.has(pubkey)) await storage.put(devicePrefix + pubkey, now);
        }
        return await this.forget([...known].filter((pubkey) => !keep.has(pubkey)));
      }

      case "join": {
        const join = parseJoin(msg);
        if (!join) return this.drop(ws, CLOSE_PROTOCOL, "bad join");
        const { roomId: id, token, phonePubkey, sig } = join;
        if (id !== conn.room) return this.drop(ws, CLOSE_PROTOCOL, "wrong room");
        if (token === undefined) {
          if ((await storage.get<number>(devicePrefix + phonePubkey)) === undefined) {
            return this.drop(ws, CLOSE_PROTOCOL, "unknown device");
          }
          if (!(await this.verify(conn.nonce, sig, phonePubkey))) {
            return this.drop(ws, CLOSE_BAD_SIGNATURE, "bad join signature");
          }
          await storage.put(devicePrefix + phonePubkey, now);
        } else {
          const expiresAt = await storage.get<number>(tokenPrefix + token);
          if (expiresAt === undefined) return this.drop(ws, CLOSE_PROTOCOL, "unknown token");
          if (now > expiresAt) {
            await storage.delete(tokenPrefix + token);
            return this.drop(ws, CLOSE_PROTOCOL, "expired token");
          }
          if (!(await this.verify(token, sig, phonePubkey))) {
            return this.drop(ws, CLOSE_BAD_SIGNATURE, "bad join signature");
          }
          await storage.delete(tokenPrefix + token);
          await this.remember(phonePubkey, now);
        }
        ws.serializeAttachment({ ...conn, role: "phone", key: phonePubkey } satisfies Conn);
        ws.send(JSON.stringify({ type: "joined", roomId: id, ownerOnline: this.ownerOnline(), flowControl: true }));
        log("joined", { rejoin: token === undefined, ownerOnline: this.ownerOnline() });
        this.notifyPhones();
        return;
      }

      case "push": {
        if (conn.role !== "phone" || !conn.key) return this.drop(ws, CLOSE_PROTOCOL, "not joined");
        const push = parsePush(msg);
        if (!push) return this.drop(ws, CLOSE_PROTOCOL, "bad push");
        const key = pushPrefix + conn.key;
        await storage.transaction(async (storage) => {
          const records = await storage.list<PushRecord>({ prefix: pushPrefix });
          const stale = [...records]
            .filter(([other, record]) => other !== key && record.deviceToken === push.deviceToken)
            .map(([other]) => other);
          if (stale.length > 0) await storage.delete(stale);
          const record = records.get(key);
          const next: PushRecord = { ...record, deviceToken: push.deviceToken };
          if (record?.deviceToken !== push.deviceToken) delete next.sandbox;
          await storage.put(key, next);
        });
        return;
      }

      case "notify": {
        if (conn.role !== "mac") return this.drop(ws, CLOSE_PROTOCOL, "not registered");
        const notify = parseNotify(msg);
        if (notify === null) return this.drop(ws, CLOSE_PROTOCOL, "bad notify");
        if (!notify) return;
        const limit = positiveLimit(this.env.RELAY_NOTIFY_PER_MINUTE, NOTIFY_PER_MINUTE);
        if (!(await this.reserveNotify(now, "notify-window", limit))) {
          ws.send(JSON.stringify({ type: "state", state: "notify rate limit" }));
          return;
        }
        const woken = this.wake(notify, now).catch((error: unknown) =>
          log("error", { role: "mac", error: String(error) }),
        );
        this.state.waitUntil(woken);
        return;
      }

      case "activityToken": {
        if (conn.role !== "mac") return this.drop(ws, CLOSE_PROTOCOL, "not registered");
        const registration = parseActivityToken(msg);
        if (!registration) return this.drop(ws, CLOSE_PROTOCOL, "bad activity token");
        return await this.registerActivity(registration.device, registration.token);
      }

      case "activityPush": {
        if (conn.role !== "mac") return this.drop(ws, CLOSE_PROTOCOL, "not registered");
        const push = parseActivityPush(msg);
        if (push === null) return this.drop(ws, CLOSE_PROTOCOL, "bad activity push");
        if (!push) return;
        const limit = positiveLimit(this.env.RELAY_ACTIVITY_PER_MINUTE, ACTIVITY_PUSH_PER_MINUTE);
        if (!(await this.reserveNotify(now, "activity-window", limit))) {
          ws.send(JSON.stringify({ type: "state", state: "activity rate limit" }));
          return;
        }
        const pushed = this.activityTail
          .then(() => this.pushActivity(push, now))
          .catch((error: unknown) => log("error", { role: "mac", error: String(error) }));
        this.activityTail = pushed;
        this.state.waitUntil(pushed);
        return;
      }

      case "frame": {
        if (!conn.role || !conn.key) return this.drop(ws, CLOSE_PROTOCOL, "not joined");
        const frames = parseFrames(msg);
        if (!frames) return this.drop(ws, CLOSE_BAD_SIGNATURE, "unsigned frame");
        if (msg.frames !== undefined && conn.role === "phone") {
          return this.drop(ws, CLOSE_PROTOCOL, "batch from phone");
        }
        for (const frame of frames) {
          if (!(await this.verify(frame.payload, frame.sig, conn.key))) {
            return this.drop(ws, CLOSE_BAD_SIGNATURE, "bad frame signature");
          }
        }
        if (conn.role === "phone") {
          const mac = this.mac();
          if (mac) send(mac, raw);
          else await this.buffer(raw, now);
          ws.send(JSON.stringify({ type: "accepted", sig: frames[0]!.sig, buffered: !mac }));
        } else {
          for (const phone of this.sockets("phone")) for (const frame of frames) this.sendPhone(phone, frame);
        }
        return;
      }

      default:
        return; // An unknown type is ignored (it still costs a rate-limit token).
    }
  }
}

async function overLimit(request: Request, env: Env): Promise<boolean> {
  const address = request.headers.get("CF-Connecting-IP");
  const verdict = address ? await env.CONNECT_LIMIT?.limit({ key: address }).catch(() => undefined) : undefined;
  return verdict?.success === false;
}

export { Mailbox } from "./mailbox.js";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const mailbox = /^\/mailbox\/([^/]+)$/.exec(url.pathname)?.[1];
    if (mailbox !== undefined) {
      if (!isMailboxId(mailbox)) return new Response("bad mailbox", { status: 400 });
      if (Number(request.headers.get("Content-Length") ?? 0) > MAX_LETTER_BYTES) {
        return new Response("letter too large", { status: 413 });
      }
      if (await overLimit(request, env)) return new Response("too many connections", { status: 429 });
      return env.MAILBOX.get(env.MAILBOX.idFromName(mailbox)).fetch(request);
    }
    const room = url.searchParams.get("room");
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("yorozu relay\n", { headers: { "content-type": "text/plain" } });
    }
    if (!room) return new Response("missing ?room", { status: 400 });
    if (!isRoomId(room)) return new Response("bad ?room", { status: 400 });
    if (await overLimit(request, env)) return new Response("too many connections", { status: 429 });
    return env.ROOM.get(env.ROOM.idFromName(room)).fetch(request);
  },
} satisfies ExportedHandler<Env>;

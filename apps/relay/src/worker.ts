/// <reference types="@cloudflare/workers-types" />
/**
 * Cloudflare Worker relay: the same wire protocol as `index.ts`, one Durable Object per
 * room so every socket in a room lands on the same isolate worldwide.
 *
 * The protocol carries the room ID only *after* the socket is open (in `register`/`join`),
 * which is too late to route on, so clients pass it up front as `?room=<roomId>` — both
 * already know it before they dial. Nothing on the wire changes; the Node relay ignores
 * the query string, so a client that appends it works against either relay.
 *
 * Rooms hibernate: sockets are accepted with the Hibernation API and per-socket state
 * lives in the socket attachment, tokens and the offline buffer in DO storage. Only the
 * rate-limit bucket is in memory, which is the point of it — it is per isolate lifetime.
 */
import {
  alertPayload,
  allowFrame,
  parseAck,
  BACKGROUND_CLASSES,
  BACKGROUND_INTERVAL_MS,
  backgroundPayload,
  BUFFER_TTL_MS,
  CLOSE_BAD_SIGNATURE,
  CLOSE_PROTOCOL,
  CLOSE_RATE_LIMIT,
  dropCount,
  evictions,
  frameWire,
  newBucket,
  parseDevices,
  parseEnvelope,
  parseFrames,
  parseJoin,
  parseNotify,
  parsePush,
  parseRegister,
  parseRevoke,
  PING,
  PONG,
  safeReason,
  TOKEN_TTL_MS,
  type Bucket,
  type Notify,
} from "./protocol.js";
import * as apns from "./apns.js";

export interface Env extends apns.ApnsEnv {
  ROOM: DurableObjectNamespace;
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

/** Room ID is derived from the Mac public key; the relay never reads payloads. */
async function roomId(macPublicKey: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", fromBase64Url(macPublicKey));
  return toBase64Url(new Uint8Array(digest));
}

const randomToken = (): string => toBase64Url(crypto.getRandomValues(new Uint8Array(32)));

/** A socket that lost its peer mid-broadcast must not abort the whole fan-out. */
function send(ws: WebSocket, raw: string): void {
  try {
    ws.send(raw);
  } catch {
    // Racing a close; the close handler will clean up.
  }
}

/**
 * One line per thing worth knowing about a room's sockets, as JSON so Workers Logs can filter
 * on it. Never a payload, never a key: the relay is blind and its logs stay that way. This is
 * the only evidence there is when a phone reports "it just stopped arriving".
 */
function log(ev: string, fields: Record<string, unknown> = {}): void {
  console.log(JSON.stringify({ ev, ...fields }));
}

const roleOf = (ws: WebSocket): Conn["role"] =>
  (ws.deserializeAttachment() as Conn | null)?.role ?? null;

/** Per-socket state. Serialized into the attachment so it survives hibernation. */
type Conn = {
  nonce: string;
  /** The room this socket was routed to, straight off the URL the Worker dispatched on. */
  room: string;
  role: "mac" | "phone" | null;
  /** base64url public key whose signature every frame from this socket must carry. */
  key: string | null;
};

type Buffered = { raw: string; bytes: number; at: number; seq: number };

/** Buffer keys sort lexicographically, so zero-pad the sequence to keep them in order. */
const bufferKey = (seq: number): string => `b:${String(seq).padStart(16, "0")}`;

/** Known device keys: `p:<base64url phone signing pubkey>` -> when it last paired or rejoined. */
const devicePrefix = "p:";

/**
 * What a phone registered so it can be woken: `push:<base64url phone signing pubkey>`.
 *
 * One record per device rather than a key per token, so revoking a device is one delete and
 * cannot leave a token behind pointing at a phone that is no longer paired.
 */
const pushPrefix = "push:";

type PushRecord = {
  /** The app's own APNs device token, which alerts go to. */
  deviceToken: string;
  /**
   * When this device was last sent a silent background push, so the next one can be held back
   * until the budget allows it. Per device, because the throttling Apple does is per app install.
   */
  backgroundAt?: number;
  /**
   * Whether this token is reachable through sandbox APNs — an Xcode-signed build — rather than
   * production. Learnt from Apple's answer to the first push and kept so the next goes straight
   * there; forgotten with the token, since a new one may be from either.
   */
  sandbox?: boolean;
};

/** One-time join tokens: `t:<token>` -> expiry epoch ms. */
const tokenPrefix = "t:";

export class Room implements DurableObject {
  /**
   * One bucket per socket, in memory: a phone that floods closes itself and nobody else. A
   * socket woken from hibernation starts a fresh one, which is a full burst it was owed anyway.
   */
  private buckets = new WeakMap<WebSocket, Bucket>();
  /** Verification is async, so messages are chained to keep frames strictly in order. */
  private tail: Promise<unknown> = Promise.resolve();
  private keys = new Map<string, Promise<CryptoKey>>();
  /** An outstanding silent push reserves its device's budget until Apple answers. */
  private backgroundPending = new Set<string>();

  constructor(
    private readonly state: DurableObjectState,
    private readonly env: Env,
  ) {
    // Answered at the edge, so a heartbeat keeps the socket warm without ever waking this
    // object. Set per isolate rather than per socket: it is room-wide state and applies to
    // every hibernated socket the room holds.
    this.state.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
  }

  async fetch(request: Request): Promise<Response> {
    const room = new URL(request.url).searchParams.get("room")!;
    const { 0: client, 1: server } = new WebSocketPair();
    this.state.acceptWebSocket(server);
    const nonce = randomToken();
    server.serializeAttachment({ nonce, room, role: null, key: null } satisfies Conn);
    server.send(JSON.stringify({ type: "nonce", nonce }));
    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(ws: WebSocket, data: string | ArrayBuffer): Promise<void> {
    // Logged rather than swallowed: a throw in here is a frame that went nowhere, and the
    // socket is left open, so this line is the only sign of it anywhere.
    const done = this.tail
      .then(() => this.handle(ws, data))
      .catch((error: unknown) => log("error", { role: roleOf(ws), error: String(error) }));
    this.tail = done;
    return done;
  }

  webSocketClose(ws: WebSocket, code: number, reason: string, wasClean: boolean): void {
    const conn = ws.deserializeAttachment() as Conn | null;
    log("close", { role: conn?.role ?? null, code, reason: safeReason(reason), wasClean });
    // A re-registering Mac closes its own stale socket: only go offline if none is left.
    if (conn?.role === "mac" && !this.sockets("mac").some((other) => other !== ws)) {
      this.notifyOwner(false);
    }
  }

  webSocketError(ws: WebSocket, error: unknown): void {
    log("error", { role: roleOf(ws), error: String(error) });
  }

  /** The relay hanging up on a socket, with the reason on record. */
  private drop(ws: WebSocket, code: number, reason: string): void {
    log("drop", { role: roleOf(ws), code, reason });
    ws.close(code, reason);
  }

  /** The buffer's TTL and the join tokens' expiry, swept once rather than per entry. */
  async alarm(): Promise<void> {
    const now = Date.now();
    const storage = this.state.storage;
    await this.trim(now);
    const tokens = await storage.list<number>({ prefix: tokenPrefix });
    const expired = [...tokens].filter(([, expiresAt]) => now > expiresAt).map(([key]) => key);
    if (expired.length > 0) await storage.delete(expired);
    // Whichever comes first: the buffer's next sweep, or the earliest token still live.
    const remaining = await storage.list({ prefix: "b:", limit: 1 });
    const next = Math.min(
      remaining.size > 0 ? now + BUFFER_TTL_MS : Infinity,
      ...[...tokens.values()].filter((expiresAt) => expiresAt >= now),
    );
    if (next !== Infinity) await storage.setAlarm(next);
  }

  /** Brings the alarm forward if `at` is sooner than whatever is already scheduled. */
  private async alarmBy(at: number): Promise<void> {
    const scheduled = await this.state.storage.getAlarm();
    if (scheduled === null || scheduled > at) await this.state.storage.setAlarm(at);
  }

  private sockets(role: "mac" | "phone"): WebSocket[] {
    return this.state
      .getWebSockets()
      .filter((ws) => (ws.deserializeAttachment() as Conn | null)?.role === role);
  }

  private mac(): WebSocket | null {
    return this.sockets("mac")[0] ?? null;
  }

  /**
   * Whether the room's Mac is reachable *now*, read off the live socket set rather than any
   * stored flag: presence is exactly "a socket with the mac role is open on this object", so
   * there is nothing to cache and nothing to go stale.
   */
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

  /**
   * Tells the room's phones whether its Mac holds a live socket, so they can show an offline
   * banner instead of a silent send. This is routing state the relay already keeps — it says
   * nothing about the ciphertext, so the relay stays blind.
   */
  private notifyOwner(online: boolean): void {
    const raw = JSON.stringify({ type: "owner", online });
    for (const phone of this.sockets("phone")) send(phone, raw);
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
      // The one place the relay loses a frame on purpose. Logged because it is data gone.
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
    // Scheduled from the oldest entry, not the newest, so the sweep cannot be deferred
    // indefinitely by a phone that keeps sending.
    await this.alarmBy(now + BUFFER_TTL_MS);
  }

  /**
   * Replays what the phones sent while no Mac was here. Each frame goes out tagged with its
   * buffer sequence and stays in storage until the Mac acks it: a send onto a socket that is
   * about to die is not a delivery, and a Mac that reconnects without having acked simply
   * gets the frames again. The runtime is idempotent on event id, so a replay costs nothing.
   */
  private async drain(mac: WebSocket, now: number): Promise<void> {
    await this.trim(now);
    const entries = await this.entries();
    if (entries.length === 0) return;
    log("drain", { count: entries.length });
    for (const [, entry] of entries) {
      send(mac, JSON.stringify({ ...(JSON.parse(entry.raw) as object), seq: entry.seq }));
    }
    // Entries buffered before frames carried a sequence cannot be acked, so they are let go
    // on send as they always were rather than replayed until their TTL.
    const legacy = entries.filter(([, entry]) => entry.seq === undefined).map(([key]) => key);
    if (legacy.length > 0) await this.state.storage.delete(legacy);
  }

  /** The Mac has handled everything up to `seq`; those entries are done with. */
  private async ack(seq: number): Promise<void> {
    const entries = await this.entries();
    const done = entries.filter(([, entry]) => entry.seq <= seq).map(([key]) => key);
    if (done.length > 0) await this.state.storage.delete(done);
  }

  /**
   * Records a phone as a device this room knows, so it can rejoin against the nonce after a
   * background, a network change or an app relaunch. Capped, oldest evicted first.
   */
  private async remember(pubkey: string, now: number): Promise<void> {
    const known = [...(await this.state.storage.list<number>({ prefix: devicePrefix }))].map(
      ([key, at]): [string, number] => [key.slice(devicePrefix.length), at],
    );
    const drop = evictions(known, pubkey);
    await this.forget(drop);
    await this.state.storage.put(devicePrefix + pubkey, now);
  }

  /**
   * Drops a device the Mac no longer considers paired: it is forgotten, so it cannot rejoin
   * against the nonce, and its sockets go now rather than at their next reconnect.
   */
  private async forget(pubkeys: readonly string[]): Promise<void> {
    if (pubkeys.length === 0) return;
    await this.state.storage.delete(pubkeys.map((key) => devicePrefix + key));
    // The whole point of revoking: a device that is no longer paired stops being woken. Its
    // tokens go with it rather than lingering as something the room could still push to.
    await this.state.storage.delete(pubkeys.map((key) => pushPrefix + key));
    const gone = new Set(pubkeys);
    for (const phone of this.sockets("phone")) {
      const key = (phone.deserializeAttachment() as Conn | null)?.key;
      if (key && gone.has(key)) this.drop(phone, CLOSE_PROTOCOL, "revoked");
    }
  }

  /**
   * Sends where the device was last reached, and to the other environment if Apple says the
   * token is not from this one. A failed APNs request costs this device's attempt, never the
   * rest of the room's fan-out.
   */
  private async push(
    request: apns.ApnsRequest,
    now: number,
    sandbox = false,
  ): Promise<{ code: number; sandbox: boolean } | null> {
    try {
      let result = await apns.send(this.env, request, now, sandbox);
      if (apns.misaddressed(result)) {
        sandbox = !sandbox;
        result = await apns.send(this.env, request, now, sandbox);
      }
      const { status: code, reason } = result;
      if (code < 200 || code >= 300) log("apns", { pushType: request.pushType, code, reason, sandbox });
      return { code, sandbox };
    } catch (error) {
      log("apns", { pushType: request.pushType, error: String(error) });
      return null;
    }
  }

  /** APNs may answer after a token rotates or its device is revoked. Only update that token. */
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

  /**
   * Alerts every paired device; background catch-up only wakes devices not already watching.
   *
   * Every registered phone gets the alert. iOS can suspend an app while its WebSocket still
   * looks open from the server, so socket presence cannot prove somebody is watching. The app
   * suppresses presentation while foregrounded; only the silent catch-up push can be skipped
   * for a phone whose socket is still live.
   *
   * Runs detached from the socket's message chain (see the `notify` case) and one device at a
   * time in parallel, so a slow Apple costs neither the next frame nor the other phones. The
   * fan-out is bounded by MAX_DEVICES, which is as many push records as a room can hold.
   */
  private async wake(notify: Notify, now: number): Promise<void> {
    // No Apple key configured — a self-hosted room, or one deployed before the secrets were
    // set. The frame has still been forwarded; there is simply nobody to wake.
    if (!apns.configured(this.env)) return;

    const watching = new Set(
      this.sockets("phone")
        .map((ws) => (ws.deserializeAttachment() as Conn | null)?.key)
        .filter((key): key is string => key !== null && key !== undefined),
    );
    const records = await this.state.storage.list<PushRecord>({ prefix: pushPrefix });
    await Promise.all(
      [...records].map(([key, record]) => this.wakeDevice(key, record, notify, now, watching)),
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

    // Reserve before refreshing the stored budget: overlapping alerts must not each spend
    // the same minute while Apple is answering. Frames and alerts remain independent.
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
        // Apple rejects an urgent background push.
        priority: 5,
      }, now, current.sandbox ?? false);
      // Only an accepted push spends the budget; failures leave the next wake eligible.
      if (silent) await this.recordPush(key, current.deviceToken, silent, now);
    } finally {
      if (background) this.backgroundPending.delete(key);
    }
  }

  private async handle(ws: WebSocket, data: string | ArrayBuffer): Promise<void> {
    const raw = typeof data === "string" ? data : new TextDecoder().decode(data);
    const now = Date.now();
    const conn = ws.deserializeAttachment() as Conn;
    const storage = this.state.storage;

    // Only the envelope is parsed; `payload` is forwarded byte-for-byte.
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
        // The Node relay derives the room from the key, so a key can only ever own its own
        // room. Here the caller picked the room in the URL: pin it back to the key, or a
        // stranger could squat someone else's room and drain its buffer.
        const owner = (await storage.get<string>("owner")) ?? null;
        if (id !== conn.room || (owner !== null && owner !== pubkey)) {
          return this.drop(ws, CLOSE_PROTOCOL, "wrong room");
        }
        if (!(await this.verify(conn.nonce, nonceSig, pubkey))) {
          return this.drop(ws, CLOSE_BAD_SIGNATURE, "bad challenge");
        }
        if (owner === null) await storage.put("owner", pubkey);
        // A fresh registration wins; the stale Mac socket is dropped.
        for (const stale of this.sockets("mac")) {
          if (stale !== ws) this.drop(stale, CLOSE_PROTOCOL, "replaced");
        }
        ws.serializeAttachment({ ...conn, role: "mac", key: pubkey } satisfies Conn);
        ws.send(JSON.stringify({ type: "registered", roomId: id }));
        log("registered", { phones: this.sockets("phone").length });
        this.notifyOwner(true);
        return await this.drain(ws, now);
      }

      // The Mac has handled the replayed frames up to this sequence number.
      case "ack": {
        if (conn.role !== "mac") return this.drop(ws, CLOSE_PROTOCOL, "not registered");
        const ack = parseAck(msg);
        if (!ack) return this.drop(ws, CLOSE_PROTOCOL, "bad ack");
        return await this.ack(ack.seq);
      }

      // The heartbeat the edge normally answers for us. Handled here too so a socket that
      // somehow reaches the object still gets a pong instead of a "unknown type" close, and so
      // the Node relay and this one behave identically.
      case "ping":
        return void ws.send(PONG);

      // "Is my Mac there?", asked by a phone after every join. The `joined` reply already
      // carries it, but a phone that has been asleep has no way to trust what it last heard.
      case "owner": {
        if (conn.role !== "phone") return this.drop(ws, CLOSE_PROTOCOL, "not joined");
        return void ws.send(JSON.stringify({ type: "owner", online: this.ownerOnline() }));
      }

      case "mint": {
        if (conn.role !== "mac") return this.drop(ws, CLOSE_PROTOCOL, "not registered");
        const token = randomToken();
        const expiresAt = now + TOKEN_TTL_MS;
        await storage.put(tokenPrefix + token, expiresAt);
        // Swept by the alarm once it expires, so a token nobody redeemed does not sit in
        // storage until the next one happens to be looked up.
        await this.alarmBy(expiresAt);
        ws.send(JSON.stringify({ type: "token", token, expiresAt }));
        return;
      }

      // The Mac unpairing a phone: forgotten, so it cannot rejoin against the nonce, and
      // dropped now rather than at its next reconnect.
      case "revoke": {
        if (conn.role !== "mac") return this.drop(ws, CLOSE_PROTOCOL, "not registered");
        const revoke = parseRevoke(msg);
        if (!revoke) return this.drop(ws, CLOSE_PROTOCOL, "bad revoke");
        return await this.forget([revoke.pubkey]);
      }

      // The Mac's whole paired list, sent right after `register` and again whenever it
      // changes. It replaces what this room knows rather than adding to it, so the Mac's
      // `devices.json` is the source of truth and storage this object lost comes back.
      //
      // A device holding a live socket is kept whatever the list says: it has just proved
      // itself, and the Mac's file may not have caught up with a token join it is still
      // being told about. Unpairing a connected phone is what `revoke` is for.
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
          // A rejoin: the room already knows this device, so it proves itself against the
          // connect nonce rather than spending a token it no longer has.
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
          // Verified before burning, so a bad signature cannot consume the token.
          if (!(await this.verify(token, sig, phonePubkey))) {
            return this.drop(ws, CLOSE_BAD_SIGNATURE, "bad join signature");
          }
          await storage.delete(tokenPrefix + token);
          await this.remember(phonePubkey, now);
        }
        ws.serializeAttachment({ ...conn, role: "phone", key: phonePubkey } satisfies Conn);
        ws.send(JSON.stringify({ type: "joined", roomId: id, ownerOnline: this.ownerOnline() }));
        log("joined", { rejoin: token === undefined, ownerOnline: this.ownerOnline() });
        return;
      }

      // A phone saying where it can be woken. Filed against the key the relay already knows
      // the device by, so revoking it takes the tokens with it and nothing has to remember to.
      case "push": {
        if (conn.role !== "phone" || !conn.key) return this.drop(ws, CLOSE_PROTOCOL, "not joined");
        const push = parsePush(msg);
        if (!push) return this.drop(ws, CLOSE_PROTOCOL, "bad push");
        const key = pushPrefix + conn.key;
        // Merged rather than written over: a phone re-registers its token on every launch, and
        // that must not hand it a fresh background budget it has already spent.
        const record = await storage.get<PushRecord>(key);
        const next: PushRecord = { ...record, deviceToken: push.deviceToken };
        // A new token may be from either environment — the phone moved from an Xcode build to
        // TestFlight, or back — so what was learnt about the old one does not carry over.
        if (record?.deviceToken !== push.deviceToken) delete next.sandbox;
        await storage.put(key, next);
        return;
      }

      // The Mac, beside a sealed frame: something of this class happened over there. The frame
      // itself has already gone out; this is only the wake-up for whoever did not catch it.
      case "notify": {
        if (conn.role !== "mac") return this.drop(ws, CLOSE_PROTOCOL, "not registered");
        const notify = parseNotify(msg);
        if (!notify) return this.drop(ws, CLOSE_PROTOCOL, "bad notify");
        // Detached from the message chain: Apple answering slowly must not hold up the next
        // frame. `waitUntil` keeps the object alive for it; the catch is the only place a
        // failure would otherwise be seen.
        const woken = this.wake(notify, now).catch((error: unknown) =>
          log("error", { role: "mac", error: String(error) }),
        );
        this.state.waitUntil(woken);
        return;
      }

      case "frame": {
        if (!conn.role || !conn.key) return this.drop(ws, CLOSE_PROTOCOL, "not joined");
        const frames = parseFrames(msg);
        if (!frames) return this.drop(ws, CLOSE_BAD_SIGNATURE, "unsigned frame");
        // Only the Mac fans out; a phone batching would be a 16x discount on its bucket.
        if (msg.frames !== undefined && conn.role === "phone") {
          return this.drop(ws, CLOSE_PROTOCOL, "batch from phone");
        }
        for (const frame of frames) {
          if (!(await this.verify(frame.payload, frame.sig, conn.key))) {
            return this.drop(ws, CLOSE_BAD_SIGNATURE, "bad frame signature");
          }
        }
        let bucket = this.buckets.get(ws);
        if (!bucket) this.buckets.set(ws, (bucket = newBucket(now)));
        if (!allowFrame(bucket, now)) return this.drop(ws, CLOSE_RATE_LIMIT, "rate limit");

        if (conn.role === "phone") {
          const mac = this.mac();
          if (mac) send(mac, raw);
          else await this.buffer(raw, now);
        } else {
          // Not buffered: a phone that is away catches up by asking the Mac on its next join,
          // which holds the whole history. The relay is only ever the fast path down. A batch
          // is unpacked here: each phone sees plain frames, never the batch.
          const wires = msg.frames === undefined ? [raw] : frames.map(frameWire);
          for (const phone of this.sockets("phone")) for (const wire of wires) send(phone, wire);
        }
        return;
      }

      default:
        return this.drop(ws, CLOSE_PROTOCOL, "unknown type");
    }
  }
}

export default {
  fetch(request: Request, env: Env): Response | Promise<Response> {
    const room = new URL(request.url).searchParams.get("room");
    if (request.headers.get("Upgrade") !== "websocket") {
      return new Response("yorozu relay\n", { headers: { "content-type": "text/plain" } });
    }
    if (!room) return new Response("missing ?room", { status: 400 });
    return env.ROOM.get(env.ROOM.idFromName(room)).fetch(request);
  },
} satisfies ExportedHandler<Env>;

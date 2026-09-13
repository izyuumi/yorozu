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
  BACKGROUND_CLASSES,
  BACKGROUND_INTERVAL_MS,
  backgroundPayload,
  BUFFER_TTL_MS,
  CLOSE_BAD_SIGNATURE,
  CLOSE_PROTOCOL,
  CLOSE_RATE_LIMIT,
  dropCount,
  evictions,
  newBucket,
  parseDevices,
  parseFrame,
  parseJoin,
  parseNotify,
  parsePush,
  parseRegister,
  parseRevoke,
  PING,
  PONG,
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

/** Per-socket state. Serialized into the attachment so it survives hibernation. */
type Conn = {
  nonce: string;
  /** The room this socket was routed to, straight off the URL the Worker dispatched on. */
  room: string;
  role: "mac" | "phone" | null;
  /** base64url public key whose signature every frame from this socket must carry. */
  key: string | null;
};

type Buffered = { raw: string; bytes: number; at: number };

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
};

export class Room implements DurableObject {
  private bucket: Bucket = newBucket(Date.now());
  /** Verification is async, so messages are chained to keep frames strictly in order. */
  private tail: Promise<unknown> = Promise.resolve();
  private keys = new Map<string, Promise<CryptoKey>>();

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
    const done = this.tail.then(() => this.handle(ws, data)).catch(() => {});
    this.tail = done;
    return done;
  }

  webSocketClose(ws: WebSocket): void {
    const conn = ws.deserializeAttachment() as Conn | null;
    // A re-registering Mac closes its own stale socket: only go offline if none is left.
    if (conn?.role === "mac" && !this.sockets("mac").some((other) => other !== ws)) {
      this.notifyOwner(false);
    }
  }

  /** The buffer's TTL, swept once rather than per entry. */
  async alarm(): Promise<void> {
    const now = Date.now();
    await this.trim(now);
    const remaining = await this.state.storage.list({ prefix: "b:", limit: 1 });
    if (remaining.size > 0) await this.state.storage.setAlarm(now + BUFFER_TTL_MS);
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
    if (drop > 0) await this.state.storage.delete(entries.slice(0, drop).map(([key]) => key));
  }

  private async buffer(raw: string, now: number): Promise<void> {
    const storage = this.state.storage;
    const seq = (await storage.get<number>("seq")) ?? 0;
    await storage.put(bufferKey(seq), {
      raw,
      bytes: new TextEncoder().encode(raw).length,
      at: now,
    } satisfies Buffered);
    await storage.put("seq", seq + 1);
    await this.trim(now);
    // Scheduled from the oldest entry, not the newest, so the sweep cannot be deferred
    // indefinitely by a phone that keeps sending.
    if ((await storage.getAlarm()) === null) await storage.setAlarm(now + BUFFER_TTL_MS);
  }

  private async drain(mac: WebSocket, now: number): Promise<void> {
    const entries = await this.entries();
    if (entries.length === 0) return;
    const drop = dropCount(
      entries.map(([, entry]) => entry),
      now,
    );
    for (const [, entry] of entries.slice(drop)) send(mac, entry.raw);
    await this.state.storage.delete(entries.map(([key]) => key));
    await this.state.storage.deleteAlarm();
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
    if (drop.length > 0) await this.state.storage.delete(drop.map((key) => devicePrefix + key));
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
      if (key && gone.has(key)) phone.close(CLOSE_PROTOCOL, "revoked");
    }
  }

  /**
   * Wakes every paired device that is not already watching.
   *
   * A phone holding a live socket has just been sent the sealed event itself, so a push to it
   * would be a second copy of news it already has. Everyone else gets one alert: something a
   * person should see, which is the only thing worth waking a phone for.
   *
   * Awaited rather than left to run behind the socket: frames are handled in order on this
   * object, and a turn produces a handful of these at most — the running commentary is not
   * notified at all, so only a turn arriving somewhere reaches here.
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
    const storage = this.state.storage;

    for (const [key, record] of await storage.list<PushRecord>({ prefix: pushPrefix })) {
      if (watching.has(key.slice(pushPrefix.length))) continue;
      const code = await apns.send(
        this.env,
        {
          token: record.deviceToken,
          payload: alertPayload(notify.class, notify.threadRef),
          pushType: "alert",
        },
        now,
      );
      // Apple no longer knows this token: the app was deleted or reinstalled. Keeping the
      // registration would only fail again on the next turn, so the device is forgotten.
      if (apns.gone(code)) {
        await storage.delete(key);
        continue;
      }

      // And, for news the phone is now behind on, a silent one behind the visible one: it
      // wakes the app for a few seconds so it can drain the sync over its own socket and
      // leave the thread cache true, rather than waiting for a tap.
      //
      // Rate limited because iOS is: an app woken more often than the budget allows is
      // simply woken less often afterwards, which would cost the wake-ups worth having. The
      // alert above has already gone out regardless.
      if (
        BACKGROUND_CLASSES.includes(notify.class) &&
        now - (record.backgroundAt ?? 0) >= BACKGROUND_INTERVAL_MS
      ) {
        const silent = await apns.send(
          this.env,
          {
            token: record.deviceToken,
            payload: backgroundPayload(),
            pushType: "background",
            // A background push is explicitly not urgent, and Apple rejects one that claims
            // to be: 5 is what "deliver when it suits you" is spelled as.
            priority: 5,
          },
          now,
        );
        if (apns.gone(silent)) {
          await storage.delete(key);
          continue;
        }
        await storage.put(key, { ...record, backgroundAt: now } satisfies PushRecord);
      }
    }
  }

  private async handle(ws: WebSocket, data: string | ArrayBuffer): Promise<void> {
    const raw = typeof data === "string" ? data : new TextDecoder().decode(data);
    const now = Date.now();
    const conn = ws.deserializeAttachment() as Conn;
    const storage = this.state.storage;

    // Only the envelope is parsed; `payload` is forwarded byte-for-byte.
    let msg: Record<string, unknown>;
    try {
      msg = JSON.parse(raw);
    } catch {
      return ws.close(CLOSE_PROTOCOL, "bad json");
    }

    switch (msg.type) {
      case "register": {
        const register = parseRegister(msg);
        if (!register) return ws.close(CLOSE_PROTOCOL, "bad register");
        const { pubkey, nonceSig } = register;
        let id: string;
        try {
          id = await roomId(pubkey);
        } catch {
          return ws.close(CLOSE_PROTOCOL, "bad pubkey");
        }
        // The Node relay derives the room from the key, so a key can only ever own its own
        // room. Here the caller picked the room in the URL: pin it back to the key, or a
        // stranger could squat someone else's room and drain its buffer.
        const owner = (await storage.get<string>("owner")) ?? null;
        if (id !== conn.room || (owner !== null && owner !== pubkey)) {
          return ws.close(CLOSE_PROTOCOL, "wrong room");
        }
        if (!(await this.verify(conn.nonce, nonceSig, pubkey))) {
          return ws.close(CLOSE_BAD_SIGNATURE, "bad challenge");
        }
        if (owner === null) await storage.put("owner", pubkey);
        // A fresh registration wins; the stale Mac socket is dropped.
        for (const stale of this.sockets("mac")) {
          if (stale !== ws) stale.close(CLOSE_PROTOCOL, "replaced");
        }
        ws.serializeAttachment({ ...conn, role: "mac", key: pubkey } satisfies Conn);
        ws.send(JSON.stringify({ type: "registered", roomId: id }));
        this.notifyOwner(true);
        return await this.drain(ws, now);
      }

      // The heartbeat the edge normally answers for us. Handled here too so a socket that
      // somehow reaches the object still gets a pong instead of a "unknown type" close, and so
      // the Node relay and this one behave identically.
      case "ping":
        return void ws.send(PONG);

      // "Is my Mac there?", asked by a phone after every join. The `joined` reply already
      // carries it, but a phone that has been asleep has no way to trust what it last heard.
      case "owner": {
        if (conn.role !== "phone") return ws.close(CLOSE_PROTOCOL, "not joined");
        return void ws.send(JSON.stringify({ type: "owner", online: this.ownerOnline() }));
      }

      case "mint": {
        if (conn.role !== "mac") return ws.close(CLOSE_PROTOCOL, "not registered");
        const token = randomToken();
        const expiresAt = now + TOKEN_TTL_MS;
        await storage.put(`t:${token}`, expiresAt);
        ws.send(JSON.stringify({ type: "token", token, expiresAt }));
        return;
      }

      // The Mac unpairing a phone: forgotten, so it cannot rejoin against the nonce, and
      // dropped now rather than at its next reconnect.
      case "revoke": {
        if (conn.role !== "mac") return ws.close(CLOSE_PROTOCOL, "not registered");
        const revoke = parseRevoke(msg);
        if (!revoke) return ws.close(CLOSE_PROTOCOL, "bad revoke");
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
        if (conn.role !== "mac") return ws.close(CLOSE_PROTOCOL, "not registered");
        const announced = parseDevices(msg);
        if (!announced) return ws.close(CLOSE_PROTOCOL, "bad devices");
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
        if (!join) return ws.close(CLOSE_PROTOCOL, "bad join");
        const { roomId: id, token, phonePubkey, sig } = join;
        if (id !== conn.room) return ws.close(CLOSE_PROTOCOL, "wrong room");
        if (token === undefined) {
          // A rejoin: the room already knows this device, so it proves itself against the
          // connect nonce rather than spending a token it no longer has.
          if ((await storage.get<number>(devicePrefix + phonePubkey)) === undefined) {
            return ws.close(CLOSE_PROTOCOL, "unknown device");
          }
          if (!(await this.verify(conn.nonce, sig, phonePubkey))) {
            return ws.close(CLOSE_BAD_SIGNATURE, "bad join signature");
          }
          await storage.put(devicePrefix + phonePubkey, now);
        } else {
          const expiresAt = await storage.get<number>(`t:${token}`);
          if (expiresAt === undefined) return ws.close(CLOSE_PROTOCOL, "unknown token");
          if (now > expiresAt) {
            await storage.delete(`t:${token}`);
            return ws.close(CLOSE_PROTOCOL, "expired token");
          }
          // Verified before burning, so a bad signature cannot consume the token.
          if (!(await this.verify(token, sig, phonePubkey))) {
            return ws.close(CLOSE_BAD_SIGNATURE, "bad join signature");
          }
          await storage.delete(`t:${token}`);
          await this.remember(phonePubkey, now);
        }
        ws.serializeAttachment({ ...conn, role: "phone", key: phonePubkey } satisfies Conn);
        ws.send(JSON.stringify({ type: "joined", roomId: id, ownerOnline: this.ownerOnline() }));
        return;
      }

      // A phone saying where it can be woken. Filed against the key the relay already knows
      // the device by, so revoking it takes the tokens with it and nothing has to remember to.
      case "push": {
        if (conn.role !== "phone" || !conn.key) return ws.close(CLOSE_PROTOCOL, "not joined");
        const push = parsePush(msg);
        if (!push) return ws.close(CLOSE_PROTOCOL, "bad push");
        const key = pushPrefix + conn.key;
        // Merged rather than written over: a phone re-registers its token on every launch, and
        // that must not hand it a fresh background budget it has already spent.
        const record = await storage.get<PushRecord>(key);
        await storage.put(key, {
          ...record,
          deviceToken: push.deviceToken,
        } satisfies PushRecord);
        return;
      }

      // The Mac, beside a sealed frame: something of this class happened over there. The frame
      // itself has already gone out; this is only the wake-up for whoever did not catch it.
      case "notify": {
        if (conn.role !== "mac") return ws.close(CLOSE_PROTOCOL, "not registered");
        const notify = parseNotify(msg);
        if (!notify) return ws.close(CLOSE_PROTOCOL, "bad notify");
        return await this.wake(notify, now);
      }

      case "frame": {
        if (!conn.role || !conn.key) return ws.close(CLOSE_PROTOCOL, "not joined");
        const frame = parseFrame(msg);
        if (!frame) return ws.close(CLOSE_BAD_SIGNATURE, "unsigned frame");
        if (!(await this.verify(frame.payload, frame.sig, conn.key))) {
          return ws.close(CLOSE_BAD_SIGNATURE, "bad frame signature");
        }
        if (!allowFrame(this.bucket, now)) return ws.close(CLOSE_RATE_LIMIT, "rate limit");

        if (conn.role === "phone") {
          const mac = this.mac();
          if (mac) send(mac, raw);
          else await this.buffer(raw, now);
        } else {
          for (const phone of this.sockets("phone")) send(phone, raw);
        }
        return;
      }

      default:
        return ws.close(CLOSE_PROTOCOL, "unknown type");
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

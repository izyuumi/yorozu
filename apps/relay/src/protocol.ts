/**
 * The parts of the relay protocol that are pure policy: limits, close codes, envelope
 * shapes, the rate-limit bucket and the offline-buffer trim rule.
 *
 * Both relays import this. Everything that differs between them — Node's synchronous
 * `node:crypto` against the Worker's async WebCrypto, an in-memory buffer against Durable
 * Object storage — stays in `index.ts` and `worker.ts` respectively; only the rules that
 * must stay byte-identical on the wire live here.
 */

export const TOKEN_TTL_MS = 10 * 60_000;
/**
 * How many phones a room remembers as known devices. A known device rejoins by answering the
 * nonce challenge instead of spending a fresh one-time token, so it survives a background,
 * a network change or an app relaunch. Past the cap the least recently paired one makes way.
 */
export const MAX_DEVICES = 16;
export const BUFFER_TTL_MS = 24 * 60 * 60_000;
export const BUFFER_CAP_BYTES = 5 * 1024 * 1024;
export const FRAMES_PER_SEC = 60;

/**
 * Application-level heartbeat. A socket that says nothing for minutes is dropped by whatever
 * sits between the two ends, and neither end is told, so each one has to ask.
 *
 * These are whole messages rather than websocket ping frames because the Worker relay answers
 * them with `state.setWebSocketAutoResponse`, which matches an exact message string: the edge
 * replies and the Durable Object stays hibernated, so a heartbeat costs no wall time. Both
 * relays also answer them in the handler, so the two behave identically on the wire.
 */
export const PING = JSON.stringify({ type: "ping" });
export const PONG = JSON.stringify({ type: "pong" });

/** Close codes. The relay closes rather than silently ignoring a bad frame. */
export const CLOSE_PROTOCOL = 4001;
export const CLOSE_BAD_SIGNATURE = 4003;
export const CLOSE_RATE_LIMIT = 4029;

/** Token bucket, per room: sustained FRAMES_PER_SEC with a one-second burst. */
export type Bucket = { tokens: number; refilledAt: number };

export function newBucket(now: number): Bucket {
  return { tokens: FRAMES_PER_SEC, refilledAt: now };
}

export function allowFrame(bucket: Bucket, now: number): boolean {
  const refill = ((now - bucket.refilledAt) / 1000) * FRAMES_PER_SEC;
  bucket.tokens = Math.min(FRAMES_PER_SEC, bucket.tokens + refill);
  bucket.refilledAt = now;
  if (bucket.tokens < 1) return false;
  bucket.tokens -= 1;
  return true;
}

/**
 * How many of the oldest buffered entries to drop so the buffer respects both the TTL and
 * the byte cap. TTLs are enforced lazily on access, so an idle relay holds no timers.
 */
export function dropCount(
  entries: readonly { bytes: number; at: number }[],
  now: number,
  cap = BUFFER_CAP_BYTES,
): number {
  let drop = 0;
  while (drop < entries.length && now - entries[drop]!.at > BUFFER_TTL_MS) drop++;
  let bytes = 0;
  for (let i = drop; i < entries.length; i++) bytes += entries[i]!.bytes;
  while (drop < entries.length && bytes > cap) bytes -= entries[drop++]!.bytes;
  return drop;
}

/**
 * Envelope shapes. Only the envelope is ever parsed; `payload` is forwarded byte-for-byte,
 * so the relay stays blind to what it carries. Each returns null on a malformed message,
 * which the caller turns into a close.
 */
export type Register = { pubkey: string; nonceSig: string };
/**
 * Two joins share one shape. With a `token` it is a first pairing and `sig` is over that
 * one-time token; without one it is a rejoin by a device the room already knows and `sig` is
 * over the connect nonce — the same challenge the Mac answers in `register`.
 */
export type Join = { roomId: string; phonePubkey: string; sig: string; token?: string };
export type Frame = { payload: string; sig: string };
/** The Mac dropping a paired device: it is forgotten, and its sockets are closed. */
export type Revoke = { pubkey: string };
/**
 * The Mac announcing every device it still considers paired. The relay replaces the room's
 * known-device set with this list, which makes `devices.json` on the Mac the source of truth:
 * a relay that lost its storage — a redeploy, an evicted object — heals on the next register
 * instead of stranding every phone behind a 4001 until it is paired again.
 */
export type Devices = { devices: string[] };

const strings = <K extends string>(
  msg: Record<string, unknown>,
  ...keys: K[]
): Record<K, string> | null =>
  keys.every((k) => typeof msg[k] === "string") ? (msg as Record<K, string>) : null;

export const parseRegister = (msg: Record<string, unknown>): Register | null =>
  strings(msg, "pubkey", "nonceSig");

export const parseJoin = (msg: Record<string, unknown>): Join | null => {
  const join = strings(msg, "roomId", "phonePubkey", "sig");
  if (!join) return null;
  if (msg.token === undefined) return join;
  return typeof msg.token === "string" ? { ...join, token: msg.token } : null;
};

export const parseFrame = (msg: Record<string, unknown>): Frame | null =>
  strings(msg, "payload", "sig");

export const parseRevoke = (msg: Record<string, unknown>): Revoke | null =>
  strings(msg, "pubkey");

/** Trimmed to the cap here, so neither relay has to remember to do it. */
export const parseDevices = (msg: Record<string, unknown>, cap = MAX_DEVICES): Devices | null =>
  Array.isArray(msg.devices) && msg.devices.every((key) => typeof key === "string")
    ? { devices: (msg.devices as string[]).slice(-cap) }
    : null;

/**
 * Which known devices a room must forget to keep `pubkey` under the cap, oldest first. A
 * device already known is re-recorded in place, so a rejoining phone evicts nobody.
 *
 * The cap is not the only thing that forgets one: the Mac revokes a device by name, which is
 * the `revoke` message.
 */
export function evictions(
  known: readonly [pubkey: string, at: number][],
  pubkey: string,
  cap = MAX_DEVICES,
): string[] {
  if (known.some(([key]) => key === pubkey)) return [];
  const surplus = known.length - cap + 1;
  if (surplus <= 0) return [];
  return [...known]
    .sort(([, a], [, b]) => a - b)
    .slice(0, surplus)
    .map(([key]) => key);
}

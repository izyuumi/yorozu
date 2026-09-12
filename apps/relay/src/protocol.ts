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
export const BUFFER_TTL_MS = 24 * 60 * 60_000;
export const BUFFER_CAP_BYTES = 5 * 1024 * 1024;
export const FRAMES_PER_SEC = 60;

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
export type Join = { roomId: string; token: string; phonePubkey: string; sig: string };
export type Frame = { payload: string; sig: string };

const strings = <K extends string>(
  msg: Record<string, unknown>,
  ...keys: K[]
): Record<K, string> | null =>
  keys.every((k) => typeof msg[k] === "string") ? (msg as Record<K, string>) : null;

export const parseRegister = (msg: Record<string, unknown>): Register | null =>
  strings(msg, "pubkey", "nonceSig");

export const parseJoin = (msg: Record<string, unknown>): Join | null =>
  strings(msg, "roomId", "token", "phonePubkey", "sig");

export const parseFrame = (msg: Record<string, unknown>): Frame | null =>
  strings(msg, "payload", "sig");

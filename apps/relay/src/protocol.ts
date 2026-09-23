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
export const MAX_PAYLOAD_BYTES = 1_048_576;
export const MAX_TOKENS_PER_ROOM = 8;
export const NOTIFY_PER_MINUTE = 60;

/** Invalid configuration must not silently remove a resource limit. */
export function positiveLimit(value: string | undefined, fallback: number): number {
  const limit = Number(value);
  return Number.isSafeInteger(limit) && limit > 0 ? limit : fallback;
}

export type NotifyWindow = { count: number; startedAt: number };

/** A room shares this budget across owner reconnects, so reconnecting cannot buy more pushes. */
export function allowNotify(window: NotifyWindow, now: number, limit = NOTIFY_PER_MINUTE): boolean {
  if (window.count === 0 || now - window.startedAt >= 60_000) {
    window.startedAt = now;
    window.count = 0;
  }
  if (window.count >= limit) return false;
  window.count++;
  return true;
}

/**
 * Application-level heartbeat. A socket that says nothing for minutes is dropped by whatever
 * sits between the two ends, and neither end is told, so each one has to ask.
 *
 * These are whole messages rather than websocket ping frames because the Worker relay answers
 * them with `state.setWebSocketAutoResponse`, which matches an exact message string: the edge
 * replies and the Durable Object stays hibernated, so a heartbeat costs no wall time. The Node
 * relay answers the exact string the same way, before the bucket, so the two match on the wire.
 */
export const PING = JSON.stringify({ type: "ping" });
export const PONG = JSON.stringify({ type: "pong" });

/** Close codes. The relay closes rather than silently ignoring a bad frame. */
export const CLOSE_PROTOCOL = 4001;
export const CLOSE_BAD_SIGNATURE = 4003;
export const CLOSE_RATE_LIMIT = 4029;
/** RFC 6455 policy violation: the socket broke a rule of the server, not of the protocol. */
export const CLOSE_POLICY = 1008;

/**
 * How long a socket may sit open without proving who it is. A `nonce` costs nothing to be
 * handed, so without this a stranger could hold sockets open forever at no cost to itself;
 * a real client answers the challenge in its first round trip.
 */
export const AUTH_TIMEOUT_MS = 10_000;

/**
 * What a room ID looks like on the wire: base64url of a 32-byte SHA-256, unpadded, so exactly
 * 43 characters. Checked before any room is touched, so a stranger cannot make the relay do
 * work for a name that no key could ever produce.
 */
export const ROOM_ID = /^[A-Za-z0-9_-]{43}$/;
export const isRoomId = (value: string): boolean => ROOM_ID.test(value);

/**
 * Token bucket, per socket: sustained FRAMES_PER_SEC messages with a one-second burst. Per socket
 * rather than per room so one phone flooding closes that phone and nobody else; a Mac's
 * fan-out to every paired phone travels as one `frames` batch and costs one token.
 */
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
 * the byte cap. Both relays also sweep idle buffers so expiry does not depend on new traffic.
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
/**
 * A frame batch: `{type:"frame", frames:[{payload,sig},...]}`, at most MAX_DEVICES entries.
 * The Mac seals one event once per paired phone; sent this way the copies cost one rate-limit
 * token instead of one each. Every entry is verified against the socket's key and forwarded
 * as a plain single `frame`, so the receiving end never sees the batch.
 */
export type Frames = { frames: Frame[] };
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

/** One frame or a batch of them; null when neither shape holds. */
export const parseFrames = (msg: Record<string, unknown>, cap = MAX_DEVICES): Frame[] | null => {
  if (msg.frames === undefined) {
    const frame = parseFrame(msg);
    return frame ? [frame] : null;
  }
  if (!Array.isArray(msg.frames) || msg.frames.length === 0 || msg.frames.length > cap) return null;
  const frames: Frame[] = [];
  for (const entry of msg.frames) {
    const frame = isEnvelope(entry) ? parseFrame(entry) : null;
    if (!frame) return null;
    frames.push({ payload: frame.payload, sig: frame.sig });
  }
  return frames;
};

/** What a single forwarded frame looks like on the wire, whether or not it arrived batched. */
export const frameWire = ({ payload, sig }: Frame): string =>
  JSON.stringify({ type: "frame", payload, sig });

/**
 * The envelope must be a JSON object: `null`, a number, a string or an array parse fine and
 * then have no `type`, and a relay that reads `msg.type` off `null` throws instead of closing.
 */
export const isEnvelope = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

export const parseEnvelope = (raw: string): Record<string, unknown> | null => {
  try {
    const value: unknown = JSON.parse(raw);
    return isEnvelope(value) ? value : null;
  } catch {
    return null;
  }
};

/**
 * A close reason is peer-controlled text headed for a log line: cut to 64 characters with
 * control characters stripped, so a peer cannot forge or split log entries.
 */
export const safeReason = (reason: string): string =>
  reason.replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 64);

/** How long an APNs request may take before it is given up as a failure. */
export const APNS_TIMEOUT_MS = 5_000;

export const parseRevoke = (msg: Record<string, unknown>): Revoke | null =>
  strings(msg, "pubkey");

/**
 * The Mac saying it has handled every replayed frame up to `seq`. Frames buffered while the
 * Mac was away are replayed with a `seq` on each and kept until acked: a send onto a socket
 * that is about to die is not a delivery. A Mac that never acks simply sees them again.
 */
export type Ack = { seq: number };

export const parseAck = (msg: Record<string, unknown>): Ack | null =>
  typeof msg.seq === "number" && Number.isInteger(msg.seq) && msg.seq >= 0
    ? { seq: msg.seq }
    : null;

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

/**
 * The wake-up side-channel: what the Mac tells the relay in the clear so it can push to a
 * phone whose socket is gone, and what a phone tells the relay so there is somewhere to push.
 *
 * These names are spelled out here rather than imported from `@yorozu/shared` on purpose. The
 * relay does not depend on the event model and must not learn it — it handles a class, an
 * opaque reference, and optional per-device ciphertext it cannot open.
 */
export const NOTIFY_CLASSES = ["reply", "approval", "done", "failed"] as const;
export type NotifyClass = (typeof NOTIFY_CLASSES)[number];

export const NOTIFY_TITLE = "Yorozu";

/**
 * Fixed fallback text. A notification extension may replace the reply phrase after opening a
 * per-device ciphertext, but the relay can neither read nor assemble that body.
 */
export const NOTIFY_BODY: Record<NotifyClass, string> = {
  reply: "Yorozu replied.",
  approval: "Yorozu needs your approval.",
  done: "Yorozu finished.",
  failed: "Yorozu stopped.",
};

/** A phone's APNs registration: the one token every alert for it is addressed to. */
export type Push = { deviceToken: string };
/**
 * The Mac, alongside a sealed frame: something of this class happened in this thread. The
 * thread is named by an opaque reference the phone can map and the relay cannot. Reply previews
 * are individually sealed for each signing key so the relay can select one without opening it.
 */
export type EncryptedPreview = { n: string; c: string };
export type Notify = {
  class: NotifyClass;
  threadRef: string;
  eventRef?: string;
  previews?: Record<string, EncryptedPreview>;
  /**
   * An approval the Mac has judged answerable from the lock screen: below every safety floor
   * and committing nothing external. The relay learns one bit and passes it on as the
   * notification category; what the action is stays in the sealed frame.
   */
  actions?: boolean;
};

/**
 * Notification categories the app registers. `approval-quick` carries Allow / Don't allow
 * buttons; `approval-review` carries only a button that opens the card.
 */
export const CATEGORY_APPROVAL_QUICK = "approval-quick";
export const CATEGORY_APPROVAL_REVIEW = "approval-review";

const base64url = /^[A-Za-z0-9_-]+$/;
const parsePreviews = (value: unknown): Record<string, EncryptedPreview> | null | undefined => {
  if (value === undefined) return undefined;
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const entries = Object.entries(value);
  if (entries.length > MAX_DEVICES) return null;
  const previews: Record<string, EncryptedPreview> = {};
  for (const [device, box] of entries) {
    if (device.length !== 43 || !base64url.test(device) || typeof box !== "object" || box === null) return null;
    const { n, c } = box as Record<string, unknown>;
    // 12-byte nonce; 16-byte tag plus at most 256 bytes of UTF-8 plaintext.
    if (typeof n !== "string" || n.length !== 16 || !base64url.test(n)) return null;
    if (typeof c !== "string" || c.length < 22 || c.length > 363 || !base64url.test(c)) return null;
    previews[device] = { n, c };
  }
  return previews;
};

export const parsePush = (msg: Record<string, unknown>): Push | null =>
  typeof msg.deviceToken === "string" && msg.deviceToken.length === 64 && /^[0-9a-f]{64}$/i.test(msg.deviceToken)
    ? { deviceToken: msg.deviceToken }
    : null;

export const parseNotify = (msg: Record<string, unknown>): Notify | null => {
  if (typeof msg.threadRef !== "string" || msg.threadRef === "") return null;
  if (!NOTIFY_CLASSES.includes(msg.class as NotifyClass)) return null;
  if (msg.eventRef !== undefined && (typeof msg.eventRef !== "string" || msg.eventRef === "")) return null;
  const previews = parsePreviews(msg.previews);
  if (previews === null) return null;
  if (msg.actions !== undefined && typeof msg.actions !== "boolean") return null;
  return {
    class: msg.class as NotifyClass,
    threadRef: msg.threadRef,
    ...(typeof msg.eventRef === "string" ? { eventRef: msg.eventRef } : {}),
    ...(previews ? { previews } : {}),
    // Only an approval has buttons to offer; the bit is meaningless on any other class.
    ...(msg.actions === true && msg.class === "approval" ? { actions: true } : {}),
  };
};

/**
 * The alert a phone is woken with. `ref` is what the tap routes on, resolved to a thread by the
 * phone. `preview`, when present, is an opaque box only that phone's extension can open.
 */
export function alertPayload(
  cls: NotifyClass,
  ref: string,
  eventRef?: string,
  preview?: EncryptedPreview,
  actions = false,
): unknown {
  return {
    aps: {
      // APNs resolves this against the app's String Catalog on the device. The relay still
      // learns only the fixed key, while fallback text follows the user's app language.
      alert: { title: NOTIFY_TITLE, "loc-key": NOTIFY_BODY[cls] },
      sound: "default",
      // Groups every notification about one thread together, without naming it.
      "thread-id": ref,
      ...(preview ? { "mutable-content": 1 } : {}),
      // Which buttons the phone draws under an approval. The category names are fixed
      // vocabulary, like the body keys.
      ...(cls === "approval"
        ? { category: actions ? CATEGORY_APPROVAL_QUICK : CATEGORY_APPROVAL_REVIEW }
        : {}),
    },
    ref,
    cls,
    ...(eventRef ? { event: eventRef } : {}),
    ...(preview ? { preview } : {}),
  };
}

/**
 * The classes that are worth waking the app for as well as the person: something landed in a
 * thread that this phone's cache is now behind on. An approval is one of them since 2026-09-18:
 * a card answered from the lock screen has to be in the cache before the button is pressed.
 */
export const BACKGROUND_CLASSES: readonly NotifyClass[] = ["reply", "approval", "done", "failed"];

/**
 * At most one silent push per phone per minute. iOS budgets background wake-ups and throttles an
 * app that is woken more often than it does anything useful with, so spending them at the rate a
 * chatty turn produces events would cost the wake-ups that matter. The alert is never held back
 * for this: a person is told every time, only the app is not.
 */
export const BACKGROUND_INTERVAL_MS = 60_000;

/**
 * The silent push that wakes the app to drain its sync. `content-available` and nothing else:
 * there is no reference and no class in here, because the app is not being told what happened —
 * it is being told to go and ask, over the socket, where the answer is sealed.
 */
export function backgroundPayload(): unknown {
  return { aps: { "content-available": 1 } };
}

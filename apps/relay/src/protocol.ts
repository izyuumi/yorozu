export const TOKEN_TTL_MS = 10 * 60_000;
export const MAX_DEVICES = 16;
export const BUFFER_TTL_MS = 24 * 60 * 60_000;
export const BUFFER_CAP_BYTES = 5 * 1024 * 1024;
export const FRAMES_PER_SEC = 60;
export const MAX_PAYLOAD_BYTES = 1_048_576;
export const PHONE_BUFFER_CAP_BYTES = 2 * MAX_PAYLOAD_BYTES;
export const MAX_TOKENS_PER_ROOM = 8;
export const NOTIFY_PER_MINUTE = 60;

export function positiveLimit(value: string | undefined, fallback: number): number {
  const limit = Number(value);
  return Number.isSafeInteger(limit) && limit > 0 ? limit : fallback;
}

export type NotifyWindow = { count: number; startedAt: number };

export function allowNotify(window: NotifyWindow, now: number, limit = NOTIFY_PER_MINUTE): boolean {
  if (window.count === 0 || now - window.startedAt >= 60_000) {
    window.startedAt = now;
    window.count = 0;
  }
  if (window.count >= limit) return false;
  window.count++;
  return true;
}

export const PING = JSON.stringify({ type: "ping" });
export const PONG = JSON.stringify({ type: "pong" });

export const CLOSE_PROTOCOL = 4001;
export const CLOSE_BAD_SIGNATURE = 4003;
export const CLOSE_RATE_LIMIT = 4029;
export const CLOSE_POLICY = 1008;

export const AUTH_TIMEOUT_MS = 10_000;

export const ROOM_ID = /^[A-Za-z0-9_-]{43}$/;
export const isRoomId = (value: string): boolean => ROOM_ID.test(value);

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

export type Register = { pubkey: string; nonceSig: string };
export type Join = { roomId: string; phonePubkey: string; sig: string; token?: string };
export type Frame = { payload: string; sig: string };
export type Frames = { frames: Frame[] };
export type Revoke = { pubkey: string };
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

export const frameWire = ({ payload, sig }: Frame): string =>
  JSON.stringify({ type: "frame", payload, sig });

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

export const safeReason = (reason: string): string =>
  reason.replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 64);

export const APNS_TIMEOUT_MS = 5_000;

export const parseRevoke = (msg: Record<string, unknown>): Revoke | null =>
  strings(msg, "pubkey");

export type Ack = { seq: number };

export const parseAck = (msg: Record<string, unknown>): Ack | null =>
  typeof msg.seq === "number" && Number.isInteger(msg.seq) && msg.seq >= 0
    ? { seq: msg.seq }
    : null;

export const parseDevices = (msg: Record<string, unknown>, cap = MAX_DEVICES): Devices | null =>
  Array.isArray(msg.devices) && msg.devices.every((key) => typeof key === "string")
    ? { devices: (msg.devices as string[]).slice(-cap) }
    : null;

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

export const NOTIFY_CLASSES = ["reply", "approval", "done", "failed"] as const;
export type NotifyClass = (typeof NOTIFY_CLASSES)[number];

export const NOTIFY_TITLE = "Yorozu";

export const SILENT_CLASS = "sync";
export type SilentClass = typeof SILENT_CLASS;

export const NOTIFY_BODY: Record<NotifyClass, string> = {
  reply: "Yorozu replied.",
  approval: "Yorozu needs your approval.",
  done: "Yorozu finished.",
  failed: "Yorozu needs attention.",
};

export type Push = { deviceToken: string };
export type EncryptedPreview = { n: string; c: string };
export type Notify = {
  class: NotifyClass | SilentClass;
  threadRef: string;
  eventRef?: string;
  previews?: Record<string, EncryptedPreview>;
  actions?: boolean;
  devices?: string[];
};

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
    if (typeof n !== "string" || n.length !== 16 || !base64url.test(n)) return null;
    if (typeof c !== "string" || c.length < 22 || c.length > 363 || !base64url.test(c)) return null;
    previews[device] = { n, c };
  }
  return previews;
};

const parseDeviceList = (value: unknown): string[] | null | undefined => {
  if (value === undefined) return undefined;
  if (!Array.isArray(value) || value.length > MAX_DEVICES) return null;
  return value.every((key) => typeof key === "string" && key.length === 43 && base64url.test(key)) ? value : null;
};

export const parsePush = (msg: Record<string, unknown>): Push | null =>
  typeof msg.deviceToken === "string" && msg.deviceToken.length > 0 && msg.deviceToken.length <= 1024 &&
    msg.deviceToken.length % 2 === 0 && !/[^0-9a-f]/i.test(msg.deviceToken)
    ? { deviceToken: msg.deviceToken }
    : null;

export const parseNotify = (msg: Record<string, unknown>): Notify | null => {
  if (typeof msg.threadRef !== "string" || msg.threadRef === "") return null;
  if (!NOTIFY_CLASSES.includes(msg.class as NotifyClass) && msg.class !== SILENT_CLASS) return null;
  if (msg.eventRef !== undefined && (typeof msg.eventRef !== "string" || msg.eventRef === "")) return null;
  const previews = parsePreviews(msg.previews);
  if (previews === null) return null;
  if (msg.actions !== undefined && typeof msg.actions !== "boolean") return null;
  const devices = parseDeviceList(msg.devices);
  if (devices === null) return null;
  return {
    class: msg.class as NotifyClass | SilentClass,
    threadRef: msg.threadRef,
    ...(typeof msg.eventRef === "string" ? { eventRef: msg.eventRef } : {}),
    ...(previews ? { previews } : {}),
    ...(devices ? { devices } : {}),
    ...(msg.actions === true && msg.class === "approval" ? { actions: true } : {}),
  };
};

export function alertPayload(
  cls: NotifyClass,
  ref: string,
  eventRef?: string,
  preview?: EncryptedPreview,
  actions = false,
): unknown {
  return {
    aps: {
      alert: { title: NOTIFY_TITLE, "loc-key": NOTIFY_BODY[cls] },
      sound: "default",
      "thread-id": ref,
      ...(preview ? { "mutable-content": 1 } : {}),
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

export type ActivityJob = {
  token: string;
  kind: (typeof ACTIVITY_KINDS)[number];
  state: (typeof ACTIVITY_STATES)[number];
  steps?: number;
  startedAt: number;
  finishedAt?: number;
};
export type ActivityState = { jobs: ActivityJob[] };
export type ActivityToken = { device: string; token?: string };
export type ActivityPush = {
  device: string;
  event: "update" | "end";
  state: ActivityState;
  priority: 5 | 10;
  staleDate?: number;
  dismissalDate?: number;
};

export const ACTIVITY_KINDS = ["turn", "recording", "transcribing", "needsYou"] as const;
export const ACTIVITY_STATES = ["running", "done", "failed"] as const;
export const MAX_ACTIVITY_JOBS = 8;
const MAX_STEPS = 100_000;
const JOB_TOKEN = /^[A-Za-z0-9_-]{16}$/;

const deviceKey = (value: unknown): value is string =>
  typeof value === "string" && value.length === 43 && base64url.test(value);
const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);
const epochSeconds = (value: unknown): value is number => Number.isSafeInteger(value) && (value as number) > 0;

function parseActivityJob(value: unknown): ActivityJob | null {
  if (!isEnvelope(value)) return null;
  const { token, kind, state, steps, startedAt, finishedAt } = value;
  if (typeof token !== "string" || !JOB_TOKEN.test(token)) return null;
  if (!ACTIVITY_KINDS.includes(kind as ActivityJob["kind"])) return null;
  if (!ACTIVITY_STATES.includes(state as ActivityJob["state"])) return null;
  if (steps !== undefined && !(Number.isSafeInteger(steps) && (steps as number) >= 0 && (steps as number) <= MAX_STEPS)) return null;
  if (!finite(startedAt) || (finishedAt !== undefined && !finite(finishedAt))) return null;
  return {
    token,
    kind: kind as ActivityJob["kind"],
    state: state as ActivityJob["state"],
    ...(steps !== undefined ? { steps: steps as number } : {}),
    startedAt,
    ...(finishedAt !== undefined ? { finishedAt: finishedAt as number } : {}),
  };
}

/** The Live Activity's content state, rebuilt from known fields only: opaque tokens, kinds, states, counts, times. */
export function parseActivityState(value: unknown): ActivityState | null {
  if (!isEnvelope(value) || !Array.isArray(value.jobs) || value.jobs.length > MAX_ACTIVITY_JOBS) return null;
  const jobs: ActivityJob[] = [];
  for (const entry of value.jobs) {
    const job = parseActivityJob(entry);
    if (!job) return null;
    jobs.push(job);
  }
  return { jobs };
}

export const parseActivityToken = (msg: Record<string, unknown>): ActivityToken | null => {
  const device = msg.device;
  if (!deviceKey(device)) return null;
  if (msg.token === undefined) return { device };
  const token = parsePush({ deviceToken: msg.token });
  return token ? { device, token: token.deviceToken } : null;
};

export const parseActivityPush = (msg: Record<string, unknown>): ActivityPush | null => {
  if (!deviceKey(msg.device) || (msg.event !== "update" && msg.event !== "end")) return null;
  if (msg.priority !== 5 && msg.priority !== 10) return null;
  if (msg.staleDate !== undefined && !epochSeconds(msg.staleDate)) return null;
  if (msg.dismissalDate !== undefined && !epochSeconds(msg.dismissalDate)) return null;
  const state = parseActivityState(msg.state);
  if (!state) return null;
  return {
    device: msg.device as string,
    event: msg.event as ActivityPush["event"],
    state,
    priority: msg.priority as ActivityPush["priority"],
    ...(msg.staleDate !== undefined ? { staleDate: msg.staleDate as number } : {}),
    ...(msg.dismissalDate !== undefined ? { dismissalDate: msg.dismissalDate as number } : {}),
  };
};

/** No alert: the activity changes silently, its own view is the notice. */
export function activityPayload(push: ActivityPush, now: number): unknown {
  return {
    aps: {
      timestamp: Math.floor(now / 1000),
      event: push.event,
      "content-state": push.state,
      ...(push.staleDate !== undefined ? { "stale-date": push.staleDate } : {}),
      ...(push.dismissalDate !== undefined ? { "dismissal-date": push.dismissalDate } : {}),
    },
  };
}

export const BACKGROUND_CLASSES: readonly NotifyClass[] = ["reply", "approval", "done", "failed"];

export const BACKGROUND_INTERVAL_MS = 60_000;

export function backgroundPayload(): unknown {
  return { aps: { "content-available": 1 } };
}

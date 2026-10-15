/**
 * The plaintext of every v3 transport box: `{"kind": …, "data": {…}}` (docs/ios-relay-contract.md, "Envelope").
 * Mirrors packages/YorozuWire/Sources/YorozuWire/V3Event.swift. An unknown kind, or a known kind whose data
 * does not parse, comes back as `unknown` and is ignored, so later kinds never break an older peer.
 */

export const PROTOCOL_VERSION = 3;

export type PeerInfo = {
  protocolMin: number;
  protocolMax: number;
  /** The sender's app or plugin version, diagnostic only. */
  app: string;
  /** Client: the device model. Host: the Mac's name. */
  name?: string;
  /** Optional features this side speaks; a later kind is sent only to a peer that lists its capability. */
  capabilities: string[];
};
export type Message = { convId: string; messageId: string; text: string };
export type MessageRef = { convId: string; messageId: string };
export type Typing = { convId: string; active: boolean };
export type Reply = { convId: string; messageId: string; text: string; ts: number };
export type ErrorInfo = { code: string; message: string; convId?: string; messageId?: string };
/** One tool call of the run answering `messageId`, for a collapsed row; `callId` groups its updates. */
export type Tool = { convId: string; messageId: string; callId: string; name: string; status: ToolStatus };
export type ToolStatus = "running" | "done" | "failed";
/**
 * A conversation's read state, one per conversation, the same on every device: replies up to and including the one
 * at `ts` (plugin clock, the reply's own `ts`; `messageId` is that reply) are read, later ones unread. `unread` is
 * Mark as Unread: the conversation counts as unread whatever the cursor says, until a read clears it.
 */
export type ReadCursor = { convId: string; messageId: string; ts: number; unread: boolean };

export type Event =
  | { kind: "peer_info"; data: PeerInfo }
  | { kind: "message"; data: Message }
  | { kind: "delivered"; data: MessageRef }
  | { kind: "run_started"; data: MessageRef }
  | { kind: "typing"; data: Typing }
  | { kind: "reply"; data: Reply }
  | { kind: "error"; data: ErrorInfo }
  | { kind: "tool"; data: Tool }
  | { kind: "read_cursor"; data: ReadCursor };

export type Received = Event | { kind: "unknown"; name: string };

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
/** Lowercase UUID, the only spelling of a `convId` or `messageId`: OpenClaw lowercases session keys. */
export const isId = (value: unknown): value is string => typeof value === "string" && ID.test(value);

/** The highest protocol both ranges hold, or null: the peers cannot talk (`update_required`). */
export function negotiate(mine: PeerInfo, theirs: PeerInfo): number | null {
  const version = Math.min(mine.protocolMax, theirs.protocolMax);
  return version >= Math.max(mine.protocolMin, theirs.protocolMin) ? version : null;
}

export const encodeEvent = (event: Event): Buffer => Buffer.from(JSON.stringify(event), "utf8");

type Fields = Record<string, unknown>;
const str = (v: unknown): v is string => typeof v === "string";
const optStr = (v: unknown): boolean => v === undefined || typeof v === "string";
const int = (v: unknown): v is number => Number.isSafeInteger(v);
const ref = (d: Fields): boolean => isId(d.convId) && isId(d.messageId);

const valid: Record<Event["kind"], (d: Fields) => boolean> = {
  peer_info: (d) =>
    int(d.protocolMin) &&
    int(d.protocolMax) &&
    str(d.app) &&
    optStr(d.name) &&
    Array.isArray(d.capabilities) &&
    d.capabilities.every(str),
  message: (d) => ref(d) && str(d.text),
  delivered: ref,
  run_started: ref,
  typing: (d) => isId(d.convId) && typeof d.active === "boolean",
  reply: (d) => ref(d) && str(d.text) && int(d.ts),
  error: (d) => str(d.code) && str(d.message) && optStr(d.convId) && optStr(d.messageId),
  tool: (d) =>
    ref(d) && str(d.callId) && str(d.name) && (d.status === "running" || d.status === "done" || d.status === "failed"),
  read_cursor: (d) => ref(d) && int(d.ts) && typeof d.unread === "boolean",
};

/** Null only for bytes that are not an envelope at all; extra fields are kept and ignored. */
export function parseEvent(bytes: Uint8Array): Received | null {
  let value: unknown;
  try {
    value = JSON.parse(Buffer.from(bytes).toString("utf8"));
  } catch {
    return null;
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
  const { kind, data } = value as Fields;
  if (!str(kind)) return null;
  const check = Object.hasOwn(valid, kind) ? valid[kind as Event["kind"]] : undefined;
  if (check && typeof data === "object" && data !== null && !Array.isArray(data) && check(data as Fields)) {
    return { kind, data } as Event;
  }
  return { kind: "unknown", name: kind };
}

import { validReport, type ActivityReport } from "./liveactivity.js";

export const PROTOCOL_VERSION = 3;

export type PeerInfo = {
  protocolMin: number;
  protocolMax: number;
  app: string;
  name?: string;
  capabilities: string[];
  mediaMaxBytes?: number;
  agent?: string;
  hostVersion?: string;
};
export const ATTACHMENTS = "attachments";
export const DEVICES = "devices";
export const INVITE = "invite";
export const REPLIES = "replies";
export const REACTIONS = "reactions";
/** Counts-only Live Activity pushes through the relay; listed only while the relay can send them. */
export const LIVE_ACTIVITY_PUSH = "liveActivityPush";
export const RESUME = "resume";
/** Introduced by #532; listed by the plugin only once its direct listener exists (#532 step 3). */
export const DIRECT = "direct";
export const CHUNK_BYTES = 160 * 1024;
export type Attachment = { id: string; name: string; mime: string; size: number };
// Capability `replies`.
export type ReplyTo = { messageId: string; text?: string };
export type Message = { convId: string; messageId: string; text: string; attachments?: Attachment[]; replyTo?: ReplyTo };
// Capability `reactions`: one emoji per person per message; `by` is set by the plugin.
export type Reaction = { convId: string; messageId: string; emoji: string; remove?: boolean; by?: "user" | "agent" };
export type Reactions = { user?: string; agent?: string };
export type MessageRef = { convId: string; messageId: string };
export type Typing = { convId: string; active: boolean };
export type Reply = { convId: string; messageId: string; text: string; ts: number; attachments?: Attachment[]; replyTo?: ReplyTo };
export type ErrorInfo = { code: string; message: string; convId?: string; messageId?: string; attachmentId?: string };
export type Upload = {
  attachmentId: string;
  name: string;
  mime: string;
  size: number;
  index: number;
  count: number;
  data: string;
  sha256?: string;
};
// Capability `resume`: the chunks the plugin already holds, as sorted half-open index ranges.
export type UploadStatus = { attachmentId: string; size: number; count: number; sha256: string };
export type UploadState = { attachmentId: string; done: boolean; have: [number, number][] };
export type UploadAck = { attachmentId: string; index: number; done: boolean };
export type Download = { attachmentId: string; index: number };
export type Chunk = { attachmentId: string; index: number; count: number; data: string };
export type Tool = { convId: string; messageId: string; callId: string; name: string; status: ToolStatus };
export type ToolStatus = "running" | "done" | "failed";
export type ConvList = { conversations: ConvSummary[] };
export type ConvSummary = { convId: string; updatedAt: number; rev: number; title?: string; archived?: true; pinnedAt?: number };
export type ConvPatch = { convId: string; title?: string; archived?: boolean; pinned?: boolean; deleted?: boolean };
export type ConvUpdate = { convId: string; title?: string; archived?: true; pinnedAt?: number; deleted?: true };
export type HistoryRequest = { convId: string; before?: number; after?: number };
export type History = HistoryRequest & { items: HistoryItem[]; more: boolean; rev: number };
export type HistoryTool = { callId: string; name: string; status: ToolStatus };
export type HistoryItem =
  | { kind: "user" | "agent"; id: string; seq: number; ts: number; text: string; attachments?: Attachment[]; replyTo?: ReplyTo; reactions?: Reactions }
  | { kind: "tools"; id: string; seq: number; ts: number; tools: HistoryTool[] }
  | { kind: "reset"; id: string; seq: number; ts: number };
export type ReadCursor = { convId: string; messageId: string; ts: number; unread: boolean };
export type Foreground = { convId?: string | null; active?: boolean };
export type DeviceInfo = { id: string; name?: string; pairedAt: number; push: boolean; current: boolean };
export type DeviceList = { devices?: DeviceInfo[]; error?: string };
export type DevicePatch = { id: string; push?: boolean; removed?: boolean };
export type PairInvite = { link?: string; webLink?: string; fingerprint?: string; expiresAt?: number; error?: string };
export type CronJob = {
  id: string;
  name: string;
  enabled: boolean;
  schedule: Record<string, unknown>;
  scheduleText: string;
  nextRunAt?: number;
  lastRunAt?: number;
  lastStatus?: "ok" | "error" | "skipped";
  lastError?: string;
  delivery?: { channel: "yorozu"; threadId: string };
};
export type CronList = { jobs?: CronJob[]; error?: string };

export type Event =
  | { kind: "peer_info"; data: PeerInfo }
  | { kind: "message"; data: Message }
  | { kind: "delivered"; data: MessageRef }
  | { kind: "run_started"; data: MessageRef }
  | { kind: "typing"; data: Typing }
  | { kind: "reply"; data: Reply }
  | { kind: "reaction"; data: Reaction }
  | { kind: "error"; data: ErrorInfo }
  | { kind: "tool"; data: Tool }
  | { kind: "conv_list"; data: Partial<ConvList> }
  | { kind: "history"; data: HistoryRequest | History }
  | { kind: "read_cursor"; data: ReadCursor }
  | { kind: "foreground"; data: Foreground }
  | { kind: "cron_list"; data: CronList }
  | { kind: "device_list"; data: DeviceList }
  | { kind: "device_patch"; data: DevicePatch }
  | { kind: "pair_invite"; data: PairInvite }
  | { kind: "conv_patch"; data: ConvPatch }
  | { kind: "conv_update"; data: ConvUpdate }
  | { kind: "upload"; data: Upload }
  | { kind: "upload_ack"; data: UploadAck }
  | { kind: "upload_status"; data: UploadStatus }
  | { kind: "upload_state"; data: UploadState }
  | { kind: "download"; data: Download }
  | { kind: "chunk"; data: Chunk }
  | { kind: "live_activity"; data: ActivityReport };

export type Invalid = { kind: "invalid"; name: string; convId?: string; messageId?: string; attachmentId?: string };
export type Received = Event | Invalid | { kind: "unknown"; name: string };

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export const isId = (value: unknown): value is string => typeof value === "string" && ID.test(value);

export function negotiate(mine: PeerInfo, theirs: PeerInfo): number | null {
  const version = Math.min(mine.protocolMax, theirs.protocolMax);
  return version >= Math.max(mine.protocolMin, theirs.protocolMin) ? version : null;
}

export const encodeEvent = (event: Event): Buffer => Buffer.from(JSON.stringify(event), "utf8");

type Fields = Record<string, unknown>;
const str = (v: unknown): v is string => typeof v === "string";
const optStr = (v: unknown): boolean => v === undefined || typeof v === "string";
const optBool = (v: unknown): boolean => v === undefined || typeof v === "boolean";
const int = (v: unknown): v is number => Number.isSafeInteger(v);
const optInt = (v: unknown): boolean => v === undefined || int(v);
const ref = (d: Fields): boolean => isId(d.convId) && isId(d.messageId);
const nat = (v: unknown): v is number => int(v) && v >= 0;
const sha256 = (v: unknown): boolean => str(v) && /^[0-9a-f]{64}$/.test(v);
const label = (v: unknown, max: number): boolean => str(v) && v.length > 0 && v.length <= max;
const attachment = (a: unknown): boolean => {
  if (typeof a !== "object" || a === null) return false;
  const d = a as Fields;
  return isId(d.id) && label(d.name, 255) && label(d.mime, 255) && nat(d.size);
};
const attachments = (v: unknown): boolean => v === undefined || (Array.isArray(v) && v.length <= 32 && v.every(attachment));
const part = (d: Fields): boolean => isId(d.attachmentId) && nat(d.index);
const replyTo = (v: unknown): boolean =>
  v === undefined || (typeof v === "object" && v !== null && isId((v as Fields).messageId) && optStr((v as Fields).text));

const valid: Record<Event["kind"], (d: Fields) => boolean> = {
  peer_info: (d) =>
    int(d.protocolMin) &&
    int(d.protocolMax) &&
    str(d.app) &&
    optStr(d.name) &&
    Array.isArray(d.capabilities) &&
    d.capabilities.every(str) &&
    (d.mediaMaxBytes === undefined || nat(d.mediaMaxBytes)),
  message: (d) => ref(d) && str(d.text) && attachments(d.attachments) && replyTo(d.replyTo),
  delivered: ref,
  run_started: ref,
  typing: (d) => isId(d.convId) && typeof d.active === "boolean",
  reply: (d) => ref(d) && str(d.text) && int(d.ts) && attachments(d.attachments) && replyTo(d.replyTo),
  reaction: (d) =>
    // `by` from a device is ignored (the plugin sets it), so any string passes.
    ref(d) && label(d.emoji, 32) && optBool(d.remove) && optStr(d.by),
  error: (d) => str(d.code) && str(d.message) && optStr(d.convId) && optStr(d.messageId) && optStr(d.attachmentId),
  tool: (d) =>
    ref(d) && str(d.callId) && str(d.name) && str(d.status),
  conv_list: (d) => d.conversations === undefined || Array.isArray(d.conversations),
  history: (d) => isId(d.convId) && optInt(d.before) && optInt(d.after) && (d.items === undefined || Array.isArray(d.items)),
  read_cursor: (d) => ref(d) && int(d.ts) && typeof d.unread === "boolean",
  foreground: (d) =>
    (d.convId === undefined || d.convId === null || isId(d.convId)) && (d.active === undefined || typeof d.active === "boolean"),
  cron_list: (d) => (d.jobs === undefined || Array.isArray(d.jobs)) && optStr(d.error),
  device_list: (d) => (d.devices === undefined || Array.isArray(d.devices)) && optStr(d.error),
  pair_invite: (d) => optStr(d.link) && optStr(d.webLink) && optStr(d.fingerprint) && optInt(d.expiresAt) && optStr(d.error),
  device_patch: (d) =>
    label(d.id, 64) && optBool(d.push) && optBool(d.removed),
  upload: (d) =>
    part(d) && label(d.name, 255) && label(d.mime, 255) && nat(d.size) && int(d.count) && d.count >= 1 &&
    (d.index as number) < d.count && str(d.data) && (d.sha256 === undefined || sha256(d.sha256)),
  upload_ack: (d) => part(d) && typeof d.done === "boolean",
  upload_status: (d) => isId(d.attachmentId) && nat(d.size) && int(d.count) && d.count >= 1 && sha256(d.sha256),
  upload_state: (d) =>
    isId(d.attachmentId) &&
    typeof d.done === "boolean" &&
    Array.isArray(d.have) &&
    d.have.every((r) => Array.isArray(r) && r.length === 2 && r.every(nat)),
  download: part,
  chunk: (d) => part(d) && int(d.count) && d.count >= 1 && (d.index as number) < d.count && str(d.data),
  conv_patch: (d) =>
    isId(d.convId) &&
    optStr(d.title) &&
    (d.archived === undefined || typeof d.archived === "boolean") &&
    (d.pinned === undefined || typeof d.pinned === "boolean") &&
    optBool(d.deleted),
  conv_update: (d) => isId(d.convId),
  live_activity: validReport,
};

export const LIMITS = "at most 32 attachments; names and types of 1 to 255 characters; device ids up to 64 characters; emoji up to 32";

export function rejection(received: Invalid | { kind: "unknown"; name: string } | null): ErrorInfo {
  if (!received) return { code: "bad_request", message: "the host could not read this event" };
  if (received.kind === "unknown") return { code: "unsupported", message: `this host does not handle "${received.name}"` };
  const { kind: _kind, name, ...ids } = received;
  return { code: "bad_request", message: `"${name}" was refused: it breaks the protocol's limits (${LIMITS})`, ...ids };
}

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
  const fields = typeof data === "object" && data !== null && !Array.isArray(data) ? (data as Fields) : undefined;
  if (!check) return { kind: "unknown", name: kind };
  if (fields && check(fields)) return { kind, data } as Event;
  const { convId, messageId, attachmentId } = fields ?? {};
  const invalid: Invalid = { kind: "invalid", name: kind };
  if (isId(convId)) invalid.convId = convId;
  if (isId(messageId)) invalid.messageId = messageId;
  if (isId(attachmentId)) invalid.attachmentId = attachmentId;
  return invalid;
}

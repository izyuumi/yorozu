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
  /** Plugin: the largest attachment it takes or sends, in bytes (`mediaMaxMb`). */
  mediaMaxBytes?: number;
  /** Plugin: the agent that answers (`channels.yorozu.agent`), for the client's Settings. */
  agent?: string;
  /** Plugin: the OpenClaw version it runs in, for the client's Settings. */
  hostVersion?: string;
};
/** Peers that list this in `capabilities` speak the attachment kinds and fields (#430). */
export const ATTACHMENTS = "attachments";
/** Peers that list this speak `device_list` and `device_patch`, and the `active` flag of `foreground`. */
export const DEVICES = "devices";
/** Raw bytes per `upload` or `chunk`: a sealed box of one stays far under the relay's 1 MiB frame. */
export const CHUNK_BYTES = 160 * 1024;
/** A file in a `message` or `reply`; `id` (a lowercase UUID, made by the side that has the bytes) names its transfer. */
export type Attachment = { id: string; name: string; mime: string; size: number };
export type Message = { convId: string; messageId: string; text: string; attachments?: Attachment[] };
export type MessageRef = { convId: string; messageId: string };
export type Typing = { convId: string; active: boolean };
export type Reply = { convId: string; messageId: string; text: string; ts: number; attachments?: Attachment[] };
export type ErrorInfo = { code: string; message: string; convId?: string; messageId?: string; attachmentId?: string };
/** Client -> plugin: chunk `index` of `count` of a file the client sends; `data` is base64. */
export type Upload = {
  attachmentId: string;
  name: string;
  mime: string;
  size: number;
  index: number;
  count: number;
  data: string;
};
/** Plugin -> the uploading client: chunk `index` arrived; `done` once the whole file is stored. */
export type UploadAck = { attachmentId: string; index: number; done: boolean };
/** Client -> plugin: send chunk `index` of an attachment. */
export type Download = { attachmentId: string; index: number };
/** Plugin -> the requesting client: chunk `index` of `count`; `data` is base64. */
export type Chunk = { attachmentId: string; index: number; count: number; data: string };
/** One tool call of the run answering `messageId`, for a collapsed row; `callId` groups its updates. */
export type Tool = { convId: string; messageId: string; callId: string; name: string; status: ToolStatus };
export type ToolStatus = "running" | "done" | "failed";
/** `conv_list`, plugin -> the asking device: the owner's Yorozu conversations, newest first. Asked with `{}`. */
export type ConvList = { conversations: ConvSummary[] };
/**
 * `rev`: the transcript's newest event seq; a client holding it has the conversation's whole history so far.
 * `title`: the manual rename, else the generated title (#428); absent before either. `archived`: only when true.
 */
export type ConvSummary = { convId: string; updatedAt: number; rev: number; title?: string; archived?: true };
/**
 * `conv_patch`, device -> plugin (#428): rename (`title`, "" clears the rename), archive or unarchive, or delete.
 * Answered by the `conv_update` every device gets, or `error` to the sender.
 */
export type ConvPatch = { convId: string; title?: string; archived?: boolean; deleted?: true };
/** `conv_update`, plugin -> every device: a conversation's title and archive state now, or that it is gone. */
export type ConvUpdate = { convId: string; title?: string; archived?: true; deleted?: true };
/** `history`, device -> plugin: one page of a conversation. `before`/`after` are item seqs; neither: the newest. */
export type HistoryRequest = { convId: string; before?: number; after?: number };
/** `history`, plugin -> the asking device: the request's fields again, then the page, oldest first. */
export type History = HistoryRequest & { items: HistoryItem[]; more: boolean; rev: number };
export type HistoryTool = { callId: string; name: string; status: ToolStatus };
/** One transcript item; items of one transcript event share its `seq`. */
export type HistoryItem =
  | { kind: "user" | "agent"; id: string; seq: number; ts: number; text: string; attachments?: Attachment[] }
  | { kind: "tools"; id: string; seq: number; ts: number; tools: HistoryTool[] }
  | { kind: "reset"; id: string; seq: number; ts: number };
/**
 * A conversation's read state, one per conversation, the same on every device: replies up to and including the one
 * at `ts` (plugin clock, the reply's own `ts`; `messageId` is that reply) are read, later ones unread. `unread` is
 * Mark as Unread: the conversation counts as unread whatever the cursor says, until a read clears it.
 */
export type ReadCursor = { convId: string; messageId: string; ts: number; unread: boolean };
/**
 * The conversation on this device's screen while the app is in the foreground, or none (#431): no push for it there.
 * `active`: the app is in the foreground at all, so no push of any conversation goes to this device; it shows its own
 * in-app notice instead. Absent from a client without `devices`.
 */
export type Foreground = { convId?: string | null; active?: boolean };
/** One paired device, for Settings. `id` is its Ed25519 relay key; `current`: the device asking. */
export type DeviceInfo = { id: string; name?: string; pairedAt: number; push: boolean; current: boolean };
/** Client -> plugin: `{}`, a request. Plugin -> that client: `devices`, or `error`. */
export type DeviceList = { devices?: DeviceInfo[]; error?: string };
/** Client -> plugin: turn a device's push on or off, or remove it. Answered with `device_list` to the sender. */
export type DevicePatch = { id: string; push?: boolean; removed?: true };
/** One cron job of the configured agent, for the Crons tab (#432). Times are epoch ms. */
export type CronJob = {
  id: string;
  name: string;
  enabled: boolean;
  /** OpenClaw's schedule object as stored (`kind` plus its fields), for a client that words it itself. */
  schedule: Record<string, unknown>;
  /** The plugin's English wording of `schedule` ("Daily at 09:00 (Asia/Tokyo)"). */
  scheduleText: string;
  nextRunAt?: number;
  lastRunAt?: number;
  lastStatus?: "ok" | "error" | "skipped";
  lastError?: string;
  /** Only when the job delivers into a Yorozu conversation: `threadId` is its `convId`. */
  delivery?: { channel: "yorozu"; threadId: string };
};
/** Client -> plugin: `{}`, a request. Plugin -> that client: `jobs`, or `error` when the store cannot be read. */
export type CronList = { jobs?: CronJob[]; error?: string };

export type Event =
  | { kind: "peer_info"; data: PeerInfo }
  | { kind: "message"; data: Message }
  | { kind: "delivered"; data: MessageRef }
  | { kind: "run_started"; data: MessageRef }
  | { kind: "typing"; data: Typing }
  | { kind: "reply"; data: Reply }
  | { kind: "error"; data: ErrorInfo }
  | { kind: "tool"; data: Tool }
  | { kind: "conv_list"; data: Partial<ConvList> }
  | { kind: "history"; data: HistoryRequest | History }
  | { kind: "read_cursor"; data: ReadCursor }
  | { kind: "foreground"; data: Foreground }
  | { kind: "cron_list"; data: CronList }
  | { kind: "device_list"; data: DeviceList }
  | { kind: "device_patch"; data: DevicePatch }
  | { kind: "conv_patch"; data: ConvPatch }
  | { kind: "conv_update"; data: ConvUpdate }
  | { kind: "upload"; data: Upload }
  | { kind: "upload_ack"; data: UploadAck }
  | { kind: "download"; data: Download }
  | { kind: "chunk"; data: Chunk };

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
const optInt = (v: unknown): boolean => v === undefined || int(v);
const ref = (d: Fields): boolean => isId(d.convId) && isId(d.messageId);
const nat = (v: unknown): v is number => int(v) && v >= 0;
const label = (v: unknown, max: number): boolean => str(v) && v.length > 0 && v.length <= max;
const attachment = (a: unknown): boolean => {
  if (typeof a !== "object" || a === null) return false;
  const d = a as Fields;
  return isId(d.id) && label(d.name, 255) && label(d.mime, 255) && nat(d.size);
};
const attachments = (v: unknown): boolean => v === undefined || (Array.isArray(v) && v.length <= 32 && v.every(attachment));
const part = (d: Fields): boolean => isId(d.attachmentId) && nat(d.index);

const valid: Record<Event["kind"], (d: Fields) => boolean> = {
  peer_info: (d) =>
    int(d.protocolMin) &&
    int(d.protocolMax) &&
    str(d.app) &&
    optStr(d.name) &&
    Array.isArray(d.capabilities) &&
    d.capabilities.every(str) &&
    (d.mediaMaxBytes === undefined || nat(d.mediaMaxBytes)),
  message: (d) => ref(d) && str(d.text) && attachments(d.attachments),
  delivered: ref,
  run_started: ref,
  typing: (d) => isId(d.convId) && typeof d.active === "boolean",
  reply: (d) => ref(d) && str(d.text) && int(d.ts) && attachments(d.attachments),
  error: (d) => str(d.code) && str(d.message) && optStr(d.convId) && optStr(d.messageId) && optStr(d.attachmentId),
  tool: (d) =>
    ref(d) && str(d.callId) && str(d.name) && (d.status === "running" || d.status === "done" || d.status === "failed"),
  // The plugin reads only the requests; the pages it sends are checked by the client (V3Event.swift).
  conv_list: (d) => d.conversations === undefined || Array.isArray(d.conversations),
  history: (d) => isId(d.convId) && optInt(d.before) && optInt(d.after) && (d.items === undefined || Array.isArray(d.items)),
  read_cursor: (d) => ref(d) && int(d.ts) && typeof d.unread === "boolean",
  foreground: (d) =>
    (d.convId === undefined || d.convId === null || isId(d.convId)) && (d.active === undefined || typeof d.active === "boolean"),
  cron_list: (d) => (d.jobs === undefined || Array.isArray(d.jobs)) && optStr(d.error),
  device_list: (d) => (d.devices === undefined || Array.isArray(d.devices)) && optStr(d.error),
  device_patch: (d) =>
    label(d.id, 64) && (d.push === undefined || typeof d.push === "boolean") && (d.removed === undefined || d.removed === true),
  upload: (d) =>
    part(d) && label(d.name, 255) && label(d.mime, 255) && nat(d.size) && int(d.count) && d.count >= 1 &&
    (d.index as number) < d.count && str(d.data),
  upload_ack: (d) => part(d) && typeof d.done === "boolean",
  download: part,
  chunk: (d) => part(d) && int(d.count) && d.count >= 1 && (d.index as number) < d.count && str(d.data),
  conv_patch: (d) =>
    isId(d.convId) &&
    optStr(d.title) &&
    (d.archived === undefined || typeof d.archived === "boolean") &&
    (d.deleted === undefined || d.deleted === true),
  // Sent only by the plugin.
  conv_update: (d) => isId(d.convId),
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

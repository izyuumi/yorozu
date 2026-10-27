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
export const CHUNK_BYTES = 160 * 1024;
export type Attachment = { id: string; name: string; mime: string; size: number };
export type Message = { convId: string; messageId: string; text: string; attachments?: Attachment[] };
export type MessageRef = { convId: string; messageId: string };
export type Typing = { convId: string; active: boolean };
export type Reply = { convId: string; messageId: string; text: string; ts: number; attachments?: Attachment[] };
export type ErrorInfo = { code: string; message: string; convId?: string; messageId?: string; attachmentId?: string };
export type Upload = {
  attachmentId: string;
  name: string;
  mime: string;
  size: number;
  index: number;
  count: number;
  data: string;
};
export type UploadAck = { attachmentId: string; index: number; done: boolean };
export type Download = { attachmentId: string; index: number };
export type Chunk = { attachmentId: string; index: number; count: number; data: string };
export type Tool = { convId: string; messageId: string; callId: string; name: string; status: ToolStatus };
export type ToolStatus = "running" | "done" | "failed";
export type ConvList = { conversations: ConvSummary[] };
export type ConvSummary = { convId: string; updatedAt: number; rev: number; title?: string; archived?: true; pinnedAt?: number };
export type ConvPatch = { convId: string; title?: string; archived?: boolean; pinned?: boolean; deleted?: true };
export type ConvUpdate = { convId: string; title?: string; archived?: true; pinnedAt?: number; deleted?: true };
export type HistoryRequest = { convId: string; before?: number; after?: number };
export type History = HistoryRequest & { items: HistoryItem[]; more: boolean; rev: number };
export type HistoryTool = { callId: string; name: string; status: ToolStatus };
export type HistoryItem =
  | { kind: "user" | "agent"; id: string; seq: number; ts: number; text: string; attachments?: Attachment[] }
  | { kind: "tools"; id: string; seq: number; ts: number; tools: HistoryTool[] }
  | { kind: "reset"; id: string; seq: number; ts: number };
export type ReadCursor = { convId: string; messageId: string; ts: number; unread: boolean };
export type Foreground = { convId?: string | null; active?: boolean };
export type DeviceInfo = { id: string; name?: string; pairedAt: number; push: boolean; current: boolean };
export type DeviceList = { devices?: DeviceInfo[]; error?: string };
export type DevicePatch = { id: string; push?: boolean; removed?: true };
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
  | { kind: "download"; data: Download }
  | { kind: "chunk"; data: Chunk };

export type Received = Event | { kind: "unknown"; name: string };

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
  conv_list: (d) => d.conversations === undefined || Array.isArray(d.conversations),
  history: (d) => isId(d.convId) && optInt(d.before) && optInt(d.after) && (d.items === undefined || Array.isArray(d.items)),
  read_cursor: (d) => ref(d) && int(d.ts) && typeof d.unread === "boolean",
  foreground: (d) =>
    (d.convId === undefined || d.convId === null || isId(d.convId)) && (d.active === undefined || typeof d.active === "boolean"),
  cron_list: (d) => (d.jobs === undefined || Array.isArray(d.jobs)) && optStr(d.error),
  device_list: (d) => (d.devices === undefined || Array.isArray(d.devices)) && optStr(d.error),
  pair_invite: (d) => optStr(d.link) && optStr(d.webLink) && optStr(d.fingerprint) && optInt(d.expiresAt) && optStr(d.error),
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
    (d.pinned === undefined || typeof d.pinned === "boolean") &&
    (d.deleted === undefined || d.deleted === true),
  conv_update: (d) => isId(d.convId),
};

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

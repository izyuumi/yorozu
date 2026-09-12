/**
 * Wire events exchanged between Mac, phone and relay.
 * The relay never reads these: they travel sealed. See docs/spec-v1.html sections 3, 7, 8.
 *
 * JSON shape is `{ ...base, kind, data }` and is mirrored byte-for-byte by
 * `YorozuEvent` in packages/shared-swift.
 */

/** Fields every event carries, whatever its kind. */
export interface EventBase {
  id: string;
  threadId: string;
  /** Epoch milliseconds. */
  ts: number;
  agentId: string;
  /** Set when the emitting agent was delegated to by another. */
  parentAgentId?: string;
}

/**
 * A file sent along with a message: a photo, a screenshot, a PDF. The bytes travel inline
 * rather than as a reference, because the relay stores nothing — a link to it would have
 * nowhere to point. One per message, which is all a phone composer offers.
 */
export interface MessageAttachment {
  /** Original file name. What a text-only model is told was attached. */
  name: string;
  /** IANA media type, e.g. "image/jpeg". `image/*` is what a vision model is handed. */
  mime: string;
  /** The file itself, standard base64 with padding. */
  data: string;
}

/**
 * Largest attachment a client may send, decoded. A message is sealed, framed and held whole in
 * memory at both ends and at the relay, so the cap is about what that costs rather than a limit
 * any provider imposes.
 */
export const ATTACHMENT_MAX_BYTES = 5 * 1024 * 1024;

export interface MessageData {
  role: "user" | "agent";
  text: string;
  /**
   * Set on the last message of a turn — a delegated agent's, so the phone's inline card for
   * that delegation stops spinning, and the main agent's, so the composer stops offering Stop.
   * A flag rather than a kind of its own: the final message is already the thing that ends a turn.
   */
  done?: boolean;
  /** A photo or file the user sent with this message. Only ever set on a `user` message. */
  attachment?: MessageAttachment;
}

export interface ThoughtData {
  text: string;
}

export interface ToolCallData {
  callId: string;
  name: string;
  args: Record<string, unknown>;
}

export interface ToolResultData {
  callId: string;
  ok: boolean;
  output: string;
}

/** Pending external action awaiting a Yes / No / Never / Discuss answer. */
export interface ApprovalCardData {
  actionId: string;
  /** e.g. "send-message", "purchase", "delete-file". */
  actionClass: string;
  target: string;
  amount?: number;
}

export interface ApprovalAnswerData {
  actionId: string;
  answer: "yes" | "no" | "never" | "discuss";
}

export interface ThreadCreateData {
  title?: string;
}

/** Renames `threadId` from the base fields. A title the user chose: auto-titling leaves it alone. */
export interface ThreadRenameData {
  title: string;
}

export interface ThreadSummary {
  id: string;
  title: string;
  archived: boolean;
  /** When the thread was last written to, epoch milliseconds. What the lists order on. */
  lastActivity: number;
  /**
   * One line of the newest message in the thread, whoever said it, for the list's preview.
   * Absent in a thread nothing has been said in yet.
   */
  lastMessage?: string;
  /** Pinned threads lead the list. Absent from a runtime older than the flag, meaning not pinned. */
  pinned?: boolean;
}

export interface ThreadListData {
  threads: ThreadSummary[];
}

/**
 * Archives `threadId` from the base fields, or brings it back when `archived` is false.
 * The flag is optional because the frame meant "archive" before unarchiving existed, and a
 * phone from then still sends `{}`.
 */
export interface ThreadArchiveData {
  archived?: boolean;
}

/** Pins or unpins `threadId` from the base fields. */
export interface ThreadPinData {
  pinned: boolean;
}

/**
 * The user pressed stop: cancel the turn running in `threadId` and every agent it
 * delegated to. Carries nothing of its own.
 */
export type InterruptData = Record<string, never>;

/** Last event id the device already holds, per thread. */
export interface SyncRequestData {
  lastSeen: Record<string, string>;
}

export interface SyncDeltaData {
  events: YorozuEvent[];
}

/**
 * One device this Mac is paired with, as the Mac app's Devices tab lists them. Public keys
 * only: they are identifiers here, and the short form of `pub` is what the user sees.
 */
export interface DeviceInfo {
  /** X25519 public key, base64url. What the sidecar seals for, and the device's identity. */
  pub: string;
  /**
   * Ed25519 key the relay knows the device by, when it announced one. A different key from
   * `pub` and not derivable from it, so revoking at the relay needs it carried here.
   */
  signingPub?: string;
  /** How the device reaches the runtime: through the relay, or on this Mac's local socket. */
  via: "relay" | "local";
  /** Epoch milliseconds the runtime last heard from it. */
  lastSeen: number;
  online: boolean;
}

export interface DeviceListData {
  devices: DeviceInfo[];
}

/**
 * Forget a device: dropped from `devices.json`, and the relay is told to revoke it so it
 * cannot rejoin against the nonce either. Answered with a fresh `device_list`.
 */
export interface DeviceRemoveData {
  pub: string;
}

/** Kind tag paired with its payload. Discriminates on `kind`. */
export type EventPayload =
  | { kind: "message"; data: MessageData }
  | { kind: "thought"; data: ThoughtData }
  | { kind: "tool_call"; data: ToolCallData }
  | { kind: "tool_result"; data: ToolResultData }
  | { kind: "approval_card"; data: ApprovalCardData }
  | { kind: "approval_answer"; data: ApprovalAnswerData }
  | { kind: "thread_create"; data: ThreadCreateData }
  | { kind: "thread_list"; data: ThreadListData }
  | { kind: "thread_archive"; data: ThreadArchiveData }
  | { kind: "thread_rename"; data: ThreadRenameData }
  | { kind: "thread_pin"; data: ThreadPinData }
  | { kind: "interrupt"; data: InterruptData }
  | { kind: "sync_request"; data: SyncRequestData }
  | { kind: "sync_delta"; data: SyncDeltaData }
  | { kind: "device_list"; data: DeviceListData }
  | { kind: "device_remove"; data: DeviceRemoveData };

export type EventKind = EventPayload["kind"];

export type YorozuEvent = EventBase & EventPayload;

/** Payload carried by a pairing QR code. */
export interface QrPayload {
  v: 1;
  relayUrl: string;
  /** Mac X25519 public key, base64url, 32 raw bytes. Used for the session key agreement. */
  macPubkey: string;
  /** One-time relay join token. */
  token: string;
  /**
   * Relay room to join: base64url sha256 of the Mac's Ed25519 relay key, which is a
   * different key from `macPubkey` and so cannot be derived from it.
   */
  roomId?: string;
}

/**
 * One compact text form of the pairing payload, short enough for a QR and for a human to
 * paste: `yorozu://pair?v=1&relay=<urlencoded>&key=<base64url>&token=<base64url>`. The QR
 * carries this same string, so one parser serves the scanner, the paste field and the
 * `yorozu://` URL scheme.
 */
export const encodePairingString = (payload: QrPayload): string => {
  const query = new URLSearchParams({
    v: "1",
    relay: payload.relayUrl,
    key: payload.macPubkey,
    token: payload.token,
  });
  if (payload.roomId) query.set("room", payload.roomId);
  return `yorozu://pair?${query}`;
};

/** base64url alphabet, unpadded: Buffer's decoder would happily skip anything else. */
const BASE64URL = /^[A-Za-z0-9_-]+$/;

/** Parses an untrusted pairing string. Throws on anything that is not a v1 payload. */
export function decodePairingString(text: string): QrPayload {
  const query = new URL(text.trim()).searchParams;
  const relayUrl = query.get("relay") ?? "";
  const macPubkey = query.get("key") ?? "";
  const token = query.get("token") ?? "";
  const roomId = query.get("room") ?? undefined;
  if (
    query.get("v") !== "1" ||
    relayUrl === "" ||
    !BASE64URL.test(macPubkey) ||
    !BASE64URL.test(token) ||
    (roomId !== undefined && !BASE64URL.test(roomId))
  ) {
    throw new Error("not a Yorozu v1 pairing string");
  }
  return { v: 1, relayUrl, macPubkey, token, ...(roomId ? { roomId } : {}) };
}

/**
 * Parses an untrusted QR string: the pairing string above, or the JSON form older phones
 * were paired with. Throws on anything that is neither.
 */
export function decodeQrPayload(text: string): QrPayload {
  if (text.trimStart().startsWith("yorozu:")) return decodePairingString(text);
  const p: unknown = JSON.parse(text);
  if (
    typeof p !== "object" ||
    p === null ||
    (p as QrPayload).v !== 1 ||
    typeof (p as QrPayload).relayUrl !== "string" ||
    typeof (p as QrPayload).macPubkey !== "string" ||
    typeof (p as QrPayload).token !== "string" ||
    !["string", "undefined"].includes(typeof (p as QrPayload).roomId)
  ) {
    throw new Error("not a Yorozu v1 QR payload");
  }
  return p as QrPayload;
}

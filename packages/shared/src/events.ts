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

/** Pending external action awaiting a Yes / Yes-and-never-ask / No / Discuss answer. */
export interface ApprovalCardData {
  actionId: string;
  /** e.g. "send-message", "purchase", "delete-file". */
  actionClass: string;
  target: string;
  amount?: number;
}

export interface ApprovalAnswerData {
  actionId: string;
  /** `always` allows this action and writes a rule, so the class is not asked about again. */
  answer: "yes" | "always" | "no" | "discuss";
}

/**
 * A choice the agent needs made before it can carry on, raised by the `ask_user` tool. Unlike
 * an approval card this is not about permission: nothing is pending, the agent simply does not
 * know which way to go. The tool call stays suspended until an answer comes back.
 */
export interface QuestionCardData {
  questionId: string;
  question: string;
  /** The choices offered, in the order the card lists them. May be empty when only free text makes sense. */
  options: string[];
  /** Whether the card also offers a free-text field. Absent means it does not. */
  allowOther?: boolean;
}

export interface QuestionAnswerData {
  questionId: string;
  /** One of the options, or whatever was typed when `allowOther` was set. */
  answer: string;
}

/** One line of a progress card. */
export interface ProgressStep {
  label: string;
  state: "pending" | "running" | "done" | "failed";
}

/**
 * A long job reporting where it has got to, raised by the `report_progress` tool. Re-reporting
 * the same `cardId` replaces the card rather than adding one, which is what makes it a card
 * that moves instead of a log — so the runtime re-emits it under one event id.
 */
export interface ProgressCardData {
  cardId: string;
  title: string;
  steps: ProgressStep[];
  /** 0–100. Absent when the job cannot say, and the steps are the whole of the progress. */
  percent?: number;
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
  /**
   * The model this thread's turns run on, as a `<providerId>/<model>` spec. Absent means the
   * configured chain, which is what nearly every thread wants — see `thread_set_model`.
   */
  model?: string;
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
 * Sets `threadId` from the base fields to one model, as a `<providerId>/<model>` spec from
 * `model_list`. Null — or an absent field, which is how a Swift client encodes it — puts the
 * thread back on the configured chain.
 */
export interface ThreadSetModelData {
  model?: string | null;
}

/** One model a thread can be set to, named the way a picker wants to draw it. */
export interface ModelOption {
  /** The `<providerId>/<model>` spec. What `thread_set_model` carries. */
  id: string;
  /** The model's own name, e.g. "claude-opus-5". */
  label: string;
  /** The provider entry it belongs to, e.g. "Claude". What groups the picker. */
  providerLabel: string;
}

/**
 * Every model the Mac is configured for, pushed alongside `thread_list` so a phone's picker
 * has real names rather than specs it would have to invent labels for. Device-facing only:
 * the providers themselves, and their keys, never leave the Mac.
 */
export interface ModelListData {
  models: ModelOption[];
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
  | { kind: "question_card"; data: QuestionCardData }
  | { kind: "question_answer"; data: QuestionAnswerData }
  | { kind: "progress_card"; data: ProgressCardData }
  | { kind: "thread_create"; data: ThreadCreateData }
  | { kind: "thread_list"; data: ThreadListData }
  | { kind: "thread_archive"; data: ThreadArchiveData }
  | { kind: "thread_rename"; data: ThreadRenameData }
  | { kind: "thread_pin"; data: ThreadPinData }
  | { kind: "thread_set_model"; data: ThreadSetModelData }
  | { kind: "model_list"; data: ModelListData }
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

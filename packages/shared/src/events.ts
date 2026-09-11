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

export interface MessageData {
  role: "user" | "agent";
  text: string;
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

export interface ThreadSummary {
  id: string;
  title: string;
  archived: boolean;
  pinned: boolean;
}

export interface ThreadListData {
  threads: ThreadSummary[];
}

/** Archives `threadId` from the base fields; carries nothing of its own. */
export type ThreadArchiveData = Record<string, never>;

/** Last event id the device already holds, per thread. */
export interface SyncRequestData {
  lastSeen: Record<string, string>;
}

export interface SyncDeltaData {
  events: YorozuEvent[];
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
  | { kind: "sync_request"; data: SyncRequestData }
  | { kind: "sync_delta"; data: SyncDeltaData };

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

export const encodeQrPayload = (payload: QrPayload): string => JSON.stringify(payload);

/** Parses an untrusted QR string. Throws on anything that is not a v1 payload. */
export function decodeQrPayload(text: string): QrPayload {
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

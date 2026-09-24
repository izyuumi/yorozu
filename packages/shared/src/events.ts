import type { PeerInfoData } from "./peer-info.js";

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
  /** Opaque log position supplied by sync; event ids can repeat for updated cards. */
  syncCursor?: string;
}

/**
 * A file sent along with a message: a photo, a screenshot, a PDF. The bytes travel inline
 * rather than as a reference, because the relay stores nothing — a link to it would have
 * nowhere to point.
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
export const MAX_ATTACHMENTS_PER_MESSAGE = 10;
export const MESSAGE_ATTACHMENTS_MAX_BYTES = 20 * 1024 * 1024;

export interface MessageData {
  role: "user" | "agent";
  text: string;
  /**
   * Set on the last message of a turn — a delegated agent's, so the phone's inline card for
   * that delegation stops spinning, and the main agent's, so the composer stops offering Stop.
   * A flag rather than a kind of its own: the final message is already the thing that ends a turn.
   */
  done?: boolean;
  /** Photos and files sent together. */
  attachments?: MessageAttachment[];
}

export function attachmentBytes(attachment: MessageAttachment): number {
  const padding = attachment.data.endsWith("==") ? 2 : attachment.data.endsWith("=") ? 1 : 0;
  return Math.max(0, Math.floor(attachment.data.length / 4) * 3 - padding);
}

export function attachmentsWithinLimits(attachments: readonly MessageAttachment[]): boolean {
  if (attachments.length > MAX_ATTACHMENTS_PER_MESSAGE) return false;
  let total = 0;
  for (const attachment of attachments) {
    const bytes = attachmentBytes(attachment);
    if (bytes > ATTACHMENT_MAX_BYTES) return false;
    total += bytes;
  }
  return total <= MESSAGE_ATTACHMENTS_MAX_BYTES;
}

export interface ThoughtData {
  text: string;
  /** Live lifecycle status. Clients show only the latest and drop it once real work arrives. */
  transient?: boolean;
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
  /**
   * Set when `output` is only the head of what the tool printed. The whole of it stays on the
   * Mac; `tool_result_request` fetches it. Absent means this is all there was.
   */
  truncated?: boolean;
  /** UTF-16 offsets for pull-based chunks that fit encrypted relay frames. */
  chunkOffset?: number;
  nextOffset?: number;
}

/**
 * A device asking for the whole of a truncated tool result in `threadId` from the base fields.
 * Answered, to that device alone, with the full `tool_result` under the event id it already
 * holds, so it replaces the truncated one in place.
 */
export interface ToolResultRequestData {
  callId: string;
  offset?: number;
}

/** Past this many characters a tool result travels truncated. About 4 KB. */
export const TOOL_RESULT_PREVIEW_CHARS = 4096;

/**
 * The fields of an action beyond its class, describing what it actually commits rather than the
 * tool mechanics behind it. Every one is optional because no single action carries all of them:
 * a message has a recipient and no merchant, a purchase the other way round. What a tool does
 * fill in is what the card shows and what a rule matches on.
 */
export interface ApprovalScope {
  /** What is being done, independent of which tool does it. */
  operation?:
    | "send"
    | "purchase"
    | "transfer"
    | "book"
    | "delete"
    | "edit"
    | "run"
    | "subscribe"
    | "trade";
  /** Who it lands on: an email address, a phone number, a payee. */
  recipient?: string;
  /** Which account it moves money out of, or acts as. */
  account?: string;
  /** Who is being paid. */
  merchant?: string;
  /** What kind of spending it is, e.g. "groceries", "crypto". */
  category?: string;
  /** How many, when the action carries a count. Changing it invalidates the approval. */
  quantity?: number;
  /** The first `CONTENT_SUMMARY_MAX` characters of what would be sent or written. */
  contentSummary?: string;
  /** One line the tool declares: what happens once this runs, in the user's terms. */
  consequence?: string;
}

/** How much of the content a card carries. Enough to recognise, not enough to be a transcript. */
export const CONTENT_SUMMARY_MAX = 200;

/**
 * One item of a batch: a decision covers exactly the items the card listed. Adding or changing
 * one after the fact needs a new card — see `ApprovalCardData.items`.
 */
export interface BatchItem {
  /** The item as one line, e.g. a recipient. */
  label: string;
  /** The rest of what identifies it, e.g. a subject line. */
  detail?: string;
}

/** How a rule matches one scope field. Absent field means the rule says nothing about it. */
export interface ApprovalRuleField {
  mode: "exact" | "prefix" | "glob";
  value: string;
}

/** The scope fields a rule can constrain. `target` is the action's own subject line. */
export const APPROVAL_SCOPE_FIELDS = [
  "target",
  "operation",
  "recipient",
  "account",
  "merchant",
  "category",
] as const;

export type ApprovalScopeField = (typeof APPROVAL_SCOPE_FIELDS)[number];

/**
 * A standing decision. Global: rules match on the structured scope of an action and never on
 * which agent is taking it, so delegating does not change what is authorized.
 */
export interface ApprovalRule {
  id: string;
  actionClass: string;
  decision: "never" | "always";
  /** Per-field patterns. A field left out is not constrained — "any". */
  scope?: Partial<Record<ApprovalScopeField, ApprovalRuleField>>;
  /** The most this rule authorizes. Absent means the rule says nothing about money. */
  maxAmount?: number;
  /** ISO 4217 currency of the cap; absent on legacy rules with unspecified units. */
  currency?: string;
  /** Absent means enabled: a rule switched off in Settings stops matching without being lost. */
  enabled?: boolean;
  createdAt?: number;
  /** Kept by the runtime so Settings can show what a rule is actually doing. */
  lastUsed?: number;
  useCount?: number;
}

/** Pending external action awaiting an answer. See `ApprovalAnswerData` for the choices. */
export interface ApprovalCardData {
  /** Native SDK request: only this invocation may be allowed, never a Yorozu rule. */
  nativeAgent?: Exclude<ThreadAgent, "yorozu">;
  actionId: string;
  /** e.g. "send-message", "purchase", "delete-file". */
  actionClass: string;
  target: string;
  amount?: number;
  /** Transaction ISO 4217 currency, independent of the receiving device locale. */
  currency?: string;
  /** What the action commits, field by field. */
  scope?: ApprovalScope;
  /** The exact items one decision covers, when the tool declared a batch. */
  items?: BatchItem[];
  /**
   * Set when no stored rule may stand in for an answer to this card — a subscription, a
   * transfer, a securities trade or crypto. The card says so rather than implying it.
   */
  mustConfirm?: boolean;
  /** The narrowest rule that would cover this action: what "Always allow" opens prefilled. */
  suggestedRule?: ApprovalRule;
}

export interface ApprovalAnswerData {
  actionId: string;
  /**
   * `yes` runs this one action; `task` also covers the same class and scope for the rest of
   * this turn and everything it delegates to, and expires with the turn; `always` runs it and
   * saves `rule`, which persists until revoked.
   */
  answer: "yes" | "task" | "always" | "no" | "discuss";
  /** The rule the editor produced, sent with `always`. */
  rule?: ApprovalRule;
  /**
   * Where the answer was given. `notification` is a lock-screen button, which the runtime only
   * honours for a card it judged quick-approvable itself — the relay chooses which buttons a
   * push draws, and a relay is not trusted to decide what a button may approve.
   */
  source?: "notification";
}

/**
 * The runtime has taken a command a device sent: it is logged or applied, whichever the kind
 * calls for. A device keeps every command in its outbox until this arrives, since a socket that
 * accepted a send is not a runtime that received it.
 */
export interface ReceiptData {
  eventId: string;
}

/**
 * Repeated matching approvals, offered back as a rule. Never active: it is a card with a
 * Review button on it, and only the editor's Save writes anything.
 */
export interface RuleProposalData {
  proposalId: string;
  rule: ApprovalRule;
  /** How many matching approvals prompted it. */
  approvals: number;
}

/** Every stored rule, as Settings lists them. Sent on request and after any change. */
export interface RuleListData {
  rules: ApprovalRule[];
}

/** Saves a rule: a new one, or the edited form of one with the same `id`. */
export interface RuleUpdateData {
  rule: ApprovalRule;
}

/** Revokes a rule outright. Answered with a fresh `rule_list`. */
export interface RuleDeleteData {
  ruleId: string;
}

/**
 * Global approval config. Empty requests current state; `yolo` updates it, from any paired
 * device: pairing is the grant. On always carries an expiry.
 */
export interface ApprovalSettingsData {
  yolo?: boolean;
  /** Epoch milliseconds when YOLO switches itself off. Reported while it is on. */
  yoloUntil?: number;
  /** How long to allow, when turning on. Default 8, capped at 24. */
  hours?: number;
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
  /** Where the job has got to, in the agent's own words. Markdown. */
  note?: string;
}

/**
 * Who answers a thread. `yorozu` is today's loop and the OpenClaw bridge; the other two are
 * native CLI coding agents, each thread one of their sessions. Absent on the wire means `yorozu`,
 * which is what every thread from before the field is.
 */
export const THREAD_AGENTS = ["yorozu", "claude-code", "codex"] as const;
export type ThreadAgent = (typeof THREAD_AGENTS)[number];

export interface ThreadCreateData {
  title?: string;
  /** Which agent answers the thread, for its whole life. Absent means `yorozu`. */
  agent?: ThreadAgent;
  /** The working directory a native agent runs in, fixed at creation. Only they have one. */
  cwd?: string;
}

/** Renames `threadId` from the base fields. A title the user chose: auto-titling leaves it alone. */
export interface ThreadRenameData {
  title: string;
}

export interface ThreadSummary {
  interruptedTurnId?: string;
  canResume?: boolean;
  bypass?: boolean;
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
  /** Requested reasoning depth. Absent means the provider's own default. */
  effort?: ReasoningEffort;
  /** Which agent answers this thread. Absent means `yorozu` — see `ThreadCreateData`. */
  agent?: ThreadAgent;
  /** A native agent's working directory. Absent on a `yorozu` thread. */
  cwd?: string;
  /**
   * When the thread was last read, on any device, epoch milliseconds. The runtime owns it — see
   * `thread_read` — so reading on the phone clears the dot on the Mac too. Absent means never.
   */
  lastReadAt?: number;
  /**
   * `ts` of the newest agent message in the thread, epoch milliseconds. Absent in a thread the
   * agent has not spoken in yet.
   *
   * Every client draws the same dot from these two and nothing else: unread is
   * `lastAgentAt > lastReadAt`. It is deliberately not "a reply arrived while this device had
   * the thread closed" — that answer differs per device, and was wrong on every device that
   * had been asleep for the reply.
   */
  lastAgentAt?: number;
  /** An approval card in this thread nobody has answered yet. Absent means none. */
  awaitingApproval?: boolean;
}

export interface ThreadListData {
  threads: ThreadSummary[];
  /** Bootstrap on an existing kind: old clients ignore this optional hint. */
  peerInfoSupported?: boolean;
  /** Only sent after the peer advertised support over the encrypted channel. */
  peerInfo?: PeerInfoData;
  /** A bounded rejection of this connection's advertised requirements. */
  peerInfoError?: string;
  /** Echoes the current peer-information request, distinguishing it from in-flight broadcasts. */
  peerInfoReplyTo?: string;
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
 * `threadId` from the base fields was read, up to `at`. Sent by whichever device is actually
 * looking at the thread, and answered with a fresh `thread_list` so every other device drops
 * its dot too.
 *
 * The runtime keeps the later of what it holds and `at`, so two devices reporting out of order
 * cannot walk the mark backwards. `reset` is the one exception: "Mark as unread" is a
 * deliberate act, and it sets `lastReadAt` to `at` outright.
 */
export interface ThreadReadData {
  /** Epoch milliseconds read up to. Normally now; `lastAgentAt - 1` to mark unread. */
  at: number;
  /** Set only by "Mark as unread": assign `at` rather than taking the later of the two. */
  reset?: boolean;
}

/**
 * Sets `threadId` from the base fields to one model, as a `<providerId>/<model>` spec from
 * `model_list`. Null — or an absent field, which is how a Swift client encodes it — puts the
 * thread back on the configured chain.
 */
export interface ThreadSetModelData {
  model?: string | null;
}

export const REASONING_EFFORTS = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra", "persistent"] as const;
export type ReasoningEffort = typeof REASONING_EFFORTS[number];
/** What a `yorozu` thread may ask for: the Gateway publishes no per-model levels, so every model offers these. */
export const YOROZU_EFFORTS: ReasoningEffort[] = ["low", "medium", "high"];

/** Sets one thread's reasoning effort. Null or absent resets to the provider default. */
export interface ThreadSetEffortData {
  effort?: ReasoningEffort | null;
}

/** One model a thread can be set to, named the way a picker wants to draw it. */
export interface ModelOption {
  efforts?: ReasoningEffort[];
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
  agentModels?: Partial<Record<Exclude<ThreadAgent, "yorozu">, ModelOption[]>>;
  models: ModelOption[];
}

/**
 * One folder a coding agent's thread can be started in, named the way a picker draws it. Only
 * the folder itself travels: what is inside it never leaves the Mac.
 */
export interface ProjectFolder {
  /** Absolute path on the Mac. What `thread_create` carries back as `cwd`. */
  path: string;
  /** The folder's own name, e.g. "yorozu". */
  name: string;
  /** Epoch milliseconds a thread was last started in it. Absent for a folder never used. */
  lastUsed?: number;
}

/**
 * The Mac's known project folders, recents first, pushed alongside `thread_list` so a phone can
 * offer them the moment a coding agent is chosen. Sent by a device with an empty list to ask.
 */
export interface ProjectListData {
  projects: ProjectFolder[];
}

/**
 * The user pressed stop: cancel the turn running in `threadId` and every agent it
 * delegated to. Carries nothing of its own.
 */
export type InterruptData = Record<string, never>;

/** Last sync cursor the device already holds, per thread. Event ids support older peers. */
export interface SyncRequestData {
  lastSeen: Record<string, string>;
}

export interface SyncDeltaData {
  events: YorozuEvent[];
  /** Threads with a turn still running on the Mac when this page was made. */
  workingThreadIds?: string[];
  /** Another bounded page is available; request again after applying this one. */
  more?: boolean;
}

/**
 * One device this Mac is paired with, as the Mac app's Devices tab lists them.
 */
export interface DeviceInfo {
  /** X25519 public key, base64url. What the sidecar seals for, and the device's identity. */
  pub: string;
  /**
   * Ed25519 key the relay knows the device by, when it announced one. A different key from
   * `pub` and not derivable from it, so revoking at the relay needs it carried here.
   */
  signingPub?: string;
  /** Platform and OS version announced by the device, when known. */
  name?: string;
  /** How the device reaches the runtime: through the relay, or on this Mac's local socket. */
  via: "relay" | "local";
  /** Epoch milliseconds the runtime last heard from it. */
  lastSeen: number;
  online: boolean;
}

export interface DeviceListData {
  devices: DeviceInfo[];
  /** Optional platform name in a device's encrypted request. */
  name?: string;
}

/**
 * Forget a device: dropped from `devices.json`, and the relay is told to revoke it so it
 * cannot rejoin against the nonce either. Answered with a fresh `device_list`.
 */
export interface DeviceRemoveData {
  pub: string;
}

/** Transient host terminal control and display data. Never part of a chat transcript. */
export interface TerminalData {
  action: "status" | "enable" | "disable" | "create" | "created" | "attach" | "detach" | "takeover"
    | "input" | "resize" | "close" | "state" | "snapshot" | "output" | "error";
  sessionId?: string;
  enabled?: boolean;
  sessions?: { id: string; title: string; cwd: string; writable: boolean; cols: number; rows: number }[];
  cols?: number;
  rows?: number;
  /** Base64 for input; UTF-8 terminal text for snapshots and output. */
  data?: string;
  /** Output sequence at snapshot or chunk emission. */
  sequence?: number;
  /** Snapshot chunks have one id and end with `last: true`. */
  snapshotId?: string;
  last?: boolean;
  error?: string;
  /** Host connection generation. Mutating controls from an older relay connection are refused. */
  epoch?: string;
}

/** Kind tag paired with its payload. Discriminates on `kind`. */
export type EventPayload =
  | { kind: "message"; data: MessageData }
  | { kind: "thought"; data: ThoughtData }
  | { kind: "tool_call"; data: ToolCallData }
  | { kind: "tool_result"; data: ToolResultData }
  | { kind: "approval_card"; data: ApprovalCardData }
  | { kind: "approval_answer"; data: ApprovalAnswerData }
  | { kind: "rule_proposal"; data: RuleProposalData }
  | { kind: "rule_list"; data: RuleListData }
  | { kind: "rule_update"; data: RuleUpdateData }
  | { kind: "rule_delete"; data: RuleDeleteData }
  | { kind: "approval_settings"; data: ApprovalSettingsData }
  | { kind: "question_card"; data: QuestionCardData }
  | { kind: "question_answer"; data: QuestionAnswerData }
  | { kind: "progress_card"; data: ProgressCardData }
  | { kind: "tool_result_request"; data: ToolResultRequestData }
  | { kind: "thread_create"; data: ThreadCreateData }
  | { kind: "thread_list"; data: ThreadListData }
  | { kind: "thread_archive"; data: ThreadArchiveData }
  | { kind: "thread_rename"; data: ThreadRenameData }
  | { kind: "thread_pin"; data: ThreadPinData }
  | { kind: "thread_read"; data: ThreadReadData }
  | { kind: "thread_set_model"; data: ThreadSetModelData }
  | { kind: "thread_set_effort"; data: ThreadSetEffortData }
  | { kind: "thread_recover"; data: { turnId: string; action: "continue" | "dismiss" } }
  | { kind: "model_list"; data: ModelListData }
  | { kind: "project_list"; data: ProjectListData }
  | { kind: "interrupt"; data: InterruptData }
  | { kind: "sync_request"; data: SyncRequestData }
  | { kind: "sync_delta"; data: SyncDeltaData }
  | { kind: "device_list"; data: DeviceListData }
  | { kind: "device_remove"; data: DeviceRemoveData }
  | { kind: "terminal"; data: TerminalData }
  | { kind: "receipt"; data: ReceiptData }
  | { kind: "update_status"; data: UpdateStatusData }
  | { kind: "update_control"; data: UpdateControlData };

export interface UpdateStatusData {
  phase: "none" | "unknown" | "waiting" | "countdown" | "postponed" | "installing";
  updateId?: string;
  version?: string;
  activeThreads?: number;
  openTerminals?: number;
  deadline?: number;
  postponedUntil?: number;
  requestId?: string;
}

export interface UpdateControlData {
  action: "queue" | "poll" | "cancel" | "postpone" | "status";
  updateId?: string;
  version?: string;
}

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
  /**
   * A Mac-minted secret the relay never sees: the QR goes from the Mac's screen to the phone's
   * camera. The phone proves it holds it in its `hello` (see `helloProof`), which is what stops
   * a relay from enrolling a device of its own.
   */
  secret?: string;
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
  if (payload.secret) query.set("secret", payload.secret);
  return `yorozu://pair?${query}`;
};

/** base64url alphabet, unpadded: Buffer's decoder would happily skip anything else. */
const BASE64URL = /^[A-Za-z0-9_-]+$/;

/** Parses an untrusted pairing string. Throws on anything that is not a v1 payload. */
export function decodePairingString(text: string): QrPayload {
  const url = new URL(text.trim());
  if (url.protocol !== "yorozu:" || url.hostname !== "pair") {
    throw new Error("not a Yorozu v1 pairing string");
  }
  const query = url.searchParams;
  const relayUrl = query.get("relay") ?? "";
  const macPubkey = query.get("key") ?? "";
  const token = query.get("token") ?? "";
  const roomId = query.get("room") ?? undefined;
  const secret = query.get("secret") ?? undefined;
  if (
    query.get("v") !== "1" ||
    relayUrl === "" ||
    !BASE64URL.test(macPubkey) ||
    !BASE64URL.test(token) ||
    (roomId !== undefined && !BASE64URL.test(roomId)) ||
    (secret !== undefined && !BASE64URL.test(secret))
  ) {
    throw new Error("not a Yorozu v1 pairing string");
  }
  return { v: 1, relayUrl, macPubkey, token, ...(roomId ? { roomId } : {}), ...(secret ? { secret } : {}) };
}

/** Parses an untrusted v1 pairing string. */
export function decodeQrPayload(text: string): QrPayload {
  return decodePairingString(text);
}

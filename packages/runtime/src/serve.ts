#!/usr/bin/env node
/**
 * Runtime sidecar. Pairs with phones through the blind relay and answers their messages
 * with the agent loop. See docs/spec-v1.html section 8.
 *
 * Stdout is the Mac app's only channel: one `STATE <state>` line per relay transition and,
 * per pairing payload, a `QR <string>` line to draw and a `PAIR <string>` line to copy —
 * both the same pairing string. `MINT` on stdin asks the relay for a fresh join token.
 */
import { createHash, randomBytes, randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { appendFileSync, chmodSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, truncateSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { argv, env, stdin, stdout } from "node:process";
import {
  acceptsSeq,
  localPeerInfo,
  parsePeerInfo,
  negotiatePeerInfo,
  decodeEnvelope,
  deriveChannelKeys,
  deriveSessionKey,
  encodeEnvelope,
  encodePairingString,
  fromBase64Url,
  generateKeypair,
  isSeq,
  MAX_DEVICES,
  generateSigningKeypair,
  helloProof,
  attachmentsWithinLimits,
  open,
  seal,
  notifyFor,
  notificationPreviewBody,
  NOTIFY_BODY,
  encodeNotificationPreview,
  signFrame,
  threadRef,
  toBase64Url,
  REASONING_EFFORTS,
  type ApprovalCardData,
  type ChannelKeys,
  type DeviceInfo,
  type EventPayload,
  type Keypair,
  type ModelOption,
  type PeerInfoData,
  type PeerCompatibility,
  type ReasoningEffort,
  type MessageAttachment,
  type ProgressCardData,
  type ThreadAgent,
  type YorozuEvent,
} from "@yorozu/shared";
import WebSocket from "ws";
import { UpdateGate } from "./update-gate.js";
import { AttachmentUploads } from "./attachment-upload.js";
import { MAIN_AGENT } from "./agents.js";
import {
  cardFor,
  deleteRule,
  addRule,
  hitsFloor,
  loadSettings,
  listRules,
  narrowestRule,
  quickApprovable,
  saveSettings,
  yoloExpiry,
  yoloHours,
  type Action,
  type AskResult,
  type Rule,
} from "./approval.js";
import type { AssignMode } from "./assign.js";
import type { TurnContext } from "./index.js";
import type { createLegacyRunner } from "./legacy.js";
import { localSocketPath, startLocalChannel, type Send } from "./local.js";
import type { Provider } from "./provider.js";
import { autoTitle, onDeviceTitler, type Titler } from "./title.js";
// Mirrors PING in apps/relay/src/protocol.ts; the shipped runtime must not depend on the relay package.
const PING = JSON.stringify({ type: "ping" });
import {
  appendThreadEvent,
  archiveThread,
  createThread,
  currentThread,
  eventsAfter,
  fullToolResult,
  listThreads,
  markThreadRead,
  pinThread,
  readThreadEvents,
  searchThreadPage,
  renameThread,
  setThreadEffort,
  setNativeTurn,
  recoverNativeTurns,
  retireOrphanedCards,
  setThreadModel,
  setThreadSession,
  stashToolResult,
  SYNC_LIMIT,
  SYNC_PAGE_BYTES,
  threadAgent,
  threadEffort,
  threadHome,
  threadModel,
  threadSummaries,
} from "./threads.js";
import { codexNativeRunner } from "./codex-native.js";
import { NativeCards } from "./native-cards.js";
import { claudeCodeRunner, type NativeAgentRunner } from "./native.js";
import { isProjectFolder, listProjects } from "./projects.js";
import { questionDesk, QUESTION_TIMEOUT_MS } from "./tools/cards.js";
import { OpenClawRunner, type StoredPendingTurn } from "./openclaw.js";
import { appendTranscript, readTranscripts, transcriptDir } from "./transcripts.js";

const DEFAULT_STATE_DIR = join(homedir(), "Library", "Application Support", "Yorozu");
const RECONNECT_MS = 2_000;
/**
 * Heartbeat on the relay socket. Without it a quiet Mac is silently dropped by whatever sits
 * between it and the relay — the relay then tells every phone the Mac is offline, while this
 * process still holds a socket that looks ESTABLISHED and never hears otherwise, so the phone
 * stays wrong until the app is restarted. Asking, and giving up on an unanswered ask, is what
 * turns that into a reconnect.
 */
const PING_MS = 30_000;
const PONG_MS = 10_000;
/** An unanswered card is not a yes: it expires into a refusal rather than hanging the turn. */
const APPROVAL_TIMEOUT_MS = 10 * 60_000;
const APPROVAL_LIFE_MS = 30 * 60_000;
/**
 * How long a device counts as online for. The relay tells us nothing about a phone's socket —
 * only the phone is told about ours — so "online" here means "has said something recently",
 * which is the only honest answer the runtime has.
 */
const ONLINE_MS = 90_000;

/**
 * A one-off or task-bounded answer typed in the thread instead of tapped on the card. Permanent
 * authority is deliberately absent: prose cannot explicitly choose rule dimensions, so Always
 * allow only completes through the rule editor. A bare `never` remains a one-off refusal.
 */
export function typedAnswer(text: string, card: ApprovalCardData): AskResult | null {
  const typed = text.trim().toLowerCase();
  if (/^(always|yes,? +always|yes,? +and +never +ask|never +ask +again|don'?t +ask +again)\b/.test(typed)) {
    return null;
  }
  // The bounded grant, which only exists in prose as "for this task" and its neighbours.
  if (/^(yes,? +)?(just )?(for|during) +(this|the) +(task|turn|one)\b/.test(typed)) {
    return { answer: "task" };
  }
  if (/^(yes|y|ok|okay|sure)\b/.test(typed)) return { answer: "yes" };
  if (/^(no|n|nope|stop|never)\b/.test(typed)) return { answer: "no" };
  return null;
}

export interface Keys {
  /** X25519, for the session key agreement with each phone. */
  session: Keypair;
  /** Ed25519, the relay identity: the room ID is its hash. */
  signing: Keypair;
}

type StoredKey = { priv: string; pub: string };

const store = (pair: Keypair): StoredKey => ({
  priv: toBase64Url(pair.privateKey),
  pub: toBase64Url(pair.publicKey),
});

const restore = (stored: StoredKey): Keypair => ({
  privateKey: fromBase64Url(stored.priv),
  publicKey: fromBase64Url(stored.pub),
});

/**
 * Keys outlive restarts: the room and every paired phone are pinned to them. So a fresh pair
 * is minted only when there is no file at all. A file that is there but will not read — a
 * permissions slip, a half-written save, a corrupt disk — throws instead of quietly becoming a
 * new identity that strands every paired phone.
 */
export function loadKeys(dir: string): Keys {
  const file = join(dir, "keys.json");
  if (!existsSync(file)) {
    const keys: Keys = { session: generateKeypair(), signing: generateSigningKeypair() };
    // Keys live here, so nobody but the owner may list the directory; created 0700 on first run.
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    writeFileSync(file, JSON.stringify({ session: store(keys.session), signing: store(keys.signing) }), {
      mode: 0o600,
    });
    return keys;
  }
  const stored = JSON.parse(readFileSync(file, "utf8")) as Record<keyof Keys, StoredKey>;
  const keys = { session: restore(stored.session), signing: restore(stored.signing) };
  if (keys.session.privateKey.length !== 32 || keys.signing.privateKey.length !== 32) {
    throw new Error(`${file} does not hold a usable key pair; fix or remove it to pair again`);
  }
  return keys;
}

/**
 * The phones this Mac has paired with, by X25519 public key. Outlives a restart so a phone
 * that rejoins the relay against its nonce — rather than pairing again with a fresh token —
 * is still a device we know how to seal for.
 *
 * Only public keys: the session key is re-derived from our own private key on load, and a
 * phone re-announces itself with `hello` on every join anyway. Losing the file costs nothing
 * but one extra `hello`.
 */
export function loadDevices(file: string): DeviceRecord[] {
  try {
    const stored = JSON.parse(readFileSync(file, "utf8")) as unknown;
    if (!Array.isArray(stored)) return [];
    return stored.flatMap((entry): DeviceRecord[] => {
      // Before this file carried anything but keys, it was a bare array of them.
      if (typeof entry === "string") return [{ pub: entry, lastSeen: 0 }];
      if (typeof entry !== "object" || entry === null) return [];
      const record = entry as Record<string, unknown>;
      if (typeof record.pub !== "string") return [];
      return [
        {
          pub: record.pub,
          ...(typeof record.signingPub === "string" ? { signingPub: record.signingPub } : {}),
          ...(typeof record.name === "string" && /^(iOS|iPadOS|macOS) \d+\.\d+(?:\.\d+)?$/.test(record.name)
            ? { name: record.name } : {}),
          ...(typeof record.pairedAt === "number" && Number.isFinite(record.pairedAt) && record.pairedAt > 0
            ? { pairedAt: record.pairedAt } : {}),
          lastSeen: typeof record.lastSeen === "number" ? record.lastSeen : 0,
          ...(isSeq(record.sendSeq) ? { sendSeq: record.sendSeq } : {}),
          ...(isSeq(record.recvSeq) ? { recvSeq: record.recvSeq } : {}),
          ...(record.peerInfoRequired === true ? { peerInfoRequired: true } : {}),
        },
      ];
    });
  } catch {
    return [];
  }
}

/** One device's live-channel counters, as `channel-seq.json` keeps them: public key to counts. */
export type ChannelSeqs = Record<string, { sendSeq: number; recvSeq: number }>;

/**
 * The live-channel counters, kept apart from the pairings: they move on every accepted box and
 * every thousandth send, the pairings only when a phone joins or leaves. `undefined` when there
 * is no such file, which is what tells the caller to fall back to counters `devices.json` may
 * still carry from before they were split out. An entry that is not two counts is dropped.
 */
export function loadChannelSeqs(file: string): ChannelSeqs | undefined {
  let stored: unknown;
  try {
    stored = JSON.parse(readFileSync(file, "utf8"));
  } catch {
    return undefined;
  }
  if (typeof stored !== "object" || stored === null || Array.isArray(stored)) return {};
  const seqs: ChannelSeqs = {};
  for (const [pub, value] of Object.entries(stored as Record<string, unknown>)) {
    if (typeof value !== "object" || value === null) continue;
    const { sendSeq, recvSeq } = value as Record<string, unknown>;
    if (isSeq(sendSeq) && isSeq(recvSeq)) seqs[pub] = { sendSeq, recvSeq };
  }
  return seqs;
}

/**
 * Writes a state file whole or not at all: the bytes go to `<file>.tmp` and the name is moved
 * over the old file in one step, so a crash mid-write leaves the previous version, never a
 * truncated one. A failed move takes its temporary with it.
 */
function writeFileAtomic(file: string, text: string): void {
  const temporary = `${file}.tmp`;
  writeFileSync(temporary, text, { mode: 0o600, flush: true });
  try {
    renameSync(temporary, file);
  } catch (error) {
    rmSync(temporary, { force: true });
    throw error;
  }
}

/** Stable across JSON property order and host restarts; only client-owned message fields count. */
function userMessageIdentity(event: YorozuEvent & { kind: "message" }): string {
  return createHash("sha256").update(JSON.stringify([
    event.threadId, event.clientTs ?? event.ts, event.data.role, event.data.text, event.data.admissionDeadline ?? null,
    (event.data.attachments ?? []).map(({ name, mime, data }) => [name, mime, data]),
  ])).digest("hex");
}

const ADMISSION_LIFE_MS = 30 * 60_000;
const MAX_CLIENT_CLOCK_LEAD_MS = 5 * 60_000;

/**
 * The state directory, owner-only. Created 0700 when missing; when it is already there and
 * ours, tightened to 0700, since an older release created it with the umask's default and
 * every key, pairing and transcript lives under it. Someone else's directory is left alone:
 * chmod on it would fail anyway, and the failure is not this process's to report.
 */
export function ensureStateDir(dir: string): void {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const info = statSync(dir);
  if ((info.mode & 0o777) !== 0o700 && info.uid === process.getuid?.()) chmodSync(dir, 0o700);
}

/**
 * Frame bodies, base64url JSON inside the relay's opaque `payload`. `hello` is the phone
 * announcing its X25519 key; everything after it is sealed.
 *
 * A first `hello` carries `proof`, `helloProof` over the pairing secret the QR carried and both
 * keys. That is what makes enrolment end-to-end: the relay checks the frame signature against
 * the socket's key, but only the runtime knows the secret, so only a phone that read the QR can
 * introduce a key pair. A device already on file may say `hello` again without one.
 */
type FrameBody =
  | { t: "hello"; pub: string; spub?: string; proof?: string }
  | { t: "box"; n: string; c: string };

/**
 * The relay's `payload`, read as one of the two bodies or as nothing. Everything about it is
 * attacker-controlled — not JSON, JSON that is not an object, a `t` this runtime does not
 * know, fields of the wrong type — and none of it may throw: a body this rejects is logged and
 * acked, so a bad frame in the relay's buffer is let go of rather than replayed for ever.
 */
export function parseFrameBody(payload: unknown): FrameBody | null {
  if (typeof payload !== "string") return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(payload, "base64url").toString());
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return null;
  const body = parsed as Record<string, unknown>;
  if (body.t === "hello") {
    if (typeof body.pub !== "string" || body.pub === "") return null;
    if (body.spub !== undefined && typeof body.spub !== "string") return null;
    if (body.proof !== undefined && typeof body.proof !== "string") return null;
    return {
      t: "hello",
      pub: body.pub,
      ...(body.spub !== undefined ? { spub: body.spub } : {}),
      ...(body.proof !== undefined ? { proof: body.proof } : {}),
    };
  }
  if (body.t === "box") {
    if (typeof body.n !== "string" || typeof body.c !== "string") return null;
    return { t: "box", n: body.n, c: body.c };
  }
  return null;
}

/**
 * One line of `devices.json`. `signingPub` is the Ed25519 key the relay knows the device by,
 * which the phone announces alongside its session key: it cannot be derived from `pub`, and
 * revoking a device at the relay is addressed to it.
 */
export interface DeviceRecord {
  /** Negotiation and replay protection stay required for this pairing once advertised. */
  peerInfoRequired?: true;
  pub: string;
  signingPub?: string;
  /** Platform and OS version announced by this device. */
  name?: string;
  /** First pairing time. Routine sync and live delivery start here; opening a thread can fetch its older log. */
  pairedAt?: number;
  /** Epoch milliseconds we last heard from it; 0 for a device paired before this was kept. */
  lastSeen: number;
  /** Highest live-channel seq reserved for boxes to it; nothing past it has been sealed. */
  sendSeq?: number;
  /** Last live-channel seq accepted from it; anything at or below is a replay. */
  recvSeq?: number;
}

/**
 * How many send seqs are written ahead at a time. A restart resumes past the whole block, so
 * no seq is ever sealed twice without paying a disk write per streamed delta.
 */
const SEND_SEQ_RESERVE = 1_000;

/** A phone paired over the relay, as the runtime holds it. */
interface PairedDevice {
  /** The one shared key, used for push previews and released 0.2.3 live-channel boxes. */
  key: Uint8Array;
  /** Live-channel keys, one per direction. */
  channel: ChannelKeys;
  /** Set by the first box after hello; a modern box can upgrade a legacy connection. */
  format: "current" | "legacy" | null;
  /** Last seq sealed to it; `record.sendSeq` is the ceiling written ahead of it. */
  sent: number;
  record: DeviceRecord;
  peerInfo?: PeerInfoData;
  compatibility?: PeerCompatibility;
  peerClaimReceived?: boolean;
}

export interface ServeOptions {
  /** Diagnostic version, supplied by the containing Mac app. */
  appVersion?: string;
  /** macOS ComputerName; queried again for each authenticated metadata exchange. */
  computerName?: () => string | undefined;
  relayUrl?: string;
  stateDir?: string;
  /** Defaults to the model chain configured from the environment. */
  provider?: Provider;
  /**
   * Names a new thread from its first message. Defaults to the Mac's on-device model through
   * `yorozu-native`; whatever it is, its first five words serve when it does not answer.
   */
  titler?: Titler;
  /** Defaults to stdout. */
  log?: (line: string) => void;
  /**
   * How often to ping the relay, and how long to wait for the pong before giving the socket up
   * for dead. Defaults to ``PING_MS``/``PONG_MS``; the tests turn them down so the timeout is
   * something a test can wait for rather than something only a real half-open socket reaches.
   */
  heartbeat?: { pingMs: number; pongMs: number };
  /** Test seam for Gateway restart/recovery integration. */
  openclawRunner?: OpenClawRunner;
  /**
   * The native coding agents, by thread agent kind. Defaults to Claude Code through the Agent
   * SDK; a kind with no runner answers that it is not available. Test seam for a fake SDK.
   */
  nativeRunners?: Partial<Record<Exclude<ThreadAgent, "yorozu">, NativeAgentRunner>>;
}

export interface Sidecar {
  close(): Promise<void>;
  /** Asks the relay for a fresh join token, which prints the next pairing payload. */
  mint(): void;
}

export function serve(options: ServeOptions = {}): Sidecar {
  const relayUrl = options.relayUrl ?? env.YOROZU_RELAY_URL ?? "wss://relay.yumi.to";
  const dir = options.stateDir ?? env.YOROZU_STATE_DIR ?? DEFAULT_STATE_DIR;
  const attachmentUploads = new AttachmentUploads(dir);
  const assemblingAttachments = new Set<string>();
  let assemblyTail: Promise<void> = Promise.resolve();
  // Memory and the schedule tools resolve their own paths from the environment:
  // publish the choice so an explicit `stateDir` moves the whole runtime, not just the keys.
  env.YOROZU_STATE_DIR = dir;
  // Before anything is read or written under it: keys, pairings and transcripts all live here.
  ensureStateDir(dir);
  // An older build stored a terminal opt-in. Retire it on first launch so rollback cannot
  // silently restore that permission after interactive sessions have been removed.
  rmSync(join(dir, "terminal-settings.json"), { force: true });
  const transcripts = transcriptDir(dir);
  recoverNativeTurns(dir);
  retireOrphanedCards(dir);
  const keys = loadKeys(dir);
  const provider = options.provider;
  const titler = options.titler ?? onDeviceTitler;
  const openclaw = provider ? undefined : options.openclawRunner ?? new OpenClawRunner({ stateDir: dir });
  /**
   * Whether this thread's turns, stops and archives go through the OpenClaw bridge. Only a
   * `yorozu` thread does; a native agent's thread is its own session and never Gateway's,
   * whichever backend the rest of the runtime is on.
   */
  const viaOpenClaw = (threadId: string): boolean => openclaw !== undefined && threadAgent(threadId, dir) === "yorozu";
  const nativeRunners = options.nativeRunners ?? { "claude-code": claudeCodeRunner(), codex: codexNativeRunner() };
  const log = options.log ?? ((line: string) => void stdout.write(`${line}\n`));
  const heartbeat = options.heartbeat ?? { pingMs: PING_MS, pongMs: PONG_MS };
  const state = (name: string) => log(`STATE ${name}`);
  const peerInfo = localPeerInfo(options.appVersion ?? env.YOROZU_APP_VERSION ?? "unknown");
  // An expired operation ID stays barred after restart. The old encrypted relay copy may
  // arrive later, while a fresh user confirmation must carry a new ID and deadline.
  const expiredFile = join(dir, "expired-admissions.jsonl");
  type ExpiredAdmission = { id: string; threadId: string; identity: string; deadline: number };
  let expiredText = existsSync(expiredFile) ? readFileSync(expiredFile, "utf8") : "";
  // A torn final append was never acknowledged. Drop only that tail; complete records remain durable.
  if (expiredText && !expiredText.endsWith("\n")) {
    expiredText = expiredText.slice(0, expiredText.lastIndexOf("\n") + 1);
    truncateSync(expiredFile, Buffer.byteLength(expiredText));
  }
  const storedExpired: unknown[] = expiredText ? expiredText.trimEnd().split("\n").map((line) => JSON.parse(line)) : [];
  if (!storedExpired.every((entry) =>
    typeof entry === "object" && entry !== null &&
    typeof (entry as ExpiredAdmission).id === "string" && (entry as ExpiredAdmission).id.length > 0 &&
    (entry as ExpiredAdmission).id.length <= 128 &&
    typeof (entry as ExpiredAdmission).threadId === "string" && (entry as ExpiredAdmission).threadId.length > 0 &&
    (entry as ExpiredAdmission).threadId.length <= 128 &&
    typeof (entry as ExpiredAdmission).identity === "string" && /^[a-f0-9]{64}$/.test((entry as ExpiredAdmission).identity) &&
    Number.isSafeInteger((entry as ExpiredAdmission).deadline))) throw new Error("Invalid expired admission journal");
  const expiredAdmissions = new Map((storedExpired as ExpiredAdmission[]).map((entry) => [entry.id, entry]));
  if (expiredAdmissions.size !== storedExpired.length) throw new Error("Duplicate expired admission ID");
  const rememberExpired = (entry: ExpiredAdmission): void => {
    appendFileSync(expiredFile, JSON.stringify(entry) + "\n", { mode: 0o600, flush: true });
    expiredAdmissions.set(entry.id, entry);
  };
  // A Stop is bound to one accepted operation. Keep its intent through sidecar replacement,
  // including the backend run identity needed to finish an interrupted abort request.
  type StopRecord = { targetEventId: string; threadId: string; status: "requested" | "stopped" | "completed" | "withdrawn" | "unconfirmed";
    sessionKey?: string; runId?: string; partialText?: string; requestIds: string[] };
  const stopFile = join(dir, "stopped-turns.jsonl");
  let stopText = existsSync(stopFile) ? readFileSync(stopFile, "utf8") : "";
  if (stopText && !stopText.endsWith("\n")) {
    stopText = stopText.slice(0, stopText.lastIndexOf("\n") + 1);
    truncateSync(stopFile, Buffer.byteLength(stopText));
  }
  const stopLines: unknown[] = stopText ? stopText.trimEnd().split("\n").map((line) => JSON.parse(line)) : [];
  if (!stopLines.every((entry) => typeof entry === "object" && entry !== null &&
    typeof (entry as StopRecord).targetEventId === "string" && !!(entry as StopRecord).targetEventId &&
    (entry as StopRecord).targetEventId.length <= 128 &&
    typeof (entry as StopRecord).threadId === "string" && !!(entry as StopRecord).threadId &&
    (entry as StopRecord).threadId.length <= 128 &&
    ["requested", "stopped", "completed", "withdrawn", "unconfirmed"].includes((entry as StopRecord).status) &&
    ((entry as StopRecord).runId === undefined || typeof (entry as StopRecord).runId === "string") &&
    ((entry as StopRecord).sessionKey === undefined || typeof (entry as StopRecord).sessionKey === "string") &&
    ((entry as StopRecord).partialText === undefined || typeof (entry as StopRecord).partialText === "string") &&
    Array.isArray((entry as StopRecord).requestIds) &&
    (entry as StopRecord).requestIds.every((id) => typeof id === "string" && id.length > 0 && id.length <= 128))) {
    throw new Error("Invalid stopped-turn journal");
  }
  const stopOwners = new Map<string, string>();
  for (const entry of stopLines as StopRecord[]) {
    if (stopOwners.has(entry.targetEventId) && stopOwners.get(entry.targetEventId) !== entry.threadId)
      throw new Error("Conflicting stopped-turn journal");
    stopOwners.set(entry.targetEventId, entry.threadId);
  }
  const stoppedTurns = new Map((stopLines as StopRecord[]).map((entry) => [entry.targetEventId, entry]));
  const rememberStop = (entry: StopRecord): void => {
    const previous = stoppedTurns.get(entry.targetEventId);
    if (previous?.status === entry.status && previous.requestIds.length === entry.requestIds.length) return;
    appendFileSync(stopFile, JSON.stringify(entry) + "\n", { mode: 0o600, flush: true });
    stoppedTurns.set(entry.targetEventId, entry);
  };
  const computerName = options.computerName ?? (() => {
    if (process.platform !== "darwin") return undefined;
    try {
      return execFileSync("/usr/sbin/scutil", ["--get", "ComputerName"], { encoding: "utf8", timeout: 1_000, maxBuffer: 1_024 }).trim();
    } catch { return undefined; }
  });

  // A chain nobody is signed in to answers every turn with a 401. Said once, here, so the Mac
  // app can show it instead of leaving the user to read auth errors in a chat bubble. Skipped
  // for a caller-supplied provider: that one is the caller's business.
  if (!options.provider) state("openclaw");

  /** One controller per running turn, so an `interrupt` cancels every tree at once. */
  const running = new Map<string, AbortController>();
  const runningEventIds = new Map<string, string>();
  const turnQueues = new Map<string, Promise<void>>();
  const nativeRecoveryStarted = new Set<string>();
  const admittedTurns = new Map<string, Promise<void>>();
  const activeTurnIds = new Set<string>();
  const postponeFile = join(dir, "update-postponed-until.json");
  let postponedUntil = 0;
  try {
    const stored: unknown = JSON.parse(readFileSync(postponeFile, "utf8"));
    if (typeof stored === "number" && Number.isFinite(stored)) postponedUntil = stored;
  } catch {}
  const updateGate = new UpdateGate(postponedUntil);
  let updateOwner: string | undefined;
  const updateSubscribers = new Set<string>();
  let legacy: ReturnType<typeof createLegacyRunner> | undefined;

  /**
   * Keys per paired device, keyed by the X25519 public key it announced. Several phones can
   * be paired at once, so every agent event is sealed once per device; the map outlives the
   * socket, so a reconnect unpairs nobody, and `devices.json` carries it across a restart, so
   * neither does a relaunch of this sidecar.
   */
  const devicesFile = join(dir, "devices.json");
  /**
   * The live-channel counters, in their own file: they change on every accepted box, the
   * pairings only when a phone joins or leaves, and a pairing file rewritten a thousand times
   * an hour is a pairing file a crash finds half-written.
   */
  const seqFile = join(dir, "channel-seq.json");
  const devices = new Map<string, PairedDevice>();
  /**
   * Announces the paired list to the relay, which replaces what it knows with it. Assigned
   * per connection, a no-op while there is none.
   */
  let announceDevices: () => void = () => {};
  /** The pairings alone, counters left out: written when a device joins, leaves or changes key. */
  const writeDevices = (): void => {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    writeFileAtomic(
      devicesFile,
      JSON.stringify([...devices.values()].map(({ record: { sendSeq: _send, recvSeq: _recv, ...record } }) => record)),
    );
  };
  /** The counters alone: what every accepted box and every thousandth send update. */
  const writeSeqs = (): void => {
    mkdirSync(dir, { recursive: true, mode: 0o700 });
    const seqs: ChannelSeqs = Object.fromEntries(
      [...devices.values()].map(({ record }) => [record.pub, { sendSeq: record.sendSeq ?? 0, recvSeq: record.recvSeq ?? 0 }]),
    );
    writeFileAtomic(seqFile, JSON.stringify(seqs));
  };
  const saveDevices = (): void => {
    writeDevices();
    // This file is what the relay's known-device set is rebuilt from, so it is told whenever
    // the set changes rather than only at register time.
    announceDevices();
  };
  const remember = (record: DeviceRecord): void => {
    // A repeat `hello` says nothing about seqs. The counters on file carry on, or the phone
    // would take our next box for a replay and we would take its replays for new; and the
    // seq last sealed carries on too, so a re-hello burns no block.
    const before = devices.get(record.pub);
    record.sendSeq ??= before?.record.sendSeq ?? 0;
    record.recvSeq ??= before?.record.recvSeq ?? 0;
    record.peerInfoRequired ??= before?.record.peerInfoRequired;
    const theirPub = fromBase64Url(record.pub);
    devices.set(record.pub, {
      key: deriveSessionKey(keys.session.privateKey, theirPub),
      channel: deriveChannelKeys(keys.session.privateKey, theirPub, "mac"),
      format: record.peerInfoRequired ? "current" : null,
      // Fresh from disk the ceiling is all there is, and everything up to it counts as used.
      sent: before?.sent ?? record.sendSeq,
      record,
    });
  };
  let migratedPairingTime = false;
  // Counters from their own file where there is one; a `devices.json` from before the split
  // still carries them itself, and those are honoured until the first write moves them over.
  const storedSeqs = loadChannelSeqs(seqFile);
  let legacySeqs = false;
  // Never more than the relay will be told about: a file past the cap is read up to it.
  for (const record of loadDevices(devicesFile).slice(0, MAX_DEVICES)) {
    // A key on disk we can no longer agree with is simply dropped, not a reason not to start.
    try {
      // Older releases never recorded first pairing. Do not invent historical access:
      // start a conservative cutoff once, before even a no-hello reconnect can sync.
      if (!Number.isFinite(record.pairedAt) || !record.pairedAt || record.pairedAt < 0) {
        record.pairedAt = Date.now();
        migratedPairingTime = true;
      }
      const seqs = storedSeqs?.[record.pub];
      if (seqs) {
        record.sendSeq = seqs.sendSeq;
        record.recvSeq = seqs.recvSeq;
      } else if (storedSeqs === undefined && (record.sendSeq || record.recvSeq)) {
        legacySeqs = true;
      }
      remember(record);
    } catch {
      // Not a usable X25519 key any more.
    }
  }
  if (migratedPairingTime) saveDevices();
  // Counters that were only ever in `devices.json` go to their own file now, so the next
  // start reads them from where every later write puts them.
  if (legacySeqs) writeSeqs();

  /**
   * The same thing for devices on the local socket, which need no key: the Mac app is one more
   * paired device, it just reached us without the relay. Kept apart from ``devices`` only
   * because what it stores per device is a writer rather than a session key.
   */
  const locals = new Map<string, Send>();

  let socket: WebSocket | null = null;
  // OPEN only means transport connected; the relay accepts application traffic after register.
  let relayReady = false;
  let retry: NodeJS.Timeout | null = null;
  let stopped = false;
  const catchupSends = new Map<string, { connection: WebSocket | null; device: PairedDevice;
    responses: YorozuEvent[]; next: number }>();
  let catchupTimer: NodeJS.Timeout | null = null;
  let nextCatchupAt = 0;
  /**
   * Secrets behind the QRs on screen, newest last. A phone's first `hello` proves it holds one
   * of them, and pairing spends them all: a QR is for one phone, and the next one is drawn fresh.
   */
  const pairingSecrets = new Set<string>();
  const PAIRING_SECRETS = 4;
  /** Seals and sends to one paired device. Replaced per connection, a no-op while there is none. */
  let sendTo: (device: string, event: YorozuEvent) => void = () => {};
  // A negative result means a trace was held (-1) or is too large to send live (-2).
  let sendToAll: (event: YorozuEvent, maxBuffered?: number) => number = () => 0;
  const liveReplies = new Map<string, YorozuEvent>();
  const partials = new Map<string, YorozuEvent>();
  let partialTimer: NodeJS.Timeout | null = null;
  let nextPartialAt = 0;
  const traces = new Map<string, YorozuEvent[]>();
  let traceCount = 0;
  let traceBytes = 0;
  let traceTimer: NodeJS.Timeout | null = null;
  let syncHintTimer: NodeJS.Timeout | null = null;
  let syncNeeded = false;
  let nextSyncHintAt = 0;
  const hintedClients = new Set<string>();
  let traceTokens = 30;
  let traceRefilledAt = Date.now();
  const TRACE_EVENTS = 64;
  const TRACE_BYTES = 512 * 1024;
  const refillTraceTokens = (): void => {
    const now = Date.now();
    traceTokens = Math.min(30, traceTokens + Math.max(0, now - traceRefilledAt) / 100);
    traceRefilledAt = now;
  };

  const traceEvent = (event: YorozuEvent): boolean =>
    event.kind === "thought" || event.kind === "tool_call" || event.kind === "tool_result" ||
    event.kind === "progress_card";
  const phoneTrace = (event: YorozuEvent, canDownload = true): YorozuEvent => {
    if (event.kind === "message" && event.data.attachments?.length &&
        Buffer.byteLength(JSON.stringify(event)) > (canDownload ? 256 : 450) * 1024) {
      return { ...event, data: { ...event.data, attachments: event.data.attachments.map((attachment) => {
        const bytes = Buffer.from(attachment.data, "base64");
        // Legacy clients discard unknown fields when caching. Keep descriptor in `data` so an
        // upgraded client can hydrate the same event without resetting its history cursor.
        const hash = createHash("sha256").update(bytes).digest("hex");
        return { name: attachment.name, mime: attachment.mime,
          data: canDownload ? "" : `yorozu-deferred-v1:${bytes.length}:${hash}`, sizeBytes: bytes.length,
          sha256: hash };
      }) } };
    }
    if (!traceEvent(event) || Buffer.byteLength(JSON.stringify(event)) <= 32 * 1024) return event;
    let preview: YorozuEvent;
    switch (event.kind) {
      case "thought":
        preview = { ...event, data: { ...event.data,
          text: `${event.data.text.slice(0, 4_096)}\n… [full trace on host]` } };
        break;
      case "tool_call":
        preview = { ...event, data: { ...event.data, name: event.data.name.slice(0, 256),
          args: { preview: "Arguments shortened; full trace on host" } } };
        break;
      case "tool_result":
        preview = stashToolResult(event, dir);
        break;
      case "progress_card":
        preview = { ...event, data: { ...event.data, title: event.data.title.slice(0, 256),
          steps: [], note: "Progress detail shortened; full trace on host" } };
        break;
      default: return event;
    }
    return Buffer.byteLength(JSON.stringify(preview)) <= 32 * 1024 ? preview
      : { ...event, kind: "thought", data: { text: "Large trace kept on host" } };
  };
  const durableTrace = (event: YorozuEvent): boolean =>
    event.kind !== "thought" || event.data.transient !== true;
  const clearTraces = (): void => {
    traces.clear();
    traceCount = 0;
    traceBytes = 0;
    if (traceTimer) clearTimeout(traceTimer);
    traceTimer = null;
    if (syncHintTimer) clearTimeout(syncHintTimer);
    syncHintTimer = null;
    syncNeeded = false;
    traceTokens = 30;
    traceRefilledAt = Date.now();
  };
  const sendSyncHint = (): void => {
    syncHintTimer = null;
    if (!syncNeeded || stopped || !relayReady) return;
    syncNeeded = false;
    nextSyncHintAt = Date.now() + 5_000;
    // An empty truncated delta leaves every client's replay cursor intact and asks it to sync.
    for (const pub of devices.keys()) hintedClients.add(pub);
    try { sendToAll(control({ kind: "sync_delta", data: { events: [], more: true } })); }
    catch (error) { state(`sync-hint-error ${String(error)}`); socket?.close(); }
  };
  const noteSkippedTrace = (): void => {
    syncNeeded = true;
    if (!syncHintTimer) syncHintTimer = setTimeout(sendSyncHint, Math.max(1_000, nextSyncHintAt - Date.now()));
  };
  const drainTrace = (): void => {
    traceTimer = null;
    if (stopped || !relayReady) return clearTraces();
    if ((socket?.bufferedAmount ?? 0) > TRACE_BYTES) {
      traceTimer = setTimeout(drainTrace, 100);
      return;
    }
    refillTraceTokens();
    if (traceTokens < 1) {
      traceTimer = setTimeout(drainTrace, Math.max(10, Math.ceil((1 - traceTokens) * 100)));
      return;
    }
    const entry = traces.entries().next().value;
    if (!entry) return;
    const [threadId, queue] = entry;
    traces.delete(threadId);
    const event = queue[0]!;
    let batches = 0;
    try { batches = sendToAll(event, TRACE_BYTES); }
    catch (error) { state(`trace-send-error ${String(error)}`); socket?.close(); return; }
    if (batches === -1) {
      traces.set(threadId, queue);
      traceTimer = setTimeout(drainTrace, 100);
      return;
    }
    queue.shift();
    traceCount--;
    traceBytes -= Buffer.byteLength(JSON.stringify(event));
    if (queue.length) traces.set(threadId, queue);
    if (batches === -2) { if (durableTrace(event)) noteSkippedTrace(); }
    else traceTokens -= batches;
    if (traces.size) traceTimer = setTimeout(drainTrace, 100);
  };
  const queueTrace = (event: YorozuEvent): void => {
    if (!relayReady) return; // reconnect sync owns history emitted while the relay was away
    refillTraceTokens();
    if (!traces.size && traceTokens >= 1 && (socket?.bufferedAmount ?? 0) <= TRACE_BYTES) {
      const batches = sendToAll(event, TRACE_BYTES);
      if (batches >= 0) { traceTokens -= batches; return; }
      if (batches === -2) { if (durableTrace(event)) noteSkippedTrace(); return; }
    }
    const size = Buffer.byteLength(JSON.stringify(event));
    const queue = traces.get(event.threadId) ?? [];
    queue.push(event);
    traces.set(event.threadId, queue);
    traceCount++;
    traceBytes += size;
    while (traceCount > TRACE_EVENTS || traceBytes > TRACE_BYTES) {
      const largest = [...traces].reduce((best, entry) => entry[1].length > best[1].length ? entry : best);
      const skipped = largest[1].shift()!;
      traceCount--;
      traceBytes -= Buffer.byteLength(JSON.stringify(skipped));
      if (!largest[1].length) traces.delete(largest[0]);
      if (durableTrace(skipped)) noteSkippedTrace();
    }
    if (traces.size && !traceTimer) traceTimer = setTimeout(drainTrace, 100);
  };

  /** Latest partial per thread, paced by the relay batches each broadcast actually used. */
  const flushPartial = (): void => {
    partialTimer = null;
    const entry = partials.entries().next().value;
    if (!entry || stopped) return;
    const [threadId, event] = entry;
    partials.delete(threadId);
    let batches = 0;
    try { batches = sendBroadcast(event); }
    catch (error) { state(`partial-send-error ${String(error)}`); }
    nextPartialAt = Date.now() + Math.max(100, batches * 50);
    if (partials.size) partialTimer = setTimeout(flushPartial, nextPartialAt - Date.now());
  };

  const sendBroadcast = (event: YorozuEvent, announce = true): number => {
    const batches = sendToAll(event);
    for (const send of locals.values()) send(event);
    // A suspended phone still needs a wake for a final reply or actionable card.
    if (announce) notifyRelay(event);
    return batches;
  };

  /** The same event to every paired device, through the relay or over the local socket. */
  const broadcast = (event: YorozuEvent, announce = true): void => {
    if (traceEvent(event)) {
      for (const send of locals.values()) send(event);
      queueTrace(phoneTrace(event));
      return;
    }
    if (event.kind === "message" && event.data.role === "agent" && !event.parentAgentId) {
      if (event.data.done) {
        liveReplies.delete(event.threadId);
        partials.delete(event.threadId);
        const queued = traces.get(event.threadId);
        if (queued) {
          traces.delete(event.threadId);
          traceCount -= queued.length;
          traceBytes -= queued.reduce((sum, trace) => sum + Buffer.byteLength(JSON.stringify(trace)), 0);
          if (queued.some(durableTrace)) noteSkippedTrace();
        }
      } else {
        liveReplies.set(event.threadId, event);
        partials.set(event.threadId, event);
        if (partialTimer || Date.now() < nextPartialAt) {
          if (!partialTimer) partialTimer = setTimeout(flushPartial, nextPartialAt - Date.now());
          return;
        }
        partials.delete(event.threadId);
        nextPartialAt = Date.now() + Math.max(100, sendBroadcast(event, announce) * 50);
        return;
      }
    }
    sendBroadcast(event, announce);
  };

  const currentUpdateStatus = (requestId?: string) =>
    ({ ...updateGate.status, ...(requestId ? { requestId } : {}) });

  function pushUpdateStatus(): void {
    const event = control({ kind: "update_status", data: currentUpdateStatus() });
    for (const device of updateSubscribers) {
      const send = locals.get(device);
      if (send) send(event);
      else if (devices.has(device)) sendTo(device, event);
    }
  }

  /** Asks the relay to forget a device, so a revoked phone cannot rejoin against the nonce. */
  let revokeAtRelay: (signingPub: string) => void = () => {};
  const heldRevokes = new Set<string>();

  /**
   * Tells the relay that something happened and, for replies and cards, supplies one opaque
   * preview box per phone. Replaced per connection, a no-op while there is none.
   */
  let notifyRelay: (event: YorozuEvent) => void = () => {};
  /** Turns that ended while the relay socket was down, waiting to be announced on reconnect. */
  const heldNotifies: YorozuEvent[] = [];
  const latestPerThread = (events: YorozuEvent[]): YorozuEvent[] =>
    [...new Map(events.map((event) => [event.threadId, event])).values()];

  /** Everything the runtime sees is logged first: the nightly job reads the log back. */
  function emit(event: YorozuEvent): void {
    // Startup/lifecycle copy is live UI state, not conversation history or memory material.
    const transient = event.kind === "thought" && event.data.transient === true;
    if (!transient) {
      appendTranscript(event, transcripts);
      appendThreadEvent(event, dir);
    }
    broadcast(event);
    // A raised card shows on the list as well as in the chat, so the list follows it.
    if (["approval_card", "approval_answer", "approval_status", "question_card", "question_answer"].includes(event.kind))
      broadcast(threadList());
  }

  /** Final event owns recovery marker: persist once, then acknowledge, then publish. */
  function finalizeOpenClaw(event: YorozuEvent): void {
    const admission = openclaw!.pendingTurns(true).find((turn) => turn.completionId === event.id);
    const history = readThreadEvents(event.threadId, dir);
    const stored = history.find((known) => known.id === event.id);
    const timed = stored ?? { ...event, ts: Math.max(event.ts, (history.at(-1)?.ts ?? 0) + 1) };
    const final = timed.kind === "message" && admission
      ? { ...timed, data: { ...timed.data, runId: admission.runId } } : timed;
    if (!readTranscripts(new Date(0), transcripts).some((known) => known.id === event.id)) appendTranscript(final, transcripts);
    if (!stored) appendThreadEvent(final, dir);
    openclaw!.acknowledge(event.threadId, event.id);
    // Replayed durable finals still reach connected clients, but are not a second wake-up.
    broadcast(final, !stored);
  }

  const nativeCards = new NativeCards(emit);

  /** Cards on screen somewhere, waiting to be answered, by action ID. */
  const pending = new Map<
    string,
    { card: ApprovalCardData; threadId: string; floored: boolean;
      settle: (result: AskResult, outcome?: "answer" | "already-logged" | "expired" | "cancelled") => void }
  >();
  /** Whether each pending card may be answered from a notification button. */
  const quickActions = new Map<string, boolean>();

  /**
   * Puts a card in front of every paired device and blocks the tool call until one of them
   * answers it. The turn is suspended here, so an interrupt and the timeout both have to be
   * able to settle it.
   */
  function ask(action: Action, context?: { threadId: string; agentId: string }): Promise<AskResult> {
    const actionId = randomUUID();
    const card = cardFor(actionId, action);
    const threadId = context?.threadId ?? currentThread(dir);
    // Judged here, where the action is, and read by `notifyRelay` when the card goes out.
    const settings = loadSettings(dir);
    quickActions.set(actionId, quickApprovable(action, settings, dir));
    // YOLO turned on later answers this card, unless the floor is why it was raised.
    const floored = hitsFloor(action, settings, dir);
    return new Promise<AskResult>((resolve) => {
      const timer = setTimeout(() => {
        pending.get(actionId)?.settle({ answer: "no" }, "expired");
      }, APPROVAL_TIMEOUT_MS);
      timer.unref?.();
      pending.set(actionId, {
        card,
        threadId,
        floored,
        settle: (result, outcome = "answer") => {
          if (!pending.has(actionId)) return;
          clearTimeout(timer);
          pending.delete(actionId);
          quickActions.delete(actionId);
          if (outcome === "answer") emit({
            id: randomUUID(), threadId, ts: Date.now(), agentId: MAIN_AGENT,
            kind: "approval_answer", data: { actionId, answer: result.answer, ...(result.rule ? { rule: result.rule } : {}) },
          });
          else if (outcome === "expired" || outcome === "cancelled") emit({
            id: randomUUID(), threadId, ts: Date.now(), agentId: MAIN_AGENT,
            kind: "approval_status", data: { requestId: randomUUID(), actionId,
              status: outcome === "expired" ? "expired" : "no-longer-needed" },
          });
          resolve(result);
        },
      });
      emit({
        id: randomUUID(),
        threadId,
        ts: Date.now(),
        agentId: context?.agentId ?? MAIN_AGENT,
        kind: "approval_card",
        data: card,
      });
    });
  }

  /**
   * Repeated approvals, offered back as a rule. A card and nothing more: the rule is not
   * stored, not active and not counted until the user saves it from the editor, which is
   * what keeps an inferred scope from becoming authority on its own.
   */
  const proposeRule = (rule: Rule, approvals: number, context?: TurnContext): void =>
    emit({
      id: randomUUID(),
      threadId: context?.threadId ?? currentThread(dir),
      ts: Date.now(),
      agentId: context?.agentId ?? MAIN_AGENT,
      kind: "rule_proposal",
      data: { proposalId: randomUUID(), rule, approvals },
    });

  /** Every stored rule, as the Rules screens list them. */
  const ruleList = (): YorozuEvent =>
    control({ kind: "rule_list", data: { rules: listRules(dir) } });

  /**
   * Questions the agent has put to the user. Raising one puts a card in front of every paired
   * device and suspends the `ask_user` call until an answer comes back — so, like an approval,
   * an interrupt and the desk's own timeout both have to be able to settle it.
   */
  const questions = questionDesk((card, context) =>
    emit({
      id: randomUUID(),
      threadId: context?.threadId ?? currentThread(dir),
      ts: Date.now(),
      agentId: context?.agentId ?? MAIN_AGENT,
      kind: "question_card",
      data: card,
    }), QUESTION_TIMEOUT_MS, (questionId, threadId, reason) => emit({
      id: randomUUID(), threadId: threadId ?? currentThread(dir), ts: Date.now(), agentId: MAIN_AGENT,
      kind: "question_answer", data: { questionId, answer: reason === "expired" ? "Expired" : "Cancelled" },
    }),
  );

  /**
   * A progress card, first shown or moved along. The event id is the card id, which is the
   * whole of the update-in-place: a client upserts by event id, so re-reporting replaces the
   * card it already drew instead of stacking another one under it.
   */
  const reportProgress = (card: ProgressCardData, context?: TurnContext): void =>
    emit({
      id: card.cardId,
      threadId: context?.threadId ?? currentThread(dir),
      ts: Date.now(),
      agentId: context?.agentId ?? MAIN_AGENT,
      kind: "progress_card",
      data: card,
    });

  /** A frame that is about the threads rather than in one: `threadId` is not read for these. */
  const control = (payload: EventPayload): YorozuEvent => ({
    id: randomUUID(),
    threadId: "",
    ts: Date.now(),
    agentId: MAIN_AGENT,
    ...payload,
  });

  const threadList = (minTs = 0): YorozuEvent => {
    const { yolo } = loadSettings(dir);
    const openclawTurns = new Map(openclaw?.pendingTurns().filter((turn) => turn.state === "active")
      .map((turn) => [turn.threadId, turn]) ?? []);
    return control({ kind: "thread_list", data: { threads: threadSummaries(dir, minTs).map((thread) => {
      const openclawTurn = !thread.agent || thread.agent === "yorozu" ? openclawTurns.get(thread.id) : undefined;
      const interruptedTurnId = openclawTurn?.paused ? openclawTurn.completionId : thread.interruptedTurnId;
      const stopping = interruptedTurnId && [...stoppedTurns.values()].some((stop) =>
        stop.threadId === thread.id && stop.status === "requested" &&
        completionIdFor(thread.id, stop.targetEventId) === interruptedTurnId);
      return {
        ...thread,
        ...(thread.agent && thread.agent !== "yorozu" ? { bypass: yolo } : {}),
        ...(runningEventIds.has(thread.id) ? { activeEventId: runningEventIds.get(thread.id) } : {}),
        ...(openclawTurn?.paused ? { interruptedTurnId: openclawTurn.completionId, canResume: true } :
          openclawTurn?.recoveryAttempts || openclawTurn?.recoveryPrompt ? { recoveryState: "recovering" as const } : {}),
        ...(stopping ? { interruptedTurnId: undefined, canResume: undefined, recoveryState: undefined } : {}),
      };
    }) } });
  };
  const broadcastActiveThreadList = (): void => {
    for (const id of liveReplies.keys()) if (!running.has(id)) liveReplies.delete(id);
    if (locals.size || [...devices.values()].some((device) => device.compatibility?.state === "compatible" &&
        device.compatibility.capabilities.includes("exact-stop-v1"))) broadcast(threadList());
  };

  /**
   * What a thread can be put on, by name. Sent with the thread list rather than on request: a
   * phone's model picker is one tap away from the thread it is about, and asking for the list
   * at that point would draw an empty menu first.
   */
  const agentModels: Partial<Record<Exclude<ThreadAgent, "yorozu">, ModelOption[]>> = {};
  const modelsFor = (agent: ThreadAgent): ModelOption[] =>
    agent === "yorozu" ? (provider ? legacy?.models() ?? [] : openclawModels) : agentModels[agent] ?? [];
  /** The efforts a thread may ask for: its model's, or the first model's while it is on Default. */
  const effortsFor = (agent: ThreadAgent, model: string | undefined): ReasoningEffort[] =>
    (modelsFor(agent).find((m) => m.id === model) ?? modelsFor(agent)[0])?.efforts ?? [];
  const modelList = (): YorozuEvent =>
    control({ kind: "model_list", data: { models: modelsFor("yorozu"), agentModels } });

  for (const agent of ["claude-code", "codex"] as const) {
    void nativeRunners[agent]?.models?.().then((models) => {
      agentModels[agent] = models;
      if (!stopped) broadcast(modelList());
    }).catch(() => state(`native-model-list-unavailable ${agent}`));
  }

  /**
   * Where a coding agent's thread can be started. Sent with the thread list, like the models:
   * the picker is one tap from the agent choice, and asking then would draw an empty list first.
   */
  const projectList = (): YorozuEvent => control({ kind: "project_list", data: { projects: listProjects(undefined, dir) } });

  let openclawModels: ModelOption[] = [];
  /** Asked again on every `thread_list`, so a provider added to OpenClaw shows up without a relaunch. */
  const refreshModels = (): void => {
    void openclaw?.listModels().then((models) => {
      if (JSON.stringify(models) === JSON.stringify(openclawModels)) return;
      openclawModels = models;
      broadcast(modelList());
    }).catch((error: unknown) => state(`model-list-error ${String(error)}`));
  };
  refreshModels();

  /**
   * Every device this Mac answers, the local socket's clients included: the Mac app is one more
   * paired device, it just reached us without the relay.
   */
  const deviceList = (): YorozuEvent => {
    const now = Date.now();
    const paired: DeviceInfo[] = [...devices.values()].map(({ record }) => ({
      pub: record.pub,
      ...(record.signingPub ? { signingPub: record.signingPub } : {}),
      ...(record.name ? { name: record.name } : {}),
      via: "relay",
      lastSeen: record.lastSeen,
      online: now - record.lastSeen < ONLINE_MS,
    }));
    const here: DeviceInfo[] = [...locals.keys()].map((device) => ({
      pub: device,
      via: "local",
      lastSeen: now,
      online: true,
    }));
    return control({ kind: "device_list", data: { devices: [...paired, ...here] } });
  };

  /** A device joined, left or was revoked: everyone's list is stale, so everyone gets a new one. */
  const pushDevices = (): void => broadcast(deviceList());

  /** Forgets a device here and at the relay. Unknown keys are a no-op, not an error. */
  const forgetDevice = (pub: string): void => {
    const known = devices.get(pub);
    if (!known) return;
    catchupSends.delete(pub);
    activeSearchRequests.delete(pub);
    devices.delete(pub);
    saveDevices();
    if (known.record.signingPub) revokeAtRelay(known.record.signingPub);
    state("revoked");
    pushDevices();
  };

  /** A bounded replay page. An explicit thread request includes its pre-pairing history. */
  const syncDelta = (lastSeen: Record<string, string>, pairedAt = 0, threadId?: string,
    includeApprovalStatus = true, focusThreadId?: string, includeCurrent = true,
    replayBytes = SYNC_PAGE_BYTES, replayEvents = SYNC_LIMIT, phoneCanDownload: boolean | null = null): YorozuEvent[] => {
    const events: YorozuEvent[] = [];
    const cards: YorozuEvent[] = [];
    const selected = listThreads(dir).filter((thread) => threadId ? thread.id === threadId : !thread.archived);
    const focused = !threadId && selected.find((thread) => thread.id === focusThreadId);
    if (focused) {
      selected.splice(selected.indexOf(focused), 1);
      selected.unshift(focused);
    }
    let latest: YorozuEvent | undefined;
    if (focused && includeCurrent) {
      const history = readThreadEvents(focused.id, dir).filter((event) => event.ts >= pairedAt);
      const live = running.has(focused.id) ? liveReplies.get(focused.id) : undefined;
      const reply = live && live.ts >= pairedAt ? live : undefined;
      latest = reply ?? history.findLast((event) =>
        event.kind === "message" && event.data.role === "agent" && !event.parentAgentId);
      if (running.has(focused.id)) {
        const answered = new Set(history.flatMap((event) => event.kind === "approval_answer" ? [event.data.actionId]
          : event.kind === "approval_status" && event.data.status !== "rejected" ? [event.data.actionId]
          : event.kind === "question_answer" ? [event.data.questionId] : []));
        cards.push(...history.filter((event) => event.kind === "approval_card"
          ? !answered.has(event.data.actionId) &&
              (pending.get(event.data.actionId)?.threadId === focused.id || nativeCards.has(event.data.actionId, focused.id))
          : event.kind === "question_card" && !answered.has(event.data.questionId) &&
              questions.has(event.data.questionId, focused.id)));
      }
    }
    // Keep active cards ahead of the current reply and historical replay within a bounded frame.
    const current: YorozuEvent[] = [];
    let currentBytes = 2; // []
    const deferredCards: YorozuEvent[] = [];
    for (const card of cards) {
      const size = Buffer.byteLength(JSON.stringify(card)) + (current.length ? 1 : 0);
      if (currentBytes + size <= SYNC_PAGE_BYTES / 2) {
        current.push(card);
        currentBytes += size;
      } else deferredCards.push(card);
    }
    if (latest) {
      const size = Buffer.byteLength(JSON.stringify(latest)) + (current.length ? 1 : 0);
      if (currentBytes + size <= SYNC_PAGE_BYTES / 2) {
        current.push(latest);
        currentBytes += size;
      }
    }
    let bytes = currentBytes;
    let more = false;
    threads: for (const thread of selected) {
      const page = eventsAfter(thread.id, lastSeen?.[thread.id], dir, threadId ? 0 : pairedAt,
        (event) => includeApprovalStatus || event.kind !== "approval_status");
      if (page.length === SYNC_LIMIT) more = true;
      for (const stored of page) {
        const event = phoneCanDownload === null ? stored : phoneTrace(stored, phoneCanDownload);
        const size = Buffer.byteLength(JSON.stringify(event));
        if (events.length >= replayEvents ||
          ((events.length > 0 || current.length > 0) && bytes + size > replayBytes)) {
          more = true;
          break threads;
        }
        events.push(event);
        bytes += size;
      }
    }
    return [...deferredCards, control({
      kind: "sync_delta",
      data: { events, ...(current.length ? { current } : {}), workingThreadIds: [...running.keys()],
        ...(threadId ? { threadId } : {}), ...(more ? { more: true } : {}) },
    })];
  };

  /**
   * One agent turn in `threadId`, however it was started — a phone message or a due job —
   * with its reply emitted to the phone the same way either way.
   */
  /** Deliberately not awaited: titling runs alongside the turn and must never delay a reply. */
  const title = (threadId: string, opening: string): void => {
    void autoTitle(threadId, opening, titler, dir)
      .then((changed) => { if (changed) broadcast(threadList()); })
      .catch((e: unknown) => state(`title-error ${String(e)}`));
  };

  const completionIdFor = (threadId: string, userEventId: string): string =>
    `${threadAgent(threadId, dir) === "yorozu" ? openclaw ? "openclaw" : "legacy" : "native"}:${userEventId}:final`;

  const nativeRecoveryPrompt = (threadId: string, original: string): string => {
    const recent = readThreadEvents(threadId, dir).filter((event) =>
      event.kind === "message" || event.kind === "tool_call" || event.kind === "tool_result").slice(-20).map((event) => {
      if (event.kind === "message") return `${event.data.role}: ${event.data.text.slice(0, 2_000)}`;
      if (event.kind === "tool_call") return `tool call ${event.data.name}: ${JSON.stringify(event.data.args).slice(0, 2_000)}`;
      return `tool result ${event.data.callId}: ${event.data.output.slice(0, 2_000)}`;
    }).join("\n").slice(-12_000);
    return `Resume the interrupted task. Verify prior actions and their outcomes before repeating any external effect. ` +
      `Continue unfinished work and answer the original request.\nOriginal request: ${original}\nRecent host record:\n${recent}`;
  };

  const withStoppedContext = (threadId: string, original: string, userEventId?: string): string => {
    const messages = readThreadEvents(threadId, dir).filter((event) => event.kind === "message");
    const index = userEventId ? messages.findIndex((event) => event.id === userEventId) : -1;
    const prior = index > 0 ? messages[index - 1] : index < 0 ? messages.at(-1) : undefined;
    if (prior?.kind !== "message") return original;
    const stop = prior.data.role === "user" ? stoppedTurns.get(prior.id) : undefined;
    const partial = prior.data.role === "agent" && prior.data.interrupted ? prior.data.text
      : stop?.status === "requested" || stop?.status === "stopped" ? stop.partialText ?? "" : undefined;
    if (partial === undefined) return original;
    const excerpt = partial.slice(-4_000);
    return `Previous reply was stopped or has a pending Stop request. Its partial text may be absent from your session context. ` +
      `Do not repeat actions without checking their outcomes. Partial reply: ${JSON.stringify(excerpt || "(none)")}\n\nNew user request: ${original}`;
  };

  async function runTurn(
    threadId: string,
    text: string,
    recorded = false,
    attachments: MessageAttachment[] = [],
    userEventId?: string,
  ): Promise<void> {
    liveReplies.delete(threadId);
    partials.delete(threadId);
    // A turn the phone did not send — a due job, a background delegation — is still part of
    // the thread, so it is recorded as the user message it stands in for.
    if (!recorded) {
      userEventId = randomUUID();
      appendThreadEvent(
        {
          id: userEventId,
          threadId,
          ts: Date.now(),
          agentId: MAIN_AGENT,
          kind: "message",
          data: { role: "user", text },
        },
        dir,
      );
    }

    // Started before the agent is, so the title lands while it is still working.
    title(threadId, text);

    // The reply streams under one id: every delta re-sends the whole text so far, so the phone
    // replaces that message in place and a dropped frame still converges. Only the finished
    // reply goes through `emit`, so the transcript keeps one line per turn rather than one
    // per delta.
    const agent = threadAgent(threadId, dir);
    const id = userEventId ? completionIdFor(threadId, userEventId) : randomUUID();
    // `done` on the finished one only: it is what tells a phone the turn is over, so its
    // composer can stop offering Stop. The deltas under the same id leave it unset.
    const message = (reply: string, done = false, failed = false): YorozuEvent => ({
      id,
      threadId,
      ts: Date.now(),
      agentId: MAIN_AGENT,
      kind: "message",
      data: { role: "agent", text: reply, ...(done ? { done: true } : {}), ...(failed ? { failed: true } : {}) },
    });

    // A native agent's thread is answered by that agent alone: its own session, in the
    // thread's folder, with its own tools. Yorozu's dispatch and approval gate are not here.
    if (agent !== "yorozu") {
      const runner = nativeRunners[agent];
      const finish = (reply: string, failed = false): void => {
        const final = message(reply, true, failed);
        appendTranscript(final, transcripts);
        appendThreadEvent(final, dir);
        broadcast(final);
      };
      // Finished, so the composer is not left offering Stop for a turn nobody is running.
      if (!runner) {
        finish(`${agent} is not available in this build yet.`, true);
        setNativeTurn(threadId, undefined, dir);
        broadcast(threadList());
        return;
      }
      // No folder, no agent: a thread from before folders were required, or one whose folder
      // has since left `~/Projects`, would otherwise run the agent wherever this sidecar sits.
      const home = threadHome(threadId, dir);
      if (!home.cwd || !isProjectFolder(home.cwd)) {
        state("native-cwd-refused");
        finish(`${agent} needs one of this Mac's project folders, and this thread has none.`, true);
        setNativeTurn(threadId, undefined, dir);
        broadcast(threadList());
        return;
      }
      const turn = new AbortController();
      if (!running.has(threadId)) running.set(threadId, turn);
      if (userEventId) runningEventIds.set(threadId, userEventId);
      const previous = listThreads(dir).find((thread) => thread.id === threadId)?.nativeTurn;
      let recoveryAttempts = previous?.userEventId === userEventId ? previous?.recoveryAttempts ?? 0 : 0;
      let recovering = previous?.state === "interrupted" && previous.userEventId === userEventId;
      let paused = false;
      const seenResults = new Set(readThreadEvents(threadId, dir).filter((event) => event.kind === "tool_result").map((event) => event.id));
      try {
        while (!turn.signal.aborted) {
          if (recovering) recoveryAttempts += 1;
          setNativeTurn(threadId, { id, state: "running", ...(userEventId ? { userEventId } : {}), recoveryAttempts,
            recoveryActive: recovering }, dir);
          broadcast(threadList());
          let executionStarted = false;
          try {
            const currentHome = threadHome(threadId, dir);
            const done = await runner.run({
              threadId,
              text: recovering ? nativeRecoveryPrompt(threadId, text) : withStoppedContext(threadId, text, userEventId),
              ...currentHome,
              cwd: home.cwd,
              bypass: loadSettings(dir).yolo,
              model: threadModel(threadId, dir),
              effort: threadEffort(threadId, dir),
              signal: turn.signal,
              onSession: (sessionId) => { executionStarted = true; setThreadSession(threadId, sessionId, dir); },
              approve: async (tool, input, signal) =>
                loadSettings(dir).yolo || nativeCards.approve(threadId, agent, tool, input, signal),
              ask: (question, options, signal) => nativeCards.ask(threadId, question, options, signal),
              onUpdate: (reply) => { if (!turn.signal.aborted) { executionStarted = true; broadcast(message(reply)); } },
              onActivity: (key, payload) => {
                executionStarted = true;
                const event: YorozuEvent = { id: `${agent}:${threadId}:${key}`, threadId, ts: Date.now(), agentId: MAIN_AGENT, ...payload };
                const newResult = event.kind === "tool_result" && event.data.ok && !seenResults.has(event.id);
                emit(event.kind === "tool_result" ? stashToolResult(event, dir) : event);
                if (newResult) {
                  seenResults.add(event.id);
                  recoveryAttempts = 0;
                  setNativeTurn(threadId, { id, state: "running", ...(userEventId ? { userEventId } : {}), recoveryAttempts,
                    recoveryActive: recovering }, dir);
                }
              },
            });
            if (done.sessionId && done.sessionId !== currentHome.sessionId) setThreadSession(threadId, done.sessionId, dir);
            if (turn.signal.aborted) return;
            if (done.failed) throw new Error(`${agent} reported an unsuccessful turn`);
            finish(done.text);
            return;
          } catch (error) {
            if (turn.signal.aborted) return;
            state(`native-error ${error instanceof Error ? error.message : String(error)}`);
            process.stderr.write(`native-error ${threadId}: ${error instanceof Error ? error.stack ?? error.message : String(error)}\n`);
            if (!recovering && !executionStarted) {
              finish(`${agent} could not answer; see the Mac log.`, true);
              return;
            }
            if (recoveryAttempts >= 3) {
              paused = true;
              setNativeTurn(threadId, { id, state: "interrupted", ...(userEventId ? { userEventId } : {}), recoveryAttempts }, dir);
              emit({ id: randomUUID(), threadId, ts: Date.now(), agentId: MAIN_AGENT, kind: "message",
                data: { role: "agent", text: `${agent} could not recover automatically. Retry to continue.`,
                  done: true, failed: true } });
              broadcast(threadList());
              return;
            }
            recovering = true;
          }
        }
      } finally {
        if (running.get(threadId) === turn) running.delete(threadId);
        if (runningEventIds.get(threadId) === userEventId) runningEventIds.delete(threadId);
        const stop = userEventId ? stoppedTurns.get(userEventId) : undefined;
        if (stop) completeStop(stop);
        if (!stopped && !paused) {
          setNativeTurn(threadId, undefined, dir);
          broadcast(threadList());
        }
      }
      return;
    }

    if (openclaw) {
      const turn = new AbortController();
      let failed = false;
      if (!running.has(threadId)) running.set(threadId, turn);
      if (userEventId) runningEventIds.set(threadId, userEventId);
      broadcastActiveThreadList();
      try {
        const prompt = withStoppedContext(threadId, text, userEventId);
        const reply = await openclaw.run({
          threadId,
          text,
          ...(prompt !== text ? { promptOverride: prompt } : {}),
          model: threadModel(threadId, dir),
          effort: threadEffort(threadId, dir),
          attachments,
          signal: turn.signal,
          completionId: id,
          userEventId,
          onUpdate: (reply) => { if (!turn.signal.aborted) broadcast(message(reply)); },
          onEvent: emit,
          onRecoveryState: () => broadcast(threadList()),
          onFailure: () => { failed = true; },
        });
        if (turn.signal.aborted) return;
        if (reply === undefined) return;
        const final = message(reply, true, failed);
        finalizeOpenClaw(final);
      } finally {
        if (running.get(threadId) === turn) running.delete(threadId);
        if (runningEventIds.get(threadId) === userEventId) runningEventIds.delete(threadId);
        broadcastActiveThreadList();
        const settlement = turn.signal.aborted && userEventId ? stopSettlements.get(userEventId) : undefined;
        if (settlement) {
          await settlement.promise;
          stopSettlements.delete(userEventId!);
        }
      }
      return;
    }
    if (!provider) throw new Error("no execution backend");

    const turn = new AbortController();
    if (!running.has(threadId)) running.set(threadId, turn);
    if (userEventId) runningEventIds.set(threadId, userEventId);
    broadcastActiveThreadList();
    try {
      const backend = await legacyReady;
      if (!backend || stopped || turn.signal.aborted) return;
      await backend.run(threadId, turn.signal,
        (text) => broadcast(message(text)), (text) => emit(message(text, true)));
    } finally {
      if (running.get(threadId) === turn) running.delete(threadId);
      if (runningEventIds.get(threadId) === userEventId) runningEventIds.delete(threadId);
      const stop = userEventId ? stoppedTurns.get(userEventId) : undefined;
      if (stop) completeStop(stop);
      broadcastActiveThreadList();
    }
  }

  /** Same-thread turns are FIFO. Different threads still run concurrently. */
  function enqueueTurn(
    threadId: string,
    text: string,
    recorded = false,
    attachments: MessageAttachment[] = [],
    userEventId?: string,
    acceptedEvent?: YorozuEvent,
  ): Promise<void> {
    if (userEventId && stoppedTurns.has(userEventId)) {
      openclaw?.discardPending(userEventId);
      return Promise.resolve();
    }
    if (updateGate.status.phase === "installing") return Promise.reject(new Error("Mac is installing an update"));
    updateGate.activity();
    let deferredEvent: YorozuEvent & { kind: "message" } | undefined;
    if (viaOpenClaw(threadId)) {
      userEventId ??= randomUUID();
      const event: YorozuEvent & { kind: "message" } = acceptedEvent?.kind === "message" ? acceptedEvent
        : { id: userEventId, threadId, ts: Date.now(), agentId: MAIN_AGENT,
        kind: "message" as const, data: { role: "user" as const, text, ...(attachments.length ? { attachments } : {}) } };
      const deferLog = [...stoppedTurns.values()].some((stop) => stop.threadId === threadId && stop.status === "requested");
      const stored = openclaw!.admitUserTurn({ threadId, text, model: threadModel(threadId, dir),
        effort: threadEffort(threadId, dir), attachments, userEventId, identity: userMessageIdentity(event),
        eventTs: event.ts, admissionDeadline: event.data.admissionDeadline,
        completionId: `openclaw:` + userEventId + `:final` }, (admission) => {
        const logged = admission ? { ...event, data: { ...event.data,
          runId: admission.runId, completionId: admission.completionId } } : event;
        if (deferLog) deferredEvent = logged;
        else {
          if (!readTranscripts(new Date(0), transcripts).some((known) => known.id === event.id)) appendTranscript(logged, transcripts);
          if (!readThreadEvents(threadId, dir).some((known) => known.id === event.id)) appendThreadEvent(logged, dir);
        }
      }, () => readThreadEvents(threadId, dir).some((known) => known.id === event.id));
      if (!stored) return Promise.resolve();
      text = stored.input.text;
      attachments = stored.input.attachments;
      recorded = true;
    }
    const admitted = userEventId ? admittedTurns.get(userEventId) : undefined;
    if (admitted) return admitted;
    const previous = turnQueues.get(threadId) ?? Promise.resolve();
    const next = previous.catch(() => {}).then(async () => {
      if (stopped) return;
      if (userEventId && stoppedTurns.has(userEventId)) {
        openclaw?.discardPending(userEventId);
        return;
      }
      const logged = deferredEvent;
      if (logged) {
        // The device admitted this message before Stop settled. Give its durable copy the
        // preceding final's timestamp so live and restored timelines show the same order.
        const prior = readThreadEvents(threadId, dir);
        const ordered = { ...logged, ts: (prior.at(-1)?.ts ?? Date.now()) + 1,
          clientTs: logged.ts };
        if (!readTranscripts(new Date(0), transcripts).some((known) => known.id === logged.id)) appendTranscript(ordered, transcripts);
        if (!prior.some((known) => known.id === logged.id)) appendThreadEvent(ordered, dir);
        broadcast(ordered);
      }
      if (userEventId) activeTurnIds.add(userEventId);
      try { await runTurn(threadId, text, recorded, attachments, userEventId); }
      finally { if (userEventId) activeTurnIds.delete(userEventId); }
    });
    turnQueues.set(threadId, next);
    if (userEventId) admittedTurns.set(userEventId, next);
    void next.finally(() => {
      if (turnQueues.get(threadId) === next) turnQueues.delete(threadId);
      if (userEventId && admittedTurns.get(userEventId) === next) admittedTurns.delete(userEventId);
    }).catch(() => {});
    return next;
  }

  function resumeNativeTurn(threadId: string, retry = false): boolean {
    const marker = listThreads(dir).find((thread) => thread.id === threadId)?.nativeTurn;
    if (marker?.state !== "interrupted" || !marker.userEventId || nativeRecoveryStarted.has(threadId) ||
      stoppedTurns.has(marker.userEventId) || (!retry && (marker.recoveryAttempts ?? 0) >= 3)) return false;
    const original = readThreadEvents(threadId, dir).find((event) => event.id === marker.userEventId &&
      event.kind === "message" && event.data.role === "user");
    if (original?.kind !== "message") return false;
    if (retry) setNativeTurn(threadId, { ...marker, recoveryAttempts: 0 }, dir);
    nativeRecoveryStarted.add(threadId);
    // A paused turn can receive Retry before its first worker's finally callback clears this
    // in-memory id. The next attempt still queues behind that worker for the same thread.
    admittedTurns.delete(marker.userEventId);
    const recovery = enqueueTurn(threadId, original.data.text, true, original.data.attachments ?? [], marker.userEventId);
    void recovery.finally(() => nativeRecoveryStarted.delete(threadId)).catch(() => {});
    return true;
  }

  /**
   * One event from a paired device, however it reached us — a sealed relay frame or a line on
   * the local socket. `reply` answers that one device; the thread admin cases answer all of
   * them, so a second device sees the same list.
   */
  const archiveUpdates = new Map<string, Promise<void>>();
  const stopAttempts = new Set<string>();
  const stopSettlements = new Map<string, ReturnType<typeof Promise.withResolvers<void>>>();
  const stopRetries = new Map<string, ReturnType<typeof setTimeout>>();

  const stopStatus = (record: StopRecord, requestId: string): YorozuEvent => ({
    ...control({ kind: "stop_status", data: { targetEventId: record.targetEventId, requestId, status: record.status } }),
    threadId: record.threadId,
  });
  const broadcastStop = (record: StopRecord): void => {
    for (const id of stoppedTurns.get(record.targetEventId)?.requestIds ?? record.requestIds) broadcast(stopStatus(record, id));
  };
  const persistStoppedReply = (record: StopRecord, text = record.partialText ?? ""): void => {
    const id = completionIdFor(record.threadId, record.targetEventId);
    if (readThreadEvents(record.threadId, dir).some((event) => event.id === id && event.kind === "message" && event.data.done)) return;
    const final: YorozuEvent = { id, threadId: record.threadId, ts: Date.now(), agentId: MAIN_AGENT,
      kind: "message", data: { role: "agent", text, done: true, interrupted: true } };
    if (record.runId && record.sessionKey) finalizeOpenClaw(final);
    else emit(final);
  };
  function completeStop(record: StopRecord): void {
    if (record.status !== "requested") return;
    persistStoppedReply(record);
    const finished = { ...record, status: "stopped" as const };
    rememberStop(finished);
    broadcastStop(finished);
  }

  const abortTarget = (threadId: string, target: string): boolean => {
    if (runningEventIds.get(threadId) !== target) return false;
    running.get(threadId)?.abort();
    for (const card of [...pending.values()]) if (card.threadId === threadId) card.settle({ answer: "no" }, "cancelled");
    questions.cancelAll(threadId);
    return true;
  };

  const finishStop = (record: StopRecord): void => {
    if (record.status !== "requested" || stopAttempts.has(record.targetEventId)) return;
    const target = record.targetEventId;
    if (!record.runId || !record.sessionKey) {
      const active = abortTarget(record.threadId, target);
      if (!active) {
        const nativeTurn = listThreads(dir).find((thread) => thread.id === record.threadId)?.nativeTurn;
        if (nativeTurn?.id === completionIdFor(record.threadId, target) && nativeTurn.state === "interrupted") {
          // The old SDK process is gone, but its last external effect is unknowable here.
          // Stop recovery without claiming confirmed cessation.
          rememberStop({ ...record, status: "unconfirmed" });
          setNativeTurn(record.threadId, undefined, dir);
          broadcast(threadList());
          broadcastStop(stoppedTurns.get(target)!);
          return;
        }
        openclaw?.discardPending(target);
        persistStoppedReply(record);
        rememberStop({ ...record, status: "stopped" });
        broadcastStop(stoppedTurns.get(target)!);
      }
      return;
    }
    stopAttempts.add(target);
    // Hold the thread's FIFO queue until Gateway confirms this exact run has ended.
    const settlement = stopSettlements.get(target) ?? Promise.withResolvers<void>();
    stopSettlements.set(target, settlement);
    abortTarget(record.threadId, target);
    void openclaw!.stopRun(record.sessionKey, record.runId).then((outcome) => {
      if (!outcome) return;
      if (outcome.status === "completed") {
        finalizeOpenClaw({ id: completionIdFor(record.threadId, target), threadId: record.threadId,
          ts: Date.now(), agentId: MAIN_AGENT, kind: "message",
          data: { role: "agent", text: outcome.text ?? "", done: true, ...(outcome.failed ? { failed: true } : {}) } });
      } else {
        if (outcome.status === "stopped") persistStoppedReply(record, outcome.text ?? record.partialText ?? "");
        openclaw!.discardPending(target);
      }
      rememberStop({ ...record, status: outcome.status });
      broadcastStop(stoppedTurns.get(target)!);
      settlement.resolve();
      if (!admittedTurns.has(target)) stopSettlements.delete(target);
    }).catch((error: unknown) => state(`stop-error ${String(error)}`)).finally(() => {
      stopAttempts.delete(target);
      if (!stopped && stoppedTurns.get(target)?.status === "requested" && !stopRetries.has(target)) {
        const retry = setTimeout(() => {
          stopRetries.delete(target);
          const current = stoppedTurns.get(target);
          if (current?.status === "requested") finishStop(current);
        }, 1_000);
        retry.unref();
        stopRetries.set(target, retry);
      }
    });
  };

  function updateArchive(event: YorozuEvent & { kind: "thread_archive" }, reply: Send): void {
    const threadId = event.threadId;
    const archived = event.data.archived ?? true;
    if (!viaOpenClaw(threadId)) {
      archiveThread(threadId, dir, archived);
      return broadcast(threadList());
    }
    // A restore may arrive while Gateway is still draining an archive. Preserve client order
    // and publish only committed state, so the two backends cannot finish in opposite states.
    const previous = archiveUpdates.get(threadId) ?? Promise.resolve();
    const update = previous.then(async () => {
      if (!listThreads(dir).some((thread) => thread.id === threadId)) return;
      try {
        await openclaw!.setArchived(threadId, archived);
        archiveThread(threadId, dir, archived);
      } catch (error) {
        state(`archive-error ${String(error)}`);
        reply({
          id: randomUUID(), threadId, ts: Date.now(), agentId: MAIN_AGENT,
          kind: "thought", data: { text: `Could not ${archived ? "archive" : "restore"} this thread. Please retry.` },
        });
      }
      broadcast(threadList());
    }).finally(() => {
      if (archiveUpdates.get(threadId) === update) archiveUpdates.delete(threadId);
    });
    archiveUpdates.set(threadId, update);
  }

  /**
   * Ids of the last commands taken from devices. The relay replays a buffered frame to every
   * registration until it is acked, and a phone re-sends anything it holds no receipt for; the
   * second copy of a command must not apply twice — a `rule_update` restoring a rule since
   * revoked, a `thread_archive` undoing an unarchive. Messages are also checked against the
   * thread log, which outlives a restart; for the rest this window is what there is.
   *
   * The seq inside every box catches a replayed frame first; this catches the same command
   * re-sent under a fresh seq, which is what a phone's outbox does.
   */
  const seenCommands = new Set<string>();
  const SEEN_COMMANDS = 2_000;
  // Thread logs outlive the dedup window. Rebuild this compact index at startup so a completed
  // turn's ID cannot be reused in another thread after its OpenClaw admission row is removed.
  const acceptedMessages = new Map<string, string>();
  for (const thread of listThreads(dir)) {
    for (const known of readThreadEvents(thread.id, dir)) {
      if (known.kind !== "message" || known.data.role !== "user") continue;
      const identity = userMessageIdentity(known);
      const previous = acceptedMessages.get(known.id);
      if (previous && previous !== identity) throw new Error(`conflicting stored user event ID ${known.id}`);
      acceptedMessages.set(known.id, identity);
    }
  }
  const alreadySeen = (id: string): boolean => {
    if (seenCommands.has(id)) return true;
    seenCommands.add(id);
    if (seenCommands.size > SEEN_COMMANDS) {
      const [oldest] = seenCommands;
      seenCommands.delete(oldest!);
    }
    return false;
  };

  /** The current YOLO state as every device is told it: on carries the moment it ends. */
  const approvalSettingsEvent = (extra: { pending?: true } = {}): YorozuEvent => {
    const { yolo, yoloUntil } = loadSettings(dir);
    return control({ kind: "approval_settings", data: { yolo, ...(yolo && yoloUntil ? { yoloUntil } : {}), ...extra } });
  };

  /**
   * YOLO is never on for good. One timer flips it off when the stored grant ends, armed here
   * whenever the grant changes and again at start, so a relaunch keeps the clock.
   */
  let yoloTimer: NodeJS.Timeout | null = null;
  const armYoloExpiry = (): void => {
    if (yoloTimer) clearTimeout(yoloTimer);
    yoloTimer = null;
    const { yolo, yoloUntil } = loadSettings(dir);
    if (!yolo || yoloUntil === undefined) return;
    yoloTimer = setTimeout(() => {
      yoloTimer = null;
      if (!stopped) setYolo(false);
    }, Math.max(0, yoloUntil - Date.now()));
    yoloTimer.unref();
  };

  /** Turns YOLO on for `hours` (default 8, capped at 24) or off now, and tells every device. */
  const setYolo = (on: boolean, hours?: number): void => {
    const { yoloUntil: _stale, ...settings } = loadSettings(dir);
    saveSettings(on ? { ...settings, yolo: true, yoloUntil: yoloExpiry(hours) } : { ...settings, yolo: false }, dir);
    armYoloExpiry();
    // A turn started before YOLO should not keep waiting on cards YOLO would never have raised.
    if (on) {
      nativeCards.approveAll();
      for (const [actionId, card] of [...pending]) {
        if (card.floored) continue;
        emit({ id: randomUUID(), threadId: card.threadId, ts: Date.now(), agentId: MAIN_AGENT,
          kind: "approval_answer", data: { actionId, answer: "yes" } });
        card.settle({ answer: "yes" });
      }
    }
    broadcast(threadList());
    broadcast(approvalSettingsEvent());
  };
  armYoloExpiry();

  const stillActionable = (event: YorozuEvent): boolean => event.kind === "approval_card"
    ? pending.get(event.data.actionId)?.threadId === event.threadId ||
      nativeCards.has(event.data.actionId, event.threadId)
    : event.kind === "question_card"
      ? questions.has(event.data.questionId, event.threadId)
      : true;

  /** One catch-up frame per tick; rotate phones and replace obsolete requests per phone. */
  const sendCatchup = (): void => {
    catchupTimer = null;
    const entry = catchupSends.entries().next().value;
    if (!entry) return;
    const [pub, job] = entry;
    catchupSends.delete(pub);
    if (!stopped && relayReady && socket === job.connection && job.connection?.readyState === WebSocket.OPEN &&
      devices.get(pub) === job.device) {
      if (job.connection.bufferedAmount > 512 * 1024) {
        catchupSends.set(pub, job);
        catchupTimer = setTimeout(sendCatchup, 100);
        catchupTimer.unref();
        return;
      }
      while (job.next < job.responses.length) {
        const response = job.responses[job.next++]!;
        if (!stillActionable(response)) continue;
        const fresh = response.kind === "sync_delta" && response.data.current
          ? { ...response, data: { ...response.data, current: response.data.current.filter(stillActionable) } }
          : response;
        try { sendTo(pub, fresh); }
        catch (error) {
          state(`catchup-send-error ${String(error)}`);
          job.connection?.close();
          return;
        }
        nextCatchupAt = Date.now() + 100;
        break;
      }
      if (job.next < job.responses.length) catchupSends.set(pub, job);
    }
    if (catchupSends.size) {
      catchupTimer = setTimeout(sendCatchup, Math.max(0, nextCatchupAt - Date.now()));
      catchupTimer.unref();
    }
  };

  /**
   * `from` names the relay device a sealed box came from. Absent for the local socket, whose
   * clients are this Mac's own user: that difference is what decides whether turning YOLO on
   * is a command or a request.
   */
  const activeSearchRequests = new Map<string, string>();
  const downloadFiles = new Map<string, { bytes: Buffer; sha256: string }>();
  let downloadCacheBytes = 0;
  function handleEvent(event: YorozuEvent, reply: Send, pairedAt = 0, from?: string, localDevice?: string): void {
    if (event.kind === "attachment_progress" || event.kind === "attachment_download_chunk") return;
    if (event.kind === "attachment_download_request") {
      const compatibility = from ? devices.get(from)?.compatibility : undefined;
      if (from && (compatibility?.state !== "compatible" ||
          !compatibility.capabilities.includes("attachment-chunks-v1"))) return;
      const { messageId, index, offset } = event.data;
      if (typeof messageId !== "string" || !messageId || messageId.length > 128 ||
          !Number.isSafeInteger(index) || index < 0 || index >= 10 ||
          !Number.isSafeInteger(offset) || offset < 0 || offset > 5 * 1024 * 1024 ||
          typeof event.threadId !== "string" || !event.threadId || event.threadId.length > 128) return;
      const unavailable = (): void => reply({ ...control({ kind: "attachment_download_chunk", data: {
        messageId, index, offset, totalBytes: 0, data: "", sha256: "", reason: "attachment-unavailable",
      } }), threadId: event.threadId });
      const key = `${event.threadId}\0${messageId}\0${index}`;
      let file = downloadFiles.get(key);
      if (!file) {
        const stored = readThreadEvents(event.threadId, dir).find((item) =>
          item.kind === "message" && item.id === messageId);
        if (stored?.kind !== "message") return unavailable();
        const attachment = stored.data.attachments?.[index];
        if (!attachment) return unavailable();
        const bytes = Buffer.from(attachment.data, "base64");
        if (bytes.length > 5 * 1024 * 1024) return unavailable();
        file = { bytes, sha256: createHash("sha256").update(bytes).digest("hex") };
        downloadFiles.set(key, file);
        downloadCacheBytes += bytes.length;
        while (downloadCacheBytes > 20 * 1024 * 1024) {
          const oldest = downloadFiles.keys().next().value;
          if (!oldest) break;
          downloadCacheBytes -= downloadFiles.get(oldest)!.bytes.length;
          downloadFiles.delete(oldest);
        }
      } else {
        downloadFiles.delete(key);
        downloadFiles.set(key, file);
      }
      if (offset > file.bytes.length) return unavailable();
      reply({ ...control({ kind: "attachment_download_chunk", data: { messageId, index, offset,
        totalBytes: file.bytes.length, data: file.bytes.subarray(offset, offset + 256 * 1024).toString("base64"),
        sha256: file.sha256 } }), threadId: event.threadId });
      return;
    }
    if (event.kind === "attachment_chunk" || event.kind === "attachment_commit") {
      const compatibility = from ? devices.get(from)?.compatibility : undefined;
      if (from && (compatibility?.state !== "compatible" ||
          !compatibility.capabilities.includes("attachment-chunks-v1"))) return;
      // A local socket gets a new connection ID after reconnect; the device identity does not.
      const source = from ?? `local:${event.agentId}`;
      if (event.kind === "attachment_chunk") {
        if (typeof event.data !== "object" || event.data === null) return;
        void attachmentUploads.chunk(source, event.threadId, event.data).then((progress) => {
          reply(control({ kind: "attachment_progress", data: {
            requestId: event.id, messageId: event.data.messageId, index: event.data.index, ...progress,
          } }));
        });
      } else {
        if (typeof event.data !== "object" || event.data === null ||
            typeof event.data.text !== "string" || Buffer.byteLength(event.data.text) > 256 * 1024 ||
            !Number.isSafeInteger(event.ts) || !Number.isSafeInteger(event.data.admissionDeadline) ||
            event.data.admissionDeadline !== event.ts + ADMISSION_LIFE_MS) {
          reply(control({ kind: "admission_status", data: {
            eventId: event.id, status: "rejected", reason: "invalid-attachment-commit",
          } }));
          return;
        }
        const assemblyKey = `${source}\0${event.id}`;
        if (assemblingAttachments.has(assemblyKey)) return;
        if (assemblingAttachments.size >= 8) {
          reply(control({ kind: "attachment_progress", data: {
            requestId: event.id, messageId: event.id, index: 0, nextOffset: 0,
            reason: "attachment-busy",
          } }));
          return;
        }
        assemblingAttachments.add(assemblyKey);
        const assembled = assemblyTail.then(() => attachmentUploads.assemble(source, event.id, event.threadId,
          event.data.attachments, event.data.admissionDeadline));
        assemblyTail = assembled.then(() => {}, () => {});
        void assembled.then((result) => {
          if (result.reason) {
            reply(control({ kind: "admission_status", data: { eventId: event.id, status: "rejected", reason: result.reason } }));
          } else if (result.missing) {
            reply(control({ kind: "attachment_progress", data: {
              requestId: event.id, messageId: event.id, ...result.missing,
            } }));
          } else if (result.attachments) {
            handleEvent({ ...event, kind: "message", data: { role: "user", text: event.data.text,
              attachments: result.attachments, admissionDeadline: event.data.admissionDeadline } },
              reply, pairedAt, from, localDevice);
          }
        }).catch((error) => state(`attachment-commit-error ${String(error)}`))
          .finally(() => assemblingAttachments.delete(assemblyKey));
      }
      return;
    }
    if (event.kind === "thread_search_result") return;
    if (event.kind === "thread_search_request") {
      const { requestId, query, offset = 0, lineOffset = 0 } = event.data;
      const compatibility = from ? devices.get(from)?.compatibility : undefined;
      if (from && (compatibility?.state !== "compatible" ||
          !compatibility.capabilities.includes("thread-search-v1"))) return;
      if (typeof requestId !== "string" || !requestId || requestId.length > 128 ||
          typeof query !== "string" || !query.trim() || Buffer.byteLength(query) > 128 ||
          !Number.isSafeInteger(offset) || offset < 0 ||
          !Number.isSafeInteger(lineOffset) || lineOffset < 0) return;
      const source = from ?? localDevice ?? "local";
      if ((offset > 0 || lineOffset > 0) && activeSearchRequests.get(source) !== requestId) return;
      activeSearchRequests.set(source, requestId);
      void searchThreadPage(query, offset, dir, () => activeSearchRequests.get(source) === requestId, lineOffset)
        .then((page) => {
          if (activeSearchRequests.get(source) === requestId) {
            reply(control({ kind: "thread_search_result", data: { requestId, ...page } }));
          }
        }).catch((error) => state(`thread-search-error ${String(error)}`));
      return;
    }
    if (event.kind === "approval_answer") {
      const compatibility = from ? devices.get(from)?.compatibility : undefined;
      const statusSupported = !from || compatibility?.state === "compatible" &&
        compatibility.capabilities.includes("offline-approval-v1");
      const rejectLegacy = (): void => reply({ id: randomUUID(), threadId: event.threadId,
        ts: Date.now(), agentId: MAIN_AGENT, kind: "thought",
        data: { text: "Update Yorozu to confirm this approval answer." } });
      if (typeof event.threadId !== "string" || !event.threadId || event.threadId.length > 128 ||
          typeof event.id !== "string" || !event.id || event.id.length > 128 ||
          typeof event.data.actionId !== "string" || !event.data.actionId || event.data.actionId.length > 128 ||
          !["yes", "task", "always", "no", "discuss"].includes(event.data.answer) ||
          (event.data.source !== undefined && event.data.source !== "notification")) return;
      const history = readThreadEvents(event.threadId, dir);
      const previous = history.find((known) => known.kind === "approval_status" && known.data.requestId === event.id);
      if (previous?.kind === "approval_status") {
        const accepted = history.find((known) => known.kind === "approval_answer" && known.id === event.id);
        const same = previous.data.actionId === event.data.actionId &&
          (!accepted || accepted.kind === "approval_answer" && JSON.stringify(accepted.data) === JSON.stringify(event.data));
        const response = { ...previous, id: randomUUID(), ts: Date.now(),
          ...(same ? {} : { data: { requestId: event.id, actionId: event.data.actionId, status: "rejected" as const } }) };
        if (statusSupported) reply(response);
        else if (same && previous.data.status === "applied") reply(control({ kind: "receipt", data: { eventId: event.id } }));
        else rejectLegacy();
        return;
      }
      const status = (() => {
        const now = Date.now();
        if (!Number.isSafeInteger(event.ts) || event.ts > now + MAX_CLIENT_CLOCK_LEAD_MS) return "rejected";
        if (now >= event.ts + APPROVAL_LIFE_MS) return "expired";
        if (history.some((known) => known.kind === "approval_status" && known.data.actionId === event.data.actionId &&
            known.data.status === "applied")) return "no-longer-needed";
        const active = pending.get(event.data.actionId);
        if ((!active || active.threadId !== event.threadId) && !nativeCards.has(event.data.actionId, event.threadId))
          return "no-longer-needed";
        // Notification buttons cannot inherit app-only permission to approve a sensitive card.
        if (event.data.source === "notification" && quickActions.get(event.data.actionId) !== true &&
            !nativeCards.quickApprovable(event.data.actionId)) return "rejected";
        if (!nativeCards.answer(event)) active?.settle({ answer: event.data.answer,
          ...(event.data.rule ? { rule: event.data.rule } : {}) }, "already-logged");
        if (active) emit(event);
        return "applied";
      })();
      const outcome: YorozuEvent = { id: `approval:${event.id}:status`, threadId: event.threadId,
        ts: Date.now(), agentId: MAIN_AGENT, kind: "approval_status",
        data: { requestId: event.id, actionId: event.data.actionId, status } };
      appendThreadEvent(outcome, dir);
      if (statusSupported || status === "applied") reply(control({ kind: "receipt", data: { eventId: event.id } }));
      else rejectLegacy();
      broadcast(outcome);
      return;
    }
    if (event.kind === "interrupt" && event.data.targetEventId === undefined) {
      reply({ id: randomUUID(), threadId: event.threadId, ts: Date.now(), agentId: MAIN_AGENT,
        kind: "thought", data: { text: "Update Yorozu to stop this run safely." } });
      return;
    }
    if (event.kind === "interrupt" && event.data.targetEventId !== undefined) {
      const target = event.data.targetEventId;
      if (typeof target !== "string" || !target || target.length > 128 || !event.threadId) return;
      const existing = stoppedTurns.get(target);
      if (existing && existing.threadId !== event.threadId) {
        reply(control({ kind: "stop_status", data: { targetEventId: target, requestId: event.id, status: "unknown" } }));
        return;
      }
      const history = readThreadEvents(event.threadId, dir);
      const user = history.find((stored) => stored.id === target && stored.kind === "message" && stored.data.role === "user");
      const ledger = openclaw?.pendingTurns(true).find((turn) => turn.threadId === event.threadId && turn.userEventId === target);
      const final = history.some((stored) => stored.id === completionIdFor(event.threadId, target) &&
        stored.kind === "message" && stored.data.done === true && stored.data.interrupted !== true);
      if (!existing && !user && !ledger) {
        const withdrawn: StopRecord = { targetEventId: target, threadId: event.threadId,
          status: "withdrawn", requestIds: [event.id] };
        rememberStop(withdrawn);
        reply(control({ kind: "receipt", data: { eventId: event.id } }));
        reply(stopStatus(withdrawn, event.id));
        return;
      }
      const requestIds = existing ? [...new Set([...existing.requestIds, event.id])] : [event.id];
      const live = liveReplies.get(event.threadId);
      const record: StopRecord = final ? { ...(existing ?? { targetEventId: target, threadId: event.threadId }),
        status: "completed", requestIds } : existing ? { ...existing, requestIds } : { targetEventId: target, threadId: event.threadId,
        status: "requested", requestIds,
        ...(runningEventIds.get(event.threadId) === target && live?.kind === "message" && live.data.role === "agent"
          ? { partialText: live.data.text } : {}),
        ...(ledger && (ledger.state === "active" || runningEventIds.get(event.threadId) === target)
          ? { sessionKey: ledger.sessionKey, runId: ledger.runId } : {}) };
      rememberStop(record);
      reply(control({ kind: "receipt", data: { eventId: event.id } }));
      if (record.status === "requested") {
        finishStop(record);
        if (stoppedTurns.get(target)?.status !== "requested") return;
      }
      reply(stopStatus(stoppedTurns.get(target)!, event.id));
      return;
    }
    if (event.kind === "admission_query") {
      const id = event.data.eventId;
      if (typeof id !== "string" || !id || id.length > 128 || !event.threadId) return;
      const history = readThreadEvents(event.threadId, dir);
      const user = history.find((stored): stored is YorozuEvent & { kind: "message" } =>
        stored.kind === "message" && stored.data.role === "user" && stored.id === id);
      const ledger = openclaw?.pendingTurns(true).find((turn) =>
        turn.threadId === event.threadId && turn.userEventId === id);
      const expired = expiredAdmissions.get(id);
      const withdrawal = stoppedTurns.get(id);
      const recordedCompletionId = ledger?.completionId ?? user?.data.completionId;
      const oldOpenClawCompletionId = user && viaOpenClaw(event.threadId) ? `openclaw:${id}:final` : undefined;
      const candidate = recordedCompletionId ?? oldOpenClawCompletionId;
      const final = candidate ? history.find((stored): stored is YorozuEvent & { kind: "message" } =>
        stored.id === candidate && stored.kind === "message" && stored.data.role === "agent" && stored.data.done === true) : undefined;
      const completionId = recordedCompletionId ?? (final ? oldOpenClawCompletionId : undefined);
      const status = !user && !ledger ? withdrawal?.threadId === event.threadId && withdrawal.status === "withdrawn"
        ? "withdrawn" : expired?.threadId === event.threadId ? "expired" : "unknown" : final ? "completed"
        : activeTurnIds.has(id) ? "running"
        : admittedTurns.has(id) || ledger?.state === "queued" ? "queued"
        : ledger ? "accepted" : "indeterminate";
      const runId = ledger?.runId ?? (final?.kind === "message" ? final.data.runId : undefined)
        ?? (!viaOpenClaw(event.threadId) ? user?.data.runId : undefined);
      reply(control({ kind: "receipt", data: { eventId: event.id } }));
      reply(control({ kind: "admission_status", data: {
        eventId: id, status, requestId: event.id,
        ...(status === "expired" ? { reason: "admission-deadline" } : {}),
        ...(runId ? { runId } : {}), ...(completionId ? { completionId } : {}),
      } }));
      return;
    }
    if (event.kind === "admission_status" || event.kind === "approval_status") return;
    if (event.kind === "update_status") return;
    if (event.kind === "update_control") {
      const subscriber = localDevice ?? from;
      if (subscriber) updateSubscribers.add(subscriber);
      const data = event.data;
      if (data.action === "postpone") {
        if (!seenCommands.has(event.id) && updateGate.status.phase !== "none" && updateGate.status.phase !== "installing") {
          const now = Date.now();
          writeFileAtomic(postponeFile, JSON.stringify(now + 3_600_000));
          updateGate.postpone(now);
          alreadySeen(event.id);
        }
      } else if (data.action !== "status") {
        if (!localDevice) return;
        if (data.action === "queue") {
          if (typeof data.updateId !== "string" || !data.updateId || data.updateId.length > 128 ||
              typeof data.version !== "string" || !data.version || data.version.length > 128) return;
          if (updateOwner && updateOwner !== localDevice) return;
          if (updateGate.status.phase === "installing" && updateGate.status.updateId !== data.updateId) return;
          updateOwner = localDevice;
          updateGate.queue(data.updateId, data.version);
        } else {
          if (data.action === "cancel") {
            if (updateOwner && updateOwner !== localDevice) return;
            if (updateGate.status.phase !== "none" && data.updateId !== updateGate.status.updateId) return;
            updateGate.cancel();
            updateOwner = undefined;
          } else if (data.action !== "poll" || updateOwner !== localDevice || data.updateId !== updateGate.status.updateId) return;
        }
        if (data.action !== "cancel") {
          let active: number | null;
          try {
            active = new Set([...running.keys(), ...turnQueues.keys(), ...archiveUpdates.keys(),
              ...listThreads(dir).filter((thread) => thread.nativeTurn?.state === "interrupted").map((thread) => thread.id),
              ...(openclaw?.pendingTurns(true) ?? []).map((turn) => turn.threadId)]).size;
          } catch { active = null; }
          updateGate.poll(active, Date.now());
        }
      }
      if (data.action !== "status") pushUpdateStatus();
      reply(control({ kind: "update_status", data: currentUpdateStatus(event.id) }));
      return;
    }
    // Old encrypted clients may still send a terminal command. The deprecated error frame
    // lets their terminal sheet explain the removal. No PTY session or generic command runs.
    if ((event as { kind: string }).kind === "terminal") {
      const legacyError = { id: randomUUID(), threadId: event.threadId, ts: Date.now(), agentId: MAIN_AGENT,
        kind: "terminal", data: { action: "error", error: "Remote terminal is no longer available. Update Yorozu." } };
      reply(legacyError as unknown as YorozuEvent);
      return;
    }
    const requiresAdmission = event.kind === "message" && event.data.role === "user" ||
      event.kind === "thread_create" || event.kind === "thread_archive" ||
      event.kind === "thread_recover" && event.data.action === "continue";
    if (updateGate.status.phase === "installing" && requiresAdmission) {
      if (updateSubscribers.has(localDevice ?? from ?? "")) reply(control({ kind: "update_status", data: currentUpdateStatus() }));
      return;
    }
    const rejectUserMessage = (reason: string): void => {
      if (event.kind === "message" && event.data.role === "user") {
        reply(control({ kind: "admission_status", data: { eventId: event.id, status: "rejected", reason } }));
      }
    };
    if (event.kind === "message" && !attachmentsWithinLimits(event.data.attachments ?? [])) {
      rejectUserMessage("oversized-attachments");
      return state("rejected-oversized-attachments");
    }
    const identity = event.kind === "message" && event.data.role === "user"
      ? userMessageIdentity(event) : undefined;
    if (identity && acceptedMessages.has(event.id) && acceptedMessages.get(event.id) !== identity) {
      rejectUserMessage("conflicting-message-id");
      return state("rejected-conflicting-message-id");
    }
    // Every command is receipted, the second copy included: a device that was never told the
    // first one landed is still waiting to hear so, and only a receipt lets it stop re-sending.
    const receipt = (): void => reply(control({ kind: "receipt", data: { eventId: event.id } }));
    const knownMessage = event.kind === "message"
      ? readThreadEvents(event.threadId, dir).find((known) => known.id === event.id)
      : undefined;
    const knownLedger = identity && !knownMessage ? openclaw?.pendingTurns(true).find((turn) =>
      turn.userEventId === event.id) : undefined;
    if (knownLedger && (knownLedger.threadId !== event.threadId ||
        (knownLedger.input.identity !== undefined && knownLedger.input.identity !== identity))) {
      rejectUserMessage("conflicting-message-id");
      return state("rejected-conflicting-message-id");
    }
    if (event.kind === "message" && knownMessage && (knownMessage.kind !== "message" ||
      knownMessage.data.role !== event.data.role || knownMessage.data.text !== event.data.text ||
      (knownMessage.clientTs ?? knownMessage.ts) !== event.ts || knownMessage.data.admissionDeadline !== event.data.admissionDeadline ||
      (knownMessage.data.attachments ?? []).length !== (event.data.attachments ?? []).length ||
      (knownMessage.data.attachments ?? []).some((attachment, index) => {
        const retry = event.data.attachments![index]!;
        return attachment.name !== retry.name || attachment.mime !== retry.mime || attachment.data !== retry.data;
      }))) {
      rejectUserMessage("conflicting-message-id");
      return state("rejected-conflicting-message-id");
    }
    if (event.kind === "message" && event.data.role === "user" && !knownMessage && !knownLedger) {
      const rejected = (status: "expired" | "rejected" | "withdrawn", reason: string): void =>
        reply(control({ kind: "admission_status", data: { eventId: event.id, status, reason } }));
      const withdrawal = stoppedTurns.get(event.id);
      if (withdrawal) {
        rejected(withdrawal.threadId === event.threadId ? "withdrawn" : "rejected",
          withdrawal.threadId === event.threadId ? "withdrawn" : "conflicting-message-id");
        return;
      }
      const expired = expiredAdmissions.get(event.id);
      if (expired) {
        rejected(expired.identity === identity ? "expired" : "rejected",
          expired.identity === identity ? "admission-deadline" : "conflicting-message-id");
        return;
      }
      const deadline = event.data.admissionDeadline;
      if (deadline !== undefined) {
        if (!Number.isSafeInteger(event.ts) || !Number.isSafeInteger(deadline) ||
            deadline !== event.ts + ADMISSION_LIFE_MS || event.id.length > 128 ||
            !event.threadId || event.threadId.length > 128) {
          rejected("rejected", "invalid-admission-deadline");
          return;
        }
        if (event.ts > Date.now() + MAX_CLIENT_CLOCK_LEAD_MS) {
          rejected("rejected", "client-clock-ahead");
          return;
        }
        if (Date.now() >= deadline) {
          rememberExpired({ id: event.id, threadId: event.threadId, identity: identity!, deadline });
          rejected("expired", "admission-deadline");
          return;
        }
      }
    }
    if (seenCommands.has(event.id)) {
      if (event.kind === "message" && !knownMessage) return state("missing-previous-message");
      receipt();
      return state("duplicate-command");
    }
    // A message this thread already holds is the same message again: not a second turn, and
    // not a second line in the log.
    const duplicateMessage = Boolean(knownMessage);
    const oldest = event.kind === "message" && event.data.role === "user"
      ? [...pending.values()].find((card) => card.threadId === event.threadId) : undefined;
    const typed = oldest && event.kind === "message" ? typedAnswer(event.data.text, oldest.card) : undefined;
    // A user message bound for OpenClaw crosses one admission boundary below: ledger first,
    // logs second. Every other message — a native agent's thread included — is logged here.
    const admitted = event.kind === "message" && event.data.role === "user" && !typed && viaOpenClaw(event.threadId);
    if (duplicateMessage && !admitted) {
      receipt();
      return state("duplicate-message");
    }
    if (event.kind === "thread_create" || event.kind === "message" || event.kind === "thread_recover") updateGate.activity();
    let admittedTurn: Promise<void> | undefined;
    if (admitted && event.kind === "message" && event.data.role === "user") {
      // The OpenClaw ledger owns this turn before a receipt can remove the client's copy.
      admittedTurn = enqueueTurn(event.threadId, event.data.text, true,
        event.data.attachments ?? [], event.id, event);
    } else {
      const logged = event.kind === "message" && event.data.role === "user"
        ? { ...event, data: { ...event.data,
          runId: typed ? undefined : completionIdFor(event.threadId, event.id),
          completionId: typed ? undefined : completionIdFor(event.threadId, event.id) } } : event;
      appendTranscript(logged, transcripts);
      appendThreadEvent(logged, dir);
    }
    // Failed admission never poisons the in-memory dedup window.
    alreadySeen(event.id);
    if (identity) acceptedMessages.set(event.id, identity);
    receipt();

    switch (event.kind) {
      case "interrupt":
        return;
      case "receipt":
        // Emitted by the runtime, never accepted from a device.
        return;
      // Rules are the user's own standing decisions, so saving and revoking are theirs to do
      // from either device. Both answer everyone, so a second screen sees the same list.
      case "rule_list":
        return reply(ruleList());
      case "rule_update":
        addRule(event.data.rule, dir);
        return broadcast(ruleList());
      case "rule_delete":
        deleteRule(event.data.ruleId, dir);
        return broadcast(ruleList());
      case "approval_settings":
        // Pairing is the grant: a paired device is the user's own, so on and off are both
        // applied at once from anywhere. On still carries an expiry.
        if (typeof event.data.yolo !== "boolean") return reply(approvalSettingsEvent());
        return setYolo(event.data.yolo, event.data.hours);
      case "rule_proposal":
        // Emitted by the runtime, never accepted from a device: a proposal is not a decision.
        return;
      case "question_answer":
        if (!nativeCards.answer(event)) questions.answer(event.data.questionId, event.data.answer);
        // The row's "needs your answer" mark clears with the card.
        return broadcast(threadList());
      // The rest of a truncated tool result, to the one device that asked, under the id it
      // already holds so it lands in place. Nothing to say when none was kept.
      case "tool_result_request": {
        const full = fullToolResult(event.threadId, event.data.callId, dir);
        if (!full || full.kind !== "tool_result") return state("tool-result-missing");
        const offset = event.data.offset ?? 0;
        if (!Number.isSafeInteger(offset) || offset < 0 || offset > full.data.output.length) return;
        if (full.data.output.length <= 65536 && offset === 0) return reply(full);
        let end = Math.min(offset + 65536, full.data.output.length);
        // Never cut a surrogate pair: Swift decodes each chunk independently.
        if (end < full.data.output.length && /[\uD800-\uDBFF]/.test(full.data.output[end - 1]!)) end--;
        return reply({ ...full, data: { ...full.data, output: full.data.output.slice(offset, end),
          chunkOffset: offset, ...(end < full.data.output.length ? { nextOffset: end } : {}) } });
      }
      // Thread admin is answered to every device, so a second phone sees the same list.
      case "thread_create":
        // The device minted the id: the message it typed follows straight after this frame.
        try {
          // A coding agent runs where the picker offered, and nowhere else: a path typed into a
          // frame by hand is not a folder this Mac agreed to open an agent in.
          // A missing folder is refused by `createThread` itself, after it has checked the agent.
          const cwd = event.data.cwd?.trim();
          if (event.data.agent && event.data.agent !== "yorozu" && cwd && !isProjectFolder(cwd)) {
            throw new Error(`"${cwd}" is not one of this Mac's project folders`);
          }
          createThread(event.data.title, dir, event.threadId || undefined, event.data);
        } catch (error) {
          // An agent this runtime does not know: no thread is made, and the device that asked
          // is told why in the thread it is looking at, since the message it sends next has
          // nowhere to land.
          const reason = error instanceof Error ? error.message : String(error);
          state(`thread-create-error ${reason}`);
          return reply({
            id: randomUUID(), threadId: event.threadId, ts: Date.now(), agentId: MAIN_AGENT,
            kind: "thought", data: { text: `Could not create this thread: ${reason}.` },
          });
        }
        broadcast(threadList());
        // A folder just started in is a recent now.
        if (event.data.cwd) broadcast(projectList());
        return;
      case "thread_rename":
        renameThread(event.threadId, event.data.title, dir);
        return broadcast(threadList());
      case "thread_archive":
        return updateArchive(event, reply);
      case "thread_pin":
        pinThread(event.threadId, event.data.pinned, dir);
        return broadcast(threadList());
      // Read state is the runtime's, not each device's: the device that is actually looking at
      // the thread says so, and everyone is told, so the dot clears on the Mac when the phone
      // reads it. A frame that moves nothing is not worth a list.
      case "thread_read":
        if (markThreadRead(event.threadId, event.data.at, dir, event.data.reset)) {
          broadcast(threadList());
        }
        return;
      case "thread_list":
        reply(threadList());
        refreshModels();
        return reply(projectList());
      case "project_list":
        return reply(projectList());
      case "thread_recover": {
        const thread = listThreads(dir).find((t) => t.id === event.threadId);
        const openclawTurn = thread && !thread.agent ? openclaw?.pendingTurns().find((turn) =>
          turn.threadId === event.threadId && turn.completionId === event.data.turnId && turn.paused) : undefined;
        if (openclawTurn) {
          if ([...stoppedTurns.values()].some((stop) => stop.threadId === event.threadId &&
            completionIdFor(event.threadId, stop.targetEventId) === event.data.turnId)) return;
          if (event.data.action === "continue") openclaw?.retryRecovery(event.threadId, event.data.turnId);
          else if (event.data.action === "dismiss") openclaw?.dismissRecovery(event.threadId, event.data.turnId);
          return;
        }
        if (thread?.nativeTurn?.state !== "interrupted" || thread.nativeTurn.id !== event.data.turnId) return;
        if ([...stoppedTurns.values()].some((stop) => stop.threadId === event.threadId &&
          completionIdFor(event.threadId, stop.targetEventId) === event.data.turnId)) return;
        if (event.data.action !== "continue" && event.data.action !== "dismiss") return;
        if (event.data.action === "continue") {
          resumeNativeTurn(event.threadId, true);
        } else {
          setNativeTurn(event.threadId, undefined, dir);
          broadcast(threadList());
        }
        return;
      }
      // A pick is only ever one of the published options, whichever agent the thread is on. An
      // effort the new model does not offer is dropped with the switch, and one it does is kept.
      case "thread_set_model": {
        const agent = threadAgent(event.threadId, dir);
        const model = event.data.model;
        if (model != null && typeof model !== "string") return;
        if (model && !modelsFor(agent).some((m) => m.id === model)) return;
        if (!setThreadModel(event.threadId, model ?? null, dir)) return;
        const effort = threadEffort(event.threadId, dir);
        if (effort && !effortsFor(agent, model ?? undefined).includes(effort)) setThreadEffort(event.threadId, null, dir);
        return broadcast(threadList());
      }
      case "thread_set_effort": {
        const agent = threadAgent(event.threadId, dir);
        const effort = event.data.effort;
        if (effort != null && !REASONING_EFFORTS.includes(effort)) return;
        if (effort && !effortsFor(agent, threadModel(event.threadId, dir)).includes(effort)) return;
        setThreadEffort(event.threadId, effort ?? null, dir);
        return broadcast(threadList());
      }
      case "device_list": {
        const name = event.data.name;
        const known = from && devices.get(from);
        if (known && typeof name === "string" && /^(iOS|iPadOS|macOS) \d+\.\d+(?:\.\d+)?$/.test(name)
          && known.record.name !== name) {
          known.record.name = name;
          saveDevices();
          return pushDevices();
        }
        return reply(deviceList());
      }
      case "device_remove":
        return forgetDevice(event.data.pub);
      case "sync_request": {
        if (event.data.threadId !== undefined && (typeof event.data.threadId !== "string" || !event.data.threadId)) return;
        if (event.data.focusThreadId !== undefined &&
          (typeof event.data.focusThreadId !== "string" || event.data.focusThreadId.length > 256)) return;
        const compatibility = from ? devices.get(from)?.compatibility : undefined;
        const hinted = !!from && hintedClients.has(from);
        const responses = syncDelta(event.data.lastSeen, pairedAt, event.data.threadId,
          !from || compatibility?.state === "compatible" && compatibility.capabilities.includes("offline-approval-v1"),
          event.data.focusThreadId, event.data.includeCurrent !== false,
          hinted ? 32 * 1024 : SYNC_PAGE_BYTES, hinted ? 32 : SYNC_LIMIT,
          from ? compatibility?.state === "compatible" &&
            compatibility.capabilities.includes("attachment-chunks-v1") : null);
        if (hinted && event.data.threadId === undefined &&
          responses.some((response) => response.kind === "sync_delta" && !response.data.more))
          hintedClients.delete(from!);
        if (from) catchupSends.delete(from);
        if (from) {
          const device = devices.get(from);
          if (!device) return;
          catchupSends.set(from, { connection: socket, device, responses, next: 0 });
          if (!catchupTimer) {
            catchupTimer = setTimeout(sendCatchup, Math.max(0, nextCatchupAt - Date.now()));
            catchupTimer.unref();
          }
        } else for (const response of responses) reply(response);
        return;
      }
    }

    if (event.kind !== "message" || event.data.role !== "user") return;
    // A plain "yes" while a card is up in this thread answers the card rather than starting a
    // turn. Only this thread's: a "yes" typed into another chat is a message there, not an
    // answer to whatever happens to be the oldest card anywhere.
    if (typed && oldest) return oldest.settle(typed);
    const queued = admittedTurn ?? enqueueTurn(event.threadId, event.data.text, true,
      event.data.attachments ?? [], event.id, event);
    // Admission is durable now. Echoing by id is harmless and converges all clients.
    broadcast(event);
    queued.catch((e: unknown) => {
      state(`agent-error ${String(e)}`);
      // A thrown turn has no final event. Save one so its alert names a real row after sync.
      const id = completionIdFor(event.threadId, event.id);
      if (!readThreadEvents(event.threadId, dir).some((known) => known.id === id)) {
        emit({ id, threadId: event.threadId, ts: Date.now(), agentId: MAIN_AGENT,
          kind: "message", data: { role: "agent", text: "The agent could not answer. Check this Mac's log.",
            done: true, failed: true } });
      }
    });
  }

  /**
   * The relay-free path in: the Mac app's own chat UI connects here instead of pairing. Its
   * first frame is the thread list, exactly as a phone's `hello` is answered with one.
   */
  const local = startLocalChannel({
    path: localSocketPath(dir),
    onOpen: (device, send) => {
      locals.set(device, send);
      state("local-connected");
      send(threadList());
      send(modelList());
      send(projectList());
      pushDevices();
    },
    onEvent: (device, event) => {
      try {
        handleEvent(event, locals.get(device) ?? (() => {}), 0, undefined, device);
      } catch (e) {
        state(`local-event-error ${e instanceof Error ? e.message : String(e)}`);
      }
    },
    onClose: (device) => {
      locals.delete(device);
      activeSearchRequests.delete(device);
      updateSubscribers.delete(device);
      if (updateOwner === device) {
        updateOwner = undefined;
        if (updateGate.status.phase !== "installing") updateGate.cancel();
        pushUpdateStatus();
      }
      pushDevices();
    },
    onError: state,
  });

  function connect(): void {
    relayReady = false;
    state("connecting");
    // The room ID is only carried in `register`, which is too late for a relay that has to
    // route the socket before reading it, so it also goes in the URL. It is the hash of our
    // own signing key, so we know it before we dial; the QR keeps the bare URL.
    const dial = new URL(relayUrl);
    dial.searchParams.set(
      "room",
      toBase64Url(createHash("sha256").update(keys.signing.publicKey).digest()),
    );
    const ws = new WebSocket(dial);
    socket = ws;
    let room: string | null = null;
    /** Set once a replayed frame on this socket threw; nothing after it is acked. */
    let ackBlocked = false;

    const signedFrame = (body: FrameBody): { payload: string; sig: string } => {
      const payload = toBase64Url(Buffer.from(JSON.stringify(body)));
      const sig = signFrame(keys.signing.privateKey, Buffer.from(payload));
      return { payload, sig: toBase64Url(sig) };
    };
    const sendFrame = (body: FrameBody): void => ws.send(JSON.stringify({ type: "frame", ...signedFrame(body) }));

    /**
     * The relay learns who is paired from us, not the other way round: a relay that lost its
     * storage would otherwise refuse every rejoin with a 4001 until each phone paired again.
     *
     * The relay replaces its whole set with this list, so it is only sent when every paired
     * device carries the signing key the relay knows it by. A record from before that key was
     * kept cannot be named, and announcing the rest would unpair it; its next `hello` fills
     * the key in, and the announces resume.
     */
    announceDevices = (): void => {
      if (!relayReady || ws.readyState !== WebSocket.OPEN) return;
      const records = [...devices.values()].map(({ record }) => record);
      if (records.some(({ signingPub }) => signingPub === undefined)) return;
      ws.send(JSON.stringify({ type: "devices", devices: records.map((r) => r.signingPub) }));
    };

    notifyRelay = (event: YorozuEvent): void => {
      // Nothing to wake: no device has ever paired through the relay.
      if (devices.size === 0) return;
      const cls = notifyFor(event);
      if (!cls || !event.threadId) return;
      // The socket is down. The frame did not go out either, but the phone will catch up on
      // its own by asking for a sync — what it cannot do on its own is find out that it
      // should look. So the wake-up is held for the next registration rather than dropped.
      if (!relayReady || ws.readyState !== WebSocket.OPEN) {
        heldNotifies.push(event);
        return;
      }
      // An approval the phone may answer from its lock screen: below every floor and nothing
      // external, or a native agent's own local tool. One bit for the relay, which draws the
      // buttons; the same bit sealed into the preview, which is what the phone acts on. The
      // action itself stays in the sealed frame.
      const quick =
        event.kind === "approval_card" &&
        (quickActions.get(event.data.actionId) === true || nativeCards.quickApprovable(event.data.actionId));
      // A reply's words, or a card's one line, each sealed once per phone under its own key,
      // together with the reference of the event they are about and the quick judgement.
      const body = notificationPreviewBody(event) ?? NOTIFY_BODY[cls];
      // The thread's title rides inside the sealed box, never beside it: the relay sees none of it.
      let title: string | undefined;
      try {
        title = listThreads(dir).find((thread) => thread.id === event.threadId)?.title;
      } catch {
        // An unreadable index costs the title, not the notification.
      }
      const plaintext = encodeNotificationPreview({ body, event: threadRef(event.id),
        thread: threadRef(event.threadId), class: cls, quick, title });
      const previews = plaintext
        ? Object.fromEntries(
            [...devices.values()].flatMap(({ key, record }) => {
              if (!record.signingPub || event.ts < (record.pairedAt ?? 0)) return [];
              const box = seal(key, Buffer.from(plaintext));
              return [[record.signingPub, { n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }]];
            }),
          )
        : undefined;
      const actions = quick;
      // Thread and event ids travel only as short one-way references. The latter lets a tap
      // select the exact encrypted card after sync without teaching the relay what it contains.
      ws.send(
        JSON.stringify({
          type: "notify",
          class: cls,
          threadRef: threadRef(event.threadId),
          eventRef: threadRef(event.id),
          ...(previews && Object.keys(previews).length > 0 ? { previews } : {}),
          ...(actions ? { actions: true } : {}),
        }),
      );
    };

    revokeAtRelay = (signingPub: string): void => {
      if (relayReady && ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: "revoke", pubkey: signingPub }));
      } else {
        heldRevokes.add(signingPub);
      }
    };

    /**
     * The one place a live-channel box is sealed: every seq is used once, and its ceiling is
     * written ahead in blocks so a restart resumes past anything this process may have sent.
     */
    const sealFor = (known: PairedDevice, event: YorozuEvent): FrameBody => {
      known.sent += 1;
      if (known.sent > (known.record.sendSeq ?? 0)) {
        // If the write fails the ceiling stays where it was, so the next send tries again
        // rather than sealing the rest of a block nothing on disk knows about. The seq that
        // was about to go out is burnt either way: a gap costs nothing, a reuse costs the box.
        const ceiling = known.record.sendSeq;
        known.record.sendSeq = known.sent + SEND_SEQ_RESERVE - 1;
        try {
          writeSeqs();
        } catch (e) {
          known.record.sendSeq = ceiling;
          throw e;
        }
      }
      const box = seal(known.channel.send, encodeEnvelope(known.sent, event));
      return { t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) };
    };

    const sealLegacyFor = (known: PairedDevice, event: YorozuEvent): FrameBody => {
      const box = seal(known.key, Buffer.from(JSON.stringify(event)));
      return { t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) };
    };

    const boxesFor = (device: string, event: YorozuEvent): FrameBody[] => {
      const known = devices.get(device);
      if (!known || !relayReady || ws.readyState !== WebSocket.OPEN) return [];
      const supportsApprovalStatus = known.compatibility?.state === "compatible" &&
        known.compatibility.capabilities.includes("offline-approval-v1");
      if (!supportsApprovalStatus && event.kind === "approval_status") return [];
      const awaitingCompatibility = known.record.peerInfoRequired && known.compatibility?.state !== "compatible";
      if (awaitingCompatibility && event.kind !== "thread_list") return [];
      const cutoff = known.record.pairedAt ?? 0;
      if (event.threadId && event.ts < cutoff) return [];
      if (event.kind === "thread_list") {
        const list = threadList(cutoff);
        if (list.kind !== "thread_list") return [];
        const name = known.compatibility?.state === "compatible" && known.compatibility.capabilities.includes("host-name") ? computerName() : undefined;
        event = { ...list, id: event.id, ts: event.ts, data: {
          threads: awaitingCompatibility ? [] : list.data.threads,
          peerInfoSupported: true,
          ...(event.data.peerInfoReplyTo ? { peerInfoReplyTo: event.data.peerInfoReplyTo } : {}),
          ...(known.peerClaimReceived ? { peerInfo: localPeerInfo(peerInfo.appVersion, name) } : {}),
          ...(known.compatibility?.state === "update-required" ? { peerInfoError: known.compatibility.reason } : {}),
        } };
      }
      if (event.kind === "message") event = phoneTrace(event,
        known.compatibility?.state === "compatible" &&
        known.compatibility.capabilities.includes("attachment-chunks-v1"));
      // A hello carries no format version. Greet both released clients; each ignores the box
      // it cannot open. Once one answers, send only its format. Modern goes first so a client
      // able to read both never settles on the older format.
      const boxes: FrameBody[] = [];
      if (known.format !== "legacy") boxes.push(sealFor(known, event));
      if (known.format !== "current") {
        // Legacy uses a bidirectional key: our own greeting can be reflected. Never put
        // negotiation claims in that format, where direction cannot be authenticated.
        const legacyEvent = event.kind === "thread_list" ? { ...event, data: { threads: event.data.threads } } : event;
        boxes.push(sealLegacyFor(known, legacyEvent));
      }
      return boxes;
    };
    sendTo = (device, event) => { for (const box of boxesFor(device, event)) sendFrame(box); };
    const emptyBatchBytes = Buffer.byteLength(JSON.stringify({ type: "frame", frames: [] }));
    sendToAll = (event, maxBuffered) => {
      if (maxBuffered !== undefined) {
        // Cover both current and legacy boxes without burning sequence numbers while held.
        const estimate = devices.size * (Buffer.byteLength(JSON.stringify(event)) * 3 + 1_024);
        if (estimate > maxBuffered) return -2;
        if (ws.bufferedAmount + estimate > maxBuffered) return -1;
      }
      let frames: ReturnType<typeof signedFrame>[] = [];
      let bytes = emptyBatchBytes;
      const batches: string[] = [];
      const flush = (): void => {
        if (frames.length) {
          batches.push(JSON.stringify({ type: "frame", frames }));
        }
        frames = [];
        bytes = emptyBatchBytes;
      };
      for (const device of devices.keys()) for (const box of boxesFor(device, event)) {
        const frame = signedFrame(box);
        const size = Buffer.byteLength(JSON.stringify(frame)) + (frames.length ? 1 : 0);
        // Stay below the relay's 1 MiB message ceiling, including JSON envelope overhead.
        if (frames.length && (frames.length === MAX_DEVICES || bytes + size > 900_000)) flush();
        frames.push(frame);
        bytes += size;
      }
      flush();
      if (maxBuffered !== undefined) {
        const total = batches.reduce((sum, batch) => sum + Buffer.byteLength(batch), 0);
        if (total > maxBuffered) return -2;
        if (ws.bufferedAmount + total > maxBuffered) return -1;
      }
      for (const batch of batches) ws.send(batch);
      return batches.length;
    };

    /**
     * Frames carry no sender, so whichever paired key opens one identifies its device.
     * Modern boxes retain the per-direction replay check. Legacy boxes have no seq; accepting
     * them ends once a modern box from that device has been seen on this connection.
     */
    function openFrom(body: { n: string; c: string }): [string, YorozuEvent] | null {
      for (const [device, known] of devices) {
        let plain: Uint8Array | null = null;
        try {
          plain = open(known.channel.recv, fromBase64Url(body.n), fromBase64Url(body.c));
        } catch {
          // An older client used the shared key in both directions.
        }
        if (plain === null) {
          if (known.format === "current" || known.record.peerInfoRequired) continue;
          try {
            const legacy = open(known.key, fromBase64Url(body.n), fromBase64Url(body.c));
            const event = JSON.parse(Buffer.from(legacy).toString()) as YorozuEvent;
            if (typeof event?.id !== "string" || typeof event?.kind !== "string" ||
              typeof event?.threadId !== "string" || typeof event?.ts !== "number" ||
              typeof event?.data !== "object" || event.data === null) {
              state("malformed-frame");
              return null;
            }
            known.format = "legacy";
            return [device, event];
          } catch {
            continue; // Not sealed for this device: try the next one.
          }
        }
        let envelope: ReturnType<typeof decodeEnvelope>;
        try {
          envelope = decodeEnvelope(plain);
        } catch {
          state("malformed-frame");
          return null;
        }
        if (!acceptsSeq(known.record.recvSeq ?? 0, envelope.seq)) {
          state("replayed-frame");
          return null;
        }
        // Written before the event is acted on: a crash between the two must not reopen it.
        // And acted on only if written: a box whose seq could not be recorded is left for the
        // relay's replay to bring again, so the counter is put back to say so.
        const accepted = known.record.recvSeq;
        known.record.recvSeq = envelope.seq;
        try {
          writeSeqs();
        } catch (e) {
          known.record.recvSeq = accepted;
          throw e;
        }
        known.format = "current";
        return [device, envelope.event];
      }
      return null;
    }

    /**
     * A well-formed body, whose every field is still attacker-controlled: a bad frame must not
     * kill the sidecar. What throws here is a handler's own failure, which is what keeps the
     * relay's ack back; the shape was already judged by `parseFrameBody`.
     */
    function onFrame(body: FrameBody): void {
      if (body.t === "hello") {
        const known = devices.get(body.pub);
        // The relay remembers this many devices per room and the announce below is capped at
        // as many, so a seventeenth phone would be one the relay could never be told about.
        if (!known && devices.size >= MAX_DEVICES) return state("hello-refused device-limit");
        // A key pair not on file gets in only with proof it read a QR this Mac drew. The
        // relay verified the frame's signature, but the relay could have signed it itself.
        const proved =
          typeof body.proof === "string" &&
          typeof body.spub === "string" &&
          [...pairingSecrets].some((secret) => helloProof(secret, body.pub, body.spub!) === body.proof);
        if (!known && !proved) return state("hello-refused");
        // A device on file may say hello again without proof, but it cannot move its relay
        // identity without one: `revoke` is addressed to that key, so a relay that could swap
        // it in with a signed frame could make the device unrevokable. The stored key stays.
        let signingPub = known?.record.signingPub;
        if (typeof body.spub === "string" && body.spub !== signingPub) {
          if (proved) signingPub = body.spub;
          else state("hello-spub-ignored");
        }
        if (proved) pairingSecrets.clear();
        const changed = !known || signingPub !== known.record.signingPub;
        remember({
          pub: body.pub,
          ...(signingPub ? { signingPub } : {}),
          ...(known?.record.name ? { name: known.record.name } : {}),
          pairedAt: known?.record.pairedAt ?? Date.now(),
          lastSeen: Date.now(),
        });
        saveDevices();
        state("paired");
        // A phone that has just paired needs the thread list before it can ask for anything.
        sendTo(body.pub, threadList());
        sendTo(body.pub, modelList());
        sendTo(body.pub, projectList());
        // And every device's list of devices has just gained one.
        pushDevices();
        // Join tokens are one-time, so the one in the printed QR has just been burnt: mint the
        // next one now, and the Mac's menu bar shows a QR a second device can still use. A
        // known device saying hello again with no proof read no QR and burnt nothing, so the
        // code on screen stays as it is rather than being redrawn on every reconnect.
        if (changed || proved) ws.send(JSON.stringify({ type: "mint" }));
        return;
      }
      const opened = openFrom(body);
      if (!opened) return;
      const [device, event] = opened;
      const known = devices.get(device);
      // Hearing from a device is the only thing that makes it online, so the stamp is kept.
      if (known) known.record.lastSeen = Date.now();
      if (known && event.kind === "thread_list" &&
          ("peerInfo" in event.data || "peerInfoSupported" in event.data || "peerInfoError" in event.data || "peerInfoReplyTo" in event.data)) {
        // Legacy boxes are reflectable. A reflected greeting must not raise the security
        // floor and permanently disable a released client that cannot negotiate it.
        if (known.format !== "current") return;
        known.peerClaimReceived = true;
        if (!known.record.peerInfoRequired) {
          known.record.peerInfoRequired = true;
          try { writeDevices(); }
          catch (error) { delete known.record.peerInfoRequired; throw error; }
        }
        try {
          if (event.id.length > 128 || !event.id ||
              ("peerInfoSupported" in event.data && typeof event.data.peerInfoSupported !== "boolean") ||
              "peerInfoError" in event.data || "peerInfoReplyTo" in event.data) {
            throw new Error("Invalid peer information");
          }
          known.peerInfo = parsePeerInfo(event.data.peerInfo);
          known.compatibility = negotiatePeerInfo(peerInfo, known.peerInfo);
        } catch {
          known.compatibility = { state: "update-required", reason: "Invalid peer information." };
        }
        if (known.compatibility.state === "update-required") state("peer-update-required");
        sendTo(device, control({ kind: "thread_list", data: { threads: [], peerInfoReplyTo: event.id.slice(0, 128) } }));
        if (known.compatibility.state === "compatible") {
          sendTo(device, modelList());
          sendTo(device, projectList());
        }
        return;
      }
      if (known?.record.peerInfoRequired && known.compatibility?.state !== "compatible") return;
      handleEvent(event, (answer) => sendTo(device, answer), known?.record.pairedAt ?? 0, device);
    }

    /**
     * One ping every PING_MS, and the socket is declared dead if the pong does not come back
     * within PONG_MS. `terminate()` rather than `close()`: a half-open socket will not complete
     * a closing handshake, which is the case this exists for. The close handler then reconnects
     * and re-registers, which is what puts the room's presence right again.
     */
    let pinger: NodeJS.Timeout | null = null;
    let deadline: NodeJS.Timeout | null = null;
    const stopHeartbeat = (): void => {
      if (pinger) clearInterval(pinger);
      if (deadline) clearTimeout(deadline);
      pinger = deadline = null;
    };

    ws.on("open", () => {
      state("connected");
      pinger = setInterval(() => {
        // Still waiting on the last pong: the deadline below owns the socket, not us.
        if (deadline) return;
        deadline = setTimeout(() => {
          state("heartbeat-timeout");
          ws.terminate();
        }, heartbeat.pongMs);
        ws.send(PING);
      }, heartbeat.pingMs);
      // Node keeps the process alive for a bare interval; the socket is what should.
      pinger.unref();
    });

    ws.on("message", (data) => {
      try {
        // Inside the try: the relay is the one peer that can hand us a frame that is not JSON
        // at all, and a parse error here would end the process rather than the frame.
        const msg = JSON.parse(data.toString()) as Record<string, unknown>;
        switch (msg.type) {
          case "pong":
            if (deadline) clearTimeout(deadline);
            deadline = null;
            return;
          case "nonce":
            return ws.send(
              JSON.stringify({
                type: "register",
                pubkey: toBase64Url(keys.signing.publicKey),
                nonceSig: toBase64Url(
                  signFrame(keys.signing.privateKey, Buffer.from(String(msg.nonce))),
                ),
              }),
            );
          case "registered":
            room = String(msg.roomId);
            relayReady = true;
            state("registered");
            announceDevices();
            // Announcements preserve live phone sockets, so explicit removals must follow
            // them and reach the relay before any held notification can wake that device.
            for (const pubkey of heldRevokes) revokeAtRelay(pubkey);
            heldRevokes.clear();
            // One wake-up per thread that finished while we were away: the phone's sync picks
            // up every event in that thread, so the class of the last one is what matters.
            for (const held of latestPerThread(heldNotifies.splice(0))) notifyRelay(held);
            return ws.send(JSON.stringify({ type: "mint" }));
          case "token": {
            // One secret per QR, and only the last few QRs are honoured: the token is relay
            // state, the secret is ours, and the two are shown together.
            const secret = toBase64Url(randomBytes(32));
            pairingSecrets.add(secret);
            if (pairingSecrets.size > PAIRING_SECRETS) {
              const [oldest] = pairingSecrets;
              pairingSecrets.delete(oldest!);
            }
            const pairing = encodePairingString({
              v: 1,
              relayUrl,
              macPubkey: toBase64Url(keys.session.publicKey),
              token: String(msg.token),
              ...(room ? { roomId: room } : {}),
              secret,
            });
            // The same string twice: one line the Mac draws as a QR, one it offers to copy.
            log(`QR ${pairing}`);
            return log(`PAIR ${pairing}`);
          }
          case "frame": {
            // A replayed frame carries the relay's buffer sequence; acking it is what lets the
            // relay let go. The ack is cumulative, so it is sent only once every frame up to
            // this one has been handled: a frame that threw is left for the next replay
            // rather than deleted by the ack of the one after it. Live frames carry no `seq`.
            // A body that is not a frame at all is different: nothing will ever handle it, so
            // it is logged and acked, or it would sit at the head of the buffer for good.
            const body = parseFrameBody(msg.payload);
            if (!body) {
              state("frame-error malformed body");
            } else {
              try {
                onFrame(body);
              } catch (e) {
                if (typeof msg.seq === "number") ackBlocked = true;
                throw e;
              }
            }
            if (typeof msg.seq === "number" && !ackBlocked) {
              ws.send(JSON.stringify({ type: "ack", seq: msg.seq }));
            }
            return;
          }
          case "state":
            // The relay's own word on something it did to us — a notify held back by its rate
            // limit, say — surfaced as a state so the Mac app can show it rather than a mystery.
            return state(`relay-${String(msg.state).replace(/\s+/g, " ").slice(0, 200)}`);
        }
      } catch (e) {
        state(`frame-error ${e instanceof Error ? e.message : String(e)}`);
      }
    });

    ws.on("error", (e) => state(`error ${e.message}`));

    ws.on("close", () => {
      relayReady = false;
      clearTraces();
      catchupSends.clear();
      if (catchupTimer) clearTimeout(catchupTimer);
      catchupTimer = null;
      stopHeartbeat();
      state("disconnected");
      if (!stopped) retry = setTimeout(connect, RECONNECT_MS);
    });
  }

  connect();

  // App replacement kills this process, not OpenClaw's run. Recovery owns queue head until
  // its deterministic final is durable; later persisted user messages are then replayed FIFO.
  const resumeOpenClaw = async (stored: StoredPendingTurn): Promise<void> => {
    const { threadId, completionId } = stored;
    liveReplies.delete(threadId);
    const stop = stored.userEventId ? stoppedTurns.get(stored.userEventId) : undefined;
    if (stop) {
      if (stop.status === "requested") {
        finishStop(stop);
        await stopSettlements.get(stop.targetEventId)?.promise;
      }
      else if (stored.userEventId) openclaw!.discardPending(stored.userEventId);
      return;
    }
    const known = readThreadEvents(threadId, dir);
    const durableFinal = known.find((event) => event.id === completionId);
    if (durableFinal) {
      finalizeOpenClaw(durableFinal);
      return;
    }
    const turn = new AbortController();
    running.set(threadId, turn);
    if (stored.userEventId) runningEventIds.set(threadId, stored.userEventId);
    broadcastActiveThreadList();
    const message = (text: string, done = false, failed = false): YorozuEvent => ({
      id: completionId, threadId, ts: Date.now(), agentId: MAIN_AGENT, kind: "message",
      data: { role: "agent", text, ...(done ? { done: true } : {}), ...(failed ? { failed: true } : {}) },
    });
    try {
      while (!turn.signal.aborted) {
        try {
          let failed = false;
          const reply = await openclaw!.resume({
            threadId,
            signal: turn.signal,
            seenEventIds: readThreadEvents(threadId, dir).map((event) => event.id),
            onUpdate: (text) => broadcast(message(text)),
            onEvent: emit,
            onRecoveryState: () => broadcast(threadList()),
            onFailure: () => { failed = true; },
          });
          if (turn.signal.aborted || reply === undefined) return;
          finalizeOpenClaw(message(reply, true, failed));
          return;
        } catch (error) {
          state(`openclaw-resume-error ${String(error)}`);
          await new Promise((resolve) => setTimeout(resolve, 250));
        }
      }
    } finally {
      if (running.get(threadId) === turn) running.delete(threadId);
      if (runningEventIds.get(threadId) === stored.userEventId) runningEventIds.delete(threadId);
      broadcastActiveThreadList();
    }
  };

  for (const stop of stoppedTurns.values()) if (stop.status === "requested") finishStop(stop);

  for (const thread of listThreads(dir)) {
    if (thread.nativeTurn?.state === "interrupted") resumeNativeTurn(thread.id);
  }

  for (const stored of openclaw?.pendingTurns() ?? []) {
    if (stored.state !== "queued") {
      const recovery = resumeOpenClaw(stored);
      if (stored.userEventId) activeTurnIds.add(stored.userEventId);
      turnQueues.set(stored.threadId, recovery);
      if (stored.userEventId) admittedTurns.set(stored.userEventId, recovery);
      void recovery.finally(() => {
        if (stored.userEventId) activeTurnIds.delete(stored.userEventId);
        if (turnQueues.get(stored.threadId) === recovery) turnQueues.delete(stored.threadId);
        if (stored.userEventId && admittedTurns.get(stored.userEventId) === recovery) admittedTurns.delete(stored.userEventId);
      }).catch(() => {});
    } else {
      const logged = readThreadEvents(stored.threadId, dir).find((event): event is YorozuEvent & { kind: "message" } =>
        event.kind === "message" && event.data.role === "user" && event.id === stored.userEventId);
      const accepted = logged ?? (stored.userEventId && stored.input.eventTs !== undefined ? {
        id: stored.userEventId, threadId: stored.threadId, ts: stored.input.eventTs,
        agentId: MAIN_AGENT, kind: "message" as const,
        data: { role: "user" as const, text: stored.input.text,
          ...(stored.input.admissionDeadline !== undefined ? { admissionDeadline: stored.input.admissionDeadline } : {}),
          ...(stored.input.attachments.length ? { attachments: stored.input.attachments } : {}) },
      } : undefined);
      void enqueueTurn(stored.threadId, stored.input.text, true, stored.input.attachments, stored.userEventId, accepted);
    }
  }

  // Production never installs legacy agents or starts its scheduler. Initialization remains
  // async so importing the sidecar does not load the old provider/tool graph.
  const legacyReady = provider ? import("./legacy.js").then(({ createLegacyRunner }) => {
    if (stopped) return undefined;
    legacy = createLegacyRunner({ provider, dir, emit, ask, askUser: questions.ask,
      reportProgress, proposeRule, turn: runTurn, enqueue: enqueueTurn, state });
    if (legacy.models().length) broadcast(modelList());
    return legacy;
  }) : undefined;
  void legacyReady?.catch((error: unknown) => state(`legacy-init-error ${String(error)}`));

  return {
    mint: () => {
      if (relayReady && socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: "mint" }));
    },
    close: async () => {
      stopped = true;
      for (const retry of stopRetries.values()) clearTimeout(retry);
      stopRetries.clear();
      clearTraces();
      partials.clear();
      if (partialTimer) clearTimeout(partialTimer);
      partialTimer = null;
      catchupSends.clear();
      if (catchupTimer) clearTimeout(catchupTimer);
      catchupTimer = null;
      for (const turn of running.values()) turn.abort();
      if (retry) clearTimeout(retry);
      await local.close();
      await legacyReady?.catch(() => undefined);
      await legacy?.close();
      return new Promise<void>((done) => {
        const ws = socket;
        if (!ws || ws.readyState === WebSocket.CLOSED) return done();
        ws.once("close", () => done());
        ws.close();
      });
    },
  };
}

if (import.meta.main) {
  // Subcommands answer the Mac app's settings and exit; no argument serves.
  const [command, argument, extra] = argv.slice(2);
  const mode = (name?: string): AssignMode => (name === "research" ? "research" : "catalog");
  switch (command) {
    case "probe":
      stdout.write(`${JSON.stringify(await (await import("./probe.js")).probe())}\n`);
      break;
    // The model list of one `openai-compat` entry, one id per line, for the Settings picker.
    case "models":
      stdout.write(`${(await (await import("./providers.js")).listEntryModels(argument ?? "")).join("\n")}\n`);
      break;
    case "assign":
      stdout.write(await (await import("./assign.js")).autoAssign({ mode: mode(argument) }));
      break;
    case "assign-revert":
      stdout.write(`${(await import("./assign.js")).revertAssign()}\n`);
      break;
    case "assign-cron":
      stdout.write(`${(await import("./assign.js")).setAssignCron(argument ?? "", mode(extra))}\n`);
      break;
    default: {
      // Test rigs can pin a deterministic provider instead of talking to the live OpenClaw
      // gateway. Ordinary launches have no argument and keep OpenClaw as their backend.
      const { chainFromEnv } = await import("./chain.js");
      const sidecar = serve(command === "--direct-provider" ? { provider: chainFromEnv() } : {});
      // The Mac app's "New code" button, and the only thing stdin is for. Skipped on a
      // terminal: reading one from a backgrounded shell job earns a SIGTTIN, and a person
      // running the sidecar by hand has no button to press anyway.
      if (!stdin.isTTY) {
        stdin.on("data", (chunk) => {
          if (chunk.toString().includes("MINT")) sidecar.mint();
        });
        stdin.on("error", () => {});
      }
    }
  }
}

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
import { execFile, execFileSync } from "node:child_process";
import { appendFileSync, chmodSync, copyFileSync, existsSync, mkdtempSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { argv, env, stdin, stdout } from "node:process";
import { AcceptedMessages, type AcceptedEntry } from "./accepted.js";
import { ExpiredAdmissions } from "./admission.js";
import { StopStore, type StopRecord } from "./stops.js";
import { promisify } from "node:util";
import {
  encodePairingLink,
  encodePairingString,
  fromBase64Url,
  generateKeypair,
  isSeq,
  MAX_DEVICES,
  generateSigningKeypair,
  attachmentsWithinLimits,
  notifyFor,
  notificationPreviewBody,
  NOTIFY_BODY,
  encodeNotificationPreview,
  threadRef,
  toBase64Url,
  REASONING_EFFORTS,
  THREAD_AGENTS,
  validAgentDescriptor,
  validAgentId,
  type AgentDescriptor,
  type ApprovalCardData,
  type ChannelModelOption,
  type DeviceInfo,
  type EventPayload,
  type Keypair,
  type ModelOption,
  type PeerCompatibility,
  type ReasoningEffort,
  type MessageAttachment,
  type SkillOption,
  type ProgressCardData,
  type ThreadAgent,
  type TurnChangesData,
  type YorozuEvent,
} from "@yorozu/shared";
import WebSocket from "ws";
import { startRustRelay, type RustRelaySocket } from "./relay-rust.js";
import { CatchupQueue } from "./catchup-rust.js";
import { hostPeerInfo, claimPeer } from "./session-peers.js";
import { UpdateGate } from "./update-gate.js";
import { WireCrypto } from "./wire-crypto.js";
import { SessionSequences } from "./session-sequences.js";
import { AttachmentUploads } from "./attachment-upload.js";
import { agentStatus } from "./agent-status.js";
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
import { startChannelHost, type RunStatus, type ChannelInbound } from "./channel.js";
import { startDirect, type Direct } from "./direct.js";
import type { Provider } from "./provider.js";
import { autoTitle, onDeviceTitler, type Titler } from "./title.js";
import {
  appendThreadEvent,
  attachmentFiles,
  archiveThread,
  createThread,
  currentThread,
  eventsAfter,
  fullToolResult,
  listThreads,
  markThreadRead,
  pinThread,
  readThreadEvents,
  visibleThreadEvents,
  latestRewindId,
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
  threadSummary,
} from "./threads.js";
import { codexNativeRunner, connectCodex } from "./codex-native.js";
import { NativeCards } from "./native-cards.js";
import { claudeCodeRunner, type NativeAgentRunner, type NativeTurn } from "./native.js";
import { isProjectFolder, listProjects } from "./projects.js";
import { questionDesk, QUESTION_TIMEOUT_MS } from "./tools/cards.js";
import { persistThreadAndTranscript, persistThreadAndTranscriptBatch } from "./transcripts.js";
import { retainSyncHost, syncHostRequest } from "./rust-sync.js";

const DEFAULT_STATE_DIR = join(homedir(), "Library", "Application Support", "Yorozu");

const gitExec = promisify(execFile);

/** Synchronous so a folder outside git starts its turn without an extra tick. */
function gitRoot(cwd: string): string | undefined {
  try {
    return execFileSync("git", ["rev-parse", "--show-toplevel"],
      { cwd, encoding: "utf8", timeout: 5_000, stdio: ["ignore", "pipe", "ignore"] }).trim();
  } catch { return undefined; }
}

/**
 * The working tree as a tree object, staged through a throwaway index so the person's index,
 * HEAD and refs are never touched. The throwaway starts as a copy of the real index: its stat
 * cache lets `add -A` hash only what changed instead of every file in the repository.
 */
async function workingTree(root: string, abort?: AbortSignal): Promise<{ root: string; tree: string } | undefined> {
  const signal = abort ? AbortSignal.any([AbortSignal.timeout(5_000), abort]) : AbortSignal.timeout(5_000);
  let temporary: string | undefined;
  try {
    temporary = mkdtempSync(join(tmpdir(), "yorozu-git-index-"));
    const index = join(temporary, "index");
    const gitEnv = { ...env, GIT_INDEX_FILE: index };
    const run = (args: string[]) => gitExec("git", args, { cwd: root, env: gitEnv, signal });
    const real = (await gitExec("git", ["rev-parse", "--path-format=absolute", "--git-path", "index"],
      { cwd: root, encoding: "utf8", signal })).stdout.trim();
    try { copyFileSync(real, index); }
    catch {
      try { await run(["read-tree", "HEAD"]); }
      catch { await run(["read-tree", "--empty"]); }
    }
    await run(["add", "-A"]);
    return { root, tree: (await run(["write-tree"])).stdout.trim() };
  } catch { return undefined; }
  finally { if (temporary) try { rmSync(temporary, { recursive: true, force: true }); } catch { /* Best effort. */ } }
}

async function changedFiles(start: { root: string; tree: string }): Promise<TurnChangesData["files"]> {
  const end = await workingTree(start.root);
  if (!end) return [];
  try {
    const { stdout } = await gitExec("git", ["diff", "--no-renames", "--numstat", "-z", start.tree, end.tree],
      { cwd: start.root, encoding: "utf8", timeout: 5_000 });
    return stdout.split("\0").filter(Boolean).map((line) => {
      const [added, removed, ...path] = line.split("\t");
      return { path: path.join("\t"), added: added === "-" ? 0 : Number(added), removed: removed === "-" ? 0 : Number(removed) };
    });
  } catch { return []; }
}
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
    ...(event.data.channelModel !== undefined ? [event.data.channelModel.model ?? null] : []),
    ...(event.data.replyTo !== undefined ? ["replyTo", event.data.replyTo] : []),
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

/** A phone paired over the relay, as the runtime holds it. */
interface PairedDevice {
  /** Set by the first box after hello; a modern box can upgrade a legacy connection. */
  format: "current" | "legacy" | null;
  record: DeviceRecord;
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
  /**
   * The opt-in direct path: a loopback port `tailscale serve` publishes, and the tailnet URL
   * paired phones are told inside the sealed channel. Defaults to `YOROZU_DIRECT_PORT` and
   * `YOROZU_DIRECT_URL`; with either missing nothing listens and nothing is said.
   */
  direct?: { port: number; url: string };
  /**
   * The native coding agents, by thread agent kind. Defaults to Claude Code through the Agent
   * SDK; a kind with no runner answers that it is not available. Test seam for a fake SDK.
   */
  nativeRunners?: Record<string, NativeAgentRunner>;
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
  const releaseHistory = retainSyncHost(dir);
  try {
  syncHostRequest(dir, { op: "queue_open" });
  syncHostRequest(dir, { op: "steering_open" });
  const wireCrypto = new WireCrypto(dir);
  const sessionSequences = new SessionSequences(dir);
  // A SIGKILL cannot run the SDK's exit cleanup. Stop an orphaned CLI before any native
  // recovery starts; a live old CLI beside a resumed one could repeat external tool effects.
  const agentProcessesFile = join(dir, "native-agent-processes.json");
  type AgentProcess = { pid: number; startedAt: string; commandLine: string };
  const agentProcesses: AgentProcess[] = existsSync(agentProcessesFile)
    ? JSON.parse(readFileSync(agentProcessesFile, "utf8")) as AgentProcess[] : [];
  if (!Array.isArray(agentProcesses) || !agentProcesses.every((entry) =>
    Number.isSafeInteger(entry?.pid) && entry.pid > 0 &&
    typeof entry.startedAt === "string" && !!entry.startedAt &&
    typeof entry.commandLine === "string" && !!entry.commandLine)) throw new Error("Invalid native agent process journal");
  const agentIdentity = (pid: number): { startedAt: string; commandLine: string; state: string } | undefined => {
    try {
      const ps = (field: string) => execFileSync("/bin/ps", ["-p", String(pid), "-o", `${field}=`],
        { encoding: "utf8", timeout: 1_000, maxBuffer: 4_096 }).trim();
      const startedAt = ps("lstart");
      return startedAt ? { startedAt, commandLine: ps("command"), state: ps("stat") } : undefined;
    } catch { return undefined; }
  };
  for (const agent of agentProcesses) {
    const matches = () => {
      const identity = agentIdentity(agent.pid);
      if (!identity) {
        let alive = false;
        try { process.kill(agent.pid, 0); alive = true; } catch {}
        if (alive) throw new Error("Could not identify orphaned native agent");
        return false;
      }
      return identity.startedAt === agent.startedAt && identity.commandLine === agent.commandLine &&
        !identity.state.startsWith("Z");
    };
    if (!matches()) continue;
    try { process.kill(agent.pid, "SIGTERM"); }
    catch (error) { if (matches()) throw error; }
    const limit = Date.now() + 3_000;
    while (matches() && Date.now() < limit) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
    if (matches()) {
      try { process.kill(agent.pid, "SIGKILL"); }
      catch (error) { if (matches()) throw error; }
      const killLimit = Date.now() + 1_000;
      while (matches() && Date.now() < killLimit) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
      if (matches()) throw new Error("Orphaned native agent did not stop; refusing duplicate recovery");
    }
  }
  agentProcesses.length = 0;
  const saveAgentProcesses = (): void => writeFileAtomic(agentProcessesFile, JSON.stringify(agentProcesses));
  saveAgentProcesses();
  const trackAgentProcess = (pid: number): (() => void) => {
    const identity = agentIdentity(pid);
    if (!identity || !identity.commandLine) throw new Error("Could not identify native agent process");
    const entry = { pid, commandLine: identity.commandLine, startedAt: identity.startedAt };
    agentProcesses.push(entry);
    try { saveAgentProcesses(); }
    catch (error) { agentProcesses.pop(); throw error; }
    return () => {
      const index = agentProcesses.indexOf(entry);
      if (index >= 0) { agentProcesses.splice(index, 1); saveAgentProcesses(); }
    };
  };
  // An older build stored a terminal opt-in. Retire it on first launch so rollback cannot
  // silently restore that permission after interactive sessions have been removed.
  rmSync(join(dir, "terminal-settings.json"), { force: true });
  recoverNativeTurns(dir);
  retireOrphanedCards(dir);
  const keys = { session: { publicKey: wireCrypto.sessionPub }, signing: { publicKey: wireCrypto.signingPub } };
  const provider = options.provider;
  const titler = options.titler ?? onDeviceTitler;
  /**
   * Whether this thread talks to OpenClaw through its `yorozu` channel plugin on `channel.sock`.
   * Only a `yorozu` thread does, and only without a caller-supplied provider.
   */
  const viaChannel = (threadId: string): boolean => !provider && threadAgent(threadId, dir) === "yorozu";
  const nativeRunners = options.nativeRunners ?? { "claude-code": claudeCodeRunner(undefined, trackAgentProcess),
    codex: codexNativeRunner((handlers) => connectCodex(handlers, trackAgentProcess)) };
  const builtInAgents: Record<string, AgentDescriptor> = {
    "claude-code": { id: "claude-code", label: "Claude Code", needsFolder: true },
    codex: { id: "codex", label: "Codex", needsFolder: true },
  };
  const agentDescriptors: AgentDescriptor[] = [{ id: "yorozu", label: "Yorozu", needsFolder: false }];
  for (const [id, runner] of Object.entries(nativeRunners)) {
    if (!validAgentId(id) || id === "yorozu") throw new Error(`invalid registered agent "${id}"`);
    const builtIn = Object.hasOwn(builtInAgents, id);
    if (runner.descriptor && (runner.descriptor.id !== id || builtIn))
      throw new Error(`agent "${id}" cannot claim a built-in identity`);
    const descriptor = runner.descriptor ?? (builtIn ? builtInAgents[id] : undefined);
    if (!descriptor) throw new Error(`agent "${id}" needs a descriptor`);
    if (validAgentDescriptor(descriptor) && agentDescriptors.length < 32)
      agentDescriptors.push(descriptor);
  }
  const log = options.log ?? ((line: string) => void stdout.write(`${line}\n`));
  const heartbeat = options.heartbeat ?? { pingMs: PING_MS, pongMs: PONG_MS };
  const state = (name: string) => log(`STATE ${name}`);
  const peerInfo = hostPeerInfo(dir, options.appVersion ?? env.YOROZU_APP_VERSION ?? "unknown");
  // An expired operation ID stays barred after restart. The old encrypted relay copy may
  // arrive later, while a fresh user confirmation must carry a new ID and deadline.
  const admissionStore = new ExpiredAdmissions(dir);
  const expiredAdmissions = admissionStore.records;
  // A Stop is bound to one accepted operation. Keep its intent through sidecar replacement,
  // including the backend run identity needed to finish an interrupted abort request.
  const stopStore = new StopStore(dir);
  const acceptedStore = new AcceptedMessages(dir);
  const stoppedTurns = stopStore.records;
  let startupRecovery: Promise<void> = Promise.resolve();
  const rememberStop = (record: StopRecord): Promise<void> => stopStore.save(record);
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
  const terminateRunning = new Map<string, () => void>();
  const steerRunning = new Map<string, Parameters<NonNullable<NativeTurn["onSteer"]>>[0]>();
  const steering = new Map<string, { threadId: string; promise: Promise<void> }>();
  const steered = new Set<string>();
  type SteeringRecord = { eventId: string; threadId: string; attemptId: string;
    activeEventId: string; completionId: string; status: "attempting" | "delivered" | "rejected" };
  const steeringRecords = new Map<string, SteeringRecord>();
  let steeringFenced = false;
  for (let offset: number | null = 0; offset !== null;) {
    const page = syncHostRequest(dir, { op: "steering_list", offset });
    for (const record of page.records as SteeringRecord[]) {
      steeringRecords.set(record.eventId, record);
      if (record.status === "delivered") steered.add(record.eventId);
    }
    offset = page.next as number | null;
  }
  const uncertainSteering = (eventId: string): boolean => steeringRecords.get(eventId)?.status === "attempting";
  const uncertainActiveSteering = (threadId: string, activeEventId: string): boolean =>
    [...steeringRecords.values()].some((record) => record.threadId === threadId &&
      record.activeEventId === activeEventId && record.status === "attempting");
  const stopTimers = new Map<string, ReturnType<typeof setTimeout>>();
  type TurnState = "idle" | "starting" | "running" | "stopping" | "stopped-unconfirmed";
  const turnStates = new Map<string, { state: TurnState; activeEventId?: string; queued: string[] }>();
  const channelRuns = new Map<string, { threadId: string; status?: RunStatus; replied?: boolean;
    calls?: Set<string>; results?: Set<string>; replyDraft?: Extract<YorozuEvent, { kind: "message" }> }>();
  const pendingChannelAdmissions = new Map<string, { threadId: string; fresh: boolean; promise: Promise<void> }>();
  const admitChannel = (message: ChannelInbound, fresh: boolean): Promise<void> => {
    const existing = pendingChannelAdmissions.get(message.id);
    if (existing) return existing.promise;
    const promise = channel.forward(message).then(async () => {
      const stop = stoppedTurns.get(message.id);
      if (stop?.preDispatch) await withdrawBeforeDispatch(stop);
      else if (stop?.status === "withdrawn") await channel.withdraw(message.id);
    });
    pendingChannelAdmissions.set(message.id, { threadId: message.threadId, fresh, promise });
    void promise.finally(() => {
      if (pendingChannelAdmissions.get(message.id)?.promise === promise) pendingChannelAdmissions.delete(message.id);
    }).catch(() => {});
    return promise;
  };
  const pendingChanges = new Map<string, Promise<void>>();
  const workingThreadIds = (): string[] =>
    [...turnStates].filter(([, turn]) => turn.state !== "idle").map(([id]) => id);
  const turnQueues = new Map<string, Promise<void>>();
  const nativeQueueFile = join(dir, "native-turn-queue.json");
  type NativeQueueEntry = { threadId: string; eventId: string };
  const queuedNative: NativeQueueEntry[] = existsSync(nativeQueueFile)
    ? JSON.parse(readFileSync(nativeQueueFile, "utf8")) as NativeQueueEntry[] : [];
  if (!Array.isArray(queuedNative) || !queuedNative.every((entry) =>
    typeof entry?.threadId === "string" && !!entry.threadId &&
    typeof entry.eventId === "string" && !!entry.eventId)) throw new Error("Invalid native turn queue");
  syncHostRequest(dir, { op: "queue_open", expectedHash: existsSync(nativeQueueFile)
    ? createHash("sha256").update(readFileSync(nativeQueueFile)).digest("hex") : null });
  const removeNativeQueue = (eventId: string): void => {
    const index = queuedNative.findIndex((entry) => entry.eventId === eventId);
    if (index >= 0) {
      syncHostRequest(dir, { op: "queue_remove", eventId, threadId: queuedNative[index]!.threadId });
      queuedNative.splice(index, 1);
    }
  };
  const nativeRecoveryStarted = new Set<string>();
  const admittedTurns = new Map<string, Promise<void>>();
  const activeTurnIds = new Set<string>();
  const postponeFile = join(dir, "update-postponed-until.json");
  const pendingSinceFile = join(dir, "update-pending-since.json");
  let postponedUntil = 0;
  try {
    const stored: unknown = JSON.parse(readFileSync(postponeFile, "utf8"));
    if (typeof stored === "number" && Number.isFinite(stored)) postponedUntil = stored;
  } catch {}
  let pendingSince: { updateId: string; since: number } | undefined;
  try {
    const stored: unknown = JSON.parse(readFileSync(pendingSinceFile, "utf8"));
    if (stored && typeof stored === "object" && !Array.isArray(stored) &&
        typeof (stored as { updateId?: unknown }).updateId === "string" &&
        Number.isSafeInteger((stored as { since?: unknown }).since)) {
      pendingSince = stored as { updateId: string; since: number };
    }
  } catch {}
  const updateGate = new UpdateGate(postponedUntil, pendingSince);
  const openToolCalls = new Map<string, Set<string>>();
  const drainPauses = new Map<string, () => void>();
  const drainInterrupted = new Set<string>();
  const drainWaiters = new Set<() => void>();
  const wakeDrainWaiters = (): void => {
    for (const wake of drainWaiters) wake();
    drainWaiters.clear();
  };
  const pauseAtSafePoint = (threadId: string): void => {
    if (updateGate.draining && !(openToolCalls.get(threadId)?.size)) drainPauses.get(threadId)?.();
  };
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
  /** Merge legacy pairing counters before their fields can be stripped from devices.json. */
  const writeSeqs = (): void => {
    const seqs: ChannelSeqs = Object.fromEntries(
      [...devices.values()].map(({ record }) => [record.pub, { sendSeq: record.sendSeq ?? 0, recvSeq: record.recvSeq ?? 0 }]),
    );
    sessionSequences.save(seqs);
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
    const stored = sessionSequences.get(record.pub);
    record.sendSeq = Math.max(record.sendSeq ?? 0, before?.record.sendSeq ?? 0, stored.sendSeq);
    record.recvSeq = Math.max(record.recvSeq ?? 0, before?.record.recvSeq ?? 0, stored.recvSeq);
    record.peerInfoRequired ??= before?.record.peerInfoRequired;
    wireCrypto.validate(record.pub);
    devices.set(record.pub, {
      format: record.peerInfoRequired ? "current" : null,
      record,
    });
  };
  let migratedPairingTime = false;
  // Rust validates and retains legacy counters before the pairing projection can strip them.
  let legacySeqs = false;
  // Never more than the relay will be told about: a file past the cap is read up to it.
  for (const record of loadDevices(devicesFile).slice(0, MAX_DEVICES)) {
    // A key on disk we can no longer agree with is simply dropped, not a reason not to start.
    const seqs = sessionSequences.get(record.pub);
    record.sendSeq = Math.max(record.sendSeq ?? 0, seqs.sendSeq);
    record.recvSeq = Math.max(record.recvSeq ?? 0, seqs.recvSeq);
    if ((!sessionSequences.hasProjection && (record.sendSeq || record.recvSeq)) ||
        record.sendSeq !== seqs.sendSeq || record.recvSeq !== seqs.recvSeq) legacySeqs = true;
    try {
      // Older releases never recorded first pairing. Do not invent historical access:
      // start a conservative cutoff once, before even a no-hello reconnect can sync.
      if (!Number.isFinite(record.pairedAt) || !record.pairedAt || record.pairedAt < 0) {
        record.pairedAt = Date.now();
        migratedPairingTime = true;
      }
      wireCrypto.validate(record.pub);
    } catch {
      // Not a usable X25519 key any more.
      continue;
    }
    remember(record);
  }
  // A legacy pairing can carry higher currency even when a projection already exists.
  // Prove those counters before rewriting the pairing file without them.
  if (legacySeqs) writeSeqs();
  if (migratedPairingTime) saveDevices();

  /**
   * The same thing for devices on the local socket, which need no key: the Mac app is one more
   * paired device, it just reached us without the relay. Kept apart from ``devices`` only
   * because what it stores per device is a writer rather than a session key.
   */
  const locals = new Map<string, Send>();

  let socket: RustRelaySocket | null = null;
  // OPEN only means transport connected; the relay accepts application traffic after register.
  let relayReady = false;
  let relay: ReturnType<typeof startRustRelay> | undefined;
  let stopped = false;
  const catchupQueue = new CatchupQueue(dir);
  const catchupSends = new Map<string, { connection: RustRelaySocket; device: PairedDevice; generation: string }>();
  let catchupTimer: NodeJS.Timeout | null = null;
  /**
   * Secrets behind the QRs on screen, newest last. A phone's first `hello` proves it holds one
   * of them, and pairing spends them all: a QR is for one phone, and the next one is drawn fresh.
   */
  const pairingSecrets = new Set<string>();
  const PAIRING_SECRETS = 4;
  /** A relay-format frame body from a phone on the direct path. Replaced per relay connection. */
  let onDirectFrame: (payload: string) => void = () => {};
  const directPort = Number(env.YOROZU_DIRECT_PORT);
  const directConfig = options.direct ?? (Number.isInteger(directPort) && directPort > 0 && env.YOROZU_DIRECT_URL
    ? { port: directPort, url: env.YOROZU_DIRECT_URL } : undefined);
  const direct: Direct | undefined = directConfig && startDirect({
    port: directConfig.port,
    known: (pub) => [...devices.values()].some(({ record }) => record.signingPub === pub),
    onFrame: (_, payload) => onDirectFrame(payload),
    onError: state,
  });
  /** The direct socket a device is on right now, if any; its boxes skip the relay. */
  const directFor = (known: PairedDevice): WebSocket | undefined =>
    known.record.signingPub ? direct?.socketFor(known.record.signingPub) : undefined;
  /** Seals and sends to one paired device. Replaced per connection, a no-op while there is none. */
  let sendTo: (device: string, event: YorozuEvent) => void = () => {};
  // A negative result means a trace was held (-1) or is too large to send live (-2).
  let sendToAll: (event: YorozuEvent, maxBuffered?: number) => number = () => 0;
  const liveReplies = new Map<string, YorozuEvent>();
  const partials = new Map<string, YorozuEvent>();
  // Full-text partials grow quadratically on a slow link. Beyond this preview, pace
  // relay snapshots by their transfer cost while local Mac clients keep live updates.
  const LIVE_PARTIAL_BYTES = 16 * 1024;
  const largePartialAt = new Map<string, number>();
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
    if (announce && statusPush(event)) notifyRelay(event);
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
        largePartialAt.delete(event.threadId);
        const queued = traces.get(event.threadId);
        if (queued) {
          traces.delete(event.threadId);
          traceCount -= queued.length;
          traceBytes -= queued.reduce((sum, trace) => sum + Buffer.byteLength(JSON.stringify(trace)), 0);
          if (queued.some(durableTrace)) noteSkippedTrace();
        }
      } else {
        liveReplies.set(event.threadId, event);
        if (Buffer.byteLength(event.data.text) > LIVE_PARTIAL_BYTES) {
          partials.delete(event.threadId);
          for (const send of locals.values()) send(event);
          const now = Date.now();
          if (now < (largePartialAt.get(event.threadId) ?? 0)) return;
          // Four reference transfer times at 64 KiB/s between snapshots. The actual link
          // speed is unknown; the relay buffer cap is the second bound. Final is never held.
          const batches = sendToAll(event, TRACE_BYTES);
          if (batches > 0) {
            largePartialAt.set(event.threadId, now + Math.ceil(Buffer.byteLength(event.data.text) * 4_000 / 65_536));
            if (announce && statusPush(event)) notifyRelay(event);
          }
          return;
        }
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

  const updateStatusFor = (device: string | undefined, requestId?: string) => {
    const status = currentUpdateStatus(requestId);
    const compatibility = device ? devices.get(device)?.compatibility : undefined;
    if (status.phase === "draining" && device && devices.has(device) &&
        (compatibility?.state !== "compatible" || !compatibility.capabilities.includes("update-drain-v1"))) {
      return { ...status, phase: "waiting" as const, deadline: undefined };
    }
    return status;
  };

  function pushUpdateStatus(): void {
    for (const device of updateSubscribers) {
      const event = control({ kind: "update_status", data: updateStatusFor(device) });
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

  /**
   * The status each thread last had, for the events that can change it: the phone is woken
   * only when a thread moves into needs-approval, needs-input, failed or done, not for each
   * further card or reply while it is already there. Ordered as `ThreadStatus` on the clients.
   */
  const lastStatus = new Map<string, "approval" | "input" | "failed" | "working" | "done" | "idle">();
  const statusOf = (threadId: string, working?: boolean) => {
    const thread = threadSummary(threadId, dir);
    const turn = turnStates.get(threadId);
    if (thread.awaitingApproval) return "approval";
    if (thread.awaitingQuestion) return "input";
    if (thread.needsAttention || thread.interruptedTurnId || turn?.state === "stopped-unconfirmed") return "failed";
    if (working ?? (turn !== undefined && turn.state !== "idle")) return "working";
    return (thread.lastAgentAt ?? 0) > (thread.lastReadAt ?? 0) ? "done" : "idle";
  };
  /** Whether `event` moved its thread into a status worth waking the phone for. */
  const statusPush = (event: YorozuEvent): boolean => {
    const { threadId } = event;
    const finalReply = event.kind === "message" && event.data.role === "agent" &&
      event.data.done === true && event.parentAgentId === undefined;
    if (!threadId || !(finalReply || ["approval_card", "approval_answer", "approval_status", "question_card",
      "question_answer", "interrupt"].includes(event.kind) || event.kind === "message" && event.data.role === "user"))
      return false;
    // A user message starts a turn before the host has said so; a final reply ends it, unless
    // another turn is already queued behind it.
    const status = statusOf(threadId, event.kind === "message" && !finalReply ? true
      : finalReply ? (turnStates.get(threadId)?.queued.length ?? 0) > 0 : undefined);
    const previous = lastStatus.get(threadId);
    lastStatus.set(threadId, status);
    return status !== previous && status !== "working" && status !== "idle" && notifyFor(event) !== null;
  };

  /** Everything the runtime sees is logged first: the nightly job reads the log back. */
  function emit(event: YorozuEvent): void {
    // Startup/lifecycle copy is live UI state, not conversation history or memory material.
    const transient = event.kind === "thought" && event.data.transient === true;
    if (!transient) {
      persistThreadAndTranscript(event, dir);
    }
    broadcast(event);
    // A raised card shows on the list as well as in the chat, so the list follows it.
    if (["approval_card", "approval_answer", "approval_status", "question_card", "question_answer"].includes(event.kind))
      broadcast(threadList());
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

  const threadList = (minTs = 0, includeTurnState = true): YorozuEvent => {
    const { yolo } = loadSettings(dir);
    return control({ kind: "thread_list", data: { threads: threadSummaries(dir, minTs).map((thread) => {
      const interruptedTurnId = thread.interruptedTurnId;
      const stopping = interruptedTurnId && [...stoppedTurns.values()].some((stop) =>
        stop.threadId === thread.id && stop.status === "requested" &&
        completionIdFor(thread.id, stop.targetEventId) === interruptedTurnId);
      return {
        ...thread,
        ...(thread.agent && thread.agent !== "yorozu" ? { bypass: yolo } : {}),
        ...(runningEventIds.has(thread.id) ? { activeEventId: runningEventIds.get(thread.id) } : {}),
        ...(includeTurnState ? {
          activeEventId: turnStates.get(thread.id)?.activeEventId,
          turnState: turnStates.get(thread.id)?.state ?? "idle",
          queuedTurnCount: turnStates.get(thread.id)?.queued.length ?? 0,
          queuedEventIds: [...(turnStates.get(thread.id)?.queued ?? [])],
          canRewind: !viaChannel(thread.id),
        } : {}),
        ...(stopping ? { interruptedTurnId: undefined, canResume: undefined, recoveryState: undefined } : {}),
      };
    }) } });
  };
  const broadcastActiveThreadList = (): void => {
    for (const id of liveReplies.keys()) if (!running.has(id) && (turnStates.get(id)?.state ?? "idle") === "idle") liveReplies.delete(id);
    if (locals.size || [...devices.values()].some((device) => device.compatibility?.state === "compatible" &&
        (device.compatibility.capabilities.includes("exact-stop-v1") ||
          device.compatibility.capabilities.includes("turn-state-v1")))) broadcast(threadList());
  };

  const publishTurnState = (threadId: string): void => {
    if (turnStates.has(threadId)) broadcastActiveThreadList();
  };

  const admitTurn = (threadId: string, eventId: string): void => {
    const turn = turnStates.get(threadId) ?? { state: "idle" as TurnState, queued: [] as string[] };
    if (turn.state === "idle" || !turn.activeEventId) {
      turn.state = "starting";
      turn.activeEventId = eventId;
    } else turn.queued.push(eventId);
    turnStates.set(threadId, turn);
    publishTurnState(threadId);
  };

  const startTurnState = (threadId: string, eventId: string): void => {
    const turn = turnStates.get(threadId) ?? { state: "starting" as TurnState, activeEventId: eventId, queued: [] as string[] };
    if (turn.activeEventId === eventId) turn.state = "running";
    turnStates.set(threadId, turn);
    publishTurnState(threadId);
  };

  const finishTurnState = (threadId: string, eventId: string): void => {
    const turn = turnStates.get(threadId);
    if (!turn || turn.activeEventId !== eventId) return;
    const next = turn.queued.shift();
    turn.activeEventId = next;
    turn.state = next ? "starting" : "idle";
    publishTurnState(threadId);
  };

  /**
   * What a thread can be put on, by name. Sent with the thread list rather than on request: a
   * phone's model picker is one tap away from the thread it is about, and asking for the list
   * at that point would draw an empty menu first.
   */
  const agentModels: Record<string, ModelOption[]> = {};
  let skillsByAgent: Record<string, SkillOption[]> = {};
  let codexSkillPaths = new Map<string, string>();
  let skillsBuiltAt: number | undefined;
  let skillsRefreshing: Promise<void> | undefined;
  const refreshSkills = (): Promise<void> => {
    if (skillsRefreshing) return skillsRefreshing;
    if (skillsBuiltAt !== undefined && Date.now() - skillsBuiltAt < 600_000) return Promise.resolve();
    const refresh = Promise.all(agentDescriptors.map(async ({ id }) => {
      try {
        const skills = await Promise.resolve().then(() =>
          id === "yorozu" ? [] : nativeRunners[id]?.skills?.() ?? []);
        return { id, skills: skills as (SkillOption & { path?: string })[] };
      } catch {
        return { id, skills: [] as (SkillOption & { path?: string })[] };
      }
    })).then((listed) => {
      const visible = (skills: SkillOption[]): SkillOption[] => {
        const seen = new Set<string>();
        return skills.flatMap((skill) => {
          if (!skill || typeof skill.name !== "string" || !skill.name || seen.has(skill.name)) return [];
          seen.add(skill.name);
          return [{ name: skill.name,
            description: typeof skill.description === "string" ? skill.description.slice(0, 200) : "",
            ...(typeof skill.argumentHint === "string" && skill.argumentHint
              ? { argumentHint: skill.argumentHint.slice(0, 80) } : {}) }];
        });
      };
      const next: Record<string, SkillOption[]> = {};
      for (const { id, skills } of listed) next[id] = visible(skills);
      const codex = listed.find(({ id }) => id === "codex");
      const paths = new Map<string, string>();
      for (const skill of codex?.skills ?? []) {
        if (skill && typeof skill.path === "string" && !paths.has(skill.name) &&
            next.codex?.some((shown) => shown.name === skill.name)) paths.set(skill.name, skill.path);
      }
      codexSkillPaths = paths;
      skillsBuiltAt = Date.now();
      if (JSON.stringify(next) !== JSON.stringify(skillsByAgent)) {
        skillsByAgent = next;
        if (!stopped) broadcast(modelList());
      }
    }).finally(() => { if (skillsRefreshing === refresh) skillsRefreshing = undefined; });
    skillsRefreshing = refresh;
    return refresh;
  };
  const modelsFor = (agent: ThreadAgent): ModelOption[] =>
    agent === "yorozu" ? legacy?.models() ?? [] : agentModels[agent] ?? [];
  /** The efforts a thread may ask for: its model's, or the first model's while it is on Default. */
  const effortsFor = (agent: ThreadAgent, model: string | undefined): ReasoningEffort[] =>
    (modelsFor(agent).find((m) => m.id === model) ?? modelsFor(agent)[0])?.efforts ?? [];
  /** What plugins can do, in the order clients name what is missing. */
  const CHANNEL_CAPABILITIES = ["run-boundary-v1", "progress-v1", "model-select-v1", "media-v1", "reply-stream-v1", "reply-context-v1"];
  /**
   * What the connected plugin announced, then `missing:<capability>` for each it did not, so a
   * client can tell an outdated plugin (some `missing:`) from no plugin (empty).
   */
  const channelCapabilities = (): string[] => {
    if (provider || !channel.connected) return [];
    const { announced } = channel;
    return [...CHANNEL_CAPABILITIES.filter((c) => announced.has(c)),
      ...CHANNEL_CAPABILITIES.filter((c) => !announced.has(c)).map((c) => `missing:${c}`)];
  };
  const modelList = (): YorozuEvent =>
    control({ kind: "model_list", data: { models: modelsFor("yorozu"), agentModels, agents: agentDescriptors, skills: skillsByAgent, channelCapabilities: channelCapabilities() } });

  void refreshSkills();

  for (const { id: agent } of agentDescriptors.filter(({ id }) => id !== "yorozu")) {
    const runner = nativeRunners[agent];
    if (!runner?.models) continue;
    void Promise.resolve().then(() => runner.models!()).then((models) => {
      agentModels[agent] = models;
      if (!stopped) broadcast(modelList());
    }).catch(() => state(`native-model-list-unavailable ${agent}`));
  }

  /**
   * Where a coding agent's thread can be started. Sent with the thread list, like the models:
   * the picker is one tap from the agent choice, and asking then would draw an empty list first.
   */
  const projectList = (): YorozuEvent => control({ kind: "project_list", data: { projects: listProjects(undefined, dir) } });

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
    try { catchupQueue.cancel(pub); } catch { state("catchup-unavailable"); socket?.close(); }
    activeSearchRequests.delete(pub);
    devices.delete(pub);
    wireCrypto.forget(pub);
    saveDevices();
    if (known.record.signingPub) {
      revokeAtRelay(known.record.signingPub);
      direct?.drop(known.record.signingPub);
    }
    state("revoked");
    pushDevices();
  };

  /** A bounded replay page. An explicit thread request includes its pre-pairing history. */
  const syncDelta = (lastSeen: Record<string, string>, pairedAt = 0, threadId?: string,
    includeApprovalStatus = true, focusThreadId?: string, includeCurrent = true,
    replayBytes = SYNC_PAGE_BYTES, replayEvents = SYNC_LIMIT, phoneCanDownload: boolean | null = null): YorozuEvent[] => {
    const events: YorozuEvent[] = [];
    const cards: YorozuEvent[] = [];
    const allThreads = listThreads(dir);
    const selected = allThreads.filter((thread) => threadId ? thread.id === threadId : !thread.archived);
    const focused = !threadId && selected.find((thread) => thread.id === focusThreadId);
    if (focused) {
      selected.splice(selected.indexOf(focused), 1);
      selected.unshift(focused);
    }
    const activeCards = (id: string, history: YorozuEvent[]): YorozuEvent[] => {
      const answered = new Set(history.flatMap((event) => event.kind === "approval_answer" ? [event.data.actionId]
        : event.kind === "approval_status" && event.data.status !== "rejected" ? [event.data.actionId]
        : event.kind === "question_answer" ? [event.data.questionId] : []));
      return history.filter((event) => event.kind === "approval_card"
        ? !answered.has(event.data.actionId) &&
          (pending.get(event.data.actionId)?.threadId === id || nativeCards.has(event.data.actionId, id))
        : event.kind === "question_card" && !answered.has(event.data.questionId) &&
          questions.has(event.data.questionId, id));
    };
    let latest: YorozuEvent | undefined;
    if (focused && includeCurrent) {
      const history = visibleThreadEvents(focused.id, dir).filter((event) => event.ts >= pairedAt);
      const live = running.has(focused.id) || (turnStates.get(focused.id)?.state ?? "idle") !== "idle" ? liveReplies.get(focused.id) : undefined;
      const reply = live && live.ts >= pairedAt ? live : undefined;
      latest = reply ?? history.findLast((event) =>
        event.kind === "message" && event.data.role === "agent" && !event.parentAgentId);
      if (running.has(focused.id)) cards.push(...activeCards(focused.id, history));
    }
    if (!threadId && includeCurrent) {
      const waiting = new Set([...pending.values()].map((card) => card.threadId));
      for (const id of nativeCards.waitingThreads()) waiting.add(id);
      for (const id of questions.waitingThreads()) waiting.add(id);
      for (const thread of allThreads) {
        if (thread.archived && waiting.has(thread.id)) {
          cards.push(...activeCards(thread.id,
            readThreadEvents(thread.id, dir).filter((event) => event.ts >= pairedAt)));
        }
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
      data: { events, ...(current.length ? { current } : {}),
        workingThreadIds: workingThreadIds(),
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
    `${threadAgent(threadId, dir) === "yorozu" ? "legacy" : "native"}:${userEventId}:final`;

  const nativeRecoveryPrompt = (threadId: string, original: string, userEventId?: string): string => {
    const recent = visibleThreadEvents(threadId, dir).filter((event) =>
      event.kind === "message" || event.kind === "tool_call" || event.kind === "tool_result").filter((event) =>
      !(event.kind === "message" && event.data.role === "user" && event.id !== userEventId &&
        (uncertainSteering(event.id) || queuedNative.some((entry) => entry.eventId === event.id))))
      .slice(-20).map((event) => {
      if (event.kind === "message") return `${event.data.role}: ${event.data.text.slice(0, 2_000)}`;
      if (event.kind === "tool_call") return `tool call ${event.data.name}: ${JSON.stringify(event.data.args).slice(0, 2_000)}`;
      return `tool result ${event.data.callId}: ${event.data.output.slice(0, 2_000)}`;
    }).join("\n").slice(-12_000);
    return `Resume the interrupted task. Verify prior actions and their outcomes before repeating any external effect. ` +
      `Continue unfinished work and answer the original request.\nOriginal request: ${original}\nRecent host record:\n${recent}`;
  };

  const withStoppedContext = (threadId: string, original: string, userEventId?: string): string => {
    const messages = visibleThreadEvents(threadId, dir).filter((event) => event.kind === "message");
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
    largePartialAt.delete(threadId);
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
      let startTree: Awaited<ReturnType<typeof workingTree>>;
      let changesScheduled = false;
      const reportChanges = (): void => {
        if (changesScheduled) return;
        if (startTree && userEventId) {
          changesScheduled = true;
          const turnEventId = userEventId;
          const pending = changedFiles(startTree).then((files) => {
            if (files.length) emit({ id: randomUUID(), threadId, ts: Date.now(), agentId: MAIN_AGENT,
              kind: "turn_changes", data: { turnEventId, files } });
          }).catch(() => {});
          pendingChanges.set(threadId, pending);
          void pending.finally(() => { if (pendingChanges.get(threadId) === pending) pendingChanges.delete(threadId); });
        }
      };
      const finish = (reply: string, failed = false): void => {
        const final = message(reply, true, failed);
        persistThreadAndTranscript(final, dir);
        broadcast(final);
        reportChanges();
      };
      // Finished, so the composer is not left offering Stop for a turn nobody is running.
      if (!runner || !agentDescriptors.some(({ id }) => id === agent)) {
        finish(`${agent} is no longer registered on this host.`, true);
        setNativeTurn(threadId, undefined, dir);
        broadcast(threadList());
        return;
      }
      // No folder, no agent: a thread from before folders were required, or one whose folder
      // has since left `~/Projects`, would otherwise run the agent wherever this sidecar sits.
      const home = threadHome(threadId, dir);
      if (agentDescriptors.find(({ id }) => id === agent)?.needsFolder && (!home.cwd || !isProjectFolder(home.cwd))) {
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
      const activityBuffer: YorozuEvent[] = [];
      let activityBytes = 0;
      let activityFlushScheduled = false;
      const flushActivity = (): void => {
        if (!activityBuffer.length || stopped) return;
        const events = activityBuffer.splice(0);
        activityBytes = 0;
        try {
          // Keep day boundaries explicit while preserving event order in each durable batch.
          let batch: YorozuEvent[] = [];
          for (const event of events) {
            if (batch.length && new Date(batch[0]!.ts).toISOString().slice(0, 10) !== new Date(event.ts).toISOString().slice(0, 10)) {
              persistThreadAndTranscriptBatch(batch, dir); for (const saved of batch) broadcast(saved); batch = [];
            }
            batch.push(event);
          }
          persistThreadAndTranscriptBatch(batch, dir); for (const saved of batch) broadcast(saved);
        } catch (error) {
          paused = true; turn.abort(); state("history-storage-failed"); throw error;
        }
      };
      const queueActivity = (event: YorozuEvent): void => {
        const bytes = Buffer.byteLength(JSON.stringify(event));
        if (activityBuffer.length && activityBytes + bytes > 8 * 1024 * 1024) flushActivity();
        activityBuffer.push(event);
        activityBytes += bytes;
        if (activityBuffer.length >= 256 || event.kind === "tool_call" || event.kind === "tool_result") { flushActivity(); return; }
        if (!activityFlushScheduled) {
          activityFlushScheduled = true;
          queueMicrotask(() => { activityFlushScheduled = false; try { flushActivity(); } catch { /* abort and retained intent report uncertainty */ } });
        }
      };
      const pauseForUpdate = (): void => {
        if (paused || turn.signal.aborted) return;
        paused = true;
        drainInterrupted.add(threadId);
        setNativeTurn(threadId, { id, state: "interrupted", ...(userEventId ? { userEventId } : {}), recoveryAttempts }, dir);
        broadcast(threadList());
        turn.abort();
      };
      drainPauses.set(threadId, pauseForUpdate);
      const seenResults = new Set(readThreadEvents(threadId, dir).filter((event) => event.kind === "tool_result").map((event) => event.id));
      try {
        const root = home.cwd ? gitRoot(home.cwd) : undefined;
        if (root) {
          const pending = pendingChanges.get(threadId);
          if (pending && !turn.signal.aborted) {
            let onAbort: () => void = () => {};
            const aborted = new Promise<void>((resolve) => {
              onAbort = resolve;
              turn.signal.addEventListener("abort", onAbort, { once: true });
            });
            try { await Promise.race([pending, aborted]); }
            finally { turn.signal.removeEventListener("abort", onAbort); }
          }
          if (!turn.signal.aborted) startTree = await workingTree(root, turn.signal);
        }
        while (!turn.signal.aborted) {
          if (recovering && userEventId && uncertainActiveSteering(threadId, userEventId)) {
            paused = true;
            setNativeTurn(threadId, { id, state: "interrupted", userEventId, recoveryAttempts }, dir);
            state("native-follow-up-unconfirmed");
            broadcast(threadList());
            return;
          }
          if (recovering) recoveryAttempts += 1;
          setNativeTurn(threadId, { id, state: "running", ...(userEventId ? { userEventId } : {}), recoveryAttempts,
            recoveryActive: recovering }, dir);
          broadcast(threadList());
          let executionStarted = false;
          try {
            const currentHome = threadHome(threadId, dir);
            const skillName = !recovering && agent === "codex" ? /^\/(\S+)(?=\s|$)/.exec(text)?.[1] : undefined;
            const skillPath = skillName ? codexSkillPaths.get(skillName) : undefined;
            // Written inside the attempt, so a full disk is this turn's failure and not the sidecar's.
            const files = attachmentFiles(threadId, userEventId ?? id, attachments, dir);
            const attached = files.map((file) =>
              `[attached: ${JSON.stringify(file.name)} (${JSON.stringify(file.mime)}) at ${file.path}]`).join("\n");
            let prompt = recovering ? nativeRecoveryPrompt(threadId, text, userEventId) : withStoppedContext(threadId,
              skillPath ? text.slice(skillName!.length + 1).trimStart() : text, userEventId);
            if (!currentHome.sessionId && latestRewindId(threadId, dir)) {
              const history = visibleThreadEvents(threadId, dir);
              const index = history.findIndex((event) => event.id === userEventId);
              const retained = history.slice(0, index < 0 ? history.length : index).flatMap((event) => {
                if (event.kind !== "message") return [];
                const files = attachmentFiles(threadId, event.id, event.data.attachments ?? [], dir);
                return [{ role: event.data.role, text: event.data.text, attachments: files }];
              });
              prompt = `Conversation before the rewind (files were not reverted):\n${JSON.stringify(retained)}\n\nNew user request:\n${prompt}`;
            }
            const done = await runner.run({
              threadId,
              text: [prompt, attached].filter(Boolean).join("\n\n"),
              ...(skillPath ? { skill: { name: skillName!, path: skillPath } } : {}),
              ...(files.length ? { attachments: files } : {}),
              ...currentHome,
              cwd: home.cwd ?? "",
              bypass: loadSettings(dir).yolo,
              model: threadModel(threadId, dir),
              effort: threadEffort(threadId, dir),
              signal: turn.signal,
              onSession: (sessionId) => { if (!stopped) { executionStarted = true; setThreadSession(threadId, sessionId, dir); } },
              onTerminate: (terminate) => { if (!stopped) terminateRunning.set(threadId, terminate); },
              onSteer: (steer) => { if (!stopped) steerRunning.set(threadId, steer); },
              approve: async (tool, input, signal) => {
                flushActivity(); return loadSettings(dir).yolo || nativeCards.approve(threadId, agent, tool, input, signal);
              },
              ask: (question, options, signal) => { flushActivity(); return nativeCards.ask(threadId, agent, question, options, signal); },
              beforeTool: async (signal) => {
                flushActivity();
                while (updateGate.draining && !signal.aborted) {
                  pauseAtSafePoint(threadId);
                  if (signal.aborted) break;
                  await new Promise<void>((resolve) => {
                    const wake = (): void => { signal.removeEventListener("abort", wake); drainWaiters.delete(wake); resolve(); };
                    drainWaiters.add(wake);
                    signal.addEventListener("abort", wake, { once: true });
                  });
                }
                return !signal.aborted && updateGate.status.phase !== "installing";
              },
              onToolBoundary: () => { flushActivity(); pauseAtSafePoint(threadId); },
              onUpdate: (reply) => { if (!turn.signal.aborted) { executionStarted = true; broadcast(message(reply)); } },
              onActivity: (key, payload) => {
                if (stopped) return;
                executionStarted = true;
                if (payload.kind === "tool_call") {
                  const calls = openToolCalls.get(threadId) ?? new Set<string>();
                  calls.add(payload.data.callId);
                  openToolCalls.set(threadId, calls);
                } else if (payload.kind === "tool_result") {
                  openToolCalls.get(threadId)?.delete(payload.data.callId);
                }
                const event: YorozuEvent = { id: `${agent}:${threadId}:${key}`, threadId, ts: Date.now(), agentId: MAIN_AGENT, ...payload };
                const newResult = event.kind === "tool_result" && event.data.ok && !seenResults.has(event.id);
                queueActivity(event.kind === "tool_result" ? stashToolResult(event, dir) : event);
                if (newResult) {
                  seenResults.add(event.id);
                  recoveryAttempts = 0;
                  setNativeTurn(threadId, { id, state: "running", ...(userEventId ? { userEventId } : {}), recoveryAttempts,
                    recoveryActive: recovering }, dir);
                }
                if (payload.kind === "tool_result") { pauseAtSafePoint(threadId); wakeDrainWaiters(); }
              },
            }).finally(async () => {
              steerRunning.delete(threadId);
              await Promise.all([...steering.values()].filter((entry) => entry.threadId === threadId).map((entry) => entry.promise));
            });
            if (stopped) return;
            flushActivity();
            if (done.sessionId && done.sessionId !== currentHome.sessionId) setThreadSession(threadId, done.sessionId, dir);
            const stop = userEventId ? stoppedTurns.get(userEventId) : undefined;
            if (done.completed && stop && (stop.status === "requested" || stop.status === "unconfirmed")) {
              finish(done.text);
              await completeStop(stop, "completed");
              return;
            }
            if (turn.signal.aborted) return;
            if (done.failed) throw new Error(`${agent} reported an unsuccessful turn`);
            finish(done.text);
            return;
          } catch (error) {
            try { flushActivity(); } catch { /* durable failure already aborted this turn */ }
            openToolCalls.delete(threadId);
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
        drainPauses.delete(threadId);
        terminateRunning.delete(threadId);
        steerRunning.delete(threadId);
        openToolCalls.delete(threadId);
        if (running.get(threadId) === turn) running.delete(threadId);
        if (runningEventIds.get(threadId) === userEventId) runningEventIds.delete(threadId);
        const stop = userEventId ? stoppedTurns.get(userEventId) : undefined;
        if (stop) await completeStop(stop);
        if (stop && !paused) reportChanges();
        if (!stopped && !paused) {
          setNativeTurn(threadId, undefined, dir);
          broadcast(threadList());
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
      await backend.run(threadId, userEventId, turn.signal,
        (text) => broadcast(message(text)), (text) => emit(message(text, true)));
    } finally {
      if (running.get(threadId) === turn) running.delete(threadId);
      if (runningEventIds.get(threadId) === userEventId) runningEventIds.delete(threadId);
      const stop = userEventId ? stoppedTurns.get(userEventId) : undefined;
      if (stop) await completeStop(stop);
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
    const turnKey = userEventId ?? randomUUID();
    if (userEventId && stoppedTurns.has(userEventId)) return Promise.resolve();
    if (updateGate.status.phase === "installing") return Promise.reject(new Error("Mac is installing an update"));
    updateGate.activity();
    const admitted = userEventId ? admittedTurns.get(userEventId) : undefined;
    if (admitted) return admitted;
    if (userEventId && threadAgent(threadId, dir) !== "yorozu" &&
        !queuedNative.some((entry) => entry.eventId === userEventId)) {
      syncHostRequest(dir, { op: "queue_enqueue", threadId, eventId: userEventId });
      queuedNative.push({ threadId, eventId: userEventId });
    }
    admitTurn(threadId, turnKey);
    const previous = turnQueues.get(threadId) ?? Promise.resolve();
    const queuedBehindTurn = turnQueues.has(threadId);
    const next = previous.catch(() => {}).then(async () => {
      while ((updateGate.draining || updateGate.status.phase === "installing") && !stopped) {
        await new Promise<void>((resolve) => drainWaiters.add(resolve));
      }
      if (stopped) return;
      if (userEventId) await steering.get(userEventId)?.promise;
      if (userEventId && uncertainSteering(userEventId)) {
        finishTurnState(threadId, turnKey);
        return;
      }
      if (userEventId && (!stopStore.available || !acceptedStore.available || steeringFenced || stoppedTurns.has(userEventId) || steered.has(userEventId) || uncertainSteering(userEventId))) return;
      const logged = queuedBehindTurn ? acceptedEvent : undefined;
      if (logged) {
        // A queued message was admitted while an earlier turn ran. Append its corrected
        // position after that turn, leaving the original log entry for replay cursors.
        const prior = readThreadEvents(threadId, dir);
        const existing = prior.find((known) => known.id === logged.id);
        if (existing?.clientTs === undefined) {
          const original = existing?.kind === "message" ? existing : logged;
          const ordered = { ...original, ts: Math.max(Date.now(), prior.at(-1)?.ts ?? 0),
            clientTs: original.clientTs ?? original.ts };
          persistThreadAndTranscript(ordered, dir);
          broadcast(ordered);
        }
      }
      if (userEventId && threadAgent(threadId, dir) !== "yorozu") syncHostRequest(dir, { op: "queue_ready" });
      startTurnState(threadId, turnKey);
      if (userEventId) activeTurnIds.add(userEventId);
      try { await runTurn(threadId, text, recorded, attachments, userEventId); }
      finally {
        if (userEventId) activeTurnIds.delete(userEventId);
        finishTurnState(threadId, turnKey);
      }
    });
    turnQueues.set(threadId, next);
    if (userEventId) admittedTurns.set(userEventId, next);
    void next.finally(() => {
      if (stopped) return;
      if (turnQueues.get(threadId) === next) turnQueues.delete(threadId);
      if (userEventId && admittedTurns.get(userEventId) === next) admittedTurns.delete(userEventId);
      if (!updateGate.draining && updateGate.status.phase !== "installing" && drainInterrupted.has(threadId) &&
          resumeNativeTurn(threadId)) drainInterrupted.delete(threadId);
      if (userEventId && queuedNative.some((entry) => entry.eventId === userEventId) &&
          readThreadEvents(threadId, dir).some((event) =>
            event.id === completionIdFor(threadId, userEventId) && event.kind === "message" && event.data.done)) {
        removeNativeQueue(userEventId);
      }
    }).catch(() => {});
    return next;
  }

  function steerMessage(event: YorozuEvent & { kind: "message" }, attemptId = event.id): Promise<void> {
    const existing = steering.get(event.id);
    if (existing) return existing.promise;
    if (steeringFenced || steered.has(event.id) || uncertainSteering(event.id)) return Promise.resolve();
    const turn = turnStates.get(event.threadId);
    const steer = steerRunning.get(event.threadId);
    const active = turn?.activeEventId;
    if (!steer || !active || turn.state !== "running" || !turn.queued.includes(event.id) ||
        stoppedTurns.has(event.id) || updateGate.draining || updateGate.status.phase === "installing" ||
        nativeCards.waitingThreads().has(event.threadId) || questions.waitingThreads().has(event.threadId) ||
        [...pending.values()].some((card) => card.threadId === event.threadId)) return Promise.resolve();
    const delivery = Promise.resolve().then(async () => {
      if (steerRunning.get(event.threadId) !== steer || turn.state !== "running" || stoppedTurns.has(event.id)) return;
      const files = attachmentFiles(event.threadId, event.id, event.data.attachments ?? [], dir);
      const attached = files.map((file) =>
        `[attached: ${JSON.stringify(file.name)} (${JSON.stringify(file.mime)}) at ${file.path}]`).join("\n");
      const completionId = completionIdFor(event.threadId, active);
      const sessionId = threadHome(event.threadId, dir).sessionId;
      const intent = syncHostRequest(dir, { op: "steering_begin", record: {
        eventId: event.id, threadId: event.threadId, attemptId, activeEventId: active,
        completionId, identity: userMessageIdentity(event), ...(sessionId ? { sessionId } : {}),
      } });
      const record = intent.record as SteeringRecord;
      steeringRecords.set(event.id, record);
      if (intent.reserved !== true) return;
      let delivered: boolean;
      try { delivered = await steer([event.data.text, attached].filter(Boolean).join("\n\n"), files); }
      catch {
        if (!stopped) {
          state("steer-outcome-unconfirmed");
          broadcast({ ...control({ kind: "admission_status", data: { eventId: event.id,
            status: "indeterminate", reason: "steering-outcome-unconfirmed" } }), threadId: event.threadId });
        }
        return;
      }
      if (stopped) return;
      if (!delivered) {
        const rejected = syncHostRequest(dir, { op: "steering_reject", eventId: event.id, attemptId });
        steeringRecords.set(event.id, rejected.record as SteeringRecord);
        return;
      }
      const prior = readThreadEvents(event.threadId, dir);
      const ordered: YorozuEvent = { ...event, ts: Math.max(Date.now(), prior.at(-1)?.ts ?? 0),
        clientTs: event.clientTs ?? event.ts, data: { ...event.data, delivery: "steer",
          runId: completionId, completionId } };
      // Rust commits the two projections, outcome and queue cleanup. On restart it completes
      // interrupted cleanup using the original projection, without repeating the SDK effect.
      const committed = syncHostRequest(dir, { op: "steering_commit", eventId: event.id, attemptId, event: ordered });
      steeringRecords.set(event.id, committed.record as SteeringRecord);
      steered.add(event.id);
      removeNativeQueue(event.id);
      turn.queued = turn.queued.filter((id) => id !== event.id);
      broadcast(ordered);
      broadcast(threadList());
    }).catch(() => { if (!stopped) { steeringFenced = true; state("steer-storage-unconfirmed"); } });
    steering.set(event.id, { threadId: event.threadId, promise: delivery });
    void delivery.finally(() => steering.delete(event.id));
    return delivery;
  }

  function resumeNativeTurn(threadId: string, retry = false): boolean {
    const marker = listThreads(dir).find((thread) => thread.id === threadId)?.nativeTurn;
    if (marker?.state !== "interrupted" || !marker.userEventId || nativeRecoveryStarted.has(threadId) ||
      stoppedTurns.has(marker.userEventId) || (!retry && (marker.recoveryAttempts ?? 0) >= 3)) return false;
    if (uncertainActiveSteering(threadId, marker.userEventId)) {
      if (retry) broadcast({ ...control({ kind: "thought", data: {
        text: "A follow-up may already have reached this run. Yorozu cannot confirm its outcome, so this run remains paused.",
      } }), threadId });
      return false;
    }
    const original = visibleThreadEvents(threadId, dir).find((event) => event.id === marker.userEventId &&
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

  const stopStatus = (record: StopRecord, requestId: string): YorozuEvent => ({
    ...control({ kind: "stop_status", data: { targetEventId: record.targetEventId, requestId, status: record.status } }),
    threadId: record.threadId,
  });
  const broadcastStop = (record: StopRecord): void => {
    const confirmed = stopStore.confirmed(record.targetEventId);
    if (confirmed) for (const id of confirmed.requestIds) broadcast(stopStatus(confirmed, id));
  };
  const preDispatchStops = new Map<string, Promise<void>>();
  const withdrawBeforeDispatch = (record: StopRecord): Promise<void> => {
    const prior = preDispatchStops.get(record.targetEventId);
    if (prior) return prior;
    const promise = (stopStore.pending(record.targetEventId) ?? Promise.resolve())
      .then(() => channel.withdraw(record.targetEventId)).then(async () => {
      const current = stoppedTurns.get(record.targetEventId);
      if (!current?.preDispatch || current.status === "withdrawn") return;
      const withdrawn = { ...current, status: "withdrawn" as const };
      await rememberStop(withdrawn);
      if (!stopped) broadcastStop(withdrawn);
    });
    preDispatchStops.set(record.targetEventId, promise);
    void promise.finally(() => { if (preDispatchStops.get(record.targetEventId) === promise) preDispatchStops.delete(record.targetEventId); }).catch(() => {});
    return promise;
  };
  const persistStoppedReply = (record: StopRecord, text = record.partialText ?? ""): void => {
    const id = completionIdFor(record.threadId, record.targetEventId);
    if (readThreadEvents(record.threadId, dir).some((event) => event.id === id && event.kind === "message" && event.data.done)) return;
    const final: YorozuEvent = { id, threadId: record.threadId, ts: Date.now(), agentId: MAIN_AGENT,
      kind: "message", data: { role: "agent", text, done: true, interrupted: true } };
    emit(final);
  };
  async function completeStop(record: StopRecord, status: "stopped" | "completed" = "stopped"): Promise<void> {
    const pending = stopStore.pending(record.targetEventId);
    if (pending) await pending;
    record = stoppedTurns.get(record.targetEventId) ?? record;
    if (record.status !== "requested" && record.status !== "unconfirmed") return;
    clearTimeout(stopTimers.get(record.targetEventId));
    stopTimers.delete(record.targetEventId);
    if (status === "stopped" && !viaChannel(record.threadId)) persistStoppedReply(record);
    const finished = { ...record, status };
    await rememberStop(finished);
    broadcastStop(finished);
  }

  const abortTarget = (threadId: string, target: string): boolean => {
    if (runningEventIds.get(threadId) !== target) return false;
    for (const card of [...pending.values()]) if (card.threadId === threadId) card.settle({ answer: "no" }, "cancelled");
    questions.cancelAll(threadId);
    nativeCards.cancelAll(threadId);
    running.get(threadId)?.abort();
    return true;
  };

  const finishStop = async (record: StopRecord): Promise<void> => {
    const pending = stopStore.pending(record.targetEventId);
    if (pending) await pending;
    record = stoppedTurns.get(record.targetEventId) ?? record;
    if (record.status !== "requested") return;
    const target = record.targetEventId;
    if (viaChannel(record.threadId)) {
      if (stopTimers.has(target)) return;
      channel.abort(target);
      const timer = setTimeout(() => {
        void (async () => {
          stopTimers.delete(target);
          const current = stoppedTurns.get(target);
          if (current?.status !== "requested") return;
          const uncertain = { ...current, status: "unconfirmed" as const };
          await rememberStop(uncertain);
          const turn = turnStates.get(record.threadId);
          if (turn?.activeEventId === target) {
            turn.state = "stopped-unconfirmed";
            publishTurnState(record.threadId);
          }
          broadcastStop(uncertain);
        })().catch(() => state("stop-storage-failed"));
      }, 3_000);
      timer.unref?.();
      stopTimers.set(target, timer);
      return;
    }
    if (abortTarget(record.threadId, target)) {
      if (!stopTimers.has(target)) {
        const timer = setTimeout(() => {
          if (stoppedTurns.get(target)?.status !== "requested") return;
          const confirm = setTimeout(() => {
            void (async () => {
              stopTimers.delete(target);
              if (stoppedTurns.get(target)?.status !== "requested") return;
              const uncertain = { ...record, status: "unconfirmed" as const };
              await rememberStop(uncertain);
              const turn = turnStates.get(record.threadId);
              if (turn?.activeEventId === target) {
                turn.state = "stopped-unconfirmed";
                publishTurnState(record.threadId);
              }
              broadcastStop(uncertain);
            })().catch(() => state("stop-storage-failed"));
          }, 100);
          confirm.unref?.();
          stopTimers.set(target, confirm);
          try { terminateRunning.get(record.threadId)?.(); }
          catch (error) { state(`native-terminate-error ${String(error)}`); }
        }, 3_000);
        timer.unref?.();
        stopTimers.set(target, timer);
      }
    } else {
      const nativeTurn = listThreads(dir).find((thread) => thread.id === record.threadId)?.nativeTurn;
      if (nativeTurn?.id === completionIdFor(record.threadId, target) && nativeTurn.state === "interrupted") {
        // The old SDK process is gone, but its last external effect is unknowable here.
        // Stop recovery without claiming confirmed cessation.
        await rememberStop({ ...record, status: "unconfirmed" });
        const turn = turnStates.get(record.threadId);
        if (turn?.activeEventId === target) {
          turn.state = "stopped-unconfirmed";
          publishTurnState(record.threadId);
        }
        setNativeTurn(record.threadId, undefined, dir);
        broadcast(threadList());
        broadcastStop(stoppedTurns.get(target)!);
        return;
      }
      persistStoppedReply(record);
      await rememberStop({ ...record, status: "stopped" });
      broadcastStop(stoppedTurns.get(target)!);
    }
  };

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

  /** The compatibility timer only wakes Rust's monotonic, connection-scoped scheduler. */
  const sendCatchup = (): void => {
    catchupTimer = null;
    if (stopped || !socket) return;
    const connection = socket;
    const eligible = [...catchupSends].flatMap(([pub, target]) => devices.get(pub) === target.device && target.connection === connection
      ? [{ pub, generation: target.generation }] : []);
    try {
      // Retired cards do not consume pacing. Bound work in one JS turn while Rust retains jobs.
      for (let scanned = 0; scanned < 256; scanned++) {
        const next = catchupQueue.next(connection.epoch, eligible, relayReady && connection.readyState === WebSocket.OPEN, connection.bufferedAmount);
        let remaining = next.remaining; let waitMs = next.waitMs;
        if (next.event) {
          const response = next.event;
          const fresh = response.kind === "sync_delta" && response.data.current
            ? { ...response, data: { ...response.data, current: response.data.current.filter(stillActionable) } } : response;
          const sent = stillActionable(response);
          if (sent) sendTo(next.pub!, fresh); // Seal/reserve only now, after fresh actionability.
          const finished = catchupQueue.finish(next.claim!, next.pub!, next.generation!, sent);
          remaining = finished.remaining; waitMs = finished.waitMs;
          if (next.done && catchupSends.get(next.pub!)?.generation === next.generation) catchupSends.delete(next.pub!);
          if (!sent && remaining && scanned < 255) continue;
        }
        if (remaining) { catchupTimer = setTimeout(sendCatchup, waitMs); catchupTimer.unref(); }
        else catchupSends.clear();
        return;
      }
    } catch (error) { state(`catchup-send-error ${String(error)}`); connection.close(); }
  };

  /**
   * `from` names the relay device a sealed box came from. Absent for the local socket, whose
   * clients are this Mac's own user: that difference is what decides whether turning YOLO on
   * is a command or a request.
   */
  const activeSearchRequests = new Map<string, string>();
  const downloadFiles = new Map<string, { bytes: Buffer; sha256: string }>();
  let downloadCacheBytes = 0;
  function handleEvent(event: YorozuEvent, reply: Send, pairedAt = 0, from?: string, localDevice?: string, durable?: AcceptedEntry): void {
    if (event.kind === "steer") {
      const compatibility = from ? devices.get(from)?.compatibility : undefined;
      if (from && (compatibility?.state !== "compatible" || !compatibility.capabilities.includes("steer-v1"))) return;
      if (typeof event.threadId !== "string" || !event.threadId || event.threadId.length > 128 ||
          typeof event.data.targetEventId !== "string" || !event.data.targetEventId || event.data.targetEventId.length > 128) return;
      const message = readThreadEvents(event.threadId, dir).find((known) => known.id === event.data.targetEventId);
      if (message?.kind !== "message" || message.data.role !== "user") {
        reply(control({ kind: "receipt", data: { eventId: event.id } }));
        return;
      }
      void steerMessage(message, event.id).then(() => {
        const delivered = readThreadEvents(event.threadId, dir).find((known) => known.id === message.id);
        if (delivered) reply(delivered);
        reply(control({ kind: "receipt", data: { eventId: event.id } }));
      });
      return;
    }
    if (event.kind === "thread_models") return;
    if (event.kind === "thread_models_request" || event.kind === "thread_set_model" && viaChannel(event.threadId)) {
      const compatibility = from ? devices.get(from)?.compatibility : undefined;
      if (from && (compatibility?.state !== "compatible" || !compatibility.capabilities.includes("model-select-v1"))) return;
      if (typeof event.threadId !== "string" || !event.threadId || event.threadId.length > 128 || !viaChannel(event.threadId)) return;
      if (!event.data || typeof event.data !== "object") return;
      const result = (data: { models?: ChannelModelOption[]; error?: string }): void => {
        reply({ id: randomUUID(), threadId: event.threadId, ts: Date.now(), agentId: MAIN_AGENT,
          kind: "thread_models", data: { requestId: event.id, ...data } });
        reply(control({ kind: "receipt", data: { eventId: event.id } }));
      };
      if (event.kind === "thread_models_request") {
        void channel.refreshModels(event.threadId).then((models) => result({ models }),
          (error: Error) => result({ error: error.message }));
      } else {
        const model = event.data.model ?? null;
        if (model !== null && (typeof model !== "string" || !model || model.length > 512)) return;
        if (!listThreads(dir).some((thread) => thread.id === event.threadId)) return;
        void channel.selectModel(event.threadId, model).then(() => result({}),
          (error: Error) => result({ error: error.message }));
      }
      return;
    }
    if (event.kind === "message" && event.data.channelModel !== undefined &&
        (!event.data.channelModel || typeof event.data.channelModel !== "object" ||
          Array.isArray(event.data.channelModel) || event.data.channelModel.model != null &&
          (typeof event.data.channelModel.model !== "string" || !event.data.channelModel.model || event.data.channelModel.model.length > 512))) return;
    if (event.kind === "stop_status") return;
    if (event.kind === "thread_rewound") return;
    if (event.kind === "thread_rewind") {
      const compatibility = from ? devices.get(from)?.compatibility : undefined;
      if (from && (compatibility?.state !== "compatible" ||
          !compatibility.capabilities.includes("thread-rewind-v1"))) return;
      if (typeof event.threadId !== "string" || !event.threadId || event.threadId.length > 128 ||
          !listThreads(dir).some((thread) => thread.id === event.threadId)) return;
      if (typeof event.data.eventId !== "string" || !event.data.eventId || event.data.eventId.length > 128) return;
      const stored = readThreadEvents(event.threadId, dir);
      const previous = stored.find((known) =>
        known.kind === "thread_rewound" && known.data.requestId === event.id);
      if (previous) { reply(previous); return; }
      const history = visibleThreadEvents(event.threadId, dir);
      const index = history.findIndex((known) => known.id === event.data.eventId &&
        known.kind === "message" && known.data.role === "user");
      const reason = viaChannel(event.threadId) ? "This agent does not support Edit from here yet."
        : running.has(event.threadId) || turnQueues.has(event.threadId) ||
          (turnStates.get(event.threadId)?.state ?? "idle") !== "idle" ? "Wait for this thread to finish working."
        : index < 0 ? "This message is no longer in the conversation." : undefined;
      const result: YorozuEvent = { id: randomUUID(), threadId: event.threadId,
        ts: stored.reduce((latest, known) => Math.max(latest, known.ts), Date.now()), agentId: MAIN_AGENT,
        kind: "thread_rewound", data: { requestId: event.id, eventId: event.data.eventId,
          ...(reason ? { reason } : { hiddenEventIds: history.slice(index).map((known) => known.id) }) } };
      if (reason) { reply(result); return; }
      appendThreadEvent(result, dir);
      setNativeTurn(event.threadId, undefined, dir);
      liveReplies.delete(event.threadId);
      partials.delete(event.threadId);
      broadcast(result);
      broadcast(threadList());
      return;
    }
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
              attachments: result.attachments, admissionDeadline: event.data.admissionDeadline, delivery: event.data.delivery,
              ...(event.data.channelModel !== undefined ? { channelModel: event.data.channelModel } : {}),
              ...(event.data.replyTo !== undefined ? { replyTo: event.data.replyTo } : {}) } },
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
      const stopEvent = event;
      void (async () => {
        const event = stopEvent;
        const target = event.data.targetEventId;
        const priorWrite = stopStore.pending(target!);
        if (priorWrite) { await priorWrite; handleEvent(event, reply, pairedAt, from, localDevice); return; }
        if (typeof target !== "string" || !target || target.length > 128 || !event.threadId) return;
        const inFlight = steering.get(target);
        if (inFlight?.threadId === event.threadId) {
          void inFlight.promise.then(() => handleEvent(event, reply, pairedAt, from, localDevice));
          return;
        }
        const existing = stoppedTurns.get(target);
        if (existing && existing.threadId !== event.threadId) {
          reply(control({ kind: "stop_status", data: { targetEventId: target, requestId: event.id, status: "unknown" } }));
          return;
        }
        const history = readThreadEvents(event.threadId, dir);
        if (uncertainSteering(target) && steeringRecords.get(target)?.threadId === event.threadId) {
          const uncertain: StopRecord = { targetEventId: target, threadId: event.threadId,
            status: "unconfirmed", requestIds: [...new Set([...(existing?.requestIds ?? []), event.id])] };
          await rememberStop(uncertain);
          reply(control({ kind: "receipt", data: { eventId: event.id } }));
          reply(stopStatus(uncertain, event.id));
          return;
        }
        const user = history.find((stored) => stored.id === target && stored.kind === "message" && stored.data.role === "user");
        const channelAdmission = pendingChannelAdmissions.get(target);
        const acceptance = acceptedStore.pending.get(target);
        if (existing?.preDispatch || !existing && !channelRuns.has(target) &&
            (channelAdmission?.fresh && channelAdmission.threadId === event.threadId ||
              viaChannel(event.threadId) && acceptance?.entry.threadId === event.threadId && !user)) {
          const request: StopRecord = existing ? { ...existing, requestIds: [...new Set([...existing.requestIds,event.id])] }
            : { targetEventId: target, threadId: event.threadId, status: "requested", preDispatch: true, requestIds: [event.id] };
          await rememberStop(request);
          reply(control({ kind: "receipt", data: { eventId: event.id } }));
          reply(stopStatus(request, event.id));
          void withdrawBeforeDispatch(request).catch(() => state("channel-storage-failed"));
          return;
        }
        const channelRun = channelRuns.get(target);
        if (viaChannel(event.threadId) && !existing &&
            (!channelRun || channelRun.threadId !== event.threadId ||
              (!channelRun.status && turnStates.get(event.threadId)?.activeEventId !== target))) {
          reply(control({ kind: "receipt", data: { eventId: event.id } }));
          reply({ ...control({ kind: "stop_status", data: { targetEventId: target, requestId: event.id, status: "unknown" } }),
            threadId: event.threadId });
          return;
        }
        const final = viaChannel(event.threadId) ? !!channelRun?.status && channelRun.status !== "aborted"
          : history.some((stored) => stored.id === completionIdFor(event.threadId, target) &&
            stored.kind === "message" && stored.data.done === true && stored.data.interrupted !== true);
        if (!existing && !user) {
          const withdrawn: StopRecord = { targetEventId: target, threadId: event.threadId,
            status: "withdrawn", requestIds: [event.id] };
          await rememberStop(withdrawn);
          reply(control({ kind: "receipt", data: { eventId: event.id } }));
          reply(stopStatus(withdrawn, event.id));
          return;
        }
        if (user?.kind === "message" && user.data.delivery === "steer") {
          reply(control({ kind: "receipt", data: { eventId: event.id } }));
          reply(control({ kind: "stop_status", data: { targetEventId: target, requestId: event.id,
            status: history.some((stored) => stored.id === user.data.completionId && stored.kind === "message" && stored.data.done)
              ? "completed" : "unknown" } }));
          return;
        }
        const turn = turnStates.get(event.threadId);
        const queuedIndex = turn?.queued.indexOf(target) ?? -1;
        if (!existing && user && turn && queuedIndex >= 0) {
          const withdrawn: StopRecord = { targetEventId: target, threadId: event.threadId,
            status: "withdrawn", requestIds: [event.id] };
          await rememberStop(withdrawn);
          turn.queued.splice(queuedIndex, 1);
          removeNativeQueue(target);
          if (viaChannel(event.threadId)) channel.abort(target);
          publishTurnState(event.threadId);
          reply(control({ kind: "receipt", data: { eventId: event.id } }));
          reply(stopStatus(withdrawn, event.id));
          return;
        }
        const requestIds = existing ? [...new Set([...existing.requestIds, event.id])] : [event.id];
        const live = liveReplies.get(event.threadId);
        const record: StopRecord = final ? { ...(existing ?? { targetEventId: target, threadId: event.threadId }),
          status: "completed", requestIds } : existing ? { ...existing, requestIds } : { targetEventId: target, threadId: event.threadId,
          status: channelRun?.status === "aborted" ? "stopped" : "requested", requestIds,
          ...(runningEventIds.get(event.threadId) === target && live?.kind === "message" && live.data.role === "agent"
            ? { partialText: live.data.text } : {}) };
        const persistence: Promise<void>[] = [rememberStop(record)];
        if (record.status === "requested" && turn?.activeEventId === target) {
          // Withdraw before aborting: the runner can settle and release its queue immediately.
          for (const queued of turn.queued) {
            const withdraw = async (): Promise<void> => {
              if (steered.has(queued) || uncertainSteering(queued)) return;
              const withdrawn: StopRecord = { targetEventId: queued, threadId: event.threadId,
                status: "withdrawn", requestIds: [event.id] };
              await rememberStop(withdrawn);
              removeNativeQueue(queued);
              if (viaChannel(event.threadId)) channel.abort(queued);
              emit(stopStatus(withdrawn, event.id));
            };
            const inFlight = steering.get(queued);
            if (inFlight) void inFlight.promise.then(withdraw).catch(() => state("stop-storage-failed"));
            else persistence.push(withdraw());
          }
          turn.queued = [];
          turn.state = "stopping";
          publishTurnState(event.threadId);
        } else if (record.status === "requested" && turn) {
          const queuedIndex = turn.queued.indexOf(target);
          if (queuedIndex >= 0) {
            turn.queued.splice(queuedIndex, 1);
            publishTurnState(event.threadId);
          }
        }
        await Promise.all(persistence);
        reply(control({ kind: "receipt", data: { eventId: event.id } }));
        if (record.status === "requested") {
          await finishStop(record);
          if (turn?.activeEventId === target && runningEventIds.get(event.threadId) !== target &&
              stoppedTurns.get(target)?.status !== "requested") finishTurnState(event.threadId, target);
          if (stoppedTurns.get(target)?.status !== "requested") return;
        }
        reply(stopStatus(stoppedTurns.get(target)!, event.id));
        return;
      })().catch(() => state("stop-storage-failed"));
      return;
    }
    if (event.kind === "admission_query") {
      const id = event.data.eventId;
      if (typeof id !== "string" || !id || id.length > 128 || !event.threadId) return;
      const acceptance = acceptedStore.pending.get(id);
      if (acceptance?.entry.threadId === event.threadId) {
        void acceptance.promise.then(() => { if (!stopped) handleEvent(event, reply, pairedAt, from, localDevice); })
          .catch(() => {
            if (!stopped) reply(control({ kind: "admission_status", data: {
              eventId: id, requestId: event.id, status: "indeterminate", reason: "accepted-storage-unconfirmed" } }));
          });
        return;
      }
      const accepted = acceptedStore.records.get(id);
      const history = readThreadEvents(event.threadId, dir);
      const user = history.find((stored): stored is YorozuEvent & { kind: "message" } =>
        stored.kind === "message" && stored.data.role === "user" && stored.id === id);
      const expired = expiredAdmissions.get(id);
      const withdrawal = stopStore.confirmed(id);
      const rejectedReply = history.findLast((stored) => stored.kind === "admission_status" &&
        stored.data.eventId === id && stored.data.status === "rejected" && stored.data.reason?.startsWith("reply-"));
      const recordedCompletionId = user?.data.completionId;
      const oldOpenClawCompletionId = user && viaChannel(event.threadId) ? `openclaw:${id}:final` : undefined;
      const candidate = recordedCompletionId ?? oldOpenClawCompletionId;
      const final = candidate ? history.find((stored): stored is YorozuEvent & { kind: "message" } =>
        stored.id === candidate && stored.kind === "message" && stored.data.role === "agent" && stored.data.done === true) : undefined;
      const completionId = recordedCompletionId ?? (final ? oldOpenClawCompletionId : undefined);
      const steeringUnconfirmed = uncertainSteering(id) && steeringRecords.get(id)?.threadId === event.threadId;
      const status = steeringUnconfirmed ? "indeterminate" : withdrawal?.threadId === event.threadId && withdrawal.status === "withdrawn"
        ? "withdrawn" : rejectedReply ? "rejected" : !user ? expired?.threadId === event.threadId ? "expired"
          : accepted?.threadId === event.threadId || !acceptedStore.available ? "indeterminate" : "unknown" : final ? "completed"
        : activeTurnIds.has(id) || user?.data.delivery === "steer" &&
          recordedCompletionId === completionIdFor(event.threadId, runningEventIds.get(event.threadId) ?? "") ? "running"
        : admittedTurns.has(id) ? "queued" : "indeterminate";
      const runId = (final?.kind === "message" ? final.data.runId : undefined)
        ?? (!viaChannel(event.threadId) ? user?.data.runId : undefined);
      reply(control({ kind: "receipt", data: { eventId: event.id } }));
      reply(control({ kind: "admission_status", data: {
        eventId: id, status, requestId: event.id,
        ...(user?.data.delivery ? { delivery: user.data.delivery } : {}),
        ...(status === "expired" ? { reason: "admission-deadline" } : {}),
        ...(steeringUnconfirmed ? { reason: "steering-outcome-unconfirmed" } : {}),
        ...(rejectedReply?.kind === "admission_status" ? { reason: rejectedReply.data.reason } : {}),
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
          wakeDrainWaiters();
          for (const threadId of drainInterrupted) {
            if (resumeNativeTurn(threadId)) drainInterrupted.delete(threadId);
          }
          alreadySeen(event.id);
        }
      } else if (data.action === "install_now") {
        if (!seenCommands.has(event.id) && updateGate.status.phase !== "none" && updateGate.status.phase !== "installing") {
          updateGate.installNow();
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
          if (pendingSince?.updateId !== data.updateId) {
            const next = { updateId: data.updateId, since: Date.now() };
            writeFileAtomic(pendingSinceFile, JSON.stringify(next));
            pendingSince = next;
          }
          updateGate.queue(data.updateId, data.version);
        } else {
          if (data.action === "cancel") {
            if (updateOwner && updateOwner !== localDevice) return;
            if (updateGate.status.phase !== "none" && data.updateId !== updateGate.status.updateId) return;
            writeFileAtomic(pendingSinceFile, "null");
            pendingSince = undefined;
            updateGate.cancel();
            wakeDrainWaiters();
            for (const threadId of drainInterrupted) {
              if (resumeNativeTurn(threadId)) drainInterrupted.delete(threadId);
            }
            updateOwner = undefined;
          } else if (data.action !== "poll" || updateOwner !== localDevice || data.updateId !== updateGate.status.updateId) return;
        }
        if (data.action !== "cancel") {
          let active: number | null;
          try {
            const interrupted = updateGate.draining ? [] : listThreads(dir)
              .filter((thread) => thread.nativeTurn?.state === "interrupted").map((thread) => thread.id);
            active = new Set([
              ...running.keys(), ...(!updateGate.draining ? turnQueues.keys() : []), ...interrupted,
              ...[...acceptedStore.pending.values()].map((pending) => pending.entry.threadId),
            ]).size;
          } catch { active = null; }
          updateGate.poll(active, Date.now());
          if (updateGate.draining) {
            for (const threadId of nativeCards.waitingThreads()) drainPauses.get(threadId)?.();
          }
          wakeDrainWaiters();
        }
      }
      if (data.action !== "status") pushUpdateStatus();
      reply(control({ kind: "update_status", data: updateStatusFor(from, event.id) }));
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
    if ((updateGate.status.phase === "installing" || updateGate.status.phase === "draining") && requiresAdmission) {
      if (updateSubscribers.has(localDevice ?? from ?? "")) reply(control({ kind: "update_status", data: updateStatusFor(from) }));
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
    if (event.kind === "message" && event.data.role === "user" && event.data.attachments?.length &&
        viaChannel(event.threadId) && channel.attachments === "unsupported") {
      rejectUserMessage("attachments-unsupported");
      return state("rejected-attachments-unsupported");
    }
    if (event.kind === "message" && event.data.delivery !== undefined &&
        event.data.delivery !== "queue" && event.data.delivery !== "steer") {
      rejectUserMessage("invalid-delivery");
      return;
    }
    const identity = event.kind === "message" && event.data.role === "user"
      ? userMessageIdentity(event) : undefined;
    if (identity && !stopStore.available) return state("stop-storage-failed");
    if (identity && !acceptedStore.available) return state("accepted-storage-failed");
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
    if (event.kind === "message" && knownMessage && (knownMessage.kind !== "message" ||
      knownMessage.data.role !== event.data.role || knownMessage.data.text !== event.data.text ||
      knownMessage.data.replyTo !== event.data.replyTo ||
      (knownMessage.data.channelModel?.model ?? null) !== (event.data.channelModel?.model ?? null) ||
      (knownMessage.data.channelModel !== undefined) !== (event.data.channelModel !== undefined) ||
      (knownMessage.clientTs ?? knownMessage.ts) !== event.ts || knownMessage.data.admissionDeadline !== event.data.admissionDeadline ||
      (knownMessage.data.attachments ?? []).length !== (event.data.attachments ?? []).length ||
      (knownMessage.data.attachments ?? []).some((attachment, index) => {
        const retry = event.data.attachments![index]!;
        return attachment.name !== retry.name || attachment.mime !== retry.mime || attachment.data !== retry.data;
      }))) {
      rejectUserMessage("conflicting-message-id");
      return state("rejected-conflicting-message-id");
    }
    if (knownMessage && event.kind === "message" && event.data.role === "user") {
      const rejection = readThreadEvents(event.threadId, dir).findLast((stored) => stored.kind === "admission_status" &&
        stored.data.eventId === event.id && stored.data.status === "rejected" && stored.data.reason?.startsWith("reply-"));
      if (rejection?.kind === "admission_status") {
        rejectUserMessage(rejection.data.reason!);
        return;
      }
    }
    // Resolve references from this conversation only. Clients send an ID, never trusted
    // quoted text. Accepted duplicates retain their existing operation identity on reconnect.
    const quotedMessage = event.kind === "message" && event.data.role === "user" && event.data.replyTo !== undefined
      ? readThreadEvents(event.threadId, dir).findLast((parent) => parent.id === event.data.replyTo && parent.kind === "message")
      : undefined;
    const replyContext = quotedMessage?.kind === "message" ? {
      id: quotedMessage.id,
      text: (quotedMessage.data.text || (quotedMessage.data.attachments ?? []).map((file) => file.name).join(", ")).slice(0, 4096),
      sender: quotedMessage.data.role === "user" ? "owner" : "Yorozu",
    } : undefined;
    if (event.kind === "message" && event.data.role === "user" && event.data.replyTo !== undefined && !knownMessage) {
      const replyCompatibility = from ? devices.get(from)?.compatibility : undefined;
      if (typeof event.data.replyTo !== "string" || !event.data.replyTo || event.data.replyTo.length > 128 ||
          event.data.replyTo === event.id || !quotedMessage || quotedMessage.parentAgentId !== undefined ||
          !visibleThreadEvents(event.threadId, dir).some((parent) => parent.id === event.data.replyTo) ||
          quotedMessage.kind !== "message" || quotedMessage.data.role === "agent" && quotedMessage.data.done !== true) {
        rejectUserMessage("reply-target-unavailable");
        return;
      }
      if (!viaChannel(event.threadId) || !channel.announced.has("reply-context-v1") ||
          from && (replyCompatibility?.state !== "compatible" || !replyCompatibility.capabilities.includes("reply-context-v1"))) {
        rejectUserMessage("reply-context-unsupported");
        return;
      }
    }
    if (event.kind === "message" && event.data.role === "user" && !knownMessage) {
      const rejected = (status: "expired" | "rejected" | "withdrawn", reason: string): void =>
        reply(control({ kind: "admission_status", data: { eventId: event.id, status, reason } }));
      const withdrawal = stoppedTurns.get(event.id);
      if (withdrawal) {
        rejected(withdrawal.threadId === event.threadId ? "withdrawn" : "rejected",
          withdrawal.threadId === event.threadId ? "withdrawn" : "conflicting-message-id");
        return;
      }
      const pendingExpiration = admissionStore.pendingDisposition(event.id, event.threadId, identity!);
      if (pendingExpiration) {
        void pendingExpiration.then((status) => { if (!stopped) rejected(status,
          status === "expired" ? "admission-deadline" : "conflicting-message-id"); })
          .catch(() => state("admission-storage-failed"));
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
          void admissionStore.expire({ id: event.id, threadId: event.threadId, identity: identity!, deadline }, Date.now())
            .then((status) => { if (!stopped) rejected(status,
              status === "expired" ? "admission-deadline" : "conflicting-message-id"); })
            .catch(() => state("admission-storage-failed"));
          return;
        }
        // Deadline-bearing clients create draft threads first. A failed create must not
        // silently route its first message to the default agent through threadAgent().
        if (!listThreads(dir).some((thread) => thread.id === event.threadId)) {
          rejected("rejected", "thread-not-created");
          return;
        }
      }
    }
    if (event.kind === "thread_create") {
      const rejectCreate = (reason: string): void => {
        state(`thread-create-error ${reason}`);
        reply(control({ kind: "admission_status", data: { eventId: event.id, status: "rejected", reason } }));
        return reply({
          id: randomUUID(), threadId: event.threadId, ts: Date.now(), agentId: MAIN_AGENT,
          kind: "thought", data: { text: `Could not create this thread: ${reason}.` },
        });
      };
      try {
        const creation = { eventId: event.id, identity: createHash("sha256").update(JSON.stringify([
          event.threadId, event.data.title ?? null, event.data.agent ?? null, event.data.cwd ?? null,
        ])).digest("hex") };
        const existing = listThreads(dir).find((thread) => thread.id === event.threadId);
        if (existing) {
          // A lost receipt still confirms the durable record, even if its folder or agent
          // disappeared afterward. A reused ID with different content does not.
          const matches = existing.creation
            ? existing.creation.eventId === creation.eventId && existing.creation.identity === creation.identity
            : (existing.agent ?? "yorozu") === (event.data.agent ?? "yorozu") &&
              existing.cwd === (event.data.cwd?.trim() || undefined);
          if (!matches) return rejectCreate("conflicting-thread-create");
        } else {
          const descriptor = agentDescriptors.find(({ id }) => id === (event.data.agent ?? "yorozu"));
          const cwd = event.data.cwd?.trim();
          const invalid = !event.threadId ? "missing-thread-id"
            : !descriptor ? `unregistered agent "${String(event.data.agent)}"`
              : descriptor.needsFolder && cwd && !isProjectFolder(cwd)
                ? `"${cwd}" is not one of this Mac's project folders`
                : descriptor.needsFolder && !cwd ? `a ${descriptor.id} thread needs a project folder` : undefined;
          if (invalid) return rejectCreate(invalid);
          // The client's first message waits behind this receipt.
          createThread(event.data.title, dir, event.threadId, { ...event.data,
            needsFolder: descriptor!.needsFolder, creation });
        }
      } catch (error) {
        const reason = error instanceof Error ? error.message : String(error);
        state(`thread-create-error ${reason}`);
        // Storage can recover. Leave this command in the client's outbox for retry.
        return reply({
          id: randomUUID(), threadId: event.threadId, ts: Date.now(), agentId: MAIN_AGENT,
          kind: "thought", data: { text: `Could not create this thread: ${reason}.` },
        });
      }
    }
    const oldest = event.kind === "message" && event.data.role === "user"
      ? [...pending.values()].find((card) => card.threadId === event.threadId) : undefined;
    const typedCandidate = oldest && event.kind === "message" && event.data.replyTo === undefined
      ? typedAnswer(event.data.text, oldest.card) : undefined;
    const typed = !durable || durable.purpose === "legacy" || durable.purpose === "approval-reply" &&
      durable.approvalActionId === oldest?.card.actionId ? typedCandidate : undefined;
    if (event.kind === "message" && event.data.role === "user" && !durable) {
      const turnless = typed || viaChannel(event.threadId);
      const projected = knownMessage?.kind === "message" ? knownMessage : { ...event, data: { ...event.data,
        delivery: "queue" as const, ...(turnless ? {} : { runId: completionIdFor(event.threadId, event.id),
          completionId: completionIdFor(event.threadId, event.id) }) } };
      const entry: AcceptedEntry = { id: event.id, threadId: event.threadId, identity: identity!, event: projected,
        purpose: acceptedStore.records.get(event.id)?.purpose ?? (knownMessage ? "legacy" : typed ? "approval-reply" : "conversation"),
        ...(typed && oldest ? { approvalActionId: oldest.card.actionId } : {}) };
      updateGate.activity();
      void acceptedStore.accept(entry).then((confirmed) => {
        acceptedMessages.set(event.id, confirmed.identity);
        if (stopped) return;
        try { handleEvent(event, reply, pairedAt, from, localDevice, confirmed); }
        catch { state("message-processing-failed"); }
      }).catch((error: unknown) => {
        if (error instanceof Error && error.message === "Conflicting message ID") rejectUserMessage("conflicting-message-id");
        else state("accepted-storage-failed");
      });
      return;
    }
    if (seenCommands.has(event.id)) {
      if (event.kind === "message" && !knownMessage) return state("missing-previous-message");
      if (event.kind === "message" && event.data.role === "user" && durable?.purpose !== "approval-reply" && viaChannel(event.threadId)) channel.retry(event.threadId);
      receipt();
      return state("duplicate-command");
    }
    // A message this thread already holds is the same message again: not a second turn, and
    // not a second line in the log.
    const duplicateMessage = Boolean(knownMessage);
    if (duplicateMessage) {
      if (durable?.purpose === "approval-reply") { receipt(); return; }
      if (!visibleThreadEvents(event.threadId, dir).some((known) => known.id === event.id)) {
        receipt();
        return;
      }
      if (event.kind === "message" && event.data.role === "user" &&
          knownMessage?.kind === "message" && knownMessage.data.completionId === completionIdFor(event.threadId, event.id) &&
          threadAgent(event.threadId, dir) !== "yorozu" &&
          !queuedNative.some((entry) => entry.eventId === event.id) && !admittedTurns.has(event.id) &&
          !stoppedTurns.has(event.id) &&
          listThreads(dir).find((thread) => thread.id === event.threadId)?.nativeTurn?.userEventId !== event.id &&
          !readThreadEvents(event.threadId, dir).some((logged) =>
            logged.id === completionIdFor(event.threadId, event.id) && logged.kind === "message" && logged.data.done)) {
        // The message log may have survived a failed queue-journal write. A retry repairs
        // that admission before it receives the missing receipt.
        void enqueueTurn(event.threadId, event.data.text, true, event.data.attachments ?? [], event.id);
      }
      // Logged but maybe never queued, if the host died in between. The plugin dedupes by id.
      if (event.kind === "message" && event.data.role === "user" && !typed &&
          viaChannel(event.threadId)) {
        void admitChannel({ id: event.id, threadId: event.threadId, ts: event.ts, text: event.data.text,
          ...(replyContext ? { replyContext } : {}),
          ...(event.data.channelModel !== undefined ? { channelModel: event.data.channelModel } : {}),
          ...(event.data.attachments?.length ? { attachments: event.data.attachments } : {}) }, false).then(() => { receipt(); state("duplicate-message"); })
          .catch(() => state("channel-storage-failed"));
        return;
      }
      receipt();
      return state("duplicate-message");
    }
    if (event.kind === "thread_create" || event.kind === "message" || event.kind === "thread_recover") updateGate.activity();
    let admittedTurn: Promise<void> | undefined;
    // A channel message has no completion of its own: OpenClaw answers when it answers.
    const turnless = typed || viaChannel(event.threadId);
    const logged = durable?.event ?? (event.kind === "message" && event.data.role === "user"
      ? { ...event, data: { ...event.data, delivery: "queue" as const,
        runId: turnless ? undefined : completionIdFor(event.threadId, event.id),
        completionId: turnless ? undefined : completionIdFor(event.threadId, event.id) } } : event);
    persistThreadAndTranscript(logged, dir);
    if (event.kind === "message" && event.data.role === "user" && !typed && durable?.purpose !== "approval-reply" &&
        threadAgent(event.threadId, dir) !== "yorozu") {
      admittedTurn = enqueueTurn(event.threadId, event.data.text, true,
        event.data.attachments ?? [], event.id, logged);
      if (event.data.delivery === "steer" && logged.kind === "message") void steerMessage(logged);
    }
    if (event.kind === "message" && event.data.role === "user" && !typed && durable?.purpose !== "approval-reply" && viaChannel(event.threadId)) {
      if (identity) acceptedMessages.set(event.id, identity);
      title(event.threadId, event.data.text);
      void admitChannel({ id: event.id, threadId: event.threadId, ts: event.ts, text: event.data.text,
        ...(replyContext ? { replyContext } : {}),
        ...(event.data.channelModel !== undefined ? { channelModel: event.data.channelModel } : {}),
        ...(event.data.attachments?.length ? { attachments: event.data.attachments } : {}) }, true).then(() => {
          alreadySeen(event.id); receipt();
          if (!stopped) broadcast(logged);
        }).catch(() => state("channel-storage-failed"));
      return;
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
        broadcast(threadList());
        // A folder just started in is a recent now.
        if (event.data.cwd) broadcast(projectList());
        return;
      case "thread_rename":
        renameThread(event.threadId, event.data.title, dir);
        return broadcast(threadList());
      case "thread_archive":
        archiveThread(event.threadId, dir, event.data.archived ?? true);
        return broadcast(threadList());
      case "thread_pin":
        pinThread(event.threadId, event.data.pinned, dir);
        return broadcast(threadList());
      // Read state is the runtime's, not each device's: the device that is actually looking at
      // the thread says so, and everyone is told, so the dot clears on the Mac when the phone
      // reads it. A frame that moves nothing is not worth a list.
      case "thread_read":
        if (markThreadRead(event.threadId, event.data.at, dir, event.data.reset)) {
          lastStatus.set(event.threadId, statusOf(event.threadId));
          broadcast(threadList());
        }
        return;
      case "thread_list":
        reply(threadList());
        return reply(projectList());
      case "project_list":
        return reply(projectList());
      case "thread_recover": {
        const thread = listThreads(dir).find((t) => t.id === event.threadId);
        if (thread?.nativeTurn?.state !== "interrupted" || thread.nativeTurn.id !== event.data.turnId) return;
        if ([...stoppedTurns.values()].some((stop) => stop.threadId === event.threadId &&
          completionIdFor(event.threadId, stop.targetEventId) === event.data.turnId)) return;
        if (event.data.action !== "continue" && event.data.action !== "dismiss") return;
        if (event.data.action === "continue") {
          resumeNativeTurn(event.threadId, true);
        } else {
          setNativeTurn(event.threadId, undefined, dir);
          if (thread.nativeTurn.userEventId) removeNativeQueue(thread.nativeTurn.userEventId);
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
      case "agent_status":
        return void agentStatus()
          .then((data) => reply(control({ kind: "agent_status", data: { ...data, requestId: event.id } })))
          .catch(() => reply(control({ kind: "agent_status", data: { requestId: event.id, failed: true } })));
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
          if (!device || !socket) { catchupQueue.cancel(from); return; }
          const generation = randomUUID();
          catchupQueue.replace(from, generation, socket.epoch, responses);
          catchupSends.set(from, { connection: socket, device, generation });
          if (!catchupTimer) {
            catchupTimer = setTimeout(sendCatchup, 0);
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
    if (durable?.purpose === "approval-reply") {
      if (typed && oldest) oldest.settle(typed);
      return;
    }
    if (typed && oldest) return oldest.settle(typed);
    const queued = admittedTurn ?? enqueueTurn(event.threadId, event.data.text, true,
      event.data.attachments ?? [], event.id, logged);
    // Admission is durable now. Echoing by id is harmless and converges all clients.
    broadcast(logged);
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

  /** The run progress may write into: started, not finished, and its thread's active turn. */
  const activeChannelRun = (messageId: string) => {
    const run = channelRuns.get(messageId);
    const turn = run && turnStates.get(run.threadId);
    return run && !run.status && viaChannel(run.threadId) && turn && turn.activeEventId === messageId &&
      turn.state !== "starting" && turn.state !== "idle" ? run : undefined;
  };

  /** OpenClaw's `yorozu` channel plugin. Its messages land like any agent reply: logged, synced, pushed. */
  const channel = startChannelHost({
    dir,
    canDispatch: (id) => !stopped && stopStore.available && acceptedStore.available && !stoppedTurns.has(id),
    onError: (message) => state(`channel-${message}`),
    onCapabilities: () => { if (!stopped) broadcast(modelList()); },
    onModel: (threadId, model) => {
      if (setThreadModel(threadId, model, dir)) broadcast(threadList());
    },
    onDeliveryError: (message, error) => {
      if (!stopped) broadcast({ id: randomUUID(), threadId: message.threadId, ts: Date.now(), agentId: MAIN_AGENT,
        kind: "thread_models", data: { requestId: message.id, error: error === "reply-delivery-unconfirmed"
          ? "Reply delivery is unconfirmed. This connection cannot receive replies. Restore its reply support, or cancel the send before trying again."
          : `Message queued: ${error}. Will retry when OpenClaw reconnects.` } });
    },
    onRejected: (message, reason) => {
      if (reason.startsWith("reply-")) {
        const rejection: YorozuEvent = { id: `${message.id}:rejected`, threadId: message.threadId,
          ts: Date.now(), agentId: MAIN_AGENT, kind: "admission_status", data: { eventId: message.id, status: "rejected", reason } };
        if (!readThreadEvents(message.threadId, dir).some((event) => event.id === rejection.id)) appendThreadEvent(rejection, dir);
        if (!stopped) broadcast(rejection);
        return;
      }
      if (!stopped) broadcast(control({ kind: "admission_status", data: { eventId: message.id, status: "rejected", reason } }));
    },
    forwarded: ({ id, threadId }) => {
      if (!channelRuns.has(id)) channelRuns.set(id, { threadId,
        replied: readThreadEvents(threadId, dir).some((event) => event.kind === "message" &&
          event.data.role === "agent" && event.data.done === true && event.data.replyTo === id) });
    },
    handedOff: ({ id, threadId }) => {
      const run = channelRuns.get(id);
      const turn = turnStates.get(threadId);
      if (!run || run.status || stoppedTurns.has(id) || !viaChannel(threadId) ||
          turn?.activeEventId === id || turn?.queued.includes(id)) return;
      admitTurn(threadId, id);
    },
    runBoundaryLost: () => {
      // OpenClaw is gone before it started these: they are queued again, to be handed off on reconnect.
      for (const [threadId, turn] of turnStates) {
        if (turn.state !== "starting" || !viaChannel(threadId)) continue;
        turnStates.set(threadId, { state: "idle", queued: [] });
        publishTurnState(threadId);
      }
    },
    runStarted: (messageId) => {
      const run = channelRuns.get(messageId);
      if (!run || run.status || !viaChannel(run.threadId)) return;
      const stop = stoppedTurns.get(messageId);
      if (stop) {
        if (stop.status === "requested" || stop.status === "unconfirmed") channel.abort(messageId);
        return;
      }
      const turn = turnStates.get(run.threadId);
      if (turn?.state === "starting" && turn.activeEventId === messageId) return startTurnState(run.threadId, messageId);
      if (turn && turn.state !== "idle") return;
      admitTurn(run.threadId, messageId);
      startTurnState(run.threadId, messageId);
    },
    toolStarted: (messageId, callId, name, args) => {
      const run = activeChannelRun(messageId);
      if (!run) return;
      run.calls ??= new Set();
      if (run.calls.has(callId)) return;
      run.calls.add(callId);
      emit({ id: `openclaw:${run.threadId}:call:${callId}`, threadId: run.threadId, ts: Date.now(), agentId: MAIN_AGENT,
        kind: "tool_call", data: { callId, name, args } });
    },
    toolFinished: (messageId, callId, ok, output) => {
      const run = activeChannelRun(messageId);
      if (!run?.calls?.has(callId)) return;
      run.results ??= new Set();
      if (run.results.has(callId)) return;
      run.results.add(callId);
      emit(stashToolResult({ id: `openclaw:${run.threadId}:result:${callId}`, threadId: run.threadId, ts: Date.now(),
        agentId: MAIN_AGENT, kind: "tool_result", data: { callId, ok, output } }, dir));
    },
    runFinished: (messageId, status) => {
      const run = channelRuns.get(messageId);
      if (!run || run.status || turnStates.get(run.threadId)?.activeEventId !== messageId) return;
      run.status = status;
      const draft = run.replyDraft;
      if (draft && !readThreadEvents(run.threadId, dir).some((event) => event.id === draft.id)) {
        emit({ ...draft, kind: "message", data: { role: "agent", replyTo: messageId, text: status !== "completed" ? draft.data.text : "",
          done: true, streamRevision: (draft.data.streamRevision ?? 0) + 1, ...(status === "failed" ? { failed: true } : {}), ...(status === "aborted" ? { interrupted: true } : {}) } });
        run.replied = true;
      }
      run.replyDraft = undefined;
      const stop = stoppedTurns.get(messageId);
      if (stop) {
        void completeStop(stop, status === "aborted" ? "stopped" : "completed")
          .then(() => finishTurnState(run.threadId, messageId))
          .catch(() => state("stop-storage-failed"));
        return;
      }
      // A failed run with nothing said leaves the message unanswered: say so, as a native agent does.
      else if (status === "failed" && !run.replied) {
        emit({ id: `openclaw:${messageId}:failed`, threadId: run.threadId, ts: Date.now(), agentId: MAIN_AGENT,
          kind: "message", data: { role: "agent", text: "OpenClaw could not answer. Check the OpenClaw Gateway log.",
            done: true, failed: true, replyTo: messageId } });
      }
      finishTurnState(run.threadId, messageId);
    },
    preview: ({ id, messageId, threadId, text }) => {
      const run = activeChannelRun(messageId);
      if (!run || run.threadId !== threadId || run.replied || stoppedTurns.has(messageId) ||
          run.replyDraft && run.replyDraft.id !== id) return;
      const ts = run.replyDraft?.ts ?? Date.now();
      const draft: YorozuEvent = { id, threadId, ts, agentId: MAIN_AGENT, kind: "message",
        data: { role: "agent", text, streamRevision: (run.replyDraft?.data.streamRevision ?? 0) + 1 } };
      run.replyDraft = draft;
      broadcast(draft, false);
    },
    deliver: ({ id, threadId, text, title: named, messageId, failed, interrupted }, auxiliary) => {
      const thread = listThreads(dir).find((known) => known.id === threadId);
      if (thread && (thread.agent ?? "yorozu") !== "yorozu") throw new Error("not-a-channel-thread");
      if (readThreadEvents(threadId, dir).some((known) => known.id === id)) return;
      const active = messageId ? activeChannelRun(messageId) : channelRuns.get(turnStates.get(threadId)?.activeEventId ?? "");
      if (messageId && (!active || active.threadId !== threadId)) throw new Error("not-an-active-channel-run");
      if (messageId && active?.replyDraft && active.replyDraft.id !== id) throw new Error("reply-identity-mismatch");
      if (!thread) createThread(named, dir, threadId);
      if (!thread && !named) title(threadId, text);
      const ts = active?.replyDraft?.id === id ? active.replyDraft.ts : Date.now();
      const event: YorozuEvent = { id, threadId, ts, agentId: MAIN_AGENT, kind: "message",
        data: { role: "agent", text, done: true,
          ...(messageId ? { replyTo: messageId, streamRevision: (active?.replyDraft?.data.streamRevision ?? 0) + 1 } : {}),
          ...(failed ? { failed: true } : {}), ...(interrupted ? { interrupted: true } : {}) } };
      if (auxiliary && active && !active.status) {
        // An SDK tool prompt is complete, but the answer and its live draft still run.
        persistThreadAndTranscript(event, dir);
        sendBroadcast(event, false);
        notifyRelay(event);
      } else {
        emit(event);
        if (active) { active.replied = true; active.replyDraft = undefined; }
      }
      if (!thread) broadcast(threadList());
    },
  });

  /**
   * The relay-free path in: the Mac app's own chat UI connects here instead of pairing. Its
   * first frame is the thread list, exactly as a phone's `hello` is answered with one.
   */
  const localConnections = new Set<string>();
  const local = startLocalChannel({
    path: localSocketPath(dir),
    onOpen: (device, send) => {
      localConnections.add(device);
      void startupRecovery.then(() => {
        if (stopped || !localConnections.has(device)) return;
        locals.set(device, send);
        state("local-connected");
        send(threadList());
        send(modelList());
        void refreshSkills();
        send(projectList());
        pushDevices();
      }).catch(() => state("stop-storage-failed"));
    },
    onEvent: (device, event) => {
      void startupRecovery.then(() => {
        if (stopped) return;
        handleEvent(event, locals.get(device) ?? (() => {}), 0, undefined, device);
      }).catch((e: unknown) => {
        state(`local-event-error ${e instanceof Error ? e.message : String(e)}`);
      });
    },
    onClose: (device) => {
      localConnections.delete(device);
      locals.delete(device);
      activeSearchRequests.delete(device);
      updateSubscribers.delete(device);
      if (updateOwner === device) {
        updateOwner = undefined;
        if (!stopped && updateGate.status.phase !== "installing") {
          try { writeFileAtomic(pendingSinceFile, "null"); }
          catch (error) { state(`update-cancel-error ${error instanceof Error ? error.message : String(error)}`); }
          pendingSince = undefined;
          updateGate.cancel();
          wakeDrainWaiters();
          for (const threadId of drainInterrupted) {
            if (resumeNativeTurn(threadId)) drainInterrupted.delete(threadId);
          }
        }
        pushUpdateStatus();
      }
      pushDevices();
    },
    onError: state,
  });

  function connect(ws: RustRelaySocket): void {
    relayReady = false;
    socket = ws;
    let room: string | null = null;

    const signedFrame = (body: FrameBody): { payload: string; sig: string } => {
      const payload = toBase64Url(Buffer.from(JSON.stringify(body)));
      const sig = wireCrypto.sign(Buffer.from(payload));
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
            [...devices.values()].flatMap(({ record }) => {
              if (!record.signingPub || event.ts < (record.pairedAt ?? 0)) return [];
              return [[record.signingPub, wireCrypto.preview(record.pub, Buffer.from(plaintext))]];
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
      return { t: "box", ...wireCrypto.sealCurrent(known.record.pub, event) };
    };

    const sealLegacyFor = (known: PairedDevice, event: YorozuEvent): FrameBody => {
      return { t: "box", ...wireCrypto.seal(known.record.pub, event) };
    };

    const forAgentCapability = (event: YorozuEvent, supportsOpenAgents: boolean): YorozuEvent => {
      if (supportsOpenAgents) return event;
      if (event.kind === "sync_delta") return { ...event, data: { ...event.data,
        events: event.data.events.map((item) => forAgentCapability(item, false)),
        ...(event.data.current ? { current: event.data.current.map((item) => forAgentCapability(item, false)) } : {}),
      } };
      if ((event.kind === "approval_card" || event.kind === "question_card") &&
          event.data.nativeAgent && !THREAD_AGENTS.includes(event.data.nativeAgent as typeof THREAD_AGENTS[number])) {
        const { nativeAgent: _, ...data } = event.data;
        return { ...event, data } as YorozuEvent;
      }
      return event;
    };

    const boxesFor = (device: string, event: YorozuEvent): FrameBody[] => {
      const known = devices.get(device);
      if (!known || ((!relayReady || ws.readyState !== WebSocket.OPEN) && !directFor(known))) return [];
      if (event.kind === "thread_models" && (known.compatibility?.state !== "compatible" ||
          !known.compatibility.capabilities.includes("model-select-v1"))) return [];
      const supportsApprovalStatus = known.compatibility?.state === "compatible" &&
        known.compatibility.capabilities.includes("offline-approval-v1");
      if (!supportsApprovalStatus && event.kind === "approval_status") return [];
      const awaitingCompatibility = known.record.peerInfoRequired && known.compatibility?.state !== "compatible";
      if (awaitingCompatibility && event.kind !== "thread_list") return [];
      const cutoff = known.record.pairedAt ?? 0;
      if (event.threadId && event.ts < cutoff) return [];
      if (event.kind === "thread_list") {
        const supportsTurnState = known.compatibility?.state === "compatible" &&
          known.compatibility.capabilities.includes("turn-state-v1");
        const list = threadList(cutoff, supportsTurnState);
        if (list.kind !== "thread_list") return [];
        const name = known.compatibility?.state === "compatible" && known.compatibility.capabilities.includes("host-name") ? computerName() : undefined;
        event = { ...list, id: event.id, ts: event.ts, data: {
          threads: awaitingCompatibility ? [] : list.data.threads,
          peerInfoSupported: true,
          ...(event.data.peerInfoReplyTo ? { peerInfoReplyTo: event.data.peerInfoReplyTo } : {}),
          ...(known.peerClaimReceived ? { peerInfo: hostPeerInfo(dir, peerInfo.appVersion, name) } : {}),
          ...(known.compatibility?.state === "update-required" ? { peerInfoError: known.compatibility.reason } : {}),
          // Only inside a replay-protected box: the relay never learns the tailnet name.
          ...(directConfig && known.format === "current" ? { directUrl: directConfig.url } : {}),
        } };
      }
      if (event.kind === "sync_delta") {
        const supportsTurnState = known.compatibility?.state === "compatible" &&
          known.compatibility.capabilities.includes("turn-state-v1");
        event = { ...event, data: { ...event.data,
          workingThreadIds: supportsTurnState
            ? workingThreadIds()
            : [...running.keys()] } };
      }
      event = forAgentCapability(event, known.compatibility?.state === "compatible" &&
        known.compatibility.capabilities.includes("open-agents-v1"));
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
    sendTo = (device, event) => {
      const known = devices.get(device);
      const directSocket = known && directFor(known);
      for (const box of boxesFor(device, event)) {
        if (directSocket) directSocket.send(JSON.stringify({ type: "frame", ...signedFrame(box) }));
        else sendFrame(box);
      }
    };
    /** Phones holding a socket on the relay, by its count. Undefined until it says. */
    let phones: number | undefined;
    const emptyBatchBytes = Buffer.byteLength(JSON.stringify({ type: "frame", frames: [] }));
    sendToAll = (event, maxBuffered) => {
      // Phones on the direct path get theirs there, whatever the relay is doing. Sent last,
      // once the relay has not asked to hold the event, so a held event is not sent twice.
      const sendDirect = (): void => {
        for (const [device, known] of devices) {
          const directSocket = directFor(known);
          if (directSocket) for (const box of boxesFor(device, event)) directSocket.send(JSON.stringify({ type: "frame", ...signedFrame(box) }));
        }
      };
      // The relay keeps nothing the Mac sends, so a frame into a room with no phone in it is
      // only a bill. Unknown stays as it was: an older relay never says.
      if (phones === 0) { sendDirect(); return 0; }
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
      for (const [device, known] of devices) for (const box of directFor(known) ? [] : boxesFor(device, event)) {
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
      sendDirect();
      if (relayReady && ws.readyState === WebSocket.OPEN) for (const batch of batches) ws.send(batch);
      return batches.length;
    };

    /**
     * Frames carry no sender, so whichever paired key opens one identifies its device.
     * Modern boxes retain the per-direction replay check. Legacy boxes have no seq; accepting
     * them ends once a modern box from that device has been seen on this connection.
     */
    function openFrom(body: { n: string; c: string }): [string, YorozuEvent] | null {
      for (const [device, known] of devices) {
        const opened = wireCrypto.openCurrent(known.record.pub, body);
        if (opened.status === "unauthenticated") {
          if (known.format === "current" || known.record.peerInfoRequired) continue;
          const legacy = wireCrypto.open(known.record.pub, body, true);
          if (legacy.status === "malformed") {
            state("malformed-frame");
            return null;
          }
          if (legacy.status === "opened") {
            known.format = "legacy";
            return [device, legacy.event];
          }
          continue;
        }
        if (opened.status === "malformed") {
          state("malformed-frame");
          return null;
        }
        // Rust exposes the event only after durable receive admission. A storage blocker
        // leaves it unaccepted for retry; replay decisions never use a Node counter copy.
        if (opened.status === "replayed") {
          state("replayed-frame");
          return null;
        }
        known.format = "current";
        return [device, (opened as { status: "opened"; event: YorozuEvent }).event];
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
          [...pairingSecrets].some((secret) => wireCrypto.helloProof(secret, body.pub, body.spub!) === body.proof);
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
        void refreshSkills();
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
          known.compatibility = claimPeer(dir, event);
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

    onDirectFrame = (payload) => {
      const body = parseFrameBody(payload);
      if (!body) return state("frame-error malformed body");
      onFrame(body);
    };

    ws.on("open", () => state("connected"));

    ws.on("message", (data, receiveToken?: string) => {
      let handled = true;
      try {
        // Inside the try: the relay is the one peer that can hand us a frame that is not JSON
        // at all, and a parse error here would end the process rather than the frame.
        const msg = JSON.parse(data.toString()) as Record<string, unknown>;
        switch (msg.type) {
          case "pong":
            return;
          case "nonce":
            return ws.send(
              JSON.stringify({
                type: "register",
                pubkey: toBase64Url(keys.signing.publicKey),
                nonceSig: toBase64Url(
                  wireCrypto.sign(Buffer.from(String(msg.nonce))),
                ),
              }),
            );
          case "phones":
            phones = typeof msg.count === "number" ? msg.count : undefined;
            return;
          case "registered":
            phones = typeof msg.phones === "number" ? msg.phones : undefined;
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
            const payload = {
              v: 1 as const,
              relayUrl,
              macPubkey: toBase64Url(keys.session.publicKey),
              token: String(msg.token),
              ...(room ? { roomId: room } : {}),
              secret,
            };
            // One payload twice: a web link the Mac draws as a QR, so a phone camera without
            // Yorozu lands on the download, and the `yorozu://` string it offers to copy.
            log(`QR ${encodePairingLink(payload)}`);
            return log(`PAIR ${encodePairingString(payload)}`);
          }
          case "frame": {
            // A replayed frame carries the relay's buffer sequence; acking it is what lets the
            // relay let go. The ack is cumulative, so it is sent only once every frame up to
            // this one has been handled: a frame that threw is left for the next replay
            // rather than deleted by the ack of the one after it. Live frames carry no `seq`.
            // A body that is not a frame at all is different: nothing will ever handle it, so
            // it is logged and acked, or it would sit at the head of the buffer for good.
            // A live frame is a phone speaking now, whatever the count says: believe the frame.
            if (phones === 0 && typeof msg.seq !== "number") phones = undefined;
            const body = parseFrameBody(msg.payload);
            if (!body) {
              state("frame-error malformed body");
            } else {
              try {
                onFrame(body);
              } catch (e) {
                handled = false;
                throw e;
              }
            }
            return;
          }
          case "state":
            // The relay's own word on something it did to us — a notify held back by its rate
            // limit, say — surfaced as a state so the Mac app can show it rather than a mystery.
            return state(`relay-${String(msg.state).replace(/\s+/g, " ").slice(0, 200)}`);
        }
      } catch (e) {
        handled = false;
        state(`frame-error ${e instanceof Error ? e.message : String(e)}`);
      } finally {
        ws.handled(receiveToken, handled);
      }
    });

    ws.on("error", (e) => state(`error ${e.message}`));

    ws.on("close", () => {
      if (socket !== ws) return;
      relayReady = false;
      clearTraces();
      catchupSends.clear();
      try { catchupQueue.clear(); } catch { state("catchup-unavailable"); }
      if (catchupTimer) clearTimeout(catchupTimer);
      catchupTimer = null;
      state("disconnected");
    });
  }

  function* legacyAccepted(): Iterable<AcceptedEntry> {
    for (const thread of listThreads(dir)) for (const event of readThreadEvents(thread.id, dir)) {
      if (event.kind === "message" && event.data.role === "user") yield { id: event.id, threadId: event.threadId,
        identity: userMessageIdentity(event), purpose: "legacy", event };
    }
  }
  const acceptedReady = acceptedStore.initialize(legacyAccepted(), (entry) => {
    const known = readThreadEvents(entry.threadId, dir).find((event) => event.id === entry.id &&
      event.kind === "message" && event.data.role === "user");
    if (known?.kind === "message" && userMessageIdentity(known) !== entry.identity)
      throw new Error("Conflicting accepted projection");
    if (!known) persistThreadAndTranscript(entry.event, dir);
    acceptedMessages.set(entry.id, entry.identity);
  });
  const stopRecovery: (() => Promise<void>)[] = [];
  for (const stop of stoppedTurns.values()) {
    if (stop.preDispatch && stop.status !== "withdrawn") {
      stopRecovery.push(() => withdrawBeforeDispatch(stop));
      continue;
    }
    if (viaChannel(stop.threadId) && (stop.status === "requested" || stop.status === "unconfirmed")) {
      channelRuns.set(stop.targetEventId, { threadId: stop.threadId });
      turnStates.set(stop.threadId, { state: stop.status === "requested" ? "stopping" : "stopped-unconfirmed",
        activeEventId: stop.targetEventId, queued: [] });
    }
    if (stop.status === "requested") stopRecovery.push(() => finishStop(stop));
  }

  // Recover durable Stop intent before admitting new work or clearing old native markers.
  startupRecovery = acceptedReady.then(() => Promise.all(stopRecovery.map((recover) => recover()))).then(() => {
    if (stopped) return;
    for (const thread of listThreads(dir)) {
      if (thread.nativeTurn?.state === "interrupted") resumeNativeTurn(thread.id);
      if (viaChannel(thread.id)) channel.retry(thread.id);
    }

    for (const entry of [...queuedNative]) {
      if (admittedTurns.has(entry.eventId)) continue;
      if (uncertainSteering(entry.eventId)) continue;
      if (stoppedTurns.has(entry.eventId)) { removeNativeQueue(entry.eventId); continue; }
      const marker = listThreads(dir).find((thread) => thread.id === entry.threadId)?.nativeTurn;
      if (marker?.state === "interrupted" && marker.userEventId === entry.eventId) continue;
      const events = visibleThreadEvents(entry.threadId, dir);
      if (events.some((event) => event.id === completionIdFor(entry.threadId, entry.eventId) &&
          event.kind === "message" && event.data.done)) {
        removeNativeQueue(entry.eventId);
        continue;
      }
      const original = events.find((event) => event.id === entry.eventId &&
        event.kind === "message" && event.data.role === "user");
      if (original?.kind === "message" && original.data.delivery === "steer") {
        removeNativeQueue(entry.eventId);
        continue;
      }
      if (original?.kind === "message") void enqueueTurn(entry.threadId, original.data.text, true,
        original.data.attachments ?? [], entry.eventId, original);
      else removeNativeQueue(entry.eventId);
    }
  });
  void startupRecovery.then(() => {
    if (stopped) return;
    // Preserve the same room routing URL; Rust owns each connection and redial generation.
    const dial = new URL(relayUrl);
    dial.searchParams.set("room", toBase64Url(createHash("sha256").update(keys.signing.publicKey).digest()));
    relay = startRustRelay({ dir, url: dial.toString(), heartbeat, onSocket: connect, onState: state });
  })
    .catch(() => state(acceptedStore.available ? "stop-storage-failed" : "accepted-storage-failed"));

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
      for (const timer of stopTimers.values()) clearTimeout(timer);
      stopTimers.clear();
      wakeDrainWaiters();
      clearTraces();
      partials.clear();
      largePartialAt.clear();
      if (partialTimer) clearTimeout(partialTimer);
      partialTimer = null;
      catchupSends.clear();
      try { catchupQueue.clear(); } catch { state("catchup-unavailable"); }
      if (catchupTimer) clearTimeout(catchupTimer);
      catchupTimer = null;
      for (const turn of running.values()) turn.abort();
      await relay?.close();
      await local.close();
      await Promise.allSettled([...pendingChannelAdmissions.values()].map((entry) => entry.promise));
      await Promise.allSettled([...preDispatchStops.values()]);
      await channel.close();
      await startupRecovery.catch(() => {});
      await acceptedStore.close();
      await stopStore.close();
      await admissionStore.close();
      await attachmentUploads.close();
      releaseHistory();
      await direct?.close();
      await legacyReady?.catch(() => undefined);
      await legacy?.close();
    },
  };
  } catch (error) { releaseHistory(); throw error; }
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
      let shuttingDown = false;
      process.once("SIGTERM", () => {
        if (shuttingDown) return;
        shuttingDown = true;
        const deadline = setTimeout(() => process.exit(143), 5_000);
        deadline.unref();
        void sidecar.close().then(
          () => { clearTimeout(deadline); process.exit(0); },
          () => { clearTimeout(deadline); process.exit(143); },
        );
      });
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

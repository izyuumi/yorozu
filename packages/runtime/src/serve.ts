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
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { argv, env, stdin, stdout } from "node:process";
import {
  deriveSessionKey,
  encodePairingString,
  fromBase64Url,
  generateKeypair,
  generateSigningKeypair,
  helloProof,
  attachmentsWithinLimits,
  open,
  seal,
  notifyFor,
  notificationPreview,
  signFrame,
  threadRef,
  toBase64Url,
  REASONING_EFFORTS,
  type ApprovalCardData,
  type DeviceInfo,
  type EventPayload,
  type Keypair,
  type ModelOption,
  type MessageAttachment,
  type ProgressCardData,
  type ThreadAgent,
  type YorozuEvent,
} from "@yorozu/shared";
import WebSocket from "ws";
import { MAIN_AGENT } from "./agents.js";
import {
  cardFor,
  deleteRule,
  addRule,
  loadSettings,
  listRules,
  narrowestRule,
  quickApprovable,
  saveSettings,
  type Action,
  type AskResult,
  type Rule,
} from "./approval.js";
import type { AssignMode } from "./assign.js";
import type { TurnContext } from "./index.js";
import type { createLegacyRunner } from "./legacy.js";
import { localSocketPath, startLocalChannel, type Send } from "./local.js";
import type { Provider } from "./provider.js";
import { autoTitle } from "./title.js";
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
  renameThread,
  setThreadEffort,
  setNativeTurn,
  recoverNativeTurns,
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
import { questionDesk } from "./tools/cards.js";
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
    mkdirSync(dir, { recursive: true });
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
          ...(typeof record.pairedAt === "number" && Number.isFinite(record.pairedAt) && record.pairedAt > 0
            ? { pairedAt: record.pairedAt } : {}),
          lastSeen: typeof record.lastSeen === "number" ? record.lastSeen : 0,
        },
      ];
    });
  } catch {
    return [];
  }
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
 * One line of `devices.json`. `signingPub` is the Ed25519 key the relay knows the device by,
 * which the phone announces alongside its session key: it cannot be derived from `pub`, and
 * revoking a device at the relay is addressed to it.
 */
export interface DeviceRecord {
  pub: string;
  signingPub?: string;
  /** First pairing time. Sync never backfills events older than this device relationship. */
  pairedAt?: number;
  /** Epoch milliseconds we last heard from it; 0 for a device paired before this was kept. */
  lastSeen: number;
}

export interface ServeOptions {
  relayUrl?: string;
  stateDir?: string;
  /** Defaults to the model chain configured from the environment. */
  provider?: Provider;
  /** Names new threads after their first reply. Defaults to `provider`; absent, the first five words serve. */
  titler?: Provider;
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
  // Memory and the schedule tools resolve their own paths from the environment:
  // publish the choice so an explicit `stateDir` moves the whole runtime, not just the keys.
  env.YOROZU_STATE_DIR = dir;
  const transcripts = transcriptDir(dir);
  recoverNativeTurns(dir);
  const keys = loadKeys(dir);
  const provider = options.provider;
  const titler = options.titler ?? provider;
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

  // A chain nobody is signed in to answers every turn with a 401. Said once, here, so the Mac
  // app can show it instead of leaving the user to read auth errors in a chat bubble. Skipped
  // for a caller-supplied provider: that one is the caller's business.
  if (!options.provider) state("openclaw");

  /** One controller per running turn, so an `interrupt` cancels every tree at once. */
  const running = new Map<string, AbortController>();
  const turnQueues = new Map<string, Promise<void>>();
  const admittedTurns = new Map<string, Promise<void>>();
  let legacy: ReturnType<typeof createLegacyRunner> | undefined;

  /**
   * Session key per paired device, keyed by the X25519 public key it announced. Several
   * phones can be paired at once, so every agent event is sealed once per device; the map
   * outlives the socket, so a reconnect unpairs nobody, and `devices.json` carries it across
   * a restart, so neither does a relaunch of this sidecar.
   */
  const devicesFile = join(dir, "devices.json");
  const devices = new Map<string, { key: Uint8Array; record: DeviceRecord }>();
  /**
   * Announces the paired list to the relay, which replaces what it knows with it. Assigned
   * per connection, a no-op while there is none.
   */
  let announceDevices: () => void = () => {};
  const saveDevices = (): void => {
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      devicesFile,
      JSON.stringify([...devices.values()].map(({ record }) => record)),
      { mode: 0o600 },
    );
    // This file is what the relay's known-device set is rebuilt from, so it is told whenever
    // the file changes rather than only at register time.
    announceDevices();
  };
  const remember = (record: DeviceRecord): void => {
    devices.set(record.pub, {
      key: deriveSessionKey(keys.session.privateKey, fromBase64Url(record.pub)),
      record,
    });
  };
  let migratedPairingTime = false;
  for (const record of loadDevices(devicesFile)) {
    // A key on disk we can no longer agree with is simply dropped, not a reason not to start.
    try {
      // Older releases never recorded first pairing. Do not invent historical access:
      // start a conservative cutoff once, before even a no-hello reconnect can sync.
      if (!Number.isFinite(record.pairedAt) || !record.pairedAt || record.pairedAt < 0) {
        record.pairedAt = Date.now();
        migratedPairingTime = true;
      }
      remember(record);
    } catch {
      // Not a usable X25519 key any more.
    }
  }
  if (migratedPairingTime) saveDevices();

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
  /**
   * Secrets behind the QRs on screen, newest last. A phone's first `hello` proves it holds one
   * of them, and pairing spends them all: a QR is for one phone, and the next one is drawn fresh.
   */
  const pairingSecrets = new Set<string>();
  const PAIRING_SECRETS = 4;
  /** Seals and sends to one paired device. Replaced per connection, a no-op while there is none. */
  let sendTo: (device: string, event: YorozuEvent) => void = () => {};

  /** The same event to every paired device, through the relay or over the local socket. */
  const broadcast = (event: YorozuEvent): void => {
    for (const device of devices.keys()) sendTo(device, event);
    for (const send of locals.values()) send(event);
    // Beside the sealed frame, never instead of it: a phone that is listening gets the event
    // immediately. Every phone still gets an alert because a server-open socket can belong to a
    // suspended iOS app; foreground presentation is suppressed by the app itself.
    notifyRelay(event);
  };

  /** Asks the relay to forget a device, so a revoked phone cannot rejoin against the nonce. */
  let revokeAtRelay: (signingPub: string) => void = () => {};
  const heldRevokes = new Set<string>();

  /**
   * Tells the relay that something happened and, for replies, supplies one opaque preview box
   * per phone. Replaced per connection, a no-op while there is none.
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
  }

  /** Final event owns recovery marker: persist once, then acknowledge, then publish. */
  function finalizeOpenClaw(event: YorozuEvent): void {
    if (!readTranscripts(new Date(0), transcripts).some((known) => known.id === event.id)) appendTranscript(event, transcripts);
    if (!readThreadEvents(event.threadId, dir).some((known) => known.id === event.id)) appendThreadEvent(event, dir);
    openclaw!.acknowledge(event.threadId, event.id);
    broadcast(event);
  }

  const nativeCards = new NativeCards(emit);

  /** Cards on screen somewhere, waiting to be answered, by action ID. */
  const pending = new Map<
    string,
    { card: ApprovalCardData; threadId: string; settle: (result: AskResult) => void }
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
    quickActions.set(actionId, quickApprovable(action, loadSettings(dir), dir));
    return new Promise<AskResult>((resolve) => {
      const timer = setTimeout(() => {
        pending.delete(actionId);
        quickActions.delete(actionId);
        resolve({ answer: "no" });
      }, APPROVAL_TIMEOUT_MS);
      timer.unref?.();
      pending.set(actionId, {
        card,
        threadId,
        settle: (result) => {
          clearTimeout(timer);
          pending.delete(actionId);
          quickActions.delete(actionId);
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
    return control({ kind: "thread_list", data: { threads: threadSummaries(dir, minTs).map((thread) =>
      thread.agent && thread.agent !== "yorozu" ? { ...thread, bypass: yolo } : thread) } });
  };

  /**
   * What a thread can be put on, by name. Sent with the thread list rather than on request: a
   * phone's model picker is one tap away from the thread it is about, and asking for the list
   * at that point would draw an empty menu first.
   */
  const agentModels: Partial<Record<Exclude<ThreadAgent, "yorozu">, ModelOption[]>> = {};
  const modelList = (): YorozuEvent =>
    control({
      kind: "model_list",
      data: { models: provider ? legacy?.models() ?? [] : openclawModels, agentModels },
    });

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
  void openclaw?.listModels().then((models) => {
    openclawModels = models;
    broadcast(modelList());
  }).catch((error: unknown) => state(`model-list-error ${String(error)}`));

  /**
   * Every device this Mac answers, the local socket's clients included: the Mac app is one more
   * paired device, it just reached us without the relay.
   */
  const deviceList = (): YorozuEvent => {
    const now = Date.now();
    const paired: DeviceInfo[] = [...devices.values()].map(({ record }) => ({
      pub: record.pub,
      ...(record.signingPub ? { signingPub: record.signingPub } : {}),
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
    devices.delete(pub);
    saveDevices();
    if (known.record.signingPub) revokeAtRelay(known.record.signingPub);
    state("revoked");
    pushDevices();
  };

  /**
   * What the device has not seen, across every live thread, in one frame — up to a page. A
   * page is cut where the next event would take it past `SYNC_PAGE_BYTES`, and `more` tells
   * the phone to ask again: its `lastSeen` has moved to the end of what it got, so the next
   * page carries on from there, and the threads this one never reached.
   */
  const syncDelta = (lastSeen: Record<string, string>, pairedAt = 0): YorozuEvent => {
    const events: YorozuEvent[] = [];
    let bytes = 0;
    let more = false;
    threads: for (const thread of listThreads(dir).filter((thread) => !thread.archived)) {
      const page = eventsAfter(thread.id, lastSeen?.[thread.id], dir, pairedAt);
      if (page.length === SYNC_LIMIT) more = true;
      for (const event of page) {
        const size = Buffer.byteLength(JSON.stringify(event));
        if (events.length > 0 && bytes + size > SYNC_PAGE_BYTES) {
          more = true;
          break threads;
        }
        events.push(event);
        bytes += size;
      }
    }
    return control({
      kind: "sync_delta",
      data: { events, workingThreadIds: [...running.keys()], ...(more ? { more: true } : {}) },
    });
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

  async function runTurn(
    threadId: string,
    text: string,
    recorded = false,
    attachments: MessageAttachment[] = [],
    userEventId?: string,
  ): Promise<void> {
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
    const id = agent === "yorozu" && openclaw && userEventId ? `openclaw:` + userEventId + `:final` : randomUUID();
    // `done` on the finished one only: it is what tells a phone the turn is over, so its
    // composer can stop offering Stop. The deltas under the same id leave it unset.
    const message = (reply: string, done = false): YorozuEvent => ({
      id,
      threadId,
      ts: Date.now(),
      agentId: MAIN_AGENT,
      kind: "message",
      data: { role: "agent", text: reply, ...(done ? { done: true } : {}) },
    });

    // A native agent's thread is answered by that agent alone: its own session, in the
    // thread's folder, with its own tools. Yorozu's dispatch and approval gate are not here.
    if (agent !== "yorozu") {
      const runner = nativeRunners[agent];
      const finish = (reply: string): void => {
        const final = message(reply, true);
        appendTranscript(final, transcripts);
        appendThreadEvent(final, dir);
        broadcast(final);
      };
      // Finished, so the composer is not left offering Stop for a turn nobody is running.
      if (!runner) return finish(`${agent} is not available in this build yet.`);
      const turn = new AbortController();
      if (!running.has(threadId)) running.set(threadId, turn);
      setNativeTurn(threadId, { id, state: "running" }, dir);
      broadcast(threadList());
      try {
        const home = threadHome(threadId, dir);
        const done = await runner.run({
          threadId,
          text,
          ...home,
          bypass: loadSettings(dir).yolo,
          model: threadModel(threadId, dir),
          effort: threadEffort(threadId, dir),
          signal: turn.signal,
          onSession: (sessionId) => { setThreadSession(threadId, sessionId, dir); },
          approve: (tool, input, signal) => nativeCards.approve(threadId, agent, tool, input, signal),
          ask: (question, options, signal) => nativeCards.ask(threadId, question, options, signal),
          onUpdate: (reply) => broadcast(message(reply)),
          // The agent's trace, under ids stable per step, so a replayed step is one row. A
          // long result goes out as its head, flagged; the whole stays here for the asking.
          onActivity: (key, payload) => {
            const event: YorozuEvent = { id: `${agent}:${threadId}:${key}`, threadId, ts: Date.now(), agentId: MAIN_AGENT, ...payload };
            emit(event.kind === "tool_result" ? stashToolResult(event, dir) : event);
          },
        });
        // Stored even after a stop: the session outlives the turn, and the next prompt resumes it.
        if (done.sessionId && done.sessionId !== home.sessionId) setThreadSession(threadId, done.sessionId, dir);
        // An interrupted turn says nothing: the user already knows they stopped it.
        if (turn.signal.aborted) return;
        finish(done.text);
      } catch (error) {
        // The agent could not run at all — not installed, not logged in, crashed. Said in the
        // thread, finished, so the composer is not left offering Stop for a dead turn.
        if (turn.signal.aborted) return;
        state(`native-error ${error instanceof Error ? error.message : String(error)}`);
        finish(`${agent} could not answer: ${error instanceof Error ? error.message : String(error)}`);
      } finally {
        if (running.get(threadId) === turn) running.delete(threadId);
        if (!stopped) {
          setNativeTurn(threadId, undefined, dir);
          broadcast(threadList());
        }
      }
      return;
    }

    if (openclaw) {
      const turn = new AbortController();
      if (!running.has(threadId)) running.set(threadId, turn);
      try {
        const reply = await openclaw.run({
          threadId,
          text,
          model: threadModel(threadId, dir),
          effort: threadEffort(threadId, dir),
          attachments,
          signal: turn.signal,
          completionId: id,
          userEventId,
          onUpdate: (reply) => broadcast(message(reply)),
          onEvent: emit,
        });
        if (turn.signal.aborted) return;
        if (reply === undefined) return;
        const final = message(reply, true);
        finalizeOpenClaw(final);
      } finally {
        if (running.get(threadId) === turn) running.delete(threadId);
      }
      return;
    }
    if (!provider) throw new Error("no execution backend");

    const turn = new AbortController();
    if (!running.has(threadId)) running.set(threadId, turn);
    try {
      const backend = await legacyReady;
      if (!backend || stopped || turn.signal.aborted) return;
      await backend.run(threadId, turn.signal,
        (text) => broadcast(message(text)), (text) => emit(message(text, true)));
    } finally {
      if (running.get(threadId) === turn) running.delete(threadId);
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
    if (viaOpenClaw(threadId)) {
      userEventId ??= randomUUID();
      const event = acceptedEvent ?? { id: userEventId, threadId, ts: Date.now(), agentId: MAIN_AGENT,
        kind: "message" as const, data: { role: "user" as const, text, ...(attachments.length ? { attachments } : {}) } };
      const stored = openclaw!.admitUserTurn({ threadId, text, model: threadModel(threadId, dir),
        effort: threadEffort(threadId, dir), attachments, userEventId,
        completionId: `openclaw:` + userEventId + `:final` }, () => {
        if (!readTranscripts(new Date(0), transcripts).some((known) => known.id === event.id)) appendTranscript(event, transcripts);
        if (!readThreadEvents(threadId, dir).some((known) => known.id === event.id)) appendThreadEvent(event, dir);
      }, () => readThreadEvents(threadId, dir).some((known) => known.id === event.id));
      if (!stored) return Promise.resolve();
      text = stored.input.text;
      attachments = stored.input.attachments;
      recorded = true;
    }
    const admitted = userEventId ? admittedTurns.get(userEventId) : undefined;
    if (admitted) return admitted;
    const previous = turnQueues.get(threadId) ?? Promise.resolve();
    const next = previous.then(() => stopped ? undefined : runTurn(threadId, text, recorded, attachments, userEventId));
    turnQueues.set(threadId, next);
    if (userEventId) admittedTurns.set(userEventId, next);
    void next.finally(() => {
      if (turnQueues.get(threadId) === next) turnQueues.delete(threadId);
      if (userEventId && admittedTurns.get(userEventId) === next) admittedTurns.delete(userEventId);
    }).catch(() => {});
    return next;
  }

  /**
   * One event from a paired device, however it reached us — a sealed relay frame or a line on
   * the local socket. `reply` answers that one device; the thread admin cases answer all of
   * them, so a second device sees the same list.
   */
  const archiveUpdates = new Map<string, Promise<void>>();

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
   */
  const seenCommands = new Set<string>();
  const SEEN_COMMANDS = 2_000;
  const alreadySeen = (id: string): boolean => {
    if (seenCommands.has(id)) return true;
    seenCommands.add(id);
    if (seenCommands.size > SEEN_COMMANDS) {
      const [oldest] = seenCommands;
      seenCommands.delete(oldest!);
    }
    return false;
  };

  function handleEvent(event: YorozuEvent, reply: Send, pairedAt = 0): void {
    if (event.kind === "message" && !attachmentsWithinLimits(event.data.attachments ?? [])) {
      return state("rejected-oversized-attachments");
    }
    // Every command is receipted, the second copy included: a device that was never told the
    // first one landed is still waiting to hear so, and only a receipt lets it stop re-sending.
    const receipt = (): void => reply(control({ kind: "receipt", data: { eventId: event.id } }));
    if (alreadySeen(event.id)) {
      receipt();
      return state("duplicate-command");
    }
    // A message this thread already holds is the same message again: not a second turn, and
    // not a second line in the log.
    const duplicateMessage =
      event.kind === "message" &&
      readThreadEvents(event.threadId, dir).some((known) => known.id === event.id);
    // A user message bound for OpenClaw crosses one admission boundary below: ledger first,
    // logs second. Every other message — a native agent's thread included — is logged here.
    const admitted = event.kind === "message" && event.data.role === "user" && viaOpenClaw(event.threadId);
    if (duplicateMessage && !admitted) {
      receipt();
      return state("duplicate-message");
    }
    if (!admitted) {
      appendTranscript(event, transcripts);
      appendThreadEvent(event, dir);
    }
    receipt();

    switch (event.kind) {
      case "interrupt":
        running.get(event.threadId)?.abort();
        running.delete(event.threadId);
        // A turn parked on a card would never notice the abort otherwise.
        for (const card of [...pending.values()]) if (card.threadId === event.threadId) card.settle({ answer: "no" });
        questions.cancelAll(event.threadId);
        return;
      case "approval_answer": {
        if (nativeCards.answer(event)) return;
        // A lock-screen button is honoured only for a card this runtime judged answerable
        // from one. The relay chose which buttons the push drew, and a relay that put Allow
        // under a purchase card must not be able to move money with it.
        if (event.data.source === "notification" && quickActions.get(event.data.actionId) !== true) {
          return state("notification-answer-refused");
        }
        pending.get(event.data.actionId)?.settle({
          answer: event.data.answer,
          ...(event.data.rule ? { rule: event.data.rule } : {}),
        });
        return;
      }
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
      case "approval_settings": {
        const settings = loadSettings(dir);
        const changed = typeof event.data.yolo === "boolean";
        if (changed) saveSettings({ ...settings, yolo: event.data.yolo! }, dir);
        const current = control({
          kind: "approval_settings",
          data: { yolo: changed ? event.data.yolo! : settings.yolo },
        });
        if (changed) broadcast(threadList());
        return changed ? broadcast(current) : reply(current);
      }
      case "rule_proposal":
        // Emitted by the runtime, never accepted from a device: a proposal is not a decision.
        return;
      case "question_answer":
        if (nativeCards.answer(event)) return;
        questions.answer(event.data.questionId, event.data.answer);
        return;
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
        reply(modelList());
        return reply(projectList());
      case "project_list":
        return reply(projectList());
      case "thread_recover": {
        const thread = listThreads(dir).find((t) => t.id === event.threadId);
        if (thread?.nativeTurn?.state !== "interrupted" || thread.nativeTurn.id !== event.data.turnId) return;
        if (event.data.action !== "continue" && event.data.action !== "dismiss") return;
        if (event.data.action === "continue" && !thread.nativeSessionId) return;
        setNativeTurn(event.threadId, undefined, dir);
        broadcast(threadList());
        if (event.data.action === "continue") void enqueueTurn(event.threadId, "Continue the interrupted turn.");
        return;
      }
      case "thread_set_model": {
        const agent = threadAgent(event.threadId, dir);
        const model = event.data.model;
        if (model != null && typeof model !== "string") return;
        if (agent !== "yorozu" && model && !agentModels[agent]?.some((m) => m.id === model)) return;
        if (setThreadModel(event.threadId, model ?? null, dir) && agent !== "yorozu") setThreadEffort(event.threadId, null, dir);
        return broadcast(threadList());
      }
      case "thread_set_effort": {
        const agent = threadAgent(event.threadId, dir);
        const effort = event.data.effort;
        if (effort != null && !REASONING_EFFORTS.includes(effort)) return;
        const choices = agent === "yorozu" ? ["low", "medium", "high"] :
          (agentModels[agent]?.find((m) => m.id === threadModel(event.threadId, dir)) ?? agentModels[agent]?.[0])?.efforts ?? [];
        if (effort && !choices.includes(effort)) return;
        setThreadEffort(event.threadId, effort ?? null, dir);
        return broadcast(threadList());
      }
      case "device_list":
        return reply(deviceList());
      case "device_remove":
        return forgetDevice(event.data.pub);
      case "sync_request":
        return reply(syncDelta(event.data.lastSeen, pairedAt));
    }

    if (event.kind !== "message" || event.data.role !== "user") return;
    // A plain "yes" while a card is up in this thread answers the card rather than starting a
    // turn. Only this thread's: a "yes" typed into another chat is a message there, not an
    // answer to whatever happens to be the oldest card anywhere.
    const oldest = [...pending.values()].find((card) => card.threadId === event.threadId);
    const typed = oldest && typedAnswer(event.data.text, oldest.card);
    if (typed) {
      if (admitted) {
        appendTranscript(event, transcripts);
        appendThreadEvent(event, dir);
      }
      return oldest.settle(typed);
    }
    const queued = enqueueTurn(event.threadId, event.data.text, true, event.data.attachments ?? [], event.id, event);
    // Admission is durable now. Echoing by id is harmless and converges all clients.
    broadcast(event);
    queued.catch((e: unknown) => {
      state(`agent-error ${String(e)}`);
      // A thrown turn has no final message event, so announce its terminal state explicitly.
      notifyRelay({
        id: randomUUID(),
        threadId: event.threadId,
        ts: Date.now(),
        agentId: MAIN_AGENT,
        kind: "interrupt",
        data: {},
      });
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
        handleEvent(event, locals.get(device) ?? (() => {}));
      } catch (e) {
        state(`local-event-error ${e instanceof Error ? e.message : String(e)}`);
      }
    },
    onClose: (device) => {
      locals.delete(device);
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

    const sendFrame = (body: FrameBody): void => {
      const payload = toBase64Url(Buffer.from(JSON.stringify(body)));
      const sig = signFrame(keys.signing.privateKey, Buffer.from(payload));
      ws.send(JSON.stringify({ type: "frame", payload, sig: toBase64Url(sig) }));
    };

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
      const preview = notificationPreview(event);
      const previews = preview
        ? Object.fromEntries(
            [...devices.values()].flatMap(({ key, record }) => {
              if (!record.signingPub || event.ts < (record.pairedAt ?? 0)) return [];
              const box = seal(key, Buffer.from(preview));
              return [[record.signingPub, { n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }]];
            }),
          )
        : undefined;
      // An approval the phone may answer from its lock screen: below every floor and nothing
      // external. One bit for the relay; the action itself stays in the sealed frame.
      const actions =
        event.kind === "approval_card" &&
        (quickActions.get(event.data.actionId) === true || nativeCards.quickApprovable(event.data.actionId));
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

    sendTo = (device: string, event: YorozuEvent): void => {
      const known = devices.get(device);
      const key = known?.key;
      if (!key || !relayReady || ws.readyState !== WebSocket.OPEN) return;
      const cutoff = known.record.pairedAt ?? 0;
      if (event.threadId && event.ts < cutoff) return;
      if (event.kind === "thread_list") event = { ...threadList(cutoff), id: event.id, ts: event.ts };
      const box = seal(key, Buffer.from(JSON.stringify(event)));
      sendFrame({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) });
    };

    /**
     * Frames carry no sender, so the device that sent one is whichever session key opens it.
     * A box sealed for another phone is simply not ours to read.
     */
    function openFrom(body: { n: string; c: string }): [string, YorozuEvent] | null {
      for (const [device, { key }] of devices) {
        try {
          const plain = open(key, fromBase64Url(body.n), fromBase64Url(body.c));
          return [device, JSON.parse(Buffer.from(plain).toString()) as YorozuEvent];
        } catch {
          // Not sealed for us: try the next paired device.
        }
      }
      return null;
    }

    /** Everything here is attacker-controlled: a bad frame must not kill the sidecar. */
    function onFrame(payload: unknown): void {
      if (typeof payload !== "string") return;
      const body = JSON.parse(Buffer.from(payload, "base64url").toString()) as FrameBody;
      if (body.t === "hello") {
        if (typeof body.pub !== "string" || body.pub === "") return state("hello-refused");
        const known = devices.get(body.pub);
        // A key pair not on file gets in only with proof it read a QR this Mac drew. The
        // relay verified the frame's signature, but the relay could have signed it itself.
        if (!known) {
          const proved =
            typeof body.proof === "string" &&
            typeof body.spub === "string" &&
            [...pairingSecrets].some((secret) => helloProof(secret, body.pub, body.spub!) === body.proof);
          if (!proved) return state("hello-refused");
          pairingSecrets.clear();
        }
        remember({
          pub: body.pub,
          ...(body.spub ? { signingPub: body.spub } : known?.record.signingPub
            ? { signingPub: known.record.signingPub }
            : {}),
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
        // next one now, and the Mac's menu bar shows a QR a second device can still use.
        ws.send(JSON.stringify({ type: "mint" }));
        return;
      }
      if (body.t !== "box") return;
      const opened = openFrom(body);
      if (!opened) return;
      const [device, event] = opened;
      const known = devices.get(device);
      // Hearing from a device is the only thing that makes it online, so the stamp is kept.
      if (known) known.record.lastSeen = Date.now();
      handleEvent(event, (answer) => sendTo(device, answer), known?.record.pairedAt ?? 0);
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
      const msg = JSON.parse(data.toString()) as Record<string, unknown>;
      try {
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
          case "frame":
            // A replayed frame carries the relay's buffer sequence; acking it is what lets the
            // relay let go. The ack is cumulative, so it is sent only once every frame up to
            // this one has been handled: a frame that threw is left for the next replay
            // rather than deleted by the ack of the one after it. Live frames carry no `seq`.
            try {
              onFrame(msg.payload);
            } catch (e) {
              if (typeof msg.seq === "number") ackBlocked = true;
              throw e;
            }
            if (typeof msg.seq === "number" && !ackBlocked) {
              ws.send(JSON.stringify({ type: "ack", seq: msg.seq }));
            }
            return;
        }
      } catch (e) {
        state(`frame-error ${e instanceof Error ? e.message : String(e)}`);
      }
    });

    ws.on("error", (e) => state(`error ${e.message}`));

    ws.on("close", () => {
      relayReady = false;
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
    const known = readThreadEvents(threadId, dir);
    const durableFinal = known.find((event) => event.id === completionId);
    if (durableFinal) {
      finalizeOpenClaw(durableFinal);
      return;
    }
    const turn = new AbortController();
    running.set(threadId, turn);
    const message = (text: string, done = false): YorozuEvent => ({
      id: completionId, threadId, ts: Date.now(), agentId: MAIN_AGENT, kind: "message",
      data: { role: "agent", text, ...(done ? { done: true } : {}) },
    });
    try {
      while (!turn.signal.aborted) {
        try {
          const reply = await openclaw!.resume({
            threadId,
            signal: turn.signal,
            seenEventIds: readThreadEvents(threadId, dir).map((event) => event.id),
            onUpdate: (text) => broadcast(message(text)),
            onEvent: emit,
          });
          if (turn.signal.aborted || reply === undefined) return;
          finalizeOpenClaw(message(reply, true));
          return;
        } catch (error) {
          state(`openclaw-resume-error ${String(error)}`);
          await new Promise((resolve) => setTimeout(resolve, 250));
        }
      }
    } finally {
      if (running.get(threadId) === turn) running.delete(threadId);
    }
  };

  for (const stored of openclaw?.pendingTurns() ?? []) {
    if (stored.state !== "queued") {
      const recovery = resumeOpenClaw(stored);
      turnQueues.set(stored.threadId, recovery);
      if (stored.userEventId) admittedTurns.set(stored.userEventId, recovery);
      void recovery.finally(() => {
        if (stored.userEventId && admittedTurns.get(stored.userEventId) === recovery) admittedTurns.delete(stored.userEventId);
      }).catch(() => {});
    } else {
      void enqueueTurn(stored.threadId, stored.input.text, true, stored.input.attachments, stored.userEventId);
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
      const sidecar = serve(command === "--direct-provider" ? { provider: chainFromEnv() } : { titler: chainFromEnv() });
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

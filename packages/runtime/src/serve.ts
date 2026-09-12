#!/usr/bin/env node
/**
 * Runtime sidecar. Pairs with phones through the blind relay and answers their messages
 * with the agent loop. See docs/spec-v1.html section 8.
 *
 * Stdout is the Mac app's only channel: one `STATE <state>` line per relay transition and,
 * per pairing payload, a `QR <string>` line to draw and a `PAIR <string>` line to copy —
 * both the same pairing string. `MINT` on stdin asks the relay for a fresh join token.
 */
import { createHash, randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { argv, env, stdin, stdout } from "node:process";
import {
  deriveSessionKey,
  encodePairingString,
  fromBase64Url,
  generateKeypair,
  generateSigningKeypair,
  open,
  seal,
  signFrame,
  toBase64Url,
  type ApprovalCardData,
  type DeviceInfo,
  type EventPayload,
  type Keypair,
  type ProgressCardData,
  type YorozuEvent,
} from "@yorozu/shared";
import WebSocket from "ws";
import { agentsDir, installAgents, loadAgent, MAIN_AGENT } from "./agents.js";
import {
  cardFor,
  deleteRule,
  addRule,
  listRules,
  narrowestRule,
  TaskGrants,
  type Action,
  type AskResult,
  type Rule,
} from "./approval.js";
import { autoAssign, revertAssign, setAssignCron, type AssignMode } from "./assign.js";
import { chainFromEnv, chainWithPrimary } from "./chain.js";
import { delegateTool } from "./delegate.js";
import { defaultTools, eventPayload, runAgent, type TurnContext } from "./index.js";
import { localSocketPath, startLocalChannel, type Send } from "./local.js";
import type { Provider } from "./provider.js";
import { probe } from "./probe.js";
import { listEntryModels, loadProviders, modelOptions } from "./providers.js";
import { startScheduler } from "./scheduler.js";
import { listSkills, skillsDir, skillsPrompt } from "./skills.js";
import { contextFor, updateSummary } from "./summary.js";
// Mirrors PING in apps/relay/src/protocol.ts; the shipped runtime must not depend on the relay package.
const PING = JSON.stringify({ type: "ping" });
import {
  appendThreadEvent,
  archiveThread,
  createThread,
  currentThread,
  eventsAfter,
  listThreads,
  pinThread,
  renameThread,
  setThreadModel,
  threadHistory,
  threadModel,
  threadSummaries,
} from "./threads.js";
import { closeBrowser } from "./tools/browser.js";
import { askUserTool, questionDesk, reportProgressTool } from "./tools/cards.js";
import { useProviderSearch } from "./tools/search.js";
import { appendTranscript, transcriptDir } from "./transcripts.js";

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
/** A title is a nicety: past this the thread keeps its placeholder rather than the phone waiting. */
const TITLE_TIMEOUT_MS = 5_000;
const TITLE_SYSTEM =
  "Reply with a 3-5 word title for this conversation, no quotes, no trailing period";
/** How much of the opening exchange the titler is shown. */
const TITLE_CONTEXT_CHARS = 500;
/**
 * How long a device counts as online for. The relay tells us nothing about a phone's socket —
 * only the phone is told about ours — so "online" here means "has said something recently",
 * which is the only honest answer the runtime has.
 */
const ONLINE_MS = 90_000;

/** The model's answer as a title: one line, no quotes, no trailing period, and short. */
export function cleanTitle(raw: string): string {
  return raw
    .split("\n")
    .map((line) => line.replace(/["'`]/g, "").trim())
    .find((line) => line !== "")
    ?.replace(/[.\s]+$/, "")
    .slice(0, 60) ?? "";
}

/**
 * A yes / always / no typed in the thread instead of tapped on the card. An `always` only
 * narrows to the target when the user actually named it, so "always" alone stays class-level
 * and "always buy from that shop" does not silently cover every shop. A bare "never" is the
 * one-off no it sounds like — only the explicit "never ask again" wordings allow and persist.
 */
export function typedAnswer(text: string, card: ApprovalCardData): AskResult | null {
  const typed = text.trim().toLowerCase();
  if (/^(always|yes,? +always|yes,? +and +never +ask|never +ask +again|don'?t +ask +again)\b/.test(typed)) {
    const target = card.target.toLowerCase();
    // Typed rather than tapped, so there is no editor and no edited rule: the card's own
    // suggestion is the narrowest thing that covers what was just approved.
    return {
      answer: "always",
      ...(card.suggestedRule ? { rule: card.suggestedRule } : {}),
      ...(target && typed.includes(target) ? { target: card.target } : {}),
    };
  }
  // The bounded grant, which only exists in prose as "for this task" and its neighbours.
  if (/^(yes,? +)?(just )?(for|during) +(this|the) +(task|turn|one)\b/.test(typed)) {
    return { answer: "task" };
  }
  if (/^(yes|y|ok|okay|sure)\b/.test(typed)) return { answer: "yes" };
  if (/^(no|n|nope|stop|never)\b/.test(typed)) return { answer: "no" };
  return null;
}
/** Only reached if the user deleted agents/main.md: the bundled one is installed on startup. */
const SYSTEM = "You are Yorozu, a personal assistant running on the user's Mac.";

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

/** Keys outlive restarts: the room and every paired phone are pinned to them. */
export function loadKeys(dir: string): Keys {
  const file = join(dir, "keys.json");
  try {
    const stored = JSON.parse(readFileSync(file, "utf8")) as Record<keyof Keys, StoredKey>;
    return { session: restore(stored.session), signing: restore(stored.signing) };
  } catch {
    const keys: Keys = { session: generateKeypair(), signing: generateSigningKeypair() };
    mkdirSync(dir, { recursive: true });
    writeFileSync(file, JSON.stringify({ session: store(keys.session), signing: store(keys.signing) }), {
      mode: 0o600,
    });
    return keys;
  }
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
 */
type FrameBody =
  | { t: "hello"; pub: string; spub?: string }
  | { t: "box"; n: string; c: string };

/**
 * One line of `devices.json`. `signingPub` is the Ed25519 key the relay knows the device by,
 * which the phone announces alongside its session key: it cannot be derived from `pub`, and
 * revoking a device at the relay is addressed to it.
 */
export interface DeviceRecord {
  pub: string;
  signingPub?: string;
  /** Epoch milliseconds we last heard from it; 0 for a device paired before this was kept. */
  lastSeen: number;
}

export interface ServeOptions {
  relayUrl?: string;
  stateDir?: string;
  /** Defaults to the model chain configured from the environment. */
  provider?: Provider;
  /** Defaults to stdout. */
  log?: (line: string) => void;
  /**
   * How often to ping the relay, and how long to wait for the pong before giving the socket up
   * for dead. Defaults to ``PING_MS``/``PONG_MS``; the tests turn them down so the timeout is
   * something a test can wait for rather than something only a real half-open socket reaches.
   */
  heartbeat?: { pingMs: number; pongMs: number };
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
  const keys = loadKeys(dir);
  const provider = options.provider ?? chainFromEnv();
  // `web_search` asks the running chain for native search before it drives a browser.
  useProviderSearch(provider);
  const log = options.log ?? ((line: string) => void stdout.write(`${line}\n`));
  const heartbeat = options.heartbeat ?? { pingMs: PING_MS, pongMs: PONG_MS };
  const state = (name: string) => log(`STATE ${name}`);

  // A chain nobody is signed in to answers every turn with a 401. Said once, here, so the Mac
  // app can show it instead of leaving the user to read auth errors in a chat bubble. Skipped
  // for a caller-supplied provider: that one is the caller's business.
  if (!options.provider) {
    void provider
      .auth()
      .then((result) => state(result.ok ? "provider-ok" : "no-provider"))
      .catch(() => state("no-provider"));
  }

  // The main agent is a file like every specialist; the skills on disk are listed into its
  // prompt once, at startup, and their bodies load on demand through the `skill` tool.
  const agents = installAgents(agentsDir(dir));
  const main = loadAgent(MAIN_AGENT, agents) ?? { name: MAIN_AGENT, prompt: SYSTEM };
  const system = [main.prompt, skillsPrompt(listSkills(skillsDir(dir)))]
    .filter(Boolean)
    .join("\n\n");
  /** One controller per running turn, so an `interrupt` cancels every tree at once. */
  const running = new Set<AbortController>();

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
  for (const record of loadDevices(devicesFile)) {
    // A key on disk we can no longer agree with is simply dropped, not a reason not to start.
    try {
      remember(record);
    } catch {
      // Not a usable X25519 key any more.
    }
  }

  /**
   * The same thing for devices on the local socket, which need no key: the Mac app is one more
   * paired device, it just reached us without the relay. Kept apart from ``devices`` only
   * because what it stores per device is a writer rather than a session key.
   */
  const locals = new Map<string, Send>();

  let socket: WebSocket | null = null;
  let retry: NodeJS.Timeout | null = null;
  let stopped = false;
  /** Seals and sends to one paired device. Replaced per connection, a no-op while there is none. */
  let sendTo: (device: string, event: YorozuEvent) => void = () => {};

  /** The same event to every paired device, through the relay or over the local socket. */
  const broadcast = (event: YorozuEvent): void => {
    for (const device of devices.keys()) sendTo(device, event);
    for (const send of locals.values()) send(event);
  };

  /** Asks the relay to forget a device, so a revoked phone cannot rejoin against the nonce. */
  let revokeAtRelay: (signingPub: string) => void = () => {};

  /** Everything the runtime sees is logged first: the nightly job reads the log back. */
  function emit(event: YorozuEvent): void {
    appendTranscript(event, transcripts);
    appendThreadEvent(event, dir);
    broadcast(event);
  }

  /** Cards on screen somewhere, waiting to be answered, by action ID. */
  const pending = new Map<string, { card: ApprovalCardData; settle: (result: AskResult) => void }>();

  /**
   * Puts a card in front of every paired device and blocks the tool call until one of them
   * answers it. The turn is suspended here, so an interrupt and the timeout both have to be
   * able to settle it.
   */
  function ask(action: Action, context?: { threadId: string; agentId: string }): Promise<AskResult> {
    const actionId = randomUUID();
    const card = cardFor(actionId, action);
    return new Promise<AskResult>((resolve) => {
      const timer = setTimeout(() => {
        pending.delete(actionId);
        resolve({ answer: "no" });
      }, APPROVAL_TIMEOUT_MS);
      timer.unref?.();
      pending.set(actionId, {
        card,
        settle: (result) => {
          clearTimeout(timer);
          pending.delete(actionId);
          resolve(result);
        },
      });
      emit({
        id: randomUUID(),
        threadId: context?.threadId ?? currentThread(dir),
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

  const threadList = (): YorozuEvent =>
    control({ kind: "thread_list", data: { threads: threadSummaries(dir) } });

  /**
   * What a thread can be put on, by name. Sent with the thread list rather than on request: a
   * phone's model picker is one tap away from the thread it is about, and asking for the list
   * at that point would draw an empty menu first.
   */
  const modelList = (): YorozuEvent =>
    control({ kind: "model_list", data: { models: modelOptions(loadProviders(dir)) } });

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

  /** Everything the device has not seen, across every live thread, in one frame. */
  const syncDelta = (lastSeen: Record<string, string>): YorozuEvent =>
    control({
      kind: "sync_delta",
      data: {
        events: listThreads(dir)
          .filter((thread) => !thread.archived)
          .flatMap((thread) => eventsAfter(thread.id, lastSeen?.[thread.id], dir)),
      },
    });

  /**
   * One agent turn in `threadId`, however it was started — a phone message or a due job —
   * with its reply emitted to the phone the same way either way.
   */
  async function runTurn(threadId: string, text: string, recorded = false): Promise<void> {
    // A turn the phone did not send — a due job, a background delegation — is still part of
    // the thread, so it is recorded as the user message it stands in for.
    if (!recorded) {
      appendThreadEvent(
        {
          id: randomUUID(),
          threadId,
          ts: Date.now(),
          agentId: MAIN_AGENT,
          kind: "message",
          data: { role: "user", text },
        },
        dir,
      );
    }

    // The reply streams under one id: every delta re-sends the whole text so far, so the phone
    // replaces that message in place and a dropped frame still converges. Only the finished
    // reply goes through `emit`, so the transcript keeps one line per turn rather than one
    // per delta.
    const id = randomUUID();
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

    // A thread put on a model of its own leads with it and keeps the configured chain behind
    // it, so one unreachable provider is a slower turn rather than a thread that cannot answer.
    // Resolved per turn: the picker may have been used since the last one. A spec naming a
    // provider the user has since deleted cannot be built at all — that thread falls all the
    // way back to the default chain, because an answer from the wrong model beats none.
    const spec = threadModel(threadId, dir);
    let turnProvider = provider;
    if (spec) {
      try {
        turnProvider = chainWithPrimary(spec, provider, dir);
      } catch (e) {
        state(`model-error ${e instanceof Error ? e.message : String(e)}`);
      }
    }

    const turn = new AbortController();
    running.add(turn);
    let reply = "";
    /**
     * What the deltas have already put on the wire. Streaming runs one delta behind on
     * purpose: the frame carrying the whole reply is the finished one, which is sent below
     * whatever happens, so sending a delta identical to it first would put the same reply on
     * the socket twice — which is exactly what a non-streaming provider did, one text event
     * and then the final, two identical agent messages for one turn.
     */
    let sent = "";
    try {
      // Built per turn: `delegate` carries this turn's abort signal down to its children.
      // One per turn, shared with everything this turn delegates to, and dropped with the
      // turn: that is exactly the life "Allow for this task" promises.
      const grants = new TaskGrants();
      const tools = [
        ...defaultTools,
        // Both draw on the paired devices, so they only exist where there is somebody to draw
        // for: a turn, rather than the tool list the CLI shares.
        askUserTool(questions.ask),
        reportProgressTool(reportProgress),
        delegateTool({
          provider: turnProvider,
          tools: [...defaultTools, reportProgressTool(reportProgress)],
          main,
          emit,
          turn: runTurn,
          ask,
          grants,
          onProposal: proposeRule,
          dir: agents,
          signal: turn.signal,
        }),
      ];
      for await (const event of runAgent({
        provider: turnProvider,
        system,
        // The rolling summary of what has scrolled out, then the recent window.
        messages: contextFor(threadId, dir, turnProvider.vision === true),
        tools,
        context: { threadId, agentId: MAIN_AGENT },
        ask,
        grants,
        onProposal: proposeRule,
        signal: turn.signal,
      })) {
        if (event.type === "text") {
          if (reply !== sent) {
            broadcast(message(reply));
            sent = reply;
          }
          reply += event.text;
        } else if (event.type === "final") {
          reply = event.text;
        } else {
          // The main agent's own tool calls and results, tagged like a specialist's so the
          // phone can draw the same trace for both. Its own id: only the reply streams.
          const payload = eventPayload(event);
          if (payload) {
            emit({ id: randomUUID(), threadId, ts: Date.now(), agentId: MAIN_AGENT, ...payload });
          }
        }
      }
    } finally {
      running.delete(turn);
    }
    // An interrupted turn says nothing: the user already knows they stopped it.
    if (turn.signal.aborted) return;
    // The finished reply is always logged, and always sent: unlike the deltas it carries
    // `done`, so even a reply whose text matches the last delta exactly is still news.
    const final = message(reply, true);
    appendTranscript(final, transcripts);
    appendThreadEvent(final, dir);
    broadcast(final);
    // Deliberately not awaited: titling is a second completion and must never delay a reply.
    void autoTitle(threadId).catch((e: unknown) => state(`title-error ${String(e)}`));
    // Nor is the summary: it is only ever needed by the *next* turn, and a thread that has not
    // outgrown its window does no work here at all. A failure leaves the summary as it was.
    void updateSummary(threadId, turnProvider, dir).catch((e: unknown) =>
      state(`summary-error ${String(e)}`),
    );
  }

  /**
   * Names a thread from its opening exchange, once. Only a thread whose title is still empty is
   * titled, which is also what keeps a rename the user typed: that title is not empty, so no
   * later turn overwrites it.
   */
  async function autoTitle(threadId: string): Promise<void> {
    const untitled = (): boolean =>
      listThreads(dir).find((thread) => thread.id === threadId)?.title === "";
    if (!untitled()) return;

    const history = threadHistory(threadId, dir);
    const opening = [
      history.find((m) => m.role === "user")?.content,
      history.find((m) => m.role === "assistant")?.content,
    ]
      .filter(Boolean)
      .join("\n\n")
      .slice(0, TITLE_CONTEXT_CHARS);
    if (!opening) return;

    const ask = async (): Promise<string> => {
      let text = "";
      for await (const event of provider.stream(
        [
          { role: "system", content: TITLE_SYSTEM },
          { role: "user", content: opening },
        ],
        [],
      )) {
        if (event.type === "text") text += event.text;
      }
      return text;
    };
    const title = cleanTitle(
      await Promise.race([
        ask(),
        new Promise<string>((resolve) => {
          setTimeout(() => resolve(""), TITLE_TIMEOUT_MS).unref?.();
        }),
      ]),
    );

    // Re-checked: a rename may have landed while the titler was thinking.
    if (!title || !untitled()) return;
    if (renameThread(threadId, title, dir)) broadcast(threadList());
  }

  /**
   * One event from a paired device, however it reached us — a sealed relay frame or a line on
   * the local socket. `reply` answers that one device; the thread admin cases answer all of
   * them, so a second device sees the same list.
   */
  function handleEvent(event: YorozuEvent, reply: Send): void {
    appendTranscript(event, transcripts);
    appendThreadEvent(event, dir);

    switch (event.kind) {
      case "interrupt":
        for (const turn of running) turn.abort();
        running.clear();
        // A turn parked on a card would never notice the abort otherwise.
        for (const { settle } of [...pending.values()]) settle({ answer: "no" });
        questions.cancelAll();
        return;
      case "approval_answer":
        pending.get(event.data.actionId)?.settle({
          answer: event.data.answer,
          ...(event.data.rule ? { rule: event.data.rule } : {}),
        });
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
      case "rule_proposal":
        // Emitted by the runtime, never accepted from a device: a proposal is not a decision.
        return;
      case "question_answer":
        questions.answer(event.data.questionId, event.data.answer);
        return;
      // Thread admin is answered to every device, so a second phone sees the same list.
      case "thread_create":
        // The device minted the id: the message it typed follows straight after this frame.
        createThread(event.data.title, dir, event.threadId || undefined);
        return broadcast(threadList());
      case "thread_rename":
        renameThread(event.threadId, event.data.title, dir);
        return broadcast(threadList());
      case "thread_archive":
        archiveThread(event.threadId, dir, event.data.archived ?? true);
        return broadcast(threadList());
      case "thread_pin":
        pinThread(event.threadId, event.data.pinned, dir);
        return broadcast(threadList());
      case "thread_list":
        reply(threadList());
        return reply(modelList());
      case "thread_set_model":
        setThreadModel(event.threadId, event.data.model ?? null, dir);
        return broadcast(threadList());
      case "device_list":
        return reply(deviceList());
      case "device_remove":
        return forgetDevice(event.data.pub);
      case "sync_request":
        return reply(syncDelta(event.data.lastSeen));
    }

    if (event.kind !== "message" || event.data.role !== "user") return;
    // A plain "yes" while a card is up answers the card rather than starting a turn.
    const [oldest] = pending.values();
    const typed = oldest && typedAnswer(event.data.text, oldest.card);
    if (typed) return oldest.settle(typed);
    runTurn(event.threadId, event.data.text, true).catch((e: unknown) =>
      state(`agent-error ${String(e)}`),
    );
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
      if (ws.readyState !== WebSocket.OPEN) return;
      const records = [...devices.values()].map(({ record }) => record);
      if (records.some(({ signingPub }) => signingPub === undefined)) return;
      ws.send(JSON.stringify({ type: "devices", devices: records.map((r) => r.signingPub) }));
    };

    revokeAtRelay = (signingPub: string): void => {
      if (ws.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: "revoke", pubkey: signingPub }));
      }
    };

    sendTo = (device: string, event: YorozuEvent): void => {
      const key = devices.get(device)?.key;
      if (!key || ws.readyState !== WebSocket.OPEN) return;
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
        const known = devices.get(body.pub);
        remember({
          pub: body.pub,
          ...(body.spub ? { signingPub: body.spub } : known?.record.signingPub
            ? { signingPub: known.record.signingPub }
            : {}),
          lastSeen: Date.now(),
        });
        saveDevices();
        state("paired");
        // A phone that has just paired needs the thread list before it can ask for anything.
        sendTo(body.pub, threadList());
        sendTo(body.pub, modelList());
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
      handleEvent(event, (answer) => sendTo(device, answer));
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
            state("registered");
            announceDevices();
            return ws.send(JSON.stringify({ type: "mint" }));
          case "token": {
            const pairing = encodePairingString({
              v: 1,
              relayUrl,
              macPubkey: toBase64Url(keys.session.publicKey),
              token: String(msg.token),
              ...(room ? { roomId: room } : {}),
            });
            // The same string twice: one line the Mac draws as a QR, one it offers to copy.
            log(`QR ${pairing}`);
            return log(`PAIR ${pairing}`);
          }
          case "frame":
            return onFrame(msg.payload);
        }
      } catch (e) {
        state(`frame-error ${e instanceof Error ? e.message : String(e)}`);
      }
    });

    ws.on("error", (e) => state(`error ${e.message}`));

    ws.on("close", () => {
      stopHeartbeat();
      state("disconnected");
      if (!stopped) retry = setTimeout(connect, RECONNECT_MS);
    });
  }

  connect();

  // No heartbeat: the runner only wakes to ask which jobs are due.
  const scheduler = startScheduler(
    (job) =>
      void runTurn(job.threadId, job.instruction).catch((e: unknown) =>
        state(`job-error ${job.id} ${String(e)}`),
      ),
    { dir },
  );

  return {
    mint: () => {
      if (socket?.readyState === WebSocket.OPEN) socket.send(JSON.stringify({ type: "mint" }));
    },
    close: async () => {
      stopped = true;
      scheduler.stop();
      if (retry) clearTimeout(retry);
      await local.close();
      // Whatever the agent opened in the browser goes away with the sidecar.
      await closeBrowser();
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
      stdout.write(`${JSON.stringify(await probe())}\n`);
      break;
    // The model list of one `openai-compat` entry, one id per line, for the Settings picker.
    case "models":
      stdout.write(`${(await listEntryModels(argument ?? "")).join("\n")}\n`);
      break;
    case "assign":
      stdout.write(await autoAssign({ mode: mode(argument) }));
      break;
    case "assign-revert":
      stdout.write(`${revertAssign()}\n`);
      break;
    case "assign-cron":
      stdout.write(`${setAssignCron(argument ?? "", mode(extra))}\n`);
      break;
    default: {
      const sidecar = serve();
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

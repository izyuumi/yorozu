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
  type EventPayload,
  type Keypair,
  type YorozuEvent,
} from "@yorozu/shared";
import WebSocket from "ws";
import { agentsDir, installAgents, loadAgent, MAIN_AGENT } from "./agents.js";
import type { Action, AskResult } from "./approval.js";
import { autoAssign, revertAssign, setAssignCron, type AssignMode } from "./assign.js";
import { chainFromEnv } from "./chain.js";
import { delegateTool } from "./delegate.js";
import { defaultTools, eventPayload, runAgent } from "./index.js";
import { localSocketPath, startLocalChannel, type Send } from "./local.js";
import type { Provider } from "./provider.js";
import { probe } from "./probe.js";
import { startScheduler } from "./scheduler.js";
import { listSkills, skillsDir, skillsPrompt } from "./skills.js";
import {
  appendThreadEvent,
  archiveThread,
  createThread,
  eventsAfter,
  HOME_THREAD,
  listThreads,
  renameThread,
  threadHistory,
  threadSummaries,
} from "./threads.js";
import { closeBrowser } from "./tools/browser.js";
import { useProviderSearch } from "./tools/search.js";
import { appendTranscript, transcriptDir } from "./transcripts.js";

const DEFAULT_STATE_DIR = join(homedir(), "Library", "Application Support", "Yorozu");
const RECONNECT_MS = 2_000;
/** An unanswered card is not a yes: it expires into a refusal rather than hanging the turn. */
const APPROVAL_TIMEOUT_MS = 10 * 60_000;
/** A title is a nicety: past this the thread keeps its placeholder rather than the phone waiting. */
const TITLE_TIMEOUT_MS = 5_000;
const TITLE_SYSTEM =
  "Reply with a 3-5 word title for this conversation, no quotes, no trailing period";
/** How much of the opening exchange the titler is shown. */
const TITLE_CONTEXT_CHARS = 500;

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
 * A yes / no / never typed in the thread instead of tapped on the card. A `never` only
 * narrows to the target when the user actually named it, so "never" alone stays class-level
 * and "never buy from that shop" does not silently cover every shop.
 */
export function typedAnswer(text: string, card: ApprovalCardData): AskResult | null {
  const typed = text.trim().toLowerCase();
  if (/^(yes|y|ok|okay|sure)\b/.test(typed)) return { answer: "yes" };
  if (/^(no|n|nope|stop)\b/.test(typed)) return { answer: "no" };
  if (/^never\b/.test(typed)) {
    const target = card.target.toLowerCase();
    return { answer: "never", ...(target && typed.includes(target) ? { target: card.target } : {}) };
  }
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
 * Frame bodies, base64url JSON inside the relay's opaque `payload`. `hello` is the phone
 * announcing its X25519 key; everything after it is sealed.
 */
type FrameBody = { t: "hello"; pub: string } | { t: "box"; n: string; c: string };

export interface ServeOptions {
  relayUrl?: string;
  stateDir?: string;
  /** Defaults to the model chain configured from the environment. */
  provider?: Provider;
  /** Defaults to stdout. */
  log?: (line: string) => void;
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
  const state = (name: string) => log(`STATE ${name}`);

  // The main agent is a file like every specialist; the skills on disk are listed into its
  // prompt once, at startup, and their bodies load on demand through the `skill` tool.
  const agents = installAgents(agentsDir(dir));
  const main = loadAgent(MAIN_AGENT, agents) ?? { name: MAIN_AGENT, prompt: SYSTEM };
  const system = [main.prompt, skillsPrompt(listSkills(skillsDir(dir)))]
    .filter(Boolean)
    .join("\n\n");
  /** One controller per running turn, so an `interrupt` cancels every tree at once. */
  const running = new Set<AbortController>();

  // Home exists before any phone asks for it.
  listThreads(dir);

  /**
   * Session key per paired device, keyed by the X25519 public key it announced. Several
   * phones can be paired at once, so every agent event is sealed once per device; the map
   * outlives the socket, so a reconnect unpairs nobody.
   */
  const devices = new Map<string, Uint8Array>();

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
    const card: ApprovalCardData = {
      actionId,
      actionClass: action.actionClass,
      target: action.target,
      ...(action.amount !== undefined ? { amount: action.amount } : {}),
    };
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
        threadId: context?.threadId ?? HOME_THREAD,
        ts: Date.now(),
        agentId: context?.agentId ?? MAIN_AGENT,
        kind: "approval_card",
        data: card,
      });
    });
  }

  const control = (payload: EventPayload): YorozuEvent => ({
    id: randomUUID(),
    threadId: HOME_THREAD,
    ts: Date.now(),
    agentId: MAIN_AGENT,
    ...payload,
  });

  const threadList = (): YorozuEvent =>
    control({ kind: "thread_list", data: { threads: threadSummaries(dir) } });

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
    const message = (reply: string): YorozuEvent => ({
      id,
      threadId,
      ts: Date.now(),
      agentId: MAIN_AGENT,
      kind: "message",
      data: { role: "agent", text: reply },
    });

    const turn = new AbortController();
    running.add(turn);
    let reply = "";
    try {
      // Built per turn: `delegate` carries this turn's abort signal down to its children.
      const tools = [
        ...defaultTools,
        delegateTool({
          provider,
          tools: defaultTools,
          main,
          emit,
          turn: runTurn,
          ask,
          dir: agents,
          signal: turn.signal,
        }),
      ];
      for await (const event of runAgent({
        provider,
        system,
        // The thread's own history is the context, compacted by `threadHistory`.
        messages: threadHistory(threadId, dir),
        tools,
        context: { threadId, agentId: MAIN_AGENT },
        ask,
        signal: turn.signal,
      })) {
        if (event.type === "text") {
          reply += event.text;
          broadcast(message(reply));
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
    emit(message(reply));
    // Deliberately not awaited: titling is a second completion and must never delay a reply.
    void autoTitle(threadId).catch((e: unknown) => state(`title-error ${String(e)}`));
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
        return;
      case "approval_answer":
        pending.get(event.data.actionId)?.settle({ answer: event.data.answer });
        return;
      // Thread admin is answered to every device, so a second phone sees the same list.
      case "thread_create":
        createThread(event.data.title, dir);
        return broadcast(threadList());
      case "thread_rename":
        renameThread(event.threadId, event.data.title, dir);
        return broadcast(threadList());
      case "thread_archive":
        archiveThread(event.threadId, dir);
        return broadcast(threadList());
      case "thread_list":
        return reply(threadList());
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

    sendTo = (device: string, event: YorozuEvent): void => {
      const key = devices.get(device);
      if (!key || ws.readyState !== WebSocket.OPEN) return;
      const box = seal(key, Buffer.from(JSON.stringify(event)));
      sendFrame({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) });
    };

    /**
     * Frames carry no sender, so the device that sent one is whichever session key opens it.
     * A box sealed for another phone is simply not ours to read.
     */
    function openFrom(body: { n: string; c: string }): [string, YorozuEvent] | null {
      for (const [device, key] of devices) {
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
        devices.set(body.pub, deriveSessionKey(keys.session.privateKey, fromBase64Url(body.pub)));
        state("paired");
        // A phone that has just paired needs the thread list before it can ask for anything.
        sendTo(body.pub, threadList());
        // Join tokens are one-time, so the one in the printed QR has just been burnt: mint the
        // next one now, and the Mac's menu bar shows a QR a second device can still use.
        ws.send(JSON.stringify({ type: "mint" }));
        return;
      }
      if (body.t !== "box") return;
      const opened = openFrom(body);
      if (!opened) return;
      const [device, event] = opened;
      handleEvent(event, (answer) => sendTo(device, answer));
    }

    ws.on("open", () => state("connected"));

    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Record<string, unknown>;
      try {
        switch (msg.type) {
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

#!/usr/bin/env node
/**
 * Runtime sidecar. Pairs with phones through the blind relay and answers their messages
 * with the agent loop. See docs/spec-v1.html section 8.
 *
 * Stdout is the Mac app's only channel: one `STATE <state>` line per relay transition and
 * one `QR <json>` line carrying the pairing payload.
 */
import { randomUUID } from "node:crypto";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { argv, env, stdout } from "node:process";
import {
  deriveSessionKey,
  encodeQrPayload,
  fromBase64Url,
  generateKeypair,
  generateSigningKeypair,
  open,
  seal,
  signFrame,
  toBase64Url,
  type ApprovalCardData,
  type Keypair,
  type YorozuEvent,
} from "@yorozu/shared";
import WebSocket from "ws";
import { agentsDir, installAgents, loadAgent, MAIN_AGENT } from "./agents.js";
import type { Action, AskResult } from "./approval.js";
import { chainFromEnv } from "./chain.js";
import { delegateTool } from "./delegate.js";
import { defaultTools, eventPayload, runAgent } from "./index.js";
import type { Provider } from "./provider.js";
import { probe } from "./probe.js";
import { startScheduler } from "./scheduler.js";
import { listSkills, skillsDir, skillsPrompt } from "./skills.js";
import { closeBrowser } from "./tools/browser.js";
import { appendTranscript, transcriptDir } from "./transcripts.js";

const DEFAULT_STATE_DIR = join(homedir(), "Library", "Application Support", "Yorozu");
const RECONNECT_MS = 2_000;
/** An unanswered card is not a yes: it expires into a refusal rather than hanging the turn. */
const APPROVAL_TIMEOUT_MS = 10 * 60_000;

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
}

export function serve(options: ServeOptions = {}): Sidecar {
  const relayUrl = options.relayUrl ?? env.YOROZU_RELAY_URL ?? "ws://127.0.0.1:8787";
  const dir = options.stateDir ?? env.YOROZU_STATE_DIR ?? DEFAULT_STATE_DIR;
  // Memory and the schedule tools resolve their own paths from the environment:
  // publish the choice so an explicit `stateDir` moves the whole runtime, not just the keys.
  env.YOROZU_STATE_DIR = dir;
  const transcripts = transcriptDir(dir);
  const keys = loadKeys(dir);
  const provider = options.provider ?? chainFromEnv();
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

  let socket: WebSocket | null = null;
  let retry: NodeJS.Timeout | null = null;
  let stopped = false;
  /** Seals and sends to the paired phone. Replaced per connection, a no-op while there is none. */
  let sendEvent: (event: YorozuEvent) => void = () => {};

  /** Everything the runtime sees is logged first: the nightly job reads the log back. */
  function emit(event: YorozuEvent): void {
    appendTranscript(event, transcripts);
    sendEvent(event);
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
        threadId: context?.threadId ?? "home",
        ts: Date.now(),
        agentId: context?.agentId ?? MAIN_AGENT,
        kind: "approval_card",
        data: card,
      });
    });
  }

  /**
   * One agent turn in `threadId`, however it was started — a phone message or a due job —
   * with its reply emitted to the phone the same way either way.
   */
  async function runTurn(threadId: string, text: string): Promise<void> {
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
        messages: [{ role: "user", content: text }],
        tools,
        context: { threadId, agentId: MAIN_AGENT },
        ask,
        signal: turn.signal,
      })) {
        if (event.type === "text") {
          reply += event.text;
          sendEvent(message(reply));
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
  }

  function connect(): void {
    state("connecting");
    const ws = new WebSocket(relayUrl);
    socket = ws;
    // One phone at a time: the relay frames carry no sender, so the newest pairing wins
    // until threads (ticket "Threads") give each device an identity.
    let sessionKey: Uint8Array | null = null;
    let room: string | null = null;

    const sendFrame = (body: FrameBody): void => {
      const payload = toBase64Url(Buffer.from(JSON.stringify(body)));
      const sig = signFrame(keys.signing.privateKey, Buffer.from(payload));
      ws.send(JSON.stringify({ type: "frame", payload, sig: toBase64Url(sig) }));
    };

    sendEvent = (event: YorozuEvent): void => {
      if (!sessionKey || ws.readyState !== WebSocket.OPEN) return;
      const box = seal(sessionKey, Buffer.from(JSON.stringify(event)));
      sendFrame({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) });
    };

    /** Everything here is attacker-controlled: a bad frame must not kill the sidecar. */
    function onFrame(payload: unknown): void {
      if (typeof payload !== "string") return;
      const body = JSON.parse(Buffer.from(payload, "base64url").toString()) as FrameBody;
      if (body.t === "hello") {
        sessionKey = deriveSessionKey(keys.session.privateKey, fromBase64Url(body.pub));
        state("paired");
        return;
      }
      if (body.t !== "box" || !sessionKey) return;
      const plain = open(sessionKey, fromBase64Url(body.n), fromBase64Url(body.c));
      const event = JSON.parse(Buffer.from(plain).toString()) as YorozuEvent;
      appendTranscript(event, transcripts);
      if (event.kind === "interrupt") {
        for (const turn of running) turn.abort();
        running.clear();
        // A turn parked on a card would never notice the abort otherwise.
        for (const { settle } of [...pending.values()]) settle({ answer: "no" });
        return;
      }
      if (event.kind === "approval_answer") {
        pending.get(event.data.actionId)?.settle({ answer: event.data.answer });
        return;
      }
      if (event.kind !== "message" || event.data.role !== "user") return;
      // A plain "yes" while a card is up answers the card rather than starting a turn.
      const [oldest] = pending.values();
      const typed = oldest && typedAnswer(event.data.text, oldest.card);
      if (typed) return oldest.settle(typed);
      runTurn(event.threadId, event.data.text).catch((e: unknown) =>
        state(`agent-error ${String(e)}`),
      );
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
          case "token":
            return log(
              `QR ${encodeQrPayload({
                v: 1,
                relayUrl,
                macPubkey: toBase64Url(keys.session.publicKey),
                token: String(msg.token),
                ...(room ? { roomId: room } : {}),
              })}`,
            );
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
    close: async () => {
      stopped = true;
      scheduler.stop();
      if (retry) clearTimeout(retry);
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
  // `probe` answers the Mac app's provider cards and exits; no argument serves.
  if (argv[2] === "probe") stdout.write(`${JSON.stringify(await probe())}\n`);
  else serve();
}

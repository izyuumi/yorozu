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
  type Keypair,
  type YorozuEvent,
} from "@yorozu/shared";
import WebSocket from "ws";
import { chainFromEnv } from "./chain.js";
import { defaultTools, runAgent } from "./index.js";
import { probe } from "./probe.js";
import type { Provider } from "./provider.js";

const DEFAULT_STATE_DIR = join(homedir(), "Library", "Application Support", "Yorozu");
const RECONNECT_MS = 2_000;
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
  const keys = loadKeys(options.stateDir ?? env.YOROZU_STATE_DIR ?? DEFAULT_STATE_DIR);
  const provider = options.provider ?? chainFromEnv();
  const log = options.log ?? ((line: string) => void stdout.write(`${line}\n`));
  const state = (name: string) => log(`STATE ${name}`);

  let socket: WebSocket | null = null;
  let retry: NodeJS.Timeout | null = null;
  let stopped = false;

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

    const sendEvent = (event: YorozuEvent): void => {
      if (!sessionKey) return;
      const box = seal(sessionKey, Buffer.from(JSON.stringify(event)));
      sendFrame({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) });
    };

    async function answer(incoming: YorozuEvent & { kind: "message" }): Promise<void> {
      let text = "";
      for await (const event of runAgent({
        provider,
        system: SYSTEM,
        messages: [{ role: "user", content: incoming.data.text }],
        tools: defaultTools,
      })) {
        if (event.type === "final") text = event.text;
      }
      sendEvent({
        id: randomUUID(),
        threadId: incoming.threadId,
        ts: Date.now(),
        agentId: "main",
        kind: "message",
        data: { role: "agent", text },
      });
    }

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
      if (event.kind !== "message" || event.data.role !== "user") return;
      answer(event).catch((e: unknown) => state(`agent-error ${String(e)}`));
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

  return {
    close: () =>
      new Promise<void>((done) => {
        stopped = true;
        if (retry) clearTimeout(retry);
        const ws = socket;
        if (!ws || ws.readyState === WebSocket.CLOSED) return done();
        ws.once("close", () => done());
        ws.close();
      }),
  };
}

if (import.meta.main) {
  // `probe` answers the Mac app's provider cards and exits; no argument serves.
  if (argv[2] === "probe") stdout.write(`${JSON.stringify(await probe())}\n`);
  else serve();
}

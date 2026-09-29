import { createHash, randomUUID } from "node:crypto";
import { execFileSync, spawn } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay, type Relay } from "@yorozu/relay";
import { connectPhone, keypair, rejoinPhone } from "@yorozu/relay/dist/testing.js";
import {
  decodeEnvelope,
  decodeNotificationPreview,
  decodeQrPayload,
  deriveChannelKeys,
  deriveSessionKey,
  encodeEnvelope,
  fromBase64Url,
  generateKeypair,
  helloProof,
  localPeerInfo,
  MAX_DEVICES,
  open,
  seal,
  threadRef,
  toBase64Url,
  type ApprovalCardData,
  type EventKind,
  type EventPayload,
  type QrPayload,
  type YorozuEvent,
} from "@yorozu/shared";
import { listRules, type AskResult, type Rule } from "./approval.js";
import type { AddressInfo } from "node:net";
import { createConnection, createServer } from "node:net";
import { networkInterfaces } from "node:os";
import { afterEach, expect, test, vi } from "vitest";
import { WebSocketServer } from "ws";
import { openaiCompat, type Message } from "./provider.js";
import { summaryFile } from "./summary.js";
import { ensureStateDir, loadChannelSeqs, loadDevices, loadKeys, parseFrameBody, serve as startSidecar, typedAnswer, type ServeOptions, type Sidecar } from "./serve.js";
import { claudeCodeRunner, type NativeAgentRunner, type NativeTurn, type QueryFn } from "./native.js";
import { codexNativeRunner, type CodexHandlers, type ConnectCodex } from "./codex-native.js";
import * as schedulerModule from "./scheduler.js";
import { localSocketPath } from "./local.js";
import { channelSocketPath, type HostFrame, type PluginFrame } from "./channel.js";
import { SYNC_PAGE_BYTES, setNativeTurn, setThreadSession, appendThreadEvent, createThread, eventsAfter, listThreads, readThreadEvents } from "./threads.js";
import { readTranscripts, transcriptDir } from "./transcripts.js";

/** No native helper here: a thread takes its first words unless a test brings its own titler. */
const serve = (options: ServeOptions): Sidecar =>
  startSidecar({ nativeRunners: {}, titler: async () => "", ...options });

let relay: Relay;
let sidecar: Sidecar;

/** The Mac's project folders, for every test here: one root with one folder a coding agent may open. */
const projectsRoot = mkdtempSync(join(tmpdir(), "yorozu-serve-projects-"));
mkdirSync(join(projectsRoot, "proj"));
process.env.YOROZU_PROJECTS_DIR = projectsRoot;
const proj = join(projectsRoot, "proj");

afterEach(async () => {
  await sidecar?.close();
  await relay?.close();
  vi.restoreAllMocks();
});

/** A one-turn chat completion, streamed the way the adapter expects it. */
const sse = (text: string) =>
  new Response(
    `data: ${JSON.stringify({ choices: [{ delta: { content: text }, finish_reason: "stop" }] })}\n\n` +
      "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );

const frameBody = (payload: string) => JSON.parse(Buffer.from(payload, "base64url").toString());

const encodeBody = (body: unknown) => toBase64Url(Buffer.from(JSON.stringify(body)));

/**
 * A first `hello`: both keys, and proof the phone read the QR — the Mac enrols nothing without
 * it, however well the relay signed the frame.
 */
const hello = (qr: QrPayload, pub: string, spub: string, secret = qr.secret!) =>
  encodeBody({ t: "hello", pub, spub, proof: helloProof(secret, pub, spub) });

/**
 * A phone's half of the live channel: seals under its `send` key with a running seq, opens the
 * Mac's boxes under `recv`. `box` is the encoded frame body, ready for `phone.frame`.
 */
function channelFor(priv: Uint8Array, macPub: Uint8Array) {
  const keys = deriveChannelKeys(priv, macPub, "device");
  let seq = 0;
  return {
    box(event: YorozuEvent): string {
      const sealed = seal(keys.send, encodeEnvelope(++seq, event));
      return encodeBody({ t: "box", n: toBase64Url(sealed.nonce), c: toBase64Url(sealed.ciphertext) });
    },
    /** Throws when the box is not ours. */
    envelope(body: { n: string; c: string }) {
      return decodeEnvelope(open(keys.recv, fromBase64Url(body.n), fromBase64Url(body.c)));
    },
    open(body: { n: string; c: string }): YorozuEvent {
      return this.envelope(body).event;
    },
  };
}
type PhoneChannel = ReturnType<typeof channelFor>;

async function nextModernEnvelope(
  client: { next: () => Promise<{ payload: string }> }, channel: PhoneChannel,
) {
  for (;;) {
    const body = frameBody((await client.next()).payload);
    try { return channel.envelope(body); }
    catch { /* Older-format box or another device's box. */ }
  }
}

/** The live wire format in public Mac/iOS 0.2.3: one key, plain events, no seq envelope. */
function legacyChannelFor(priv: Uint8Array, macPub: Uint8Array) {
  const key = deriveSessionKey(priv, macPub);
  return {
    box(event: YorozuEvent): string {
      const sealed = seal(key, Buffer.from(JSON.stringify(event)));
      return encodeBody({ t: "box", n: toBase64Url(sealed.nonce), c: toBase64Url(sealed.ciphertext) });
    },
    open(body: { n: string; c: string }): YorozuEvent {
      return JSON.parse(Buffer.from(open(key, fromBase64Url(body.n), fromBase64Url(body.c))).toString()) as YorozuEvent;
    },
  };
}

/**
 * The next event sealed for this phone that is not a receipt. Every command is receipted
 * before it is answered, and a test reading frames one at a time is after the answer.
 */
async function nextEvent(
  client: { next: () => Promise<{ payload: string }> },
  channel: PhoneChannel,
): Promise<YorozuEvent> {
  for (;;) {
    const event = (await nextModernEnvelope(client, channel)).event;
    if (event.kind !== "receipt") return event;
  }
}

test("a sealed message from a phone round-trips through the agent loop", async () => {
  relay = await startRelay(0);

  const lines: string[] = [];
  let qrLine!: (line: string) => void;
  const qrPrinted = new Promise<string>((resolve) => (qrLine = resolve));

  const fetchMock = vi.fn<typeof fetch>().mockImplementation(async () => sse("pong"));
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-serve-"));
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir,
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: fetchMock }),
    log: (line) => {
      lines.push(line);
      if (line.startsWith("QR ")) qrLine(line.slice(3));
    },
  });

  const qr = decodeQrPayload(await qrPrinted);
  expect(lines.filter((l) => l.startsWith("STATE "))).toEqual([
    "STATE connecting",
    "STATE connected",
    "STATE registered",
  ]);
  expect(qr.relayUrl).toBe(`ws://127.0.0.1:${relay.port}`);

  const { phone, keys } = await connectPhone(relay.port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });

  // The phone announces its X25519 key in the clear, then everything is sealed. Without proof
  // it read the QR the runtime enrols nothing: the relay signed that frame just as well.
  const phoneKeys = generateKeypair();
  const channel = channelFor(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(encodeBody({ t: "hello", pub: toBase64Url(phoneKeys.publicKey), spub: keys.pub }), keys);
  await vi.waitFor(() => expect(lines).toContain("STATE hello-refused"));
  phone.frame(hello(qr, toBase64Url(phoneKeys.publicKey), keys.pub, "not-the-secret"), keys);
  await vi.waitFor(() => expect(lines.filter((l) => l === "STATE hello-refused")).toHaveLength(2));
  expect(lines).not.toContain("STATE paired");
  phone.frame(hello(qr, toBase64Url(phoneKeys.publicKey), keys.pub), keys);
  await vi.waitFor(() => expect(lines).toContain("STATE paired"));

  const sent: YorozuEvent = {
    id: "e1",
    threadId: "t1",
    ts: Date.now(),
    agentId: "phone",
    kind: "message",
    data: { role: "user", text: "ping" },
  };
  const openNext = (): Promise<YorozuEvent> => nextEvent(phone, channel);

  // Pairing is greeted with the thread list — empty, on a state dir nothing has happened in —
  // and the agent's reply follows it.
  expect(await openNext()).toMatchObject({ kind: "thread_list", data: { threads: [] } });
  // And what a thread can be put on, so the phone's model picker has names. Empty here: the
  // provider is injected by the test, so there is no providers.json to publish.
  expect(await openNext()).toMatchObject({ kind: "model_list", data: { models: [] } });
  // And where a coding agent could be started: the test's own projects root, one folder in it.
  expect(await openNext()).toMatchObject({ kind: "project_list", data: { projects: [{ name: "proj" }] } });
  // Pairing changed who the devices are, so the new list follows it.
  expect(await openNext()).toMatchObject({ kind: "device_list" });
  phone.frame(channel.box({ id: "bad-name", threadId: "", ts: Date.now(), agentId: "phone", kind: "device_list",
    data: { devices: [], name: "bad\nname" } }), keys);
  expect(await openNext()).toMatchObject({ kind: "device_list", data: { devices: [expect.not.objectContaining({ name: "bad\nname" })] } });
  phone.frame(channel.box({ id: "device-name", threadId: "", ts: Date.now(), agentId: "phone", kind: "device_list",
    data: { devices: [], name: "iPadOS 27.0" } }), keys);
  expect(await openNext()).toMatchObject({ kind: "device_list", data: { devices: [expect.objectContaining({ name: "iPadOS 27.0" })] } });
  expect(loadDevices(join(stateDir, "devices.json"))[0]?.name).toBe("iPadOS 27.0");
  const box = channel.box(sent);
  phone.frame(box, keys);
  expect(await openNext()).toMatchObject({
    threadId: "t1",
    kind: "message",
    data: { role: "user", text: "ping" },
  });
  expect(await openNext()).toMatchObject({
    threadId: "t1",
    kind: "message",
    data: { role: "agent", text: "pong" },
  });
  expect(lines).toContain("STATE paired");
  expect(fetchMock.mock.calls[0]![0]).toBe("https://example.invalid/v1/chat/completions");

  // The same box again — a relay replaying an unacked frame, or anyone who captured it — is
  // caught by its seq before it is even read as a command.
  phone.frame(box, keys);
  await vi.waitFor(() => expect(lines).toContain("STATE replayed-frame"));
  // The same message under a fresh seq — a phone retrying a send it never saw land — is a
  // command, but not a second turn and not a second line in the thread.
  phone.frame(channel.box(sent), keys);
  await vi.waitFor(() => expect(lines).toContain("STATE duplicate-command"));
  expect(fetchMock).toHaveBeenCalledTimes(1);
  expect(readThreadEvents("t1", stateDir).filter((e) => e.id === "e1")).toHaveLength(1);

  // A box the Mac sealed, reflected back by the relay, opens under no device's key: it is
  // nobody's command, so nothing is receipted for it.
  let reflected!: { n: string; c: string };
  let reflectedId!: string;
  for (;;) {
    const body = frameBody((await phone.next()).payload);
    try { reflectedId = channel.open(body).id; reflected = body; break; }
    catch { /* Legacy box. */ }
  }
  phone.frame(encodeBody(reflected), keys);
  phone.frame(channel.box({ ...sent, id: "e2", data: { role: "user", text: "ping again" } }), keys);
  const receipts: string[] = [];
  for (;;) {
    const event = (await nextModernEnvelope(phone, channel)).event;
    if (event.kind === "receipt") receipts.push(event.data.eventId);
    if (event.kind === "message" && event.data.role === "agent" && event.data.done) break;
  }
  expect(receipts).toEqual(["e2"]);
  expect(reflectedId).not.toBe("e2");
  phone.frame(channel.box({ id: "query-e2", threadId: "t1", ts: Date.now(), agentId: "phone",
    kind: "admission_query", data: { eventId: "e2" } }), keys);
  for (;;) {
    const status = await nextEvent(phone, channel);
    if (status.kind !== "admission_status") continue;
    expect(status.data).toMatchObject({ eventId: "e2", status: "completed", requestId: "query-e2" });
    break;
  }

  // A phone says `hello` on every join. Saying it again resets no counter on either side: the
  // old box is still a replay, and the Mac's seqs carry on from where they were.
  phone.frame(channel.box({ ...sent, id: "e3", threadId: "", kind: "sync_request", data: { lastSeen: {} } } as YorozuEvent), keys);
  const before = (await nextModernEnvelope(phone, channel)).seq;
  phone.frame(hello(qr, toBase64Url(phoneKeys.publicKey), keys.pub), keys);
  await vi.waitFor(() => expect(lines.filter((l) => l === "STATE paired")).toHaveLength(2));
  expect(loadDevices(join(stateDir, "devices.json"))[0]?.name).toBe("iPadOS 27.0");
  expect((await nextModernEnvelope(phone, channel)).seq).toBeGreaterThan(before);
  phone.frame(box, keys);
  await vi.waitFor(() => expect(lines.filter((l) => l === "STATE replayed-frame")).toHaveLength(2));
});

test("public 0.2.3 phone syncs with current Mac runtime", async () => {
  relay = await startRelay(0);
  const qrs = qrQueue();
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-legacy-phone-"));
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir,
    appVersion: "0.3.0",
    computerName: () => "Legacy hidden Mac",
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => sse("pong")) }),
    log: (line) => { if (line.startsWith("QR ")) qrs.push(line.slice(3)); },
  });
  const qr = await qrs.next();
  const { phone, keys } = await connectPhone(relay.port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });
  const identity = generateKeypair();
  const channel = legacyChannelFor(identity.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(hello(qr, toBase64Url(identity.publicKey), keys.pub), keys);

  const next = async (attempts = 4): Promise<YorozuEvent> => {
    // Released client ignores boxes it cannot open. Bound attempts keep this test fast and red
    // if the Mac never sends its older wire format.
    for (let attempt = 0; attempt < attempts; attempt++) {
      try { return channel.open(frameBody((await phone.next()).payload)); }
      catch { /* New-format box belongs to another protocol. */ }
    }
    throw new Error("Mac sent no legacy greeting");
  };
  const greeting = await next();
  expect(greeting).toMatchObject({ kind: "thread_list", data: { threads: [] } });
  expect(greeting.data).toEqual({ threads: [] });
  expect(await next()).toMatchObject({ kind: "model_list" });
  expect(await next()).toMatchObject({ kind: "project_list", data: { projects: [{ name: "proj" }] } });
  expect(await next()).toMatchObject({ kind: "device_list" });
  phone.frame(channel.box({ id: "legacy-thread-list", threadId: "", ts: Date.now(),
    agentId: "phone", kind: "thread_list", data: { threads: [] } }), keys);
  expect(await next()).toMatchObject({ kind: "receipt", data: { eventId: "legacy-thread-list" } });
  const listed = await next();
  expect(listed).toMatchObject({ kind: "thread_list" });
  expect(listed.data).not.toHaveProperty("peerInfo");
  expect(await next()).toMatchObject({ kind: "project_list" });
  phone.frame(channel.box({ id: "legacy-device-list", threadId: "", ts: Date.now(),
    agentId: "phone", kind: "device_list", data: { devices: [] } }), keys);
  expect(await next()).toMatchObject({ kind: "receipt", data: { eventId: "legacy-device-list" } });
  expect(await next()).toMatchObject({ kind: "device_list" });
  phone.frame(channel.box({ id: "legacy-sync", threadId: "", ts: Date.now(),
    agentId: "phone", kind: "sync_request", data: { lastSeen: {} } }), keys);
  expect(await next()).toMatchObject({ kind: "receipt", data: { eventId: "legacy-sync" } });
  expect(await next()).toMatchObject({ kind: "sync_delta", data: { events: [] } });

  // A newer phone can share this Mac without changing the older one's format.
  const nextQr = await qrs.next();
  const modern = await connectPhone(relay.port, nextQr.roomId!, nextQr.token);
  expect(await modern.phone.next()).toMatchObject({ type: "joined" });
  const modernIdentity = generateKeypair();
  const modernChannel = channelFor(modernIdentity.privateKey, fromBase64Url(nextQr.macPubkey));
  modern.phone.frame(hello(nextQr, toBase64Url(modernIdentity.publicKey), modern.keys.pub), modern.keys);
  expect(await nextEvent(modern.phone, modernChannel)).toMatchObject({ kind: "thread_list" });
  expect(await nextEvent(modern.phone, modernChannel)).toMatchObject({ kind: "model_list" });
  expect(await nextEvent(modern.phone, modernChannel)).toMatchObject({ kind: "project_list" });
  expect(await nextEvent(modern.phone, modernChannel)).toMatchObject({ kind: "device_list" });
  expect(await next(16)).toMatchObject({ kind: "device_list" });
  modern.phone.frame(modernChannel.box({ id: "modern-device-list", threadId: "", ts: Date.now(),
    agentId: "phone", kind: "device_list", data: { devices: [] } }), modern.keys);
  expect(await nextEvent(modern.phone, modernChannel)).toMatchObject({ kind: "device_list" });
  const oldBoxForModern = legacyChannelFor(modernIdentity.privateKey, fromBase64Url(nextQr.macPubkey));
  modern.phone.frame(oldBoxForModern.box({ id: "downgrade", threadId: "downgrade-thread", ts: Date.now(),
    agentId: "phone", kind: "message", data: { role: "user", text: "replayed" } }), modern.keys);
  modern.phone.frame(modernChannel.box({ id: "after-downgrade", threadId: "", ts: Date.now(),
    agentId: "phone", kind: "device_list", data: { devices: [] } }), modern.keys);
  for (;;) {
    const event = (await nextModernEnvelope(modern.phone, modernChannel)).event;
    if (event.kind === "receipt" && event.data.eventId === "after-downgrade") break;
  }
  expect(readThreadEvents("downgrade-thread", stateDir)).toEqual([]);

  phone.frame(channel.box({ id: "old-phone-hi", threadId: "old-phone-thread", ts: Date.now(),
    agentId: "phone", kind: "message", data: { role: "user", text: "Hi" } }), keys);
  expect(await next(16)).toMatchObject({ kind: "receipt", data: { eventId: "old-phone-hi" } });
  expect(await next(16)).toMatchObject({ kind: "message", data: { role: "user", text: "Hi" } });
  expect(await next(16)).toMatchObject({ kind: "message", data: { role: "agent", text: "pong" } });
  for (;;) {
    const event = await nextEvent(modern.phone, modernChannel);
    if (event.kind === "message" && event.data.role === "user") {
      expect(event.data.text).toBe("Hi");
      break;
    }
  }
  expect(readThreadEvents("old-phone-thread", stateDir).some((event) => event.kind === "message" && event.data.text === "Hi")).toBe(true);
});

test("reflected legacy greetings cannot require negotiation, including after restart", async () => {
  relay = await startRelay(0);
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-legacy-reflection-"));
  const fetchMock = vi.fn<typeof fetch>().mockImplementation(async () => sse("pong"));
  const lines: string[] = [];
  const start = () => {
    let printed!: (qr: string) => void;
    const qr = new Promise<string>((resolve) => (printed = resolve));
    const cast = serve({
      relayUrl: `ws://127.0.0.1:${relay.port}`,
      stateDir,
      appVersion: "0.3.0",
      computerName: () => "Private Mac",
      provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: fetchMock }),
      log: (line) => {
        lines.push(line);
        if (line.startsWith("QR ")) printed(line.slice(3));
      },
    });
    return { cast, qr };
  };
  const first = start();
  sidecar = first.cast;
  const qr = decodeQrPayload(await first.qr);
  const joined = await connectPhone(relay.port, qr.roomId!, qr.token);
  let phone = joined.phone;
  const { keys } = joined;
  expect(await phone.next()).toMatchObject({ type: "joined" });
  const identity = generateKeypair();
  const channel = legacyChannelFor(identity.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(hello(qr, toBase64Url(identity.publicKey), keys.pub), keys);
  const next = async (): Promise<{ event: YorozuEvent; payload: string }> => {
    for (;;) {
      const { payload } = await phone.next();
      try { return { event: channel.open(frameBody(payload)), payload }; }
      catch { /* A released client cannot open the modern greeting. */ }
    }
  };
  const chat = async (id: string): Promise<void> => {
    phone.frame(channel.box({ id, threadId: id, ts: Date.now(), agentId: "phone",
      kind: "message", data: { role: "user", text: "ping" } }), keys);
    for (;;) {
      const { event } = await next();
      if (event.threadId === id && event.kind === "message" && event.data.role === "agent" && event.data.done) {
        expect(event.data.text).toBe("pong");
        return;
      }
    }
  };
  const greeting = await next();
  expect(greeting.event).toMatchObject({ kind: "thread_list" });
  expect(greeting.event.data).toEqual({ threads: [] });
  // Legacy uses the same key in both directions: replay the exact host ciphertext as input.
  phone.frame(greeting.payload, keys);
  await chat("after-reflection");
  expect(loadDevices(join(stateDir, "devices.json"))[0]).not.toHaveProperty("peerInfoRequired");

  // Hosts before this fix advertised support in legacy boxes. Reflecting one must also be harmless.
  phone.frame(channel.box({ id: "pre-fix-greeting", threadId: "", ts: Date.now(), agentId: "yorozu",
    kind: "thread_list", data: { threads: [], peerInfoSupported: true } }), keys);
  await chat("after-legacy-claim");
  expect(loadDevices(join(stateDir, "devices.json"))[0]).not.toHaveProperty("peerInfoRequired");
  expect(lines).not.toContain("STATE peer-update-required");

  phone.ws.close();
  await sidecar.close();
  const restarted = start();
  sidecar = restarted.cast;
  await restarted.qr;
  phone = await rejoinPhone(relay.port, qr.roomId!, keys);
  expect(await phone.next()).toMatchObject({ type: "joined" });
  await chat("after-restart");
  expect(fetchMock).toHaveBeenCalledTimes(3);
  expect(loadDevices(join(stateDir, "devices.json"))[0]).not.toHaveProperty("peerInfoRequired");
});

test.each([false, true])("a phone rejoins without hello and preserves a safe cutoff (legacy=%s)", async (legacy) => {
  relay = await startRelay(0);
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-rejoin-"));
  const fetchMock = vi.fn<typeof fetch>().mockImplementation(async () => sse("pong"));

  // Two sidecars in a row over one state dir: the second is the "restart".
  const lines: string[] = [];
  const start = () => {
    let qrLine!: (line: string) => void;
    const qr = new Promise<string>((resolve) => (qrLine = resolve));
    const cast = serve({
      relayUrl: `ws://127.0.0.1:${relay.port}`,
      stateDir,
      provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: fetchMock }),
      log: (line) => {
        lines.push(line);
        if (line.startsWith("QR ")) qrLine(line.slice(3));
      },
    });
    return { cast, qr };
  };

  const first = start();
  const qr = decodeQrPayload(await first.qr);
  const { phone, keys } = await connectPhone(relay.port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });

  const phoneKeys = generateKeypair();
  const channel = channelFor(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  const pub = toBase64Url(phoneKeys.publicKey);
  phone.frame(hello(qr, pub, keys.pub), keys);
  // The `hello` is what writes the phone into `devices.json`.
  await vi.waitFor(() =>
    expect(loadDevices(join(stateDir, "devices.json")).map((device) => device.pub)).toEqual([pub]),
  );
  // One exchange before the restart, so both counters have something to carry over.
  const early = channel.box({ id: "early", threadId: "", ts: Date.now(), agentId: "phone", kind: "sync_request", data: { lastSeen: {} } });
  phone.frame(early, keys);
  let lastMacSeq = 0;
  for (;;) {
    const envelope = await nextModernEnvelope(phone, channel);
    lastMacSeq = Math.max(lastMacSeq, envelope.seq);
    if (envelope.event.kind === "sync_delta") break;
  }
  // The send counter is written ahead of use: what is on file is past everything sent. The
  // counters have a file of their own; the pairing file carries none, and neither is left
  // with a temporary beside it once written.
  const stored = loadChannelSeqs(join(stateDir, "channel-seq.json"))![pub]!;
  expect(stored.sendSeq).toBeGreaterThanOrEqual(lastMacSeq);
  expect(stored.recvSeq).toBe(1);
  expect(loadDevices(join(stateDir, "devices.json"))[0]).not.toHaveProperty("sendSeq");
  expect(loadDevices(join(stateDir, "devices.json"))[0]).not.toHaveProperty("recvSeq");
  expect(readdirSync(stateDir).filter((name) => name.endsWith(".tmp"))).toEqual([]);

  phone.ws.close();
  await first.cast.close();
  const originalPairedAt = loadDevices(join(stateDir, "devices.json"))[0]!.pairedAt;
  // Legacy: one file from before the split, counters and all, and no counters file at all.
  if (legacy) {
    rmSync(join(stateDir, "channel-seq.json"));
    writeFileSync(join(stateDir, "devices.json"), JSON.stringify([{ pub, lastSeen: 1, sendSeq: stored.sendSeq, recvSeq: stored.recvSeq }]));
  }
  createThread("Old history", stateDir, "old-history");
  appendThreadEvent({ id: "old-message", threadId: "old-history", ts: 1, agentId: "phone", kind: "message", data: { role: "user", text: "before pairing" } }, stateDir);

  // A rejoin: the one-time token is long burnt, so the phone proves itself to the relay against
  // the connect nonce, and says no `hello` — the restarted sidecar has to know it from disk.
  const second = start();
  sidecar = second.cast;
  await second.qr;
  const again = await rejoinPhone(relay.port, qr.roomId!, keys);
  expect(await again.next()).toMatchObject({ type: "joined" });
  const restoredPairedAt = loadDevices(join(stateDir, "devices.json"))[0]!.pairedAt;
  expect(restoredPairedAt).toBeGreaterThan(1);
  if (!legacy) expect(restoredPairedAt).toBe(originalPairedAt);
  // Counters found only in the old file are moved to their own on start.
  expect(loadChannelSeqs(join(stateDir, "channel-seq.json"))).toEqual({ [pub]: stored });
  // Nothing from before the restart is taken again, and nothing after it reuses a seq.
  again.frame(early, keys);
  await vi.waitFor(() => expect(lines).toContain("STATE replayed-frame"));
  again.frame(channel.box({ id: "sync", threadId: "", ts: Date.now(), agentId: "phone", kind: "sync_request", data: { lastSeen: {} } }), keys);
  const receipt = await nextModernEnvelope(again, channel);
  expect(receipt.event.kind).toBe("receipt");
  expect(receipt.seq).toBeGreaterThan(lastMacSeq);
  expect(await nextEvent(again, channel)).toMatchObject({ kind: "sync_delta", data: { events: [] } });

  const sent: YorozuEvent = {
    id: "e2",
    threadId: "home",
    ts: Date.now(),
    agentId: "phone",
    kind: "message",
    data: { role: "user", text: "ping" },
  };
  again.frame(channel.box(sent), keys);

  expect(await nextEvent(again, channel)).toMatchObject({
    threadId: "home",
    kind: "message",
    data: { role: "user", text: "ping" },
  });
  expect(await nextEvent(again, channel)).toMatchObject({
    threadId: "home",
    kind: "message",
    data: { role: "agent", text: "pong" },
  });
});

/** A turn in which the model calls `shell`, which carries the `run-command` action class. */
const shellTurn = (cmd: string) =>
  new Response(
    `data: ${JSON.stringify({
      choices: [
        {
          delta: {
            tool_calls: [
              { index: 0, id: "call_1", function: { name: "shell", arguments: JSON.stringify({ cmd }) } },
            ],
          },
          finish_reason: "tool_calls",
        },
      ],
    })}\n\n` + "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );

/**
 * The card that ended an `eventsUntil` batch. The batch also holds what led up to it — the
 * `tool_call` the gate stopped, for one — so the card is the last event, not the first.
 */
function cardOf(events: YorozuEvent[]): ApprovalCardData {
  const last = events.at(-1);
  if (last?.kind !== "approval_card") throw new Error(`expected a card, got ${last?.kind}`);
  return last.data;
}

/** A turn in which the model messages a person, which is `send-message`: never quick. */
const sendMessageTurn = (to: string) =>
  new Response(
    `data: ${JSON.stringify({
      choices: [
        {
          delta: {
            tool_calls: [
              { index: 0, id: "call_1", function: { name: "mail_send", arguments: JSON.stringify({ to, subject: "hi", body: "hi" }) } },
            ],
          },
          finish_reason: "tool_calls",
        },
      ],
    })}\n\n` + "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );

/** Every `STATE` the sidecar under `pairedPhone` logged. */
let states: string[] = [];
/** Sends an event exactly as given, id included, so a replay can be the same event twice. */
let sendRaw: (event: YorozuEvent) => void = () => {};

/** A paired phone plus the session key, so a test can talk sealed events both ways. */
async function pairedPhone(responses: (() => Response)[], openclaw = false, extra: Partial<ServeOptions> = {},
  negotiate = false) {
  relay = await startRelay(0);
  const dir = extra.stateDir ?? mkdtempSync(join(tmpdir(), "yorozu-approval-serve-"));
  states = [];

  let qrLine!: (line: string) => void;
  const qrPrinted = new Promise<string>((resolve) => (qrLine = resolve));
  const queue = [...responses];

  sidecar = serve({
    ...extra,
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: dir,
    provider: openclaw ? undefined : openaiCompat({
      baseUrl: "https://example.invalid",
      model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => queue.shift()!()),
    }),
    log: (line) => {
      if (line.startsWith("QR ")) qrLine(line.slice(3));
      if (line.startsWith("STATE ")) states.push(line.slice(6));
    },
  });

  const qr = decodeQrPayload(await qrPrinted);
  const { phone, keys } = await connectPhone(relay.port, qr.roomId!, qr.token);
  await phone.next();

  const phoneKeys = generateKeypair();
  const channel = channelFor(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(hello(qr, toBase64Url(phoneKeys.publicKey), keys.pub), keys);

  sendRaw = (full: YorozuEvent): void => phone.frame(channel.box(full), keys);
  /** The same encoded frame body can be sent twice: what a replaying relay does. */
  const frame = (body: string): void => phone.frame(body, keys);
  const send = (
    event: Omit<YorozuEvent, "id" | "threadId" | "ts" | "agentId">,
    threadId = "t1",
  ): string => {
    const id = randomUUID();
    sendRaw({ id, threadId, ts: Date.now(), agentId: "phone", ...event } as YorozuEvent);
    return id;
  };

  /** Everything the sidecar sends, up to and including the first event `done` accepts. */
  async function eventsUntil(done: (event: YorozuEvent) => boolean): Promise<YorozuEvent[]> {
    const seen: YorozuEvent[] = [];
    for (;;) {
      const event = (await nextModernEnvelope(phone, channel)).event;
      seen.push(event);
      if (done(event)) return seen;
    }
  }

  const isReply = (event: YorozuEvent): boolean =>
    event.kind === "message" && event.data.role === "agent";

  if (negotiate) {
    const id = send({ kind: "thread_list", data: { threads: [], peerInfo: localPeerInfo("test") } }, "");
    await eventsUntil((event) => event.kind === "thread_list" && event.data.peerInfoReplyTo === id);
  }

  return { dir, send, eventsUntil, isReply, channel, frame, pub: toBase64Url(phoneKeys.publicKey), keys, qr };
}

test("a box whose seq cannot be recorded is not acted on, and is taken when it comes again", async () => {
  const { dir, eventsUntil, channel, frame, pub } = await pairedPhone([]);
  const seqFile = join(dir, "channel-seq.json");
  // The greeting ends with everyone's device list, and is what tells us the `hello` has been
  // written; wait for it before breaking the file.
  await eventsUntil((event) => event.kind === "device_list");
  // A directory where the file goes: the next write of `channel-seq.json` throws.
  rmSync(seqFile, { force: true });
  mkdirSync(seqFile);
  const request: YorozuEvent = { id: "sync-1", threadId: "", ts: Date.now(), agentId: "phone", kind: "sync_request", data: { lastSeen: {} } };
  const box = channel.box(request);
  frame(box);
  await vi.waitFor(() => expect(states.some((state) => state.startsWith("frame-error"))).toBe(true));
  // Not acted on: no receipt went out for it.
  expect(states).not.toContain("replayed-frame");

  // With the file writable again, the same box — a relay replaying what was never acked — is
  // not a replay: the seq the failed write would have recorded was put back.
  rmSync(seqFile, { recursive: true });
  // The failed move took its temporary with it.
  expect(existsSync(`${seqFile}.tmp`)).toBe(false);
  frame(box);
  const answered = await eventsUntil((event) => event.kind === "sync_delta");
  expect(answered.map((event) => event.kind)).toEqual(["receipt", "sync_delta"]);
  expect(states).not.toContain("replayed-frame");
  expect(loadChannelSeqs(seqFile)![pub]!.recvSeq).toBe(1);
  // And now that it has been recorded, it is one.
  frame(box);
  await vi.waitFor(() => expect(states).toContain("replayed-frame"));
});

/**
 * The Mac app on the local socket: the user's own machine, which needs no key and is trusted
 * with what a phone may only ask for. Keeps everything it hears.
 */
async function macClient(dir: string) {
  const socket = createConnection(localSocketPath(dir));
  const events: YorozuEvent[] = [];
  let buffer = "";
  socket.setEncoding("utf8");
  socket.on("data", (chunk: string) => {
    buffer += chunk;
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    for (const line of lines) if (line) events.push(JSON.parse(line));
  });
  await new Promise<void>((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
  const send = (event: Omit<YorozuEvent, "id" | "threadId" | "ts" | "agentId">): string => {
    const id = randomUUID();
    socket.write(`${JSON.stringify({ id, threadId: "", ts: Date.now(), agentId: "mac", ...event })}\n`);
    return id;
  };
  const settings = (): YorozuEvent[] => events.filter((event) => event.kind === "approval_settings");
  const sendRawEvent = (event: YorozuEvent): void => { socket.write(`${JSON.stringify(event)}\n`); };
  return { events, settings, send, sendRawEvent, close: () => socket.destroy() };
}

const HOUR_MS = 3_600_000;

test("queued updates wait for approvals and queued turns, prioritize new work, and fence replay at install", async () => {
  const run = vi.fn<NativeAgentRunner["run"]>(async (turn) => {
    if (turn.text === "approval") await turn.approve!("Bash", { command: "echo done" }, turn.signal);
    if (turn.text === "failure") throw new Error("final failure");
    return { text: "done", sessionId: "session" };
  });
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: { run } } });
  let mac = await macClient(dir);
  const stranger = await macClient(dir);
  send({ kind: "update_control", data: { action: "status" } });
  let now = Date.now();
  vi.spyOn(Date, "now").mockImplementation(() => now);
  async function control(action: "queue" | "poll" | "cancel" = "poll") {
    const requestId = mac.send({ kind: "update_control", data: { action, updateId: "u1", version: "1.0" } });
    await vi.waitFor(() => expect(mac.events.some((event) => event.kind === "update_status" && event.data.requestId === requestId)).toBe(true));
    const event = mac.events.find((event) => event.kind === "update_status" && event.data.requestId === requestId)!;
    if (event.kind !== "update_status") throw new Error("missing status");
    return event.data;
  }
  try {
    send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "work");
    send({ kind: "message", data: { role: "user", text: "approval" } }, "work");
    const card = (await eventsUntil((event) => event.kind === "approval_card")).at(-1)!;
    if (card.kind !== "approval_card") throw new Error("missing approval");
    expect(await control("queue")).toMatchObject({ phase: "waiting", activeThreads: 1 });
    now += 86_399_000;
    expect((await control()).phase).toBe("waiting");
    send({ kind: "message", data: { role: "user", text: "failure" } }, "work");
    send({ kind: "message", data: { role: "user", text: "after failure" } }, "work");
    send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "other");
    send({ kind: "message", data: { role: "user", text: "new task" } }, "other");
    await eventsUntil((event) => event.kind === "message" && event.data.done === true && event.threadId === "other");
    expect((await control()).phase).toBe("waiting");
    send({ kind: "approval_answer", data: { actionId: card.data.actionId, answer: "yes" } }, "work");
    await vi.waitFor(() => expect(run).toHaveBeenCalledTimes(4));
    expect((await control()).phase).toBe("countdown");
    for (let second = 0; second < 9; second++) { now += 1_000; expect((await control()).phase).toBe("countdown"); }
    send({ kind: "message", data: { role: "user", text: "last second" } }, "other");
    await vi.waitFor(() => expect(run).toHaveBeenCalledTimes(5));
    now += 1_000;
    expect((await control()).deadline).toBe(now + 10_000);
    stranger.send({ kind: "update_control", data: { action: "cancel", updateId: "u1" } });
    send({ kind: "update_control", data: { action: "cancel", updateId: "u1" } });
    expect((await control()).phase).toBe("countdown");
    for (let second = 0; second < 10; second++) { now += 1_000; await control(); }
    expect((await control()).phase).toBe("installing");
    mac.close();
    mac = await macClient(dir);
    expect((await control("queue")).phase).toBe("installing");
    const late: YorozuEvent = { id: "late-message", threadId: "other", ts: now, agentId: "phone",
      kind: "message", data: { role: "user", text: "after cutoff" } };
    sendRaw(late);
    send({ kind: "update_control", data: { action: "status" } });
    await eventsUntil((event) => event.kind === "update_status" && event.data.requestId !== undefined && event.data.phase === "installing");
    expect(readThreadEvents("other", dir).some((event) => event.id === late.id)).toBe(false);
    expect(run).toHaveBeenCalledTimes(5);
    const archive: YorozuEvent = { id: "late-archive", threadId: "other", ts: now, agentId: "phone",
      kind: "thread_archive", data: { archived: true } };
    sendRaw(archive);
    send({ kind: "update_control", data: { action: "status" } });
    await eventsUntil((event) => event.kind === "update_status" && event.data.requestId !== undefined && event.data.phase === "installing");
    expect(listThreads(dir).find((thread) => thread.id === "other")?.archived).toBe(false);
    mac.close();
    mac = await macClient(dir);
    expect((await control("cancel")).phase).toBe("none");
    sendRaw(late);
    await vi.waitFor(() => expect(run).toHaveBeenCalledTimes(6));
    sendRaw(late);
    await vi.waitFor(() => expect(states).toContain("duplicate-command"));
    expect(run).toHaveBeenCalledTimes(6);
    expect(readThreadEvents("other", dir).filter((event) => event.id === late.id)).toHaveLength(1);
    sendRaw(archive);
    await vi.waitFor(() => expect(listThreads(dir).find((thread) => thread.id === "other")?.archived).toBe(true));
  } finally { mac.close(); stranger.close(); }
});

test("phone postponement persists and losing the update controller releases admission", async () => {
  const { dir, send, eventsUntil } = await pairedPhone([]);
  const mac = await macClient(dir);
  send({ kind: "update_control", data: { action: "status" } });
  mac.send({ kind: "update_control", data: { action: "queue", updateId: "u2", version: "1.0" } });
  await eventsUntil((event) => event.kind === "update_status" && event.data.phase === "countdown");
  send({ kind: "update_control", data: { action: "postpone" } });
  const postponed = (await eventsUntil((event) => event.kind === "update_status" && event.data.phase === "postponed")).at(-1)!;
  if (postponed.kind !== "update_status") throw new Error("missing status");
  expect(JSON.parse(readFileSync(join(dir, "update-postponed-until.json"), "utf8"))).toBe(postponed.data.postponedUntil);
  mac.close();
  await eventsUntil((event) => event.kind === "update_status" && event.data.phase === "none");
  expect(JSON.parse(readFileSync(join(dir, "update-pending-since.json"), "utf8"))).toBeNull();
  const reconnected = await macClient(dir);
  reconnected.send({ kind: "update_control", data: { action: "queue", updateId: "u2", version: "1.0" } });
  expect((await eventsUntil((event) => event.kind === "update_status" && event.data.phase === "postponed")).at(-1))
    .toMatchObject({ data: { postponedUntil: postponed.data.postponedUntil } });
  const pendingBeforeRestart = JSON.parse(readFileSync(join(dir, "update-pending-since.json"), "utf8"));
  await sidecar.close();
  expect(JSON.parse(readFileSync(join(dir, "update-pending-since.json"), "utf8"))).toEqual(pendingBeforeRestart);
  reconnected.close();
});

test("losing the updater during drain resumes a paused native turn", async () => {
  const run = vi.fn<NativeAgentRunner["run"]>(async (turn) => {
    if (turn.text.includes("Resume the interrupted")) return { text: "recovered", sessionId: "session" };
    await turn.approve!("Bash", { command: "echo safe" }, turn.signal);
    return { text: "original", sessionId: "session" };
  });
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: { run } } });
  const mac = await macClient(dir);
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "disconnect-drain");
  const eventId = send({ kind: "message", data: { role: "user", text: "do work" } }, "disconnect-drain");
  await eventsUntil((event) => event.kind === "approval_card" && event.threadId === "disconnect-drain");
  let now = Date.now();
  vi.spyOn(Date, "now").mockImplementation(() => now);
  const control = async (action: "queue" | "poll") => {
    const id = mac.send({ kind: "update_control", data: { action, updateId: "lost-updater", version: "1.0" } });
    await vi.waitFor(() => expect(mac.events.some((event) => event.kind === "update_status" && event.data.requestId === id)).toBe(true));
  };
  await control("queue");
  now += 86_400_000;
  await control("poll");
  await vi.waitFor(() => expect(listThreads(dir).find((thread) => thread.id === "disconnect-drain")?.nativeTurn?.state).toBe("interrupted"));
  mac.close();
  await eventsUntil((event) => event.kind === "message" && event.id === `native:${eventId}:final` && event.data.done === true);
  expect(run).toHaveBeenCalledTimes(2);
  expect(listThreads(dir).find((thread) => thread.id === "disconnect-drain")?.nativeTurn).toBeUndefined();
});

test("24-hour drain interrupts a native approval safely and resumes after sidecar restart", async () => {
  const run = vi.fn<NativeAgentRunner["run"]>(async (turn) => {
    if (turn.text.includes("Resume the interrupted")) return { text: "recovered", sessionId: "session" };
    turn.onActivity?.("call:tool", { kind: "tool_call", data: { callId: "tool", name: "Bash", args: {} } });
    await turn.approve!("Bash", { command: "echo safe" }, turn.signal);
    return { text: "original", sessionId: "session" };
  });
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: { run } } });
  const mac = await macClient(dir);
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "drain");
  const eventId = send({ kind: "message", data: { role: "user", text: "do work" } }, "drain");
  await eventsUntil((event) => event.kind === "approval_card" && event.threadId === "drain");
  const queuedId = send({ kind: "message", data: { role: "user", text: "after drain" } }, "drain");
  await vi.waitFor(() => expect(JSON.parse(readFileSync(join(dir, "native-turn-queue.json"), "utf8")))
    .toContainEqual({ threadId: "drain", eventId: queuedId }));
  let now = Date.now();
  vi.spyOn(Date, "now").mockImplementation(() => now);
  const status = async (action: "queue" | "poll") => {
    const id = mac.send({ kind: "update_control", data: { action, updateId: "u-drain", version: "1.0" } });
    await vi.waitFor(() => expect(mac.events.some((event) => event.kind === "update_status" && event.data.requestId === id)).toBe(true));
    const event = mac.events.find((event) => event.kind === "update_status" && event.data.requestId === id)!;
    if (event.kind !== "update_status") throw new Error("missing status");
    return event.data;
  };
  expect((await status("queue")).phase).toBe("waiting");
  now += 86_400_000;
  expect((await status("poll")).phase).toBe("draining");
  const oldClientStatus = send({ kind: "update_control", data: { action: "status" } });
  const oldClientReply = (await eventsUntil((event) => event.kind === "update_status" &&
    event.data.requestId === oldClientStatus)).at(-1)!;
  expect(oldClientReply).toMatchObject({ data: { phase: "waiting" } });
  await vi.waitFor(() => expect(listThreads(dir).find((thread) => thread.id === "drain")?.nativeTurn?.state).toBe("interrupted"));
  expect((await status("poll")).phase).toBe("installing");
  expect(run).toHaveBeenCalledTimes(1);
  expect(JSON.parse(readFileSync(join(dir, "native-turn-queue.json"), "utf8")))
    .toEqual([{ threadId: "drain", eventId }, { threadId: "drain", eventId: queuedId }]);
  await sidecar.close();
  mac.close();
  await relay.close();
  vi.restoreAllMocks();
  const resumed = vi.fn<NativeAgentRunner["run"]>(async (turn) => ({ text: turn.text.includes("after drain") ? "queued" : "recovered", sessionId: "session" }));
  await pairedPhone([], false, { stateDir: dir, nativeRunners: { codex: { run: resumed } } });
  await vi.waitFor(() => expect(readThreadEvents("drain", dir).some((event) =>
    event.id === `native:${eventId}:final` && event.kind === "message" && event.data.done)).toBe(true));
  await vi.waitFor(() => expect(readThreadEvents("drain", dir).some((event) =>
    event.id === `native:${queuedId}:final` && event.kind === "message" && event.data.done)).toBe(true));
  expect(resumed).toHaveBeenCalledTimes(2);
  expect(JSON.parse(readFileSync(join(dir, "native-turn-queue.json"), "utf8"))).toEqual([]);
});

test("retry repairs a logged native message after queue persistence fails", async () => {
  const run = vi.fn<NativeAgentRunner["run"]>(async () => ({ text: "done", sessionId: "session" }));
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: { run } } });
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "retry-queue");
  const blocker = join(dir, "native-turn-queue.json.tmp");
  mkdirSync(blocker);
  const event: YorozuEvent = { id: "queue-retry", threadId: "retry-queue", ts: Date.now(), agentId: "phone",
    kind: "message", data: { role: "user", text: "once" } };
  sendRaw(event);
  await vi.waitFor(() => expect(readThreadEvents("retry-queue", dir).some((known) => known.id === event.id)).toBe(true));
  expect(run).not.toHaveBeenCalled();
  rmSync(blocker, { recursive: true });
  sendRaw(event);
  await eventsUntil((reply) => reply.kind === "message" && reply.id === `native:${event.id}:final` && reply.data.done === true);
  expect(run).toHaveBeenCalledTimes(1);
  expect(readThreadEvents("retry-queue", dir).filter((known) => known.id === event.id)).toHaveLength(1);
  expect(JSON.parse(readFileSync(join(dir, "native-turn-queue.json"), "utf8"))).toEqual([]);
});

test("skill lists refresh on join after ten minutes and broadcast only changes", async () => {
  const realNow = Date.now.bind(Date);
  let elapsed = 0;
  vi.spyOn(Date, "now").mockImplementation(() => realNow() + elapsed);
  let unavailable = false;
  let catalog = [
    { name: "plugin:Shape", description: "x".repeat(250), argumentHint: "y".repeat(100), path: "/host/shape/SKILL.md" },
    { name: "n".repeat(129), description: "Long name", path: "/host/long/SKILL.md" },
    { name: "plugin:Shape", description: "Another source", path: "/host/duplicate/SKILL.md" },
  ];
  const skills = vi.fn(async () => {
    if (unavailable) throw new Error("catalog unavailable");
    return catalog;
  });
  const { dir } = await pairedPhone([], false, { nativeRunners: {
    codex: { run: async () => ({ text: "done" }), skills },
    "claude-code": { run: async () => ({ text: "done" }), skills: async () => [] },
  } });
  const first = await macClient(dir);
  await vi.waitFor(() => expect(first.events.some((event) => event.kind === "model_list" &&
    event.data.skills?.codex?.[0]?.name === "plugin:Shape")).toBe(true));
  const listed = first.events.findLast((event) => event.kind === "model_list");
  if (listed?.kind !== "model_list") throw new Error("missing skill list");
  expect(listed.data.skills?.codex).toEqual([
    { name: "plugin:Shape", description: "x".repeat(200), argumentHint: "y".repeat(80) },
    { name: "n".repeat(129), description: "Long name" },
  ]);
  expect(listed.data.skills?.["claude-code"]).toEqual([]);
  expect(JSON.stringify(listed)).not.toContain("/host/shape/SKILL.md");
  expect(skills).toHaveBeenCalledTimes(1);
  catalog = [{ name: "new", description: "New", argumentHint: "", path: "/host/new/SKILL.md" }];
  const second = await macClient(dir);
  await vi.waitFor(() => expect(second.events.some((event) => event.kind === "model_list")).toBe(true));
  expect(skills).toHaveBeenCalledTimes(1);
  const before = first.events.filter((event) => event.kind === "model_list").length;
  elapsed += 600_001;
  const third = await macClient(dir);
  await vi.waitFor(() => expect(skills).toHaveBeenCalledTimes(2));
  await vi.waitFor(() => expect(first.events.filter((event) => event.kind === "model_list").length).toBe(before + 1));
  expect(first.events.findLast((event) => event.kind === "model_list")).toMatchObject({ data: { skills: { codex: [{ name: "new" }] } } });
  const after = first.events.filter((event) => event.kind === "model_list").length;
  elapsed += 600_001;
  const fourth = await macClient(dir);
  await vi.waitFor(() => expect(skills).toHaveBeenCalledTimes(3));
  expect(first.events.filter((event) => event.kind === "model_list")).toHaveLength(after);
  unavailable = true;
  elapsed += 600_001;
  const fifth = await macClient(dir);
  await vi.waitFor(() => expect(skills).toHaveBeenCalledTimes(4));
  await vi.waitFor(() => expect(first.events.filter((event) => event.kind === "model_list")).toHaveLength(after + 1));
  await vi.waitFor(() => expect(fifth.events.findLast((event) => event.kind === "model_list"))
    .toMatchObject({ data: { skills: { codex: [], "claude-code": [] } } }));
  unavailable = false;
  catalog = [{ name: "recovered", description: "Recovered", path: "/host/recovered/SKILL.md" }];
  const sixth = await macClient(dir);
  await vi.waitFor(() => expect(sixth.events.some((event) => event.kind === "model_list")).toBe(true));
  expect(skills).toHaveBeenCalledTimes(4);
  elapsed += 600_001;
  const seventh = await macClient(dir);
  await vi.waitFor(() => expect(skills).toHaveBeenCalledTimes(5));
  await vi.waitFor(() => expect(first.events.findLast((event) => event.kind === "model_list"))
    .toMatchObject({ data: { skills: { codex: [{ name: "recovered" }] } } }));
  first.close(); second.close(); third.close(); fourth.close(); fifth.close(); sixth.close(); seventh.close();
});

test("Codex translates only a leading known slash skill using the host path", async () => {
  const run = vi.fn<NativeAgentRunner["run"]>(async () => ({ text: "done", sessionId: "session" }));
  const { send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: { run, skills: async () => [
    { name: "Grill", description: "Questions", path: "/host/grill/SKILL.md" },
    { name: "plugin:Shape", description: "Shape", path: "/host/shape/SKILL.md" },
    { name: "plugin:Shape", description: "Shadowed", path: "/host/shadow/SKILL.md" },
    { name: "plugin/inner", description: "Nested", path: "/host/inner/SKILL.md" },
  ] } } });
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "skill-turn");
  for (const text of ["/Grill topic", "/unknown topic", "say /Grill topic", "/plugin:Shape more", "/plugin/inner next"]) {
    send({ kind: "message", data: { role: "user", text } }, "skill-turn");
    await eventsUntil((event) => event.kind === "message" && event.threadId === "skill-turn" && event.data.done === true);
  }
  expect(run.mock.calls.map(([turn]) => ({ text: turn.text, skill: turn.skill }))).toEqual([
    { text: "topic", skill: { name: "Grill", path: "/host/grill/SKILL.md" } },
    { text: "/unknown topic", skill: undefined },
    { text: "say /Grill topic", skill: undefined },
    { text: "more", skill: { name: "plugin:Shape", path: "/host/shape/SKILL.md" } },
    { text: "next", skill: { name: "plugin/inner", path: "/host/inner/SKILL.md" } },
  ]);
});

test("startup stops a journaled orphan before native recovery can run", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-orphan-recovery-"));
  const orphan = spawn("/bin/sleep", ["30"], { stdio: "ignore" });
  if (!orphan.pid) throw new Error("sleep did not start");
  const exited = new Promise<void>((resolve) => orphan.once("exit", () => resolve()));
  const startedAt = execFileSync("/bin/ps", ["-p", String(orphan.pid), "-o", "lstart="], { encoding: "utf8" }).trim();
  writeFileSync(join(dir, "native-agent-processes.json"), JSON.stringify([
    { pid: orphan.pid, startedAt, commandLine: "/bin/sleep 30" },
  ]));
  try {
    await pairedPhone([], false, { stateDir: dir });
    await exited;
    expect(orphan.signalCode).toBe("SIGTERM");
    expect(JSON.parse(readFileSync(join(dir, "native-agent-processes.json"), "utf8"))).toEqual([]);
  } finally { if (orphan.exitCode === null && orphan.signalCode === null) orphan.kill("SIGKILL"); }
});

test("native recovery awaiting Continue or Dismiss blocks a queued update", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-update-recovery-"));
  createThread("Work", dir, "native-recovery", { agent: "codex", cwd: proj });
  setNativeTurn("native-recovery", { id: "interrupted", state: "running" }, dir);
  const { send, eventsUntil } = await pairedPhone([], false, { stateDir: dir });
  const mac = await macClient(dir);
  send({ kind: "update_control", data: { action: "status" } });
  mac.send({ kind: "update_control", data: { action: "queue", updateId: "u4", version: "1.0" } });
  const waiting = (await eventsUntil((event) => event.kind === "update_status" && event.data.phase === "waiting")).at(-1);
  expect(waiting).toMatchObject({ data: { activeThreads: 1 } });
  send({ kind: "thread_recover", data: { turnId: "interrupted", action: "dismiss" } }, "native-recovery");
  await eventsUntil((event) => event.kind === "thread_list" && !event.data.threads.find((thread) => thread.id === "native-recovery")?.interruptedTurnId);
  mac.send({ kind: "update_control", data: { action: "poll", updateId: "u4" } });
  await eventsUntil((event) => event.kind === "update_status" && event.data.phase === "countdown");
  mac.close();
});
const approvalFile = (dir: string): { yolo?: boolean; yoloUntil?: number } =>
  JSON.parse(readFileSync(join(dir, "approval.json"), "utf8"));

test("a thread is answered by the agent it was created for, and an unknown agent is refused", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-removed-agent-"));
  createThread("Old coding thread", dir, "cc", { agent: "claude-code", cwd: proj });
  const { send, eventsUntil } = await pairedPhone([], true, { stateDir: dir, nativeRunners: { codex: { run: vi.fn() } } });

  // Nobody answers a thread for an agent that does not exist, and no thread is made for it.
  const badCreateId = send({ kind: "thread_create", data: { agent: "hermes" } }, "bad");
  const refusal = await eventsUntil((event) => event.kind === "thought");
  const refused = refusal.at(-1)!;
  expect(refused).toMatchObject({ threadId: "bad", data: { text: expect.stringMatching(/unregistered agent "hermes"/) } });
  const rejected = refusal.find((event) => event.kind === "admission_status" && event.data.eventId === badCreateId);
  expect(rejected).toMatchObject({ data: { eventId: badCreateId, status: "rejected",
    reason: expect.stringMatching(/unregistered agent "hermes"/) } });
  expect(refusal.some((event) => event.kind === "receipt" && event.data.eventId === badCreateId)).toBe(false);
  const now = Date.now();
  sendRaw({ id: "bad-first-message", threadId: "bad", ts: now, agentId: "phone", kind: "message",
    data: { role: "user", text: "run on Hermes", admissionDeadline: now + 30 * 60_000 } });
  const missingThread = (await eventsUntil((event) => event.kind === "admission_status" &&
    event.data.eventId === "bad-first-message")).at(-1)!;
  expect(missingThread).toMatchObject({ data: { status: "rejected", reason: "thread-not-created" } });
  expect(readThreadEvents("bad", dir)).toEqual([]);
  expect(listThreads(dir).map((thread) => thread.id)).toEqual(["cc"]);
  expect(states).toContain('thread-create-error unregistered agent "hermes"');
  // Nor is a folder the picker never offered: a path typed into a frame is not a folder this
  // Mac agreed to open an agent in.
  send({ kind: "thread_create", data: { agent: "codex", cwd: "/etc" } }, "bad2");
  const refusedFolder = (await eventsUntil((event) => event.kind === "thought")).at(-1)!;
  expect(refusedFolder).toMatchObject({ threadId: "bad2", data: { text: expect.stringMatching(/not one of this Mac's project folders/) } });
  expect(listThreads(dir).map((thread) => thread.id)).toEqual(["cc"]);
  // Nor no folder at all: an agent with nowhere to run would run where the sidecar does.
  for (const [id, cwd] of [["bad3", undefined], ["bad4", "  "]] as const) {
    send({ kind: "thread_create", data: { agent: "codex", ...(cwd ? { cwd } : {}) } }, id);
    const refusedHomeless = (await eventsUntil((event) => event.kind === "thought")).at(-1)!;
    expect(refusedHomeless).toMatchObject({ threadId: id, data: { text: expect.stringMatching(/a codex thread needs a project folder/) } });
  }
  expect(listThreads(dir).map((thread) => thread.id)).toEqual(["cc"]);
  expect(states).toContain("thread-create-error a codex thread needs a project folder");

  // The list carries who answers each thread; a plain thread says nothing, as it always has.
  send({ kind: "thread_create", data: {} }, "t1");
  const threads = (await eventsUntil((event) =>
    event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "t1"),
  )).at(-1)! as YorozuEvent & { kind: "thread_list" };
  expect(threads.data.threads.find((thread) => thread.id === "cc")).toMatchObject({ agent: "claude-code", cwd: proj });
  expect(threads.data.threads.find((thread) => thread.id === "t1")).not.toHaveProperty("agent");

  // A turn in the native thread never reaches OpenClaw: its own backend answers, and where no
  // runner is wired the answer is that it is not, finished, so the composer is not left waiting.
  const ccMessageId = send({ kind: "message", data: { role: "user", text: "fix the tests" } }, "cc");
  const reply = (await eventsUntil((event) => event.kind === "message" && event.data.done === true)).at(-1)!;
  expect(reply).toMatchObject({ threadId: "cc", data: { role: "agent", text: expect.stringMatching(/claude-code.*no longer registered/i) } });
  expect(readThreadEvents("cc", dir).map((event) => event.kind)).toEqual(["message", "message"]);

  // Stop, archive, model and effort all go to the thread's own agent too: none of them is
  // OpenClaw's business here.
  send({ kind: "interrupt", data: { targetEventId: ccMessageId } }, "cc");
  await eventsUntil((event) => event.kind === "stop_status" && event.data.targetEventId === ccMessageId);
  send({ kind: "thread_set_model", data: { model: "claude/claude-opus-5" } }, "cc");
  send({ kind: "thread_set_effort", data: { effort: "high" } }, "cc");
  send({ kind: "thread_archive", data: { archived: true } }, "cc");
  const archived = (await eventsUntil((event) =>
    event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "cc" && thread.archived),
  )).at(-1)! as YorozuEvent & { kind: "thread_list" };
  // A provider spec is not a native SDK model; unavailable agents publish no effort choices.
  expect(archived.data.threads.find((thread) => thread.id === "cc")?.model).toBeUndefined();
  expect(archived.data.threads.find((thread) => thread.id === "cc")?.effort).toBeUndefined();
  expect(existsSync(join(dir, "channel-outbox.json"))).toBe(false);

  // While the plain thread still goes to OpenClaw's channel.
  send({ kind: "message", data: { role: "user", text: "hello" } }, "t1");
  await vi.waitFor(() => expect(JSON.parse(readFileSync(join(dir, "channel-outbox.json"), "utf8")))
    .toMatchObject([{ threadId: "t1", text: "hello" }]));
});

test("thread creation gets no receipt when storage fails, then accepts the same ID on retry", async () => {
  const { dir, eventsUntil } = await pairedPhone([]);
  const blocked = join(dir, "threads.json.tmp");
  const create: YorozuEvent = { id: "create-retry", threadId: "disk", ts: Date.now(), agentId: "phone",
    kind: "thread_create", data: {} };
  mkdirSync(blocked);
  try {
    sendRaw(create);
    const failed = await eventsUntil((event) => event.kind === "thought" && event.threadId === "disk");
    expect(failed.some((event) => event.kind === "receipt" && event.data.eventId === create.id)).toBe(false);
    expect(failed.some((event) => event.kind === "admission_status" && event.data.eventId === create.id)).toBe(false);
    expect(listThreads(dir)).toEqual([]);
  } finally {
    rmSync(blocked, { recursive: true });
  }
  sendRaw(create);
  const accepted = await eventsUntil((event) => event.kind === "thread_list" &&
    event.data.threads.some((thread) => thread.id === "disk"));
  expect(accepted.some((event) => event.kind === "receipt" && event.data.eventId === create.id)).toBe(true);
  expect(listThreads(dir).map((thread) => thread.id)).toEqual(["disk"]);
});

test("an accepted thread creation retry survives a missing folder and refuses changed payload", async () => {
  const folder = join(projectsRoot, `created-${randomUUID()}`);
  mkdirSync(folder);
  try {
    const { dir, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: { run: vi.fn() } } });
    const create: YorozuEvent = { id: "created-once", threadId: "native", ts: Date.now(), agentId: "phone",
      kind: "thread_create", data: { agent: "codex", cwd: folder } };
    sendRaw(create);
    await eventsUntil((event) => event.kind === "thread_list" &&
      event.data.threads.some((thread) => thread.id === "native"));
    expect(listThreads(dir).find((thread) => thread.id === "native")?.creation?.eventId).toBe(create.id);
    rmSync(folder, { recursive: true });
    sendRaw(create);
    const retry = await eventsUntil((event) => event.kind === "receipt" && event.data.eventId === create.id);
    expect(retry.some((event) => event.kind === "admission_status" && event.data.eventId === create.id)).toBe(false);
    sendRaw({ ...create, data: { agent: "yorozu" } });
    const conflict = await eventsUntil((event) => event.kind === "admission_status" &&
      event.data.eventId === create.id);
    expect(conflict.at(-1)).toMatchObject({ data: { status: "rejected", reason: "conflicting-thread-create" } });
    expect(conflict.some((event) => event.kind === "receipt" && event.data.eventId === create.id)).toBe(false);
    expect(listThreads(dir).find((thread) => thread.id === "native")?.agent).toBe("codex");
  } finally {
    if (existsSync(folder)) rmSync(folder, { recursive: true });
  }
});

test("a registered agent appears in the catalog and answers a thread without a folder", async () => {
  const turns: NativeTurn[] = [];
  const runner: NativeAgentRunner = {
    descriptor: { id: "test-harness", label: "Test Harness", description: "Answers test prompts", needsFolder: false },
    models: async () => [{ id: "test/model", label: "Test Model", providerLabel: "Test", efforts: ["low"] }],
    skills: async () => [{ name: "plugin:Inspect", description: "Inspect a project" }],
    run: async (turn) => { turns.push(turn); turn.onUpdate?.("working"); return { text: "from test harness" }; },
  };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { "test-harness": runner } });
  const catalog = (await eventsUntil((event) => event.kind === "model_list" &&
    event.data.agents?.some((agent) => agent.id === "test-harness") === true &&
    event.data.skills?.["test-harness"]?.[0]?.name === "plugin:Inspect")).at(-1)!;
  expect(catalog).toMatchObject({ data: { agents: [
    { id: "yorozu", label: "Yorozu", needsFolder: false },
    { id: "test-harness", label: "Test Harness", description: "Answers test prompts", needsFolder: false },
  ] } });
  expect(catalog).toMatchObject({ data: { skills: { "test-harness": [{ name: "plugin:Inspect", description: "Inspect a project" }] } } });
  send({ kind: "thread_create", data: { agent: "test-harness" } }, "custom");
  await eventsUntil((event) => event.kind === "thread_list" &&
    event.data.threads.some((thread) => thread.id === "custom" && thread.agent === "test-harness"));
  send({ kind: "message", data: { role: "user", text: "hello" } }, "custom");
  const reply = (await eventsUntil((event) => event.kind === "message" && event.threadId === "custom" &&
    event.data.done === true)).at(-1)!;
  expect(reply).toMatchObject({ data: { text: "from test harness" } });
  expect(turns).toHaveLength(1);
  expect(turns[0]?.cwd).toBe("");
  expect(listThreads(dir).find((thread) => thread.id === "custom")?.agent).toBe("test-harness");
});

test("a removed agent's thread stays readable and works again when its runner returns", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-returning-agent-"));
  createThread("Saved", dir, "custom", { agent: "test-harness", needsFolder: false });
  const first = await pairedPhone([], false, { stateDir: dir, nativeRunners: {} });
  const listed = (await first.eventsUntil((event) => event.kind === "thread_list")).at(-1)!;
  expect(listed).toMatchObject({ data: { threads: [expect.objectContaining({ id: "custom", agent: "test-harness" })] } });
  first.send({ kind: "message", data: { role: "user", text: "first" } }, "custom");
  const refusal = (await first.eventsUntil((event) => event.kind === "message" && event.threadId === "custom" &&
    event.data.done === true)).at(-1)!;
  expect(refusal).toMatchObject({ data: { failed: true, text: expect.stringMatching(/no longer registered/) } });
  await sidecar.close();
  await relay.close();

  const run = vi.fn<NativeAgentRunner["run"]>().mockResolvedValue({ text: "back again" });
  const second = await pairedPhone([], false, { stateDir: dir, nativeRunners: {
    "test-harness": { descriptor: { id: "test-harness", label: "Test Harness", needsFolder: false }, run },
  } });
  second.send({ kind: "message", data: { role: "user", text: "second" } }, "custom");
  const reply = (await second.eventsUntil((event) => event.kind === "message" && event.threadId === "custom" &&
    event.data.done === true)).at(-1)!;
  expect(reply).toMatchObject({ data: { text: "back again" } });
  expect(run).toHaveBeenCalledTimes(1);
  expect(readThreadEvents("custom", dir).filter((event) => event.kind === "message").length).toBe(4);
});

test.each([false, true])("an %s open-agent peer can answer registered agent cards", async (modern) => {
  const runner: NativeAgentRunner = {
    descriptor: { id: "test-harness", label: "Test Harness", needsFolder: false },
    run: async (turn) => {
      const approved = await turn.approve?.("Edit", { path: "test.txt" }, turn.signal);
      const choice = await turn.ask?.("Proceed?", ["Yes", "No"], turn.signal);
      return { text: `${approved} ${choice}` };
    },
  };
  const { send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { "test-harness": runner } }, modern);
  send({ kind: "thread_create", data: { agent: "test-harness" } }, "custom");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "custom"));
  send({ kind: "message", data: { role: "user", text: "edit" } }, "custom");
  const approval = (await eventsUntil((event) => event.kind === "approval_card" && event.threadId === "custom")).at(-1)!;
  if (approval.kind !== "approval_card") throw new Error("expected approval card");
  expect(approval.data.nativeAgent).toBe(modern ? "test-harness" : undefined);
  send({ kind: "sync_request", data: { lastSeen: {}, threadId: "custom" } }, "");
  const replay = (await eventsUntil((event) => event.kind === "sync_delta" &&
    event.data.events.some((item) => item.id === approval.id))).at(-1)!;
  if (replay.kind !== "sync_delta") throw new Error("expected replay page");
  const replayedCard = replay.data.events.find((item) => item.id === approval.id);
  expect(replayedCard?.kind === "approval_card" ? replayedCard.data.nativeAgent : undefined)
    .toBe(modern ? "test-harness" : undefined);
  send({ kind: "approval_answer", data: { actionId: approval.data.actionId, answer: "yes" } }, "custom");
  const question = (await eventsUntil((event) => event.kind === "question_card" && event.threadId === "custom")).at(-1)!;
  if (question.kind !== "question_card") throw new Error("expected question card");
  expect(question.data.nativeAgent).toBe(modern ? "test-harness" : undefined);
  send({ kind: "question_answer", data: { questionId: question.data.questionId, answer: "Yes" } }, "custom");
  const reply = (await eventsUntil((event) => event.kind === "message" && event.data.done === true &&
    event.threadId === "custom")).at(-1)!;
  expect(reply).toMatchObject({ data: { text: "true Yes" } });
});

test("bad agent descriptors are not advertised and one model failure leaves other agents available", async () => {
  const run: NativeAgentRunner["run"] = async () => ({ text: "ok" });
  const { send, eventsUntil } = await pairedPhone([], false, { nativeRunners: {
    good: { descriptor: { id: "good", label: "Good", needsFolder: false },
      models: async () => [{ id: "good/model", label: "Good Model", providerLabel: "Good", efforts: [] }], run },
    broken: { descriptor: { id: "broken", label: "Broken", needsFolder: true },
      models: () => { throw new Error("model service down"); }, run },
    constructor: { descriptor: { id: "constructor", label: "Constructor", needsFolder: false }, run },
    oversized: { descriptor: { id: "oversized", label: "X".repeat(65), needsFolder: false }, run },
  } });
  const catalog = (await eventsUntil((event) => event.kind === "model_list" &&
    event.data.agentModels?.good?.length === 1)).at(-1)!;
  if (catalog.kind !== "model_list") throw new Error("expected model list");
  expect(catalog.data.agents?.map((agent) => agent.id)).toEqual(["yorozu", "good", "broken", "constructor"]);
  expect(catalog.data.agentModels?.broken).toBeUndefined();
  send({ kind: "thread_create", data: { agent: "oversized" } }, "bad");
  const refused = (await eventsUntil((event) => event.kind === "thought" && event.threadId === "bad")).at(-1)!;
  expect(refused).toMatchObject({ data: { text: expect.stringMatching(/unregistered agent/) } });
});

test("a registered runner needs its own valid identity", () => {
  expect(() => startSidecar({ stateDir: mkdtempSync(join(tmpdir(), "yorozu-reserved-agent-")), nativeRunners: {
    custom: { descriptor: { id: "codex", label: "Fake Codex", needsFolder: false },
      run: async () => ({ text: "" }) },
  } })).toThrow(/cannot claim a built-in identity/);
  expect(() => startSidecar({ stateDir: mkdtempSync(join(tmpdir(), "yorozu-missing-descriptor-")), nativeRunners: {
    custom: { run: async () => ({ text: "" }) },
  } })).toThrow(/needs a descriptor/);
});

test.each(["claude-code", "codex"] as const)("a %s thread runs, resumes and stops its own native session, never OpenClaw's", async (agent) => {
  const turns: NativeTurn[] = [];
  let release!: () => void;
  const runner: NativeAgentRunner = {
    run: vi.fn(async (turn: NativeTurn) => {
      turns.push(turn);
      if (turn.text.endsWith("break")) throw new Error("claude is not logged in");
      turn.onUpdate?.("working");
      if (turns.length < 3) {
        if (turns.length === 1) {
          turn.onActivity?.("u1:thinking", { kind: "thought", data: { text: "reading the failing test" } });
          turn.onActivity?.("call:toolu_1", { kind: "tool_call", data: { callId: "toolu_1", name: "Bash", args: { command: "cat big.log" } } });
          turn.onActivity?.("result:toolu_1", { kind: "tool_result", data: { callId: "toolu_1", ok: true, output: "L".repeat(5000) } });
        } else {
          turn.onActivity?.("call:denied", { kind: "tool_call", data: { callId: "denied", name: "Bash", args: { command: "rm file" } } });
          turn.onActivity?.("result:denied", { kind: "tool_result", data: { callId: "denied", ok: false, output: "declined", denied: true } });
        }
        return { text: `reply ${turns.length}`, sessionId: "s-1" };
      }
      // The third turn hangs until stopped, the way a long job would.
      turn.onActivity?.("long:call", { kind: "tool_call", data: { callId: "long", name: "Bash", args: { command: "pwd" } } });
      turn.onActivity?.("long:result", { kind: "tool_result", data: { callId: "long", ok: true, output: "done" } });
      await new Promise<void>((resolve) => {
        release = resolve;
        turn.signal.addEventListener("abort", () => resolve(), { once: true });
      });
      return { text: "", sessionId: "s-1" };
    }),
  };
  const { dir, send, eventsUntil } = await pairedPhone([], true, { nativeRunners: { [agent]: runner } });
  send({ kind: "thread_create", data: { agent, cwd: proj } }, "cc");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "cc"));

  // First prompt: a new session in the thread's folder; the streamed delta and the final both reach the phone.
  send({ kind: "message", data: { role: "user", text: "fix the tests" } }, "cc");
  const first = await eventsUntil((event) => event.kind === "message" && event.data.done === true);
  expect(first.filter((event) => event.kind === "message" && event.data.role === "agent").map((event) => (event as { data: { text: string } }).data.text)).toEqual(["working", "reply 1"]);
  expect(turns[0]).toMatchObject({ threadId: "cc", cwd: proj, text: "fix the tests" });
  // The trace rode along as the events the work row draws, under ids stable per step, and the
  // long result went out as its first 4 KB, flagged. The whole of it stayed on the Mac.
  expect(first.filter((event) => ["thought", "tool_call", "tool_result"].includes(event.kind)).map((event) => [event.id, event.kind])).toEqual([
    [`${agent}:cc:u1:thinking`, "thought"],
    [`${agent}:cc:call:toolu_1`, "tool_call"],
    [`${agent}:cc:result:toolu_1`, "tool_result"],
  ]);
  const cut = first.find((event) => event.kind === "tool_result") as YorozuEvent & { kind: "tool_result" };
  expect(cut.data).toEqual({ callId: "toolu_1", ok: true, output: "L".repeat(4096), truncated: true });
  expect(readThreadEvents("cc", dir).find((event) => event.kind === "tool_result")).toEqual(cut);
  // One tap asks for the rest: the same event, whole, to this device alone.
  send({ kind: "tool_result_request", data: { callId: "toolu_1" } }, "cc");
  const whole = (await eventsUntil((event) => event.kind === "tool_result")).at(-1) as YorozuEvent & { kind: "tool_result" };
  expect(whole.id).toBe(cut.id);
  expect(whole.data).toEqual({ callId: "toolu_1", ok: true, output: "L".repeat(5000) });
  send({ kind: "tool_result_request", data: { callId: "nope" } }, "cc");
  await vi.waitFor(() => expect(states).toContain("tool-result-missing"));
  expect(turns[0]).not.toHaveProperty("sessionId");
  expect(listThreads(dir).find((thread) => thread.id === "cc")).toMatchObject({ nativeSessionId: "s-1", title: "fix the tests" });

  // Second prompt resumes it, still in the same folder.
  send({ kind: "message", data: { role: "user", text: "and lint" } }, "cc");
  const second = await eventsUntil((event) => event.kind === "message" && event.data.done === true);
  expect(second.find((event) => event.kind === "tool_result" && event.data.callId === "denied"))
    .toMatchObject({ data: { ok: false, denied: true } });
  expect(turns[1]).toMatchObject({ cwd: proj, sessionId: "s-1" });

  // Stop ends the turn without erasing the partial reply, and keeps the session to resume.
  const longJobId = send({ kind: "message", data: { role: "user", text: "long job" } }, "cc");
  await vi.waitFor(() => expect(turns).toHaveLength(3));
  send({ kind: "sync_request", data: { lastSeen: {}, focusThreadId: "cc" } });
  const busy = (await eventsUntil((event) => event.kind === "sync_delta")).at(-1)! as YorozuEvent & { kind: "sync_delta" };
  expect(busy.data.workingThreadIds).toEqual(["cc"]);
  expect(busy.data.current).toEqual([expect.objectContaining({
    kind: "message", data: { role: "agent", text: "working" },
  })]);
  send({ kind: "interrupt", data: { targetEventId: longJobId } }, "cc");
  await vi.waitFor(() => expect(turns[2]!.signal.aborted).toBe(true));
  send({ kind: "sync_request", data: { lastSeen: {} } });
  const idle = (await eventsUntil((event) => event.kind === "sync_delta")).at(-1)! as YorozuEvent & { kind: "sync_delta" };
  expect(idle.data.workingThreadIds).toEqual([]);
  const replies = readThreadEvents("cc", dir).filter((event) => event.kind === "message" && event.data.role === "agent");
  expect(replies).toHaveLength(3);
  expect(replies.at(-1)).toMatchObject({ kind: "message", data: { text: "working", done: true, interrupted: true } });
  const history = readThreadEvents("cc", dir);
  expect(history.findIndex((event) => event.kind === "tool_result" && event.data.callId === "long"))
    .toBeLessThan(history.findIndex((event) => event.id === `native:${longJobId}:final`));
  expect(readTranscripts(new Date(0), transcriptDir(dir))).toContainEqual(expect.objectContaining({
    id: `native:${longJobId}:final`, data: expect.objectContaining({ text: "working", interrupted: true }),
  }));
  expect(idle.data.events).toContainEqual(expect.objectContaining({ id: `native:${longJobId}:final`,
    data: expect.objectContaining({ text: "working", done: true, interrupted: true }) }));
  expect(listThreads(dir).find((thread) => thread.id === "cc")?.nativeSessionId).toBe("s-1");
  // A reconnecting phone's sync carries the truncated head, and the request still answers whole.
  send({ kind: "sync_request", data: { lastSeen: {} } });
  const replayed = (await eventsUntil((event) => event.kind === "sync_delta")).at(-1) as YorozuEvent & { kind: "sync_delta" };
  const replayedCut = replayed.data.events.find((event) => event.kind === "tool_result") as YorozuEvent & { kind: "tool_result" };
  expect(replayedCut.data.truncated).toBe(true);
  expect(replayedCut.data.output).toHaveLength(4096);
  // The session id is the Mac's alone.
  expect(JSON.stringify(first)).not.toContain(JSON.stringify("s-1"));
  void release;

  // An agent that cannot run at all still finishes the turn, with the reason in the thread.
  send({ kind: "message", data: { role: "user", text: "break" } }, "cc");
  const failed = (await eventsUntil((event) => event.kind === "message" && event.data.done === true)).at(-1)!;
  expect(turns[3]?.text).toContain("Previous reply was stopped or has a pending Stop request");
  // The phone hears that the turn is over and where to look; the SDK's own words, which can
  // name local paths and accounts, stay in the Mac's log.
  expect(failed).toMatchObject({ data: { text: `${agent} could not answer; see the Mac log.`, failed: true } });
  expect(JSON.stringify(failed)).not.toContain("not logged in");
  expect(states).toContain("native-error claude is not logged in");
});

test("rapid reply revisions converge to the latest partial and final answer", async () => {
  const finish = Promise.withResolvers<void>();
  const runner: NativeAgentRunner = { run: async (turn) => {
    for (let i = 0; i < 20; i++) turn.onUpdate?.(`draft ${i}`);
    await finish.promise;
    return { text: "finished" };
  } };
  const { send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } });
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "cc");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "cc"));
  send({ kind: "message", data: { role: "user", text: "write" } }, "cc");
  const partials = await eventsUntil((event) => event.kind === "message" && event.threadId === "cc" && event.data.text === "draft 19");
  finish.resolve();
  const seen = [...partials, ...await eventsUntil((event) => event.kind === "message" && event.threadId === "cc" && event.data.done === true)];
  expect(seen.filter((event) => event.kind === "message" && event.data.role === "agent")
    .map((event) => event.kind === "message" ? event.data.text : "")).toEqual(["draft 0", "draft 19", "finished"]);
});

test("large answer pacing keeps local streaming and gives the phone progress before final", async () => {
  const finish = Promise.withResolvers<void>();
  const runner: NativeAgentRunner = { run: async (turn) => {
    turn.onUpdate?.("x".repeat(17_000));
    turn.onUpdate?.("y".repeat(18_000));
    await finish.promise;
    return { text: "finished" };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } });
  const mac = await macClient(dir);
  try {
    send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "cc");
    await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "cc"));
    send({ kind: "message", data: { role: "user", text: "write" } }, "cc");
    await eventsUntil((event) => event.kind === "message" && event.data.role === "agent" && event.data.text.length === 17_000);
    await vi.waitFor(() => expect(mac.events).toContainEqual(expect.objectContaining({
      kind: "message", data: expect.objectContaining({ role: "agent", text: "y".repeat(18_000) }),
    })));
    finish.resolve();
    expect((await eventsUntil((event) => event.kind === "message" && event.data.done === true)).at(-1))
      .toMatchObject({ data: { text: "finished", done: true } });
  } finally {
    finish.resolve();
    mac.close();
  }
});

test("a trace burst cannot delay the final answer or lose durable history", async () => {
  let release!: () => void;
  const firstReplay = new Promise<void>((resolve) => { release = resolve; });
  const runner: NativeAgentRunner = { run: async (turn) => {
    for (let i = 0; i < 150; i++) turn.onActivity?.(`thought-${i}`, { kind: "thought", data: { text: `step ${i}` } });
    turn.onActivity?.("large-thought", { kind: "thought", data: { text: "x".repeat(800_000) } });
    await firstReplay;
    return { text: "finished" };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } });
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "cc");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "cc"));
  send({ kind: "message", data: { role: "user", text: "work" } }, "cc");
  const lastSeen: Record<string, string> = {};
  const replayed: YorozuEvent[] = [];
  let hinted = false;
  let complete = false;
  const onEvent = (event: YorozuEvent): void => {
    if (event.kind !== "sync_delta") return;
    if (!hinted && event.data.events.length === 0 && event.data.more === true) {
      hinted = true;
      send({ kind: "sync_request", data: { lastSeen, focusThreadId: "cc" } }, "");
      return;
    }
    for (const item of event.data.events) {
      replayed.push(item);
      lastSeen[item.threadId] = item.syncCursor ?? item.id;
    }
    if (replayed.length && replayed.length === event.data.events.length) release();
    if (event.data.more) send({ kind: "sync_request", data: { lastSeen, focusThreadId: "cc", includeCurrent: false } }, "");
    else complete = true;
  };
  const live = await eventsUntil((event) => {
    onEvent(event);
    return event.kind === "message" && event.data.role === "agent" && event.data.done === true;
  });
  expect(hinted).toBe(true);
  expect(replayed.filter((event) => event.kind === "thought").length).toBeLessThan(151);
  expect(live.filter((event) => event.kind === "thought").length).toBeLessThan(150);
  expect(live.some((event) => event.kind === "thought" && event.data.text.length === 800_000)).toBe(false);
  while (!complete) await eventsUntil((event) => { onEvent(event); return complete; });
  expect(replayed.filter((event) => event.kind === "thought")).toHaveLength(151);
  expect(new Set(replayed.map((event) => event.id)).size).toBe(replayed.length);
  expect(replayed.some((event) => event.kind === "thought" && event.data.text.includes("full trace on host"))).toBe(true);
  expect(readThreadEvents("cc", dir).some((event) => event.kind === "thought" && event.data.text.length === 800_000)).toBe(true);
});

test("stopping a turn persists its latest unsent draft", async () => {
  const runner: NativeAgentRunner = { run: async (turn) => {
    for (let i = 0; i < 20; i++) turn.onUpdate?.(`draft ${i}`);
    await new Promise<void>((resolve) => turn.signal.addEventListener("abort", () => resolve(), { once: true }));
    return { text: "" };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } });
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "cc");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "cc"));
  const id = send({ kind: "message", data: { role: "user", text: "write" } }, "cc");
  await eventsUntil((event) => event.kind === "message" && event.data.role === "agent" && event.data.text === "draft 0");
  send({ kind: "interrupt", data: { targetEventId: id } }, "cc");
  expect((await eventsUntil((event) => event.kind === "message" && event.data.role === "agent" &&
    event.data.text === "draft 19" && event.data.done === true)).at(-1))
    .toMatchObject({ data: { text: "draft 19", done: true, interrupted: true } });
  expect(readThreadEvents("cc", dir).filter((event) => event.kind === "message" && event.data.role === "agent"))
    .toHaveLength(1);
});

test("queued messages follow earlier turns in live and saved history", async () => {
  const firstFinished = Promise.withResolvers<void>();
  const runner: NativeAgentRunner = { run: async (turn) => {
    if (turn.text === "first") await firstFinished.promise;
    return { text: `reply to ${turn.text}` };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } });
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "steered");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "steered"));
  const first = send({ kind: "message", data: { role: "user", text: "first" } }, "steered");
  await eventsUntil((event) => event.kind === "thread_list" &&
    event.data.threads.some((thread) => thread.id === "steered" && thread.activeEventId === first));
  const second = send({ kind: "message", data: { role: "user", text: "second" } }, "steered");
  const third = send({ kind: "message", data: { role: "user", text: "third" } }, "steered");
  await eventsUntil((event) => event.kind === "message" && event.id === third);
  const frozenNow = Date.now();
  const clock = vi.spyOn(Date, "now").mockReturnValue(frozenNow);
  firstFinished.resolve();
  let live: YorozuEvent[];
  try {
    live = await eventsUntil((event) => event.kind === "message" && event.data.role === "agent" &&
      event.data.text === "reply to third" && event.data.done === true);
  } finally { clock.mockRestore(); }
  expect(live.filter((event) => event.kind === "message" && [second, third].includes(event.id) &&
    event.clientTs !== undefined).map((event) => event.id)).toEqual([second, third]);
  const history = readThreadEvents("steered", dir).filter((event) => event.kind === "message");
  expect(history.map((event) => event.data.text)).toEqual([
    "first", "reply to first", "second", "reply to second", "third", "reply to third",
  ]);
  expect(history.map((event) => event.ts)).toEqual([...history.map((event) => event.ts)].sort((a, b) => a - b));
  expect(readTranscripts(new Date(0), transcriptDir(dir)).filter((event) => event.threadId === "steered" &&
    event.kind === "message").map((event) => event.data.text)).toEqual([
    "first", "reply to first", "second", "reply to second", "third", "reply to third",
  ]);
  expect(eventsAfter("steered", second, dir).some((event) => event.kind === "message" &&
    event.data.text === "reply to first")).toBe(true);
});

test("native turns report changed files after replies and skip unchanged or non-git folders", async () => {
  const gitFolder = mkdtempSync(join(projectsRoot, "changes-"));
  const plainFolder = mkdtempSync(join(projectsRoot, "plain-"));
  execFileSync("git", ["init", "-q", gitFolder]);
  writeFileSync(join(gitFolder, "file.txt"), "alpha\nbeta\ngamma\n");
  execFileSync("git", ["add", "file.txt"], { cwd: gitFolder });
  execFileSync("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid",
    "-c", "commit.gpgsign=false", "commit", "-qm", "initial"], { cwd: gitFolder });
  writeFileSync(join(gitFolder, "staged.txt"), "pending\n");
  execFileSync("git", ["add", "staged.txt"], { cwd: gitFolder });
  const staged = execFileSync("git", ["diff", "--cached", "--name-only"], { cwd: gitFolder, encoding: "utf8" });
  const runner: NativeAgentRunner = { run: async (turn) => {
    if (turn.text === "edit") writeFileSync(join(gitFolder, "file.txt"), "alpha\nupdated\ngamma\nnew\n");
    if (turn.text === "edit again") writeFileSync(join(gitFolder, "file.txt"), "alpha\nupdated\ngamma\nnew\nmore\n");
    return { text: `reply to ${turn.text}` };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } });
  try {
    send({ kind: "thread_create", data: { agent: "codex", cwd: gitFolder } }, "git-thread");
    await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "git-thread"));
    const edited = send({ kind: "message", data: { role: "user", text: "edit" } }, "git-thread");
    const reply = (await eventsUntil((event) => event.kind === "message" && event.threadId === "git-thread" &&
      event.data.role === "agent" && event.data.done === true)).at(-1)!;
    expect(reply.data).toMatchObject({ text: "reply to edit" });
    const changes = (await eventsUntil((event) => event.kind === "turn_changes" && event.threadId === "git-thread")).at(-1)!;
    expect(changes).toMatchObject({ data: { turnEventId: edited, files: [{ path: "file.txt", added: 2, removed: 1 }] } });
    expect(readThreadEvents("git-thread", dir)).toContainEqual(changes);
    expect(execFileSync("git", ["diff", "--cached", "--name-only"], { cwd: gitFolder, encoding: "utf8" })).toBe(staged);

    const unchanged = send({ kind: "message", data: { role: "user", text: "same" } }, "git-thread");
    await eventsUntil((event) => event.kind === "message" && event.threadId === "git-thread" &&
      event.data.role === "agent" && event.data.text === "reply to same" && event.data.done === true);
    const next = send({ kind: "message", data: { role: "user", text: "edit again" } }, "git-thread");
    const later = await eventsUntil((event) => event.kind === "turn_changes" && event.data.turnEventId === next);
    expect(later.filter((event) => event.kind === "turn_changes" && event.data.turnEventId === unchanged)).toEqual([]);
    send({ kind: "thread_create", data: { agent: "codex", cwd: plainFolder } }, "plain-thread");
    await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "plain-thread"));
    const plain = send({ kind: "message", data: { role: "user", text: "plain" } }, "plain-thread");
    await eventsUntil((event) => event.kind === "message" && event.threadId === "plain-thread" &&
      event.data.role === "agent" && event.data.text === "reply to plain" && event.data.done === true);
    expect(readThreadEvents("git-thread", dir).filter((event) => event.kind === "turn_changes" &&
      event.data.turnEventId === unchanged)).toEqual([]);
    expect(readThreadEvents("plain-thread", dir).filter((event) => event.kind === "turn_changes" &&
      event.data.turnEventId === plain)).toEqual([]);
  } finally {
    rmSync(gitFolder, { recursive: true, force: true });
    rmSync(plainFolder, { recursive: true, force: true });
  }
});

test.each(["codex", "claude-code"])("Edit from here keeps the log and resets %s context across restart", async (agent) => {
  const turns: NativeTurn[] = [];
  const runner: NativeAgentRunner = { run: async (turn) => {
    turns.push(turn);
    turn.onSession?.(`session-${turns.length}`);
    return { text: `answer-${turns.length}`, sessionId: `session-${turns.length}` };
  } };
  const first = await pairedPhone([], false, { nativeRunners: { [agent]: runner } }, true);
  const { dir, send, eventsUntil } = first;
  const threadId = "rewind";
  send({ kind: "thread_create", data: { agent, cwd: proj } }, threadId);
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === threadId));
  const prompts = [];
  const attachment = { name: "keep.txt", mime: "text/plain", data: Buffer.from("retained file").toString("base64") };
  for (const text of ["retained request", "discarded request", "discarded follow-up"]) {
    prompts.push(send({ kind: "message", data: { role: "user", text,
      attachments: text === "retained request" ? [attachment] : [] } }, threadId));
    await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
      thread.id === threadId && thread.turnState === "idle"));
  }
  expect(turns[1]?.sessionId).toBe("session-1");
  const other: YorozuEvent[] = [];
  const local = createConnection(localSocketPath(dir));
  let buffer = "";
  local.on("data", (chunk) => {
    buffer += chunk.toString();
    let newline: number;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      other.push(JSON.parse(buffer.slice(0, newline)) as YorozuEvent);
      buffer = buffer.slice(newline + 1);
    }
  });
  await new Promise<void>((resolve) => local.once("connect", resolve));
  try {
    const requestId = send({ kind: "thread_rewind", data: { eventId: prompts[1]! } }, threadId);
    const result = (await eventsUntil((event) => event.kind === "thread_rewound" && event.data.requestId === requestId)).at(-1)!;
    expect(result).toMatchObject({ kind: "thread_rewound", data: { eventId: prompts[1],
      hiddenEventIds: [prompts[1], `native:${prompts[1]}:final`, prompts[2], `native:${prompts[2]}:final`] } });
    await vi.waitFor(() => expect(other).toContainEqual(result));
    expect(readThreadEvents(threadId, dir)).toContainEqual(result);
    expect(readThreadEvents(threadId, dir).filter((event) => event.kind === "message")).toHaveLength(6);
    sendRaw({ id: requestId, threadId, ts: Date.now(), agentId: "phone",
      kind: "thread_rewind", data: { eventId: prompts[1]! } });
    expect((await eventsUntil((event) => event.kind === "thread_rewound")).at(-1)).toEqual(result);
    expect(readThreadEvents(threadId, dir).filter((event) => event.kind === "thread_rewound")).toHaveLength(1);
    const invalid = send({ kind: "thread_rewind", data: { eventId: prompts[2]! } }, threadId);
    expect((await eventsUntil((event) => event.kind === "thread_rewound" && event.data.requestId === invalid)).at(-1))
      .toMatchObject({ data: { reason: "This message is no longer in the conversation." } });
  } finally { local.destroy(); }
  await sidecar.close();
  await relay.close();
  const restarted = await pairedPhone([], false, { stateDir: dir, nativeRunners: { [agent]: runner } }, true);
  restarted.send({ kind: "sync_request", data: { lastSeen: {}, threadId } }, "");
  const synced = (await restarted.eventsUntil((event) => event.kind === "sync_delta")).at(-1)!;
  expect(synced.kind === "sync_delta" && synced.data.events.some((event) => event.kind === "thread_rewound")).toBe(true);
  restarted.send({ kind: "message", data: { role: "user", text: "replacement" } }, threadId);
  await restarted.eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === threadId && thread.turnState === "idle"));
  expect(turns[3]?.sessionId).toBeUndefined();
  expect(turns[3]?.text).toContain("retained request");
  expect(turns[3]?.text).toContain("answer-1");
  expect(turns[3]?.text).toContain("keep.txt");
  expect(turns[3]?.text).toContain("replacement");
  expect(turns[3]?.text).not.toContain("discarded");
  expect(turns[3]?.text).not.toContain("answer-2");
  restarted.send({ kind: "message", data: { role: "user", text: "continue" } }, threadId);
  await restarted.eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === threadId && thread.turnState === "idle"));
  expect(turns[4]?.sessionId).toBe("session-4");
  expect(turns[4]?.text).toBe("continue");
  const searchId = randomUUID();
  restarted.send({ kind: "thread_search_request", data: { requestId: searchId, query: "discarded" } }, "");
  expect((await restarted.eventsUntil((event) => event.kind === "thread_search_result" &&
    event.data.requestId === searchId)).at(-1)).toMatchObject({ data: { matches: [] } });
  const rewindAll = restarted.send({ kind: "thread_rewind", data: { eventId: prompts[0]! } }, threadId);
  await restarted.eventsUntil((event) => event.kind === "thread_rewound" && event.data.requestId === rewindAll);
  const fresh = restarted.send({ kind: "message", data: { role: "user", text: "fresh start" } }, threadId);
  await restarted.eventsUntil((event) => event.kind === "message" && event.id === `native:${fresh}:final` && event.data.done === true);
  await restarted.eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === threadId && thread.turnState === "idle"));
  expect(turns[5]?.sessionId).toBeUndefined();
  expect(turns[5]?.text).toContain("fresh start");
  expect(turns[5]?.text).not.toContain("retained");
  expect(turns[5]?.text).not.toContain("replacement");
});

test("Edit from here excludes hidden messages and stale summaries from provider context", async () => {
  relay = await startRelay(0);
  const dir = mkdtempSync(join(tmpdir(), "yorozu-rewind-summary-"));
  createThread("Summary", dir, "summary");
  const contexts: Message[][] = [];
  sidecar = serve({ stateDir: dir, relayUrl: `ws://127.0.0.1:${relay.port}`, log: () => {},
    provider: { auth: async () => ({ ok: true }), stream: async function* (messages) {
      contexts.push(structuredClone(messages));
      yield { type: "text", text: `answer-${contexts.length}` };
    } } });
  const local = createConnection(localSocketPath(dir));
  const received: YorozuEvent[] = [];
  let buffer = "";
  local.on("data", (chunk) => {
    buffer += chunk.toString();
    let newline: number;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      received.push(JSON.parse(buffer.slice(0, newline)) as YorozuEvent);
      buffer = buffer.slice(newline + 1);
    }
  });
  await new Promise<void>((resolve) => local.once("connect", resolve));
  const send = (payload: EventPayload): string => {
    const id = randomUUID();
    local.write(JSON.stringify({ id, threadId: "summary", ts: Date.now(), agentId: "mac", ...payload }) + "\n");
    return id;
  };
  try {
    const prompts: string[] = [];
    for (const text of ["retained", "discarded"]) {
      prompts.push(send({ kind: "message", data: { role: "user", text } }));
      await vi.waitFor(() => expect(received.some((event) => event.kind === "message" &&
        event.data.text === `answer-${prompts.length}` && event.data.done)).toBe(true));
    }
    writeFileSync(summaryFile("summary", dir), "<!-- yorozu:through 4 -->\ndiscarded summary\n");
    const request = send({ kind: "thread_rewind", data: { eventId: prompts[1]! } });
    await vi.waitFor(() => expect(received.some((event) => event.kind === "thread_rewound" &&
      event.data.requestId === request && !event.data.reason)).toBe(true));
    send({ kind: "message", data: { role: "user", text: "replacement" } });
    await vi.waitFor(() => expect(contexts).toHaveLength(3));
    expect(contexts[2]?.filter((message) => message.role !== "system")).toEqual([
      { role: "user", content: "retained" }, { role: "assistant", content: "answer-1" },
      { role: "user", content: "replacement" },
    ]);
    expect(JSON.stringify(contexts[2])).not.toContain("discarded");
  } finally { local.destroy(); }
});

test("Edit from here rejects a working thread without recording a marker", async () => {
  const done = Promise.withResolvers<void>();
  const runner: NativeAgentRunner = { run: async () => { await done.promise; return { text: "done" }; } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } }, true);
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "busy-rewind");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "busy-rewind"));
  const target = send({ kind: "message", data: { role: "user", text: "working" } }, "busy-rewind");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.turnState === "running"));
  const request = send({ kind: "thread_rewind", data: { eventId: target } }, "busy-rewind");
  try {
    const result = (await eventsUntil((event) => event.kind === "thread_rewound" && event.data.requestId === request)).at(-1)!;
    expect(result).toMatchObject({ data: { reason: "Wait for this thread to finish working." } });
    expect(readThreadEvents("busy-rewind", dir).some((event) => event.kind === "thread_rewound")).toBe(false);
  } finally { done.resolve(); }
});

test("turn state spans queued turns and ignores a stop for an earlier turn", async () => {
  const firstDone = Promise.withResolvers<void>();
  const secondDone = Promise.withResolvers<void>();
  const turns: NativeTurn[] = [];
  const runner: NativeAgentRunner = { run: async (turn) => {
    turns.push(turn);
    if (turn.text === "first") await firstDone.promise;
    else await secondDone.promise;
    return { text: `reply to ${turn.text}` };
  } };
  const { send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } }, true);
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "turn-state");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "turn-state"));
  const first = send({ kind: "message", data: { role: "user", text: "first" } }, "turn-state");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "turn-state" && thread.turnState === "starting" && thread.activeEventId === first));
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "turn-state" && thread.turnState === "running" && thread.activeEventId === first));
  const second = send({ kind: "message", data: { role: "user", text: "second" } }, "turn-state");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "turn-state" && thread.turnState === "running" && thread.activeEventId === first && thread.queuedTurnCount === 1 && thread.queuedEventIds?.[0] === second));
  send({ kind: "sync_request", data: { lastSeen: {} } }, "");
  const sync = await eventsUntil((event) => event.kind === "sync_delta");
  expect(sync.at(-1)).toMatchObject({ data: { workingThreadIds: ["turn-state"] } });

  firstDone.resolve();
  const duringSecond = await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "turn-state" && thread.turnState === "running" && thread.activeEventId === second));
  const earlierFinal = duringSecond.findIndex((event) => event.kind === "message" && event.id === `native:${first}:final`);
  const secondWorking = duringSecond.findIndex((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "turn-state" && thread.turnState === "running" && thread.activeEventId === second));
  expect(earlierFinal).toBeGreaterThanOrEqual(0);
  expect(secondWorking).toBeGreaterThan(earlierFinal);
  expect(duringSecond.slice(earlierFinal).filter((event) => event.kind === "thread_list")
    .every((event) => event.kind !== "thread_list" || event.data.threads.find((thread) => thread.id === "turn-state")?.turnState !== "idle")).toBe(true);
  send({ kind: "interrupt", data: { targetEventId: first } }, "turn-state");
  await eventsUntil((event) => event.kind === "stop_status" && event.data.targetEventId === first && event.data.status === "completed");
  expect(turns[1]?.signal.aborted).toBe(false);
  send({ kind: "thread_list", data: { threads: [] } }, "");
  const afterStaleStop = await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "turn-state" && thread.turnState === "running" && thread.activeEventId === second));
  const summary = afterStaleStop.flatMap((event) => event.kind === "thread_list" ? event.data.threads : [])
    .find((thread) => thread.id === "turn-state");
  expect(summary).toMatchObject({ turnState: "running", activeEventId: second, queuedTurnCount: 0, queuedEventIds: [] });
  secondDone.resolve();
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "turn-state" && thread.turnState === "idle"));
});

test.each(["phone", "mac"])("Stop from %s drains only its thread queue and reports every withdrawal", async (device) => {
  const otherDone = Promise.withResolvers<void>();
  const run = vi.fn<NativeAgentRunner["run"]>(async (turn) => {
    if (turn.text === "active") await new Promise<void>((resolve) => turn.signal.addEventListener("abort", () => resolve(), { once: true }));
    if (turn.text === "other active") await otherDone.promise;
    return { text: `reply to ${turn.text}` };
  });
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: { run } } }, true);
  const mac = await macClient(dir);
  try {
    for (const threadId of ["stop-queue", "other-queue"]) {
      send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, threadId);
      await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === threadId));
    }
    const active = send({ kind: "message", data: { role: "user", text: "active" } }, "stop-queue");
    send({ kind: "message", data: { role: "user", text: "other active" } }, "other-queue");
    await vi.waitFor(() => expect(run).toHaveBeenCalledTimes(2));
    const queued = ["first queued", "second queued"].map((text) =>
      send({ kind: "message", data: { role: "user", text } }, "stop-queue"));
    send({ kind: "message", data: { role: "user", text: "other queued" } }, "other-queue");
    await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
      thread.id === "other-queue" && thread.queuedTurnCount === 1));
    send({ kind: "stop_status", data: { targetEventId: queued[0]!, requestId: "forged", status: "withdrawn" } }, "stop-queue");
    send({ kind: "thread_list", data: { threads: [] } });
    await eventsUntil((event) => event.kind === "thread_list");
    expect(readThreadEvents("stop-queue", dir).some((event) => event.kind === "stop_status")).toBe(false);
    if (device === "phone") send({ kind: "interrupt", data: { targetEventId: active } }, "stop-queue");
    else mac.sendRawEvent({ id: "mac-stop", threadId: "stop-queue", ts: Date.now(), agentId: "mac",
      kind: "interrupt", data: { targetEventId: active } });
    const result = await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
      thread.id === "stop-queue" && thread.turnState === "idle"));
    const withdrawn = (events: YorozuEvent[]) => events.flatMap((event) =>
      event.kind === "stop_status" && event.data.status === "withdrawn" ? [event.data.targetEventId] : []);
    expect(withdrawn(result)).toEqual(queued);
    await vi.waitFor(() => expect(withdrawn(mac.events)).toEqual(queued));
    expect(withdrawn(readThreadEvents("stop-queue", dir))).toEqual(queued);
    expect(JSON.parse(readFileSync(join(dir, "native-turn-queue.json"), "utf8")))
      .not.toEqual(expect.arrayContaining([expect.objectContaining({ threadId: "stop-queue" })]));
    otherDone.resolve();
    await eventsUntil((event) => event.kind === "message" && event.threadId === "other-queue" && event.data.text === "reply to other queued");
    expect(run.mock.calls.map(([turn]) => turn.text)).toEqual(["active", "other active", "other queued"]);
    expect(readThreadEvents("stop-queue", dir).filter((event) => event.kind === "message" && event.data.role === "agent")).toHaveLength(1);
    await sidecar.close();
    await relay.close();
    const restarted = await pairedPhone([], false, { stateDir: dir, nativeRunners: { codex: { run } } });
    for (const eventId of queued) {
      restarted.send({ kind: "admission_query", data: { eventId } }, "stop-queue");
      expect((await restarted.eventsUntil((event) => event.kind === "admission_status" && event.data.eventId === eventId)).at(-1))
        .toMatchObject({ data: { status: "withdrawn" } });
    }
    expect(run).toHaveBeenCalledTimes(3);
  } finally {
    otherDone.resolve();
    mac.close();
  }
});

test("withdrawing a queued turn leaves no reply and survives restart", async () => {
  const firstDone = Promise.withResolvers<void>();
  const run = vi.fn<NativeAgentRunner["run"]>(async (turn) => {
    await firstDone.promise;
    return { text: `reply to ${turn.text}` };
  });
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: { run } } }, true);
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "withdraw-queued");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "withdraw-queued"));
  const first = send({ kind: "message", data: { role: "user", text: "first" } }, "withdraw-queued");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "withdraw-queued" && thread.turnState === "running" && thread.activeEventId === first));
  const queued = send({ kind: "message", data: { role: "user", text: "queued" } }, "withdraw-queued");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "withdraw-queued" && thread.queuedTurnCount === 1));

  send({ kind: "interrupt", data: { targetEventId: queued } }, "withdraw-queued");
  const withdrawal = await eventsUntil((event) => event.kind === "stop_status" && event.data.targetEventId === queued);
  expect(withdrawal.at(-1)).toMatchObject({ data: { status: "withdrawn" } });
  expect(withdrawal.some((event) => event.kind === "message" && event.data.role === "agent" &&
    event.id === `native:${queued}:final`)).toBe(false);
  expect(readThreadEvents("withdraw-queued", dir).some((event) => event.id === `native:${queued}:final`)).toBe(false);
  expect(readTranscripts(new Date(0), transcriptDir(dir)).some((event) => event.id === `native:${queued}:final`)).toBe(false);
  expect(run).toHaveBeenCalledTimes(1);
  send({ kind: "thread_list", data: { threads: [] } }, "");
  const active = (await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "withdraw-queued" && thread.activeEventId === first))).at(-1);
  expect(active).toMatchObject({ data: { threads: [expect.objectContaining({
    id: "withdraw-queued", turnState: "running", queuedTurnCount: 0,
  })] } });
  firstDone.resolve();
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "withdraw-queued" && thread.turnState === "idle"));
  expect(run).toHaveBeenCalledTimes(1);
  await sidecar.close();
  await relay.close();
  const restarted = await pairedPhone([], false, { stateDir: dir, nativeRunners: { codex: { run } } });
  restarted.send({ kind: "admission_query", data: { eventId: queued } }, "withdraw-queued");
  const status = (await restarted.eventsUntil((event) => event.kind === "admission_status" && event.data.eventId === queued)).at(-1);
  expect(status).toMatchObject({ data: { status: "withdrawn" } });
  expect(run).toHaveBeenCalledTimes(1);
  expect(readThreadEvents("withdraw-queued", dir).some((event) => event.id === `native:${queued}:final`)).toBe(false);
});

test("always runs the action and is permanent: the next one needs no second card", async () => {
  // Harmless, and its output is proof the gate let the tool run rather than refusing it.
  const cmd = "echo yorozu-always-ok";
  const { dir, send, eventsUntil, isReply } = await pairedPhone([
    () => shellTurn(cmd),
    () => sse("Done."),
    () => shellTurn(cmd),
    () => sse("Done again."),
  ]);

  send({ kind: "message", data: { role: "user", text: "tidy up" } });

  const batch = await eventsUntil((event) => event.kind === "approval_card");
  expect(batch.at(-1)).toMatchObject({
    kind: "approval_card",
    data: { actionClass: "run-command", target: cmd },
  });
  const card = cardOf(batch);
  expect(card.scope).toMatchObject({ operation: "run" });
  expect(card.scope?.consequence).toBeTruthy();
  expect(card.mustConfirm).toBeUndefined();
  const { actionId } = card;

  send({
    kind: "approval_answer",
    data: { actionId, answer: "always", rule: cardOf(batch).suggestedRule },
  });
  // A result at all means the gate let the tool run: always is a yes as well as a rule.
  const ran = (events: YorozuEvent[]) =>
    events.at(-1)?.kind === "tool_result" && events.at(-1)?.data.output.includes("yorozu-always-ok");
  expect(ran(await eventsUntil((event) => event.kind === "tool_result"))).toBe(true);
  await eventsUntil(isReply);

  // The rule is on disk, scoped to the command the card actually showed rather than to every
  // command there is, so the identical action must not reach the phone a second time.
  expect(JSON.parse(readFileSync(join(dir, "approval.json"), "utf8")).rules).toMatchObject([
    {
      actionClass: "run-command",
      decision: "always",
      scope: { target: { mode: "exact", value: cmd }, operation: { mode: "exact", value: "run" } },
    },
  ]);

  send({ kind: "message", data: { role: "user", text: "tidy up again" } });
  const second = await eventsUntil((event) => event.kind === "tool_result");
  expect(second.filter((event) => event.kind === "approval_card")).toEqual([]);
  expect(ran(second)).toBe(true);
});

test("YOLO on from a phone applies at once with an expiry, everyone hears, and off is anyone's", async () => {
  const { dir, send, eventsUntil } = await pairedPhone([]);
  const mac = await macClient(dir);
  try {
    // Pairing is the grant: on, for eight hours, and everyone hears so.
    const before = Date.now();
    send({ kind: "approval_settings", data: { yolo: true, hours: 8 } });
    const on = (await eventsUntil((event) => event.kind === "approval_settings")).at(-1)!;
    if (on.kind !== "approval_settings") throw new Error("unreachable");
    expect(on.data.yolo).toBe(true);
    expect(on.data.yoloUntil).toBeGreaterThanOrEqual(before + 8 * HOUR_MS);
    expect(on.data.yoloUntil).toBeLessThanOrEqual(Date.now() + 8 * HOUR_MS);
    expect(approvalFile(dir)).toMatchObject({ yolo: true, yoloUntil: on.data.yoloUntil });
    await vi.waitFor(() => expect(mac.settings().at(-1)).toMatchObject({ data: { yolo: true, yoloUntil: on.data.yoloUntil } }));
    send({ kind: "approval_settings", data: {} });
    expect((await eventsUntil((event) => event.kind === "approval_settings")).at(-1)).toMatchObject({
      data: { yolo: true, yoloUntil: on.data.yoloUntil },
    });

    // Off from the phone, just the same.
    send({ kind: "approval_settings", data: { yolo: false } });
    expect((await eventsUntil((event) => event.kind === "approval_settings")).at(-1)).toMatchObject({ data: { yolo: false } });
    expect(approvalFile(dir)).toMatchObject({ yolo: false });
    expect(approvalFile(dir).yoloUntil).toBeUndefined();
    send({ kind: "approval_settings", data: {} });
    expect((await eventsUntil((event) => event.kind === "approval_settings")).at(-1)).toMatchObject({ data: { yolo: false } });
  } finally {
    mac.close();
  }
});

test("a YOLO grant is capped at a day, ends on its own, and the end is announced", async () => {
  const { dir, eventsUntil } = await pairedPhone([]);
  const mac = await macClient(dir);
  // Only the clock the grant is on: sockets and the relay's own housekeeping stay real.
  vi.useFakeTimers({ toFake: ["setTimeout", "clearTimeout"] });
  try {
    mac.send({ kind: "approval_settings", data: { yolo: true, hours: 100 } });
    const on = (await eventsUntil((event) => event.kind === "approval_settings")).at(-1)!;
    if (on.kind !== "approval_settings") throw new Error("unreachable");
    expect(on.data.yolo).toBe(true);
    expect(on.data.yoloUntil).toBeLessThanOrEqual(Date.now() + 24 * HOUR_MS);
    expect(on.data.yoloUntil).toBeGreaterThan(Date.now() + 23 * HOUR_MS);
    vi.advanceTimersByTime(24 * HOUR_MS);
    vi.useRealTimers();
    expect((await eventsUntil((event) => event.kind === "approval_settings")).at(-1)).toMatchObject({ data: { yolo: false } });
    expect(approvalFile(dir)).toMatchObject({ yolo: false });
    await vi.waitFor(() => expect(mac.settings().at(-1)).toMatchObject({ data: { yolo: false } }));
  } finally {
    vi.useRealTimers();
    mac.close();
  }
});

test("a YOLO grant on disk is back on the clock after a relaunch", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-yolo-restart-"));
  const yoloUntil = Date.now() + 2_000;
  writeFileSync(join(dir, "approval.json"), JSON.stringify({ yolo: true, yoloUntil, moneyThreshold: 0, confirmIrreversibleDeletes: true, rules: [] }));
  const { send, eventsUntil } = await pairedPhone([], false, { stateDir: dir });
  send({ kind: "approval_settings", data: {} });
  expect((await eventsUntil((event) => event.kind === "approval_settings")).at(-1)).toMatchObject({ data: { yolo: true, yoloUntil } });
  expect((await eventsUntil((event) => event.kind === "approval_settings")).at(-1)).toMatchObject({ data: { yolo: false } });
  expect(approvalFile(dir)).toMatchObject({ yolo: false });
}, 10_000);

test("19: the phone saves the rule its editor produced, widened past the one command", async () => {
  const first = "echo yorozu-editor-one";
  const second = "echo yorozu-editor-two";
  const { dir, send, eventsUntil, isReply } = await pairedPhone([
    () => shellTurn(first),
    () => sse("Done."),
    () => shellTurn(second),
    () => sse("Done again."),
  ]);

  send({ kind: "message", data: { role: "user", text: "tidy up" } });
  const shown = cardOf(await eventsUntil((event) => event.kind === "approval_card"));

  // What the editor sends back: the same rule with the target widened to a prefix.
  send({
    kind: "approval_answer",
    data: {
      actionId: shown.actionId,
      answer: "always",
      rule: {
        ...shown.suggestedRule!,
        scope: { target: { mode: "prefix", value: "echo yorozu-editor-" } },
      },
    },
  });
  await eventsUntil(isReply);

  expect(JSON.parse(readFileSync(join(dir, "approval.json"), "utf8")).rules).toMatchObject([
    { scope: { target: { mode: "prefix", value: "echo yorozu-editor-" } } },
  ]);

  // A different command the widened rule covers: no second card.
  send({ kind: "message", data: { role: "user", text: "and the other one" } });
  const tail = await eventsUntil((event) => event.kind === "tool_result");
  expect(tail.filter((event) => event.kind === "approval_card")).toEqual([]);
  expect(tail.at(-1)?.data.output).toContain("yorozu-editor-two");
});

test("YOLO granted while a card waits answers it, and the turn runs on", async () => {
  const cmd = "echo yorozu-yolo-late";
  const { dir, send, eventsUntil, isReply } = await pairedPhone([() => shellTurn(cmd), () => sse("Done.")]);
  const mac = await macClient(dir);

  send({ kind: "message", data: { role: "user", text: "tidy up" } });
  const shown = cardOf(await eventsUntil((event) => event.kind === "approval_card"));
  mac.send({ kind: "approval_settings", data: { yolo: true } });

  const rest = await eventsUntil(isReply);
  expect(rest).toContainEqual(expect.objectContaining({ kind: "approval_answer", data: { actionId: shown.actionId, answer: "yes" } }));
  expect(rest.find((event) => event.kind === "tool_result")?.data.output).toContain("yorozu-yolo-late");
  mac.close();
});

test("18: allow for this task covers the rest of the turn and expires with it", async () => {
  const cmd = "echo yorozu-task-ok";
  const { dir, send, eventsUntil, isReply } = await pairedPhone([
    () => shellTurn(cmd),
    // Same command again inside the same turn: the grant covers it, so no second card.
    () => shellTurn(cmd),
    () => sse("Done."),
    // A new turn, and the grant went with the old one.
    () => shellTurn(cmd),
    () => sse("Done again."),
  ]);

  send({ kind: "message", data: { role: "user", text: "tidy up twice" } });
  const shown = cardOf(await eventsUntil((event) => event.kind === "approval_card"));
  send({ kind: "approval_answer", data: { actionId: shown.actionId, answer: "task" } });

  const rest = await eventsUntil(isReply);
  expect(rest.filter((event) => event.kind === "approval_card")).toEqual([]);
  expect(rest.filter((event) => event.kind === "tool_result")).toHaveLength(2);
  // A bounded grant is not a rule: nothing was written down.
  expect(listRules(dir)).toEqual([]);

  send({ kind: "message", data: { role: "user", text: "again please" } });
  const next = await eventsUntil((event) => event.kind === "approval_card");
  expect(next.at(-1)).toMatchObject({ kind: "approval_card" });
});

test("22, 23: three approvals raise a proposal, and it activates nothing", async () => {
  const cmd = "echo yorozu-proposal-ok";
  const turns = [];
  for (let i = 0; i < 4; i++) turns.push(() => shellTurn(cmd), () => sse("Done."));
  const { dir, send, eventsUntil, isReply } = await pairedPhone(turns);

  const approveOnce = async (): Promise<YorozuEvent[]> => {
    send({ kind: "message", data: { role: "user", text: "tidy up" } });
    const shown = cardOf(await eventsUntil((event) => event.kind === "approval_card"));
    send({ kind: "approval_answer", data: { actionId: shown.actionId, answer: "yes" } });
    return eventsUntil(isReply);
  };

  expect((await approveOnce()).filter((e) => e.kind === "rule_proposal")).toEqual([]);
  expect((await approveOnce()).filter((e) => e.kind === "rule_proposal")).toEqual([]);
  const third = await approveOnce();

  const [proposal] = third.filter((event) => event.kind === "rule_proposal");
  expect(proposal).toMatchObject({
    kind: "rule_proposal",
    data: {
      approvals: 3,
      rule: {
        actionClass: "run-command",
        decision: "always",
        scope: { target: { mode: "exact", value: cmd } },
      },
    },
  });

  // Proposed, not stored, and not acting: the fourth still puts a card up.
  expect(listRules(dir)).toEqual([]);
  send({ kind: "message", data: { role: "user", text: "tidy up" } });
  expect((await eventsUntil((event) => event.kind === "approval_card")).at(-1)).toMatchObject({
    kind: "approval_card",
  });
});

test("21: rules are listed, saved and revoked over the wire", async () => {
  const { dir, send, eventsUntil } = await pairedPhone([]);

  const rules = async (): Promise<YorozuEvent[]> => {
    send({ kind: "rule_list", data: { rules: [] } });
    return eventsUntil((event) => event.kind === "rule_list");
  };

  expect((await rules()).at(-1)).toMatchObject({ kind: "rule_list", data: { rules: [] } });

  const saved = {
    id: "rule-1",
    actionClass: "send-message",
    decision: "always" as const,
    scope: { recipient: { mode: "exact" as const, value: "bob@example.com" } },
  };
  send({ kind: "rule_update", data: { rule: saved } });
  expect((await eventsUntil((event) => event.kind === "rule_list")).at(-1)).toMatchObject({
    data: { rules: [saved] },
  });
  expect(JSON.parse(readFileSync(join(dir, "approval.json"), "utf8")).rules).toMatchObject([saved]);

  // Switched off rather than revoked: the same id comes back with the flag on it.
  send({ kind: "rule_update", data: { rule: { ...saved, enabled: false } } });
  expect((await eventsUntil((event) => event.kind === "rule_list")).at(-1)).toMatchObject({
    data: { rules: [{ id: "rule-1", enabled: false }] },
  });

  send({ kind: "rule_delete", data: { ruleId: "rule-1" } });
  expect((await eventsUntil((event) => event.kind === "rule_list")).at(-1)).toMatchObject({
    data: { rules: [] },
  });
});

const suggestion: Rule = {
  id: "r1",
  actionClass: "purchase",
  decision: "always",
  scope: { merchant: { mode: "exact", value: "the corner shop" } },
};

const card: ApprovalCardData = {
  actionId: "a1",
  actionClass: "purchase",
  target: "the corner shop",
  suggestedRule: suggestion,
};

test.each<[string, AskResult | null]>([
  ["yes", { answer: "yes" }],
  ["sure", { answer: "yes" }],
  ["no", { answer: "no" }],
  ["nope", { answer: "no" }],
  // A bare "never" sounds permanent but is the one-off refusal: only the explicit wordings persist.
  ["never", { answer: "no" }],
  ["never mind", { answer: "no" }],
  // Permanent authority needs the rule editor; prose cannot choose scope dimensions safely.
  ["always", null],
  ["yes always", null],
  ["yes, always", null],
  ["yes and never ask", null],
  ["yes, and never ask again", null],
  ["never ask again", null],
  ["don't ask again", null],
  ["dont ask again", null],
  // The bounded grant, which in prose is only ever "for this task" and its neighbours.
  ["for this task", { answer: "task" }],
  ["yes, for this task", { answer: "task" }],
  ["just for this turn", { answer: "task" }],
  ["maybe later", null],
])("typedAnswer: %s", (text, expected) => {
  expect(typedAnswer(text, card)).toEqual(expected);
});

test("discuss leaves the action pending and the card comes back", async () => {
  const cmd = "rm -rf /tmp/yorozu-must-not-run-either";
  const { send, eventsUntil, isReply } = await pairedPhone([
    () => shellTurn(cmd),
    // Having explained itself, the agent tries again, which re-presents the card.
    () => shellTurn(cmd),
    () => sse("Understood, I will skip it."),
  ]);

  send({ kind: "message", data: { role: "user", text: "tidy up" } });

  const firstId = cardOf(await eventsUntil((event) => event.kind === "approval_card")).actionId;
  send({ kind: "approval_answer", data: { actionId: firstId, answer: "discuss" } });

  const second = await eventsUntil((event) => event.kind === "approval_card");
  expect(second.at(-1)).toMatchObject({
    kind: "approval_card",
    data: { actionClass: "run-command", target: cmd },
  });
  // A fresh action ID: the pending action was re-presented, not resumed.
  expect(cardOf(second).actionId).not.toBe(firstId);

  // A typed "no" in another thread is a message there, not an answer to this card.
  send({ kind: "message", data: { role: "user", text: "no" } }, "t2");
  await eventsUntil((event) => event.threadId === "t2" && event.kind === "message");
  // A typed "no" in the card's thread answers it just as the button would.
  const answerId = send({ kind: "message", data: { role: "user", text: "no" } });
  const tail = await eventsUntil(isReply);
  expect(tail.at(-1)).toMatchObject({ data: { role: "agent", text: "Understood, I will skip it." } });
  send({ kind: "admission_query", data: { eventId: answerId } });
  const status = (await eventsUntil((event) => event.kind === "admission_status")).at(-1);
  expect(status).toMatchObject({ kind: "admission_status", data: { eventId: answerId, status: "indeterminate" } });
  if (status?.kind !== "admission_status") throw new Error("missing admission status");
  expect(status.data.completionId).toBeUndefined();
});

test("a lock-screen answer is honoured only for a card the runtime judged quick", async () => {
  const cmd = "echo yorozu-quick";
  const { send, eventsUntil, isReply } = await pairedPhone([
    // A message to a person: never quick, whatever buttons a relay put under it.
    () => sendMessageTurn("bob"),
    () => sse("Not sent."),
    // A local command below every floor: quick.
    () => shellTurn(cmd),
    () => sse("Done."),
  ], false, {}, true);

  send({ kind: "message", data: { role: "user", text: "tell bob" } });
  const external = cardOf(await eventsUntil((event) => event.kind === "approval_card"));
  expect(external.actionClass).toBe("send-message");
  send({ kind: "approval_answer", data: { actionId: external.actionId, answer: "yes", source: "notification" } });
  // Refused: the card is still up, so the same answer from the card itself settles it.
  await eventsUntil((event) => event.kind === "approval_status" && event.data.actionId === external.actionId &&
    event.data.status === "rejected");
  send({ kind: "approval_answer", data: { actionId: external.actionId, answer: "no" } });
  await eventsUntil(isReply);

  send({ kind: "message", data: { role: "user", text: "run it" } });
  const local = cardOf(await eventsUntil((event) => event.kind === "approval_card"));
  send({ kind: "approval_answer", data: { actionId: local.actionId, answer: "yes", source: "notification" } });
  const tail = await eventsUntil(isReply);
  expect(tail.filter((event) => event.kind === "tool_result")).toHaveLength(1);
});

test("stale offline approval cannot act, and an applied answer replays without acting twice", async () => {
  const { dir, send, eventsUntil } = await pairedPhone([() => shellTurn("echo approval-once"), () => sse("done")], false, {}, true);
  send({ kind: "message", data: { role: "user", text: "run it" } });
  const card = cardOf(await eventsUntil((event) => event.kind === "approval_card"));
  const stale: YorozuEvent = { id: "stale-approval", threadId: "t1", ts: Date.now() - 31 * 60_000,
    agentId: "phone", kind: "approval_answer", data: { actionId: card.actionId, answer: "yes" } };
  sendRaw(stale);
  expect((await eventsUntil((event) => event.kind === "approval_status" && event.data.requestId === stale.id)).at(-1))
    .toMatchObject({ data: { status: "expired" } });
  const accepted: YorozuEvent = { ...stale, id: "fresh-approval", ts: Date.now() };
  sendRaw(accepted);
  expect((await eventsUntil((event) => event.kind === "approval_status" && event.data.requestId === accepted.id)).at(-1))
    .toMatchObject({ data: { status: "applied" } });
  expect(readThreadEvents("t1", dir)).toContainEqual(expect.objectContaining({ kind: "approval_status",
    data: { requestId: accepted.id, actionId: card.actionId, status: "applied" } }));
  await eventsUntil((event) => event.kind === "message" && event.data.role === "agent" && event.data.done === true);
  sendRaw(accepted);
  expect((await eventsUntil((event) => event.kind === "approval_status" && event.data.requestId === accepted.id)).at(-1))
    .toMatchObject({ data: { status: "applied" } });
});

test("routine sync carries a pending card from an archived thread", async () => {
  const { dir, send, eventsUntil } = await pairedPhone([() => shellTurn("echo archived-card")]);
  send({ kind: "thread_create", data: {} });
  await vi.waitFor(() => expect(listThreads(dir).some((thread) => thread.id === "t1")).toBe(true));
  send({ kind: "message", data: { role: "user", text: "run it" } });
  const card = (await eventsUntil((event) => event.kind === "approval_card")).at(-1)!;
  send({ kind: "thread_archive", data: { archived: true } });
  await vi.waitFor(() => expect(listThreads(dir).find((thread) => thread.id === "t1")?.archived).toBe(true));
  send({ kind: "sync_request", data: { lastSeen: {} } }, "");
  const delta = (await eventsUntil((event) => event.kind === "sync_delta")).at(-1)!;
  if (delta.kind !== "sync_delta") throw new Error("missing sync delta");
  expect(delta.data.events).toEqual([]);
  expect(delta.data.current).toContainEqual(card);
});

test("archived current cards honor the pairing cutoff", async () => {
  let pairedAt = 0;
  const runner: NativeAgentRunner = { run: async (turn) => {
    const clock = vi.spyOn(Date, "now").mockReturnValue(pairedAt - 1);
    const answer = turn.approve!("Bash", { command: "pwd" }, turn.signal);
    clock.mockRestore();
    await answer;
    return { text: "done", sessionId: "session" };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } });
  await vi.waitFor(() => expect(loadDevices(join(dir, "devices.json"))).toHaveLength(1));
  pairedAt = loadDevices(join(dir, "devices.json"))[0]!.pairedAt!;
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "native");
  await vi.waitFor(() => expect(listThreads(dir).some((thread) => thread.id === "native")).toBe(true));
  send({ kind: "message", data: { role: "user", text: "work" } }, "native");
  await vi.waitFor(() => expect(readThreadEvents("native", dir).some((event) => event.kind === "approval_card")).toBe(true));
  const card = readThreadEvents("native", dir).find((event) => event.kind === "approval_card")!;
  send({ kind: "thread_archive", data: { archived: true } }, "native");
  await vi.waitFor(() => expect(listThreads(dir).find((thread) => thread.id === "native")?.archived).toBe(true));
  send({ kind: "sync_request", data: { lastSeen: {} } }, "");
  const delta = (await eventsUntil((event) => event.kind === "sync_delta")).at(-1)!;
  if (delta.kind !== "sync_delta") throw new Error("missing sync delta");
  expect(delta.data.current ?? []).not.toContainEqual(card);
  if (card.kind === "approval_card") send({ kind: "approval_answer", data: { actionId: card.data.actionId, answer: "no" } }, "native");
});

test("older clients see an upgrade request instead of a false approval receipt", async () => {
  const { dir, send, eventsUntil } = await pairedPhone([() => shellTurn("echo legacy-approval"), () => sse("done")]);
  send({ kind: "message", data: { role: "user", text: "run it" } });
  const cardEvent = (await eventsUntil((event) => event.kind === "approval_card")).at(-1)!;
  const card = cardOf([cardEvent]);
  sendRaw({ id: "old-stale-answer", threadId: "t1", ts: Date.now() - 31 * 60_000,
    agentId: "phone", kind: "approval_answer", data: { actionId: card.actionId, answer: "yes" } });
  const response = await eventsUntil((event) => event.kind === "thought" && event.data.text.includes("Update Yorozu"));
  expect(response.some((event) => event.kind === "receipt" && event.data.eventId === "old-stale-answer")).toBe(false);
  expect(response.some((event) => event.kind === "approval_status")).toBe(false);
  sendRaw({ id: "forged-status", threadId: "t1", ts: Date.now(), agentId: "phone", kind: "approval_status",
    data: { requestId: "fake", actionId: card.actionId, status: "applied" } });
  for (let i = 0; i < 201; i++) {
    appendThreadEvent({ id: `status-${i}`, threadId: "t1", ts: Date.now(), agentId: "main",
      kind: "approval_status", data: { requestId: `old-${i}`, actionId: `old-action-${i}`, status: "expired" } }, dir);
  }
  send({ kind: "sync_request", data: { lastSeen: { t1: cardEvent.id }, threadId: "t1" } }, "");
  const replay = (await eventsUntil((event) => event.kind === "sync_delta")).at(-1);
  expect(replay?.kind).toBe("sync_delta");
  if (replay?.kind === "sync_delta") {
    expect(replay.data.events).toEqual([]);
    expect(replay.data.more).toBeUndefined();
  }
  expect(readThreadEvents("t1", dir).some((event) => event.id === "forged-status")).toBe(false);
});

test("a replayed command applies once, and every copy is receipted", async () => {
  const { dir, send, eventsUntil } = await pairedPhone([]);
  const saved = {
    id: "rule-1",
    actionClass: "send-message",
    decision: "always" as const,
    scope: { recipient: { mode: "exact" as const, value: "bob@example.com" } },
  };
  const update: YorozuEvent = {
    id: "cmd-1", threadId: "", ts: Date.now(), agentId: "phone", kind: "rule_update", data: { rule: saved },
  };
  sendRaw(update);
  const first = await eventsUntil((event) => event.kind === "rule_list");
  expect(first.find((event) => event.kind === "receipt")).toMatchObject({ data: { eventId: "cmd-1" } });

  // Revoked in between: a replay of the update must not bring the rule back.
  send({ kind: "rule_delete", data: { ruleId: "rule-1" } });
  await eventsUntil((event) => event.kind === "rule_list");
  sendRaw(update);
  const again = await eventsUntil((event) => event.kind === "receipt" && event.data.eventId === "cmd-1");
  expect(again.filter((event) => event.kind === "rule_list")).toEqual([]);
  expect(listRules(dir)).toEqual([]);
});

test("a delayed sealed message expires before host admission", async () => {
  const { dir, eventsUntil } = await pairedPhone([() => sse("must not run")]);
  createThread("Delayed", dir, "t1");
  const queuedAt = Date.now() - 31 * 60_000;
  sendRaw({ id: "delayed-expired", threadId: "t1", ts: queuedAt, agentId: "phone",
    kind: "message", data: { role: "user", text: "stale command",
      admissionDeadline: queuedAt + 30 * 60_000 } });
  const seen = await eventsUntil((event) => event.kind === "admission_status");
  expect(seen.at(-1)).toMatchObject({ kind: "admission_status",
    data: { eventId: "delayed-expired", status: "expired" } });
  expect(seen.some((event) => event.kind === "receipt" && event.data.eventId === "delayed-expired")).toBe(false);
  expect(readThreadEvents("t1", dir).some((event) => event.id === "delayed-expired")).toBe(false);
});

test("a conflicting retry cannot reuse a receipted user message ID", async () => {
  const { dir } = await pairedPhone([], true);
  createThread("Identity", dir, "identity");
  const mac = await macClient(dir);
  const first: YorozuEvent = {
    id: "same-message", threadId: "identity", ts: Date.now(), agentId: "mac",
    kind: "message", data: { role: "user", text: "first",
      attachments: [{ name: "a.txt", mime: "text/plain", data: "YQ==" }] },
  };
  try {
    mac.sendRawEvent(first);
    await vi.waitFor(() => expect(mac.events.filter((item) =>
      item.kind === "receipt" && item.data.eventId === first.id)).toHaveLength(1));
    mac.sendRawEvent({ ...first, data: { role: "user", text: "first",
      attachments: [{ data: "YQ==", mime: "text/plain", name: "a.txt" }] } });
    await vi.waitFor(() => expect(mac.events.filter((item) =>
      item.kind === "receipt" && item.data.eventId === first.id)).toHaveLength(2));
    mac.sendRawEvent({ ...first, data: { role: "user", text: "different",
      attachments: [{ name: "a.txt", mime: "text/plain", data: "YQ==" }] } });
    await vi.waitFor(() => expect(states).toContain("rejected-conflicting-message-id"));
    expect(mac.events.filter((item) => item.kind === "receipt" && item.data.eventId === first.id)).toHaveLength(2);
    expect(readThreadEvents(first.threadId, dir).filter((item) => item.id === first.id))
      .toMatchObject([{ data: { text: "first" } }]);
  } finally { mac.close(); }
});

test("a completed message ID remains bound to its thread across host restart", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-message-identity-"));
  createThread("Original", dir, "original");
  createThread("Other", dir, "other");
  appendThreadEvent({ id: "completed-id", threadId: "original", ts: Date.now(), agentId: "phone",
    kind: "message", data: { role: "user", text: "original" } }, dir);
  await pairedPhone([], true, { stateDir: dir });
  const mac = await macClient(dir);
  try {
    mac.sendRawEvent({ id: "completed-id", threadId: "other", ts: Date.now(), agentId: "mac",
      kind: "message", data: { role: "user", text: "original" } });
    await vi.waitFor(() => expect(states).toContain("rejected-conflicting-message-id"));
    expect(mac.events.some((item) => item.kind === "receipt" && item.data.eventId === "completed-id"))
      .toBe(false);
    expect(readThreadEvents("other", dir).filter((item) => item.id === "completed-id")).toEqual([]);
  } finally { mac.close(); }
});

/** Pairing burns a token, so the sidecar prints one QR per device that can still join. */
function qrQueue() {
  const printed: string[] = [];
  const waiting: ((qr: string) => void)[] = [];
  return {
    push(qr: string) {
      const waiter = waiting.shift();
      if (waiter) waiter(qr);
      else printed.push(qr);
    },
    next(): Promise<QrPayload> {
      const ready = printed.shift();
      return (ready ? Promise.resolve(ready) : new Promise<string>((r) => waiting.push(r))).then(
        decodeQrPayload,
      );
    },
  };
}

/** A fake phone: joins, says hello, then seals and opens events under its own session key. */
async function pairPhone(port: number, qr: QrPayload) {
  const { phone, keys } = await connectPhone(port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });
  const identity = generateKeypair();
  const channel = channelFor(identity.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(hello(qr, toBase64Url(identity.publicKey), keys.pub), keys);

  return {
    send(threadId: string, payload: EventPayload, ts = Date.now()): void {
      const event: YorozuEvent = { id: randomUUID(), threadId, ts, agentId: "phone", ...payload };
      phone.frame(channel.box(event), keys);
    },
    /** The next event of `kind` this phone can open: frames for the other device are not ours. */
    async next(kind: EventKind, observed?: YorozuEvent[]): Promise<YorozuEvent> {
      for (;;) {
        const frame = await phone.next();
        if (frame?.type !== "frame") continue;
        const body = frameBody(frame.payload);
        let event: YorozuEvent;
        try {
          event = channel.open(body);
        } catch {
          continue; // Sealed for the other phone.
        }
        observed?.push(event);
        if (event.kind === kind) return event;
      }
    },
  };
}

test("large historical attachment crosses relay as preview and bounded downloads", async () => {
  relay = await startRelay(0);
  const qrs = qrQueue();
  const dir = mkdtempSync(join(tmpdir(), "yorozu-download-"));
  createThread("Archive", dir, "archive");
  const bytes = Buffer.alloc(700_000, 42);
  appendThreadEvent({ id: "old-file", threadId: "archive", ts: 1, agentId: "phone",
    kind: "message", data: { role: "user", text: "photo", attachments: [{ name: "photo.png",
      mime: "image/png", data: bytes.toString("base64") }] } }, dir);
  sidecar = serve({ relayUrl: `ws://127.0.0.1:${relay.port}`, stateDir: dir,
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => sse("pong")) }),
    log: (line) => { if (line.startsWith("QR ")) qrs.push(line.slice(3)); } });
  const phone = await pairPhone(relay.port, await qrs.next());
  await phone.next("thread_list");
  phone.send("", { kind: "thread_list", data: { threads: [], peerInfo: localPeerInfo("0.3.0") } });
  await phone.next("thread_list");
  phone.send("archive", { kind: "sync_request", data: { lastSeen: {}, threadId: "archive" } });
  const delta = await phone.next("sync_delta");
  const preview = delta.kind === "sync_delta" ? delta.data.events.find((item) => item.id === "old-file") : undefined;
  expect(preview).toMatchObject({ kind: "message", data: { attachments: [{ name: "photo.png",
    data: "", sizeBytes: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") }] } });
  const received: Buffer[] = [];
  for (let offset = 0; offset < bytes.length; offset += 256 * 1024) {
    phone.send("archive", { kind: "attachment_download_request", data: { messageId: "old-file", index: 0, offset } });
    const chunk = await phone.next("attachment_download_chunk");
    expect(chunk).toMatchObject({ data: { messageId: "old-file", index: 0, offset, totalBytes: bytes.length } });
    if (chunk.kind === "attachment_download_chunk") received.push(Buffer.from(chunk.data.data, "base64"));
  }
  expect(Buffer.concat(received)).toEqual(bytes);
  const oldPhone = await pairPhone(relay.port, await qrs.next());
  await oldPhone.next("thread_list");
  const oldInfo = localPeerInfo("0.3.0");
  oldInfo.capabilities = oldInfo.capabilities.filter((capability) => capability !== "attachment-chunks-v1");
  oldPhone.send("", { kind: "thread_list", data: { threads: [], peerInfo: oldInfo } });
  await oldPhone.next("thread_list");
  oldPhone.send("archive", { kind: "sync_request", data: { lastSeen: {}, threadId: "archive" } });
  const oldDelta = await oldPhone.next("sync_delta");
  const oldPreview = oldDelta.kind === "sync_delta" ? oldDelta.data.events.find((item) => item.id === "old-file") : undefined;
  expect(oldPreview).toMatchObject({ kind: "message", data: { attachments: [{
    data: `yorozu-deferred-v1:${bytes.length}:${createHash("sha256").update(bytes).digest("hex")}`,
  }] } });
  const local = await new Promise<ReturnType<typeof createConnection>>((resolve, reject) => {
    const socket = createConnection(localSocketPath(dir));
    socket.once("connect", () => resolve(socket));
    socket.once("error", reject);
  });
  local.write(`${JSON.stringify({ id: "live-file", threadId: "archive", ts: Date.now(), agentId: "mac",
    kind: "message", data: { role: "user", text: "new photo", attachments: [{ name: "new.png",
      mime: "image/png", data: bytes.toString("base64") }] } })}\n`);
  const live = await phone.next("message");
  expect(live).toMatchObject({ id: "live-file", data: { attachments: [{ data: "", sizeBytes: bytes.length }] } });
  local.destroy();
});

test("old relay terminal requests are refused without creating sessions", async () => {
  relay = await startRelay(0);
  const qrs = qrQueue();
  const dir = mkdtempSync(join(tmpdir(), "yorozu-terminal-removed-"));
  writeFileSync(join(dir, "terminal-settings.json"), JSON.stringify({ enabled: true }));
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: dir,
    log: (line) => { if (line.startsWith("QR ")) qrs.push(line.slice(3)); },
  });
  const phone = await pairPhone(relay.port, await qrs.next());
  await phone.next("device_list");
  phone.send("t1", { kind: "terminal", data: { action: "create", cols: 80, rows: 24 } } as unknown as EventPayload);
  expect(await phone.next("terminal" as EventKind)).toMatchObject({
    threadId: "t1", data: { action: "error", error: "Remote terminal is no longer available. Update Yorozu." },
  });
  expect(readThreadEvents("t1", dir)).toEqual([]);
  expect(existsSync(join(dir, "terminal-settings.json"))).toBe(false);
});

test.each([true, false])("peer metadata follows an encrypted handshake (host-name=%s)", async (hostName) => {
  relay = await startRelay(0);
  const qrs = qrQueue();
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-peer-info-")),
    appVersion: "0.3.0",
    computerName: () => "Studio Mac",
    log: (line) => { if (line.startsWith("QR ")) qrs.push(line.slice(3)); },
  });
  const qr = await qrs.next();
  expect(JSON.stringify(qr)).not.toContain("Studio Mac");
  const phone = await pairPhone(relay.port, qr);
  const greeting = await phone.next("thread_list");
  expect(greeting.data).toMatchObject({ threads: [], peerInfoSupported: true });
  expect(greeting.data).not.toHaveProperty("peerInfo");

  const peerInfo = localPeerInfo("0.3.1");
  if (!hostName) peerInfo.capabilities = peerInfo.capabilities.filter((capability) => capability !== "host-name");
  phone.send("", { kind: "thread_list", data: { threads: [], peerInfo } });
  expect(await phone.next("thread_list")).toMatchObject({
    data: { peerInfo: localPeerInfo("0.3.0", hostName ? "Studio Mac" : undefined) },
  });
  // The subsequent list request is still the existing command, with negotiation remembered.
  phone.send("", { kind: "thread_list", data: { threads: [] } });
  const listed = await phone.next("thread_list");
  expect(listed.data).toMatchObject({ peerInfo: localPeerInfo("0.3.0", hostName ? "Studio Mac" : undefined) });
  if (!hostName) expect(listed.data).not.toHaveProperty("peerInfo.computerName");
});

test.each(["replayed hello", "runtime restart"])("negotiated phones cannot downgrade after %s", async (reset) => {
  relay = await startRelay(0);
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-peer-downgrade-"));
  const fetchMock = vi.fn<typeof fetch>().mockImplementation(async () => sse("pong"));
  const start = () => {
    let printed!: (qr: string) => void;
    const qr = new Promise<string>((resolve) => (printed = resolve));
    const cast = serve({
      relayUrl: `ws://127.0.0.1:${relay.port}`,
      stateDir,
      appVersion: "0.3.0",
      computerName: () => "Private Mac",
      provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: fetchMock }),
      log: (line) => { if (line.startsWith("QR ")) printed(line.slice(3)); },
    });
    return { cast, qr };
  };
  const first = start();
  sidecar = first.cast;
  const qr = decodeQrPayload(await first.qr);
  const joined = await connectPhone(relay.port, qr.roomId!, qr.token);
  let phone = joined.phone;
  const { keys } = joined;
  expect(await phone.next()).toMatchObject({ type: "joined" });
  const identity = generateKeypair();
  const pub = toBase64Url(identity.publicKey);
  const channel = channelFor(identity.privateKey, fromBase64Url(qr.macPubkey));
  const legacyChannel = legacyChannelFor(identity.privateKey, fromBase64Url(qr.macPubkey));
  const initialHello = hello(qr, pub, keys.pub);
  const next = async (kind: EventKind): Promise<YorozuEvent> => {
    for (;;) {
      const event = await nextEvent(phone, channel);
      if (event.kind === kind) return event;
    }
  };
  const send = (id: string, threadId: string, payload: EventPayload): void =>
    phone.frame(channel.box({ id, threadId, ts: Date.now(), agentId: "phone", ...payload }), keys);
  phone.frame(initialHello, keys);
  await next("device_list");

  // Capture an actual command from before this phone upgraded to negotiated, sequenced boxes.
  createThread("Before upgrade", stateDir, "old-thread");
  const oldBox = legacyChannel.box({ id: "old-command", threadId: "old-thread", ts: Date.now(),
    agentId: "phone", kind: "message", data: { role: "user", text: "before upgrade" } });
  phone.frame(oldBox, keys);
  for (;;) {
    let event: YorozuEvent;
    try { event = legacyChannel.open(frameBody((await phone.next()).payload)); }
    catch { continue; }
    if (event.kind === "message" && event.data.role === "agent" && event.data.done) break;
  }
  send("negotiate", "", { kind: "thread_list", data: { threads: [], peerInfo: localPeerInfo("0.3.1") } });
  expect(await next("thread_list")).toMatchObject({
    data: { threads: [{ id: "old-thread" }], peerInfo: localPeerInfo("0.3.0", "Private Mac") },
  });
  expect(loadDevices(join(stateDir, "devices.json"))[0]).toMatchObject({ pub, peerInfoRequired: true });

  if (reset === "runtime restart") {
    phone.ws.close();
    await sidecar.close();
    const restarted = start();
    sidecar = restarted.cast;
    await restarted.qr;
    phone = await rejoinPhone(relay.port, qr.roomId!, keys);
    expect(await phone.next()).toMatchObject({ type: "joined" });
  } else {
    // This exact hello was already consumed. It contains no authenticated capability claim.
    phone.frame(initialHello, keys);
    const greeting = await next("thread_list");
    expect(greeting.data).toMatchObject({ threads: [], peerInfoSupported: true });
    expect(greeting.data).not.toHaveProperty("peerInfo");
  }
  expect(loadDevices(join(stateDir, "devices.json"))[0]).toMatchObject({ pub, peerInfoRequired: true });
  phone.frame(oldBox, keys);
  phone.frame(legacyChannel.box({ id: "legacy-forbidden", threadId: "legacy-forbidden", ts: Date.now(),
    agentId: "phone", kind: "message", data: { role: "user", text: "must not run" } }), keys);
  send("modern-held", "modern-held", { kind: "message", data: { role: "user", text: "must wait" } });
  await vi.waitFor(() => expect(loadChannelSeqs(join(stateDir, "channel-seq.json"))?.[pub]?.recvSeq).toBe(2));
  expect(fetchMock).toHaveBeenCalledTimes(1);
  expect(readThreadEvents("old-thread", stateDir).filter((event) => event.id === "old-command")).toHaveLength(1);
  expect(readThreadEvents("legacy-forbidden", stateDir)).toEqual([]);
  expect(readThreadEvents("modern-held", stateDir)).toEqual([]);

  send("renegotiate", "", { kind: "thread_list", data: { threads: [], peerInfo: localPeerInfo("0.3.1") } });
  expect(await next("thread_list")).toMatchObject({
    data: { threads: [{ id: "old-thread" }], peerInfo: localPeerInfo("0.3.0", "Private Mac") },
  });
  send("after-renegotiation", "working-thread", { kind: "message", data: { role: "user", text: "ping" } });
  expect(await next("message")).toMatchObject({ threadId: "working-thread", data: { role: "user", text: "ping" } });
  expect(await next("message")).toMatchObject({ threadId: "working-thread", data: { role: "agent", text: "pong" } });
  expect(fetchMock).toHaveBeenCalledTimes(2);
});

test.each([
  ["unsupported protocol", { ...localPeerInfo("0.4.0"), protocolMin: 2, protocolMax: 2 }],
  ["unknown required capability", { ...localPeerInfo("0.4.0"),
    capabilities: [...localPeerInfo("0.4.0").capabilities, "future-capability"], requiredCapabilities: ["future-capability"] }],
  ["malformed metadata", { ...localPeerInfo("0.4.0"), protocolMin: "1" }],
])("%s blocks only its own paired device", async (_reason, peerInfo) => {
  relay = await startRelay(0);
  const qrs = qrQueue();
  const lines: string[] = [];
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-peer-incompatible-"));
  const fetchMock = vi.fn<typeof fetch>().mockImplementation(async () => sse("pong"));
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir,
    appVersion: "0.3.0",
    computerName: () => "Private Mac",
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: fetchMock }),
    log: (line) => {
      lines.push(line);
      if (line.startsWith("QR ")) qrs.push(line.slice(3));
    },
  });
  const blocked = await pairPhone(relay.port, await qrs.next());
  await blocked.next("thread_list");
  const blockedPub = loadDevices(join(stateDir, "devices.json"))[0]!.pub;
  const healthy = await pairPhone(relay.port, await qrs.next());
  await healthy.next("thread_list");

  blocked.send("", { kind: "thread_list", data: { threads: [], peerInfo } } as EventPayload);
  const refused = await blocked.next("thread_list");
  expect(refused.data).toMatchObject({ peerInfo: localPeerInfo("0.3.0") });
  expect(refused.data).not.toHaveProperty("peerInfo.computerName");
  expect(lines).toContain("STATE peer-update-required");
  blocked.send("blocked-thread", { kind: "thread_create", data: {} });
  blocked.send("blocked-thread", { kind: "message", data: { role: "user", text: "must not run" } });
  await vi.waitFor(() => expect(loadChannelSeqs(join(stateDir, "channel-seq.json"))?.[blockedPub]?.recvSeq).toBe(3));

  healthy.send("", { kind: "thread_list", data: { threads: [], peerInfo: localPeerInfo("0.3.1") } });
  expect(await healthy.next("thread_list")).toMatchObject({ data: { peerInfo: localPeerInfo("0.3.0", "Private Mac") } });
  healthy.send("healthy-thread", { kind: "message", data: { role: "user", text: "ping" } });
  expect(await healthy.next("message")).toMatchObject({ threadId: "healthy-thread", data: { role: "user", text: "ping" } });
  expect(await healthy.next("message")).toMatchObject({ threadId: "healthy-thread", data: { role: "agent", text: "pong" } });
  expect(fetchMock).toHaveBeenCalledTimes(1);
  expect(listThreads(stateDir).some((thread) => thread.id === "blocked-thread")).toBe(false);
  expect(readThreadEvents("blocked-thread", stateDir)).toEqual([]);
});

test("two phones pair at once and see the same threads, events and deltas", async () => {
  relay = await startRelay(0);
  const qrs = qrQueue();

  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-serve-")),
    provider: openaiCompat({
      baseUrl: "https://example.invalid",
      model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => sse("pong")),
    }),
    log: (line) => {
      if (line.startsWith("QR ")) qrs.push(line.slice(3));
    },
  });

  const first = await pairPhone(relay.port, await qrs.next());
  // The first pairing burnt that token; the sidecar minted the next one for the second phone.
  const second = await pairPhone(relay.port, await qrs.next());

  // Nothing has happened in this state dir, so the greeting is an empty list.
  for (const phone of [first, second]) {
    expect(await phone.next("thread_list")).toMatchObject({ data: { threads: [] } });
  }

  // A draft on the first phone: the id is the device's, and the message follows the create.
  const chat = "draft-1";
  first.send(chat, { kind: "thread_create", data: {} });
  for (const phone of [first, second]) {
    expect(await phone.next("thread_list")).toMatchObject({ data: { threads: [{ id: chat }] } });
  }

  // A turn started on one phone is visible in full on both: prompt, then answer.
  first.send(chat, { kind: "message", data: { role: "user", text: "ping" } });
  for (const phone of [first, second]) {
    expect(await phone.next("message")).toMatchObject({
      threadId: chat,
      data: { role: "user", text: "ping" },
    });
    expect(await phone.next("message")).toMatchObject({
      threadId: chat,
      data: { role: "agent", text: "pong" },
    });
  }

  // So is a thread created on either of them.
  second.send("draft-2", { kind: "thread_create", data: { title: "Groceries" } });
  const [listed, alsoListed] = [await first.next("thread_list"), await second.next("thread_list")];
  expect(listed).toEqual(alsoListed);
  const groceries = "draft-2";

  second.send(groceries, { kind: "message", data: { role: "user", text: "milk" } });
  expect(await second.next("message")).toMatchObject({ threadId: groceries, data: { role: "user", text: "milk" } });
  expect(await second.next("message")).toMatchObject({ threadId: groceries });

  // A device that holds nothing gets every thread's history in one delta, newest thread first.
  first.send(chat, { kind: "sync_request", data: { lastSeen: {} } });
  const delta = await first.next("sync_delta");
  expect(delta).toMatchObject({ data: { workingThreadIds: [] } });
  expect(
    delta.kind === "sync_delta" &&
      delta.data.events.map((e) => `${e.threadId}:${e.kind === "message" ? e.data.text : e.kind}`),
  ).toEqual([
    `${groceries}:milk`,
    `${groceries}:pong`,
    `${chat}:ping`,
    `${chat}:pong`,
  ]);

  // And a delta from a known id is only what came after it.
  first.send(chat, { kind: "sync_request", data: { lastSeen: { [chat]: "nope" } } });
  expect((await first.next("sync_delta")).kind).toBe("sync_delta");

  // Any thread archives now, for every device at once.
  first.send(chat, { kind: "thread_archive", data: {} });
  expect(await second.next("thread_list")).toMatchObject({
    data: { threads: [{ id: groceries, archived: false }, { id: chat, archived: true }] },
  });

  // Read state is the runtime's: the phone that read the thread says so, and the *other* phone
  // is told — which is the whole point, because that is the device with a dot on it.
  const nextGroceries = async () => {
    const listed = await second.next("thread_list");
    return listed.kind === "thread_list"
      ? listed.data.threads.find((thread) => thread.id === groceries)
      : undefined;
  };

  first.send(groceries, { kind: "thread_read", data: { at: 5_000_000_000_000 } });
  expect((await nextGroceries())?.lastReadAt).toBe(5_000_000_000_000);

  // A report that would walk the mark backwards changes nothing and is not worth a list, so
  // the next one either phone sees is the rename below rather than an echo of this.
  first.send(groceries, { kind: "thread_read", data: { at: 1 } });
  first.send(groceries, { kind: "thread_rename", data: { title: "Food" } });
  expect(await nextGroceries()).toMatchObject({
    title: "Food",
    lastReadAt: 5_000_000_000_000,
  });

  // Mark as unread explicitly resets the mark, including on the other device.
  first.send(groceries, { kind: "thread_read", data: { at: 1, reset: true } });
  const unread = await nextGroceries();
  expect(unread?.lastReadAt).toBe(1);
  expect(unread?.lastAgentAt).toBeGreaterThan(1);
});

test("a burst of durable events reaches both phones without exhausting the relay", async () => {
  relay = await startRelay(0);
  const qrs = qrQueue();
  const runner: NativeAgentRunner = { run: async (turn) => {
    for (let i = 0; i < 30; i++) turn.onActivity?.(`thought-${i}`, { kind: "thought", data: { text: `step ${i}` } });
    return { text: "finished" };
  } };
  sidecar = serve({ relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-batch-serve-")), nativeRunners: { codex: runner },
    log: (line) => { if (line.startsWith("QR ")) qrs.push(line.slice(3)); } });
  const first = await pairPhone(relay.port, await qrs.next());
  const second = await pairPhone(relay.port, await qrs.next());
  await first.next("thread_list");
  await second.next("thread_list");
  first.send("cc", { kind: "thread_create", data: { agent: "codex", cwd: proj } });
  await first.next("thread_list");
  await second.next("thread_list");
  first.send("cc", { kind: "message", data: { role: "user", text: "work" } });
  for (const phone of [first, second]) {
    expect(await phone.next("message")).toMatchObject({ data: { role: "user", text: "work" } });
    const seen: YorozuEvent[] = [];
    expect(await phone.next("message", seen)).toMatchObject({ data: { role: "agent", text: "finished", done: true } });
    expect(seen.filter((event) => event.kind === "thought")).toHaveLength(30);
  }
});

test("a newly paired phone fetches old history only for an opened thread", async () => {
  relay = await startRelay(0);
  const qrs = qrQueue();
  sidecar = serve({
    // A title is thread metadata every device is meant to see; it is the events under test,
    // so the title is kept clear of the prompt's words.
    titler: async () => "Earlier chat",
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-serve-")),
    provider: openaiCompat({
      baseUrl: "https://example.invalid",
      model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => sse("pong")),
    }),
    log: (line) => {
      if (line.startsWith("QR ")) qrs.push(line.slice(3));
    },
  });

  const first = await pairPhone(relay.port, await qrs.next());
  await first.next("thread_list");
  const chat = "before-second-pairing";
  first.send(chat, { kind: "thread_create", data: {} });
  await first.next("thread_list");
  first.send(chat, { kind: "message", data: { role: "user", text: "old prompt" } });
  await first.next("message");
  await first.next("message");
  const other = "unopened-thread";
  first.send(other, { kind: "thread_create", data: {} });
  await first.next("thread_list");
  first.send(other, { kind: "message", data: { role: "user", text: "private to unopened thread" } });
  await first.next("message");
  await first.next("message");

  await new Promise((resolve) => setTimeout(resolve, 2));
  const second = await pairPhone(relay.port, await qrs.next());
  const greeting = await second.next("thread_list");
  expect(JSON.stringify(greeting)).not.toContain("old prompt");
  second.send(chat, { kind: "sync_request", data: { lastSeen: {} } });
  expect(await second.next("sync_delta")).toMatchObject({ data: { events: [] } });
  second.send(chat, { kind: "sync_request", data: { lastSeen: {}, threadId: chat } });
  const history = await second.next("sync_delta");
  expect(history).toMatchObject({ data: { threadId: chat } });
  expect(history.kind === "sync_delta" && history.data.events.map((event) => event.threadId)).toEqual([chat, chat]);
  expect(JSON.stringify(history)).toContain("old prompt");
  expect(JSON.stringify(history)).not.toContain("private to unopened thread");

  // An older offline outbox message must not evade the cutoff through live broadcast.
  first.send(chat, { kind: "message", data: { role: "user", text: "old offline prompt" } }, 1);
  expect(await second.next("message")).toMatchObject({ data: { role: "agent", text: "pong" } });

  first.send(chat, { kind: "message", data: { role: "user", text: "new prompt" } });
  expect(await second.next("message")).toMatchObject({
    threadId: chat,
    data: { role: "user", text: "new prompt" },
  });
});


/** The threads of the next non-empty list: the pairing greeting on a fresh state dir has none. */
async function threadsAfter(
  eventsUntil: (done: (event: YorozuEvent) => boolean) => Promise<YorozuEvent[]>,
): Promise<{ id: string; title: string }[]> {
  const seen = await eventsUntil(
    (event) => event.kind === "thread_list" && event.data.threads.length > 0,
  );
  const last = seen.at(-1)!;
  return last.kind === "thread_list" ? last.data.threads : [];
}

const storedThreads = (dir: string): { title: string }[] =>
  JSON.parse(readFileSync(join(dir, "threads.json"), "utf8")) as { title: string }[];

test("the first message names an untitled thread, and no later turn renames it", async () => {
  const { dir, send, eventsUntil, isReply } = await pairedPhone(
    [() => sse("Sure — milk and eggs."), () => sse("Added bread.")],
    false,
    // The on-device model answers alongside the turn — with the quotes and the full stop it
    // was told not to use.
    { titler: async () => '"Groceries for the week."\n' },
  );

  // Nobody is asked for a title: the thread arrives empty and the lists draw a placeholder.
  send({ kind: "thread_create", data: {} });
  const [created] = await threadsAfter(eventsUntil);
  expect(created!.title).toBe("");

  send({ kind: "message", data: { role: "user", text: "buy milk" } }, created!.id);
  // The title lands in a fresh list, alongside the turn: usually before the reply, never
  // guaranteed to.
  const titled = (event: YorozuEvent): boolean =>
    event.kind === "thread_list" && event.data.threads[0]?.title === "Groceries for the week";
  const seen = await eventsUntil(titled);
  expect(seen.at(-1)).toMatchObject({ data: { threads: [expect.objectContaining({ id: created!.id })] } });
  if (!seen.some(isReply)) await eventsUntil(isReply);

  // Titling spends no completion on the chain, so the queued second response is this reply.
  send({ kind: "message", data: { role: "user", text: "and bread" } }, created!.id);
  const second = await eventsUntil(isReply);
  expect(second.at(-1)).toMatchObject({ data: { role: "agent", text: "Added bread." } });
  expect(storedThreads(dir)[0]!.title).toBe("Groceries for the week");
});

test("a revoked device is forgotten here and at the relay", async () => {
  relay = await startRelay(0);
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-revoke-"));

  let qrLine!: (line: string) => void;
  const qrPrinted = new Promise<string>((resolve) => (qrLine = resolve));
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir,
    provider: openaiCompat({
      baseUrl: "https://example.invalid",
      model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => sse("pong")),
    }),
    log: (line) => {
      if (line.startsWith("QR ")) qrLine(line.slice(3));
    },
  });

  const qr = decodeQrPayload(await qrPrinted);
  const { phone, keys } = await connectPhone(relay.port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });

  // The `hello` carries the relay identity as well as the session key: revoking a device at
  // the relay is addressed to the Ed25519 key, which cannot be derived from the other one.
  const phoneKeys = generateKeypair();
  const channel = channelFor(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  const pub = toBase64Url(phoneKeys.publicKey);
  phone.frame(hello(qr, pub, keys.pub), keys);
  const devicesFile = join(stateDir, "devices.json");
  await vi.waitFor(() =>
    expect(loadDevices(devicesFile)).toMatchObject([{ pub, signingPub: keys.pub }]),
  );

  // Sent as the Mac app sends it, which is the same handler either way in.
  const remove: YorozuEvent = {
    id: "r1",
    threadId: "",
    ts: 3,
    agentId: "mac",
    kind: "device_remove",
    data: { pub },
  };
  phone.frame(channel.box(remove), keys);

  await vi.waitFor(() => expect(loadDevices(devicesFile)).toEqual([]));
  // And the relay has forgotten it too: the nonce rejoin a known device may make is refused.
  const again = await rejoinPhone(relay.port, qr.roomId!, keys);
  expect(await again.closed).toBe(4001);
});

test("a relay that stops answering the heartbeat is treated as gone, and re-registered with", async () => {
  // The live bug this exists for: something between the Mac and the relay drops a quiet socket,
  // the relay tells every phone the Mac is offline, and this process keeps a socket that still
  // looks open and never learns otherwise — so the phone stays wrong until the app is restarted.
  // A deaf relay stands in for that: it accepts and registers, then ignores every ping.
  const deaf = new WebSocketServer({ port: 0 });
  const registrations: number[] = [];
  deaf.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as { type: string };
      // Everything answered as usual except the heartbeat, which falls into a hole.
      if (msg.type === "register") {
        registrations.push(Date.now());
        ws.send(JSON.stringify({ type: "registered", roomId: "r" }));
      }
    });
  });
  const port = (deaf.address() as AddressInfo).port;

  const states: string[] = [];
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-heartbeat-")),
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
    heartbeat: { pingMs: 30, pongMs: 30 },
    log: (line) => void states.push(line),
  });

  // Two registrations means the first socket was given up on and redialled, which is the whole
  // point: a re-register is what puts the room's presence right again.
  await vi.waitFor(() => expect(registrations.length).toBeGreaterThanOrEqual(2), { timeout: 5_000 });
  expect(states).toContain("STATE heartbeat-timeout");

  await new Promise<void>((done) => deaf.close(() => done()));
});

test("a relay that answers the heartbeat is left connected", async () => {
  relay = await startRelay(0);
  const states: string[] = [];
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-heartbeat-ok-")),
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
    heartbeat: { pingMs: 20, pongMs: 200 },
    log: (line) => void states.push(line),
  });

  await vi.waitFor(() => expect(states).toContain("STATE registered"));
  // Long enough for a good few ping/pong rounds: the socket must survive all of them.
  await new Promise((r) => setTimeout(r, 300));
  expect(states).not.toContain("STATE heartbeat-timeout");
  expect(states.filter((line) => line === "STATE registered")).toHaveLength(1);
});

test("announces the paired list to the relay as soon as it has registered", async () => {
  // The relay's known-device set is rebuilt from `devices.json`, so a relay that lost its
  // storage stops refusing every rejoin with a 4001 the moment the Mac comes back.
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-announce-"));
  const signingPubs = ["kBxLN8wYlBCk9nTYMhHsO6D5Hhw4EJOa2OBCnmHRLkA", "Zm9vYmFyZm9vYmFy"];
  const devices = signingPubs.map((signingPub, i) => ({
    pub: toBase64Url(generateKeypair().publicKey),
    signingPub,
    lastSeen: i,
  }));
  writeFileSync(join(stateDir, "devices.json"), JSON.stringify(devices));

  const seen: Record<string, unknown>[] = [];
  const fake = new WebSocketServer({ port: 0 });
  fake.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Record<string, unknown>;
      seen.push(msg);
      if (msg.type === "register") ws.send(JSON.stringify({ type: "registered", roomId: "r" }));
    });
  });

  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${(fake.address() as AddressInfo).port}`,
    stateDir,
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
    log: () => {},
  });

  await vi.waitFor(() => expect(seen.map((msg) => msg.type)).toContain("devices"));
  expect(seen.find((msg) => msg.type === "devices")).toEqual({
    type: "devices",
    devices: signingPubs,
  });
  // After the registration, not before it: the relay refuses the frame on a socket that has
  // not registered yet.
  expect(seen.findIndex((msg) => msg.type === "devices")).toBeGreaterThan(
    seen.findIndex((msg) => msg.type === "register"),
  );

  // `close()` waits on the open sockets, and this sidecar's is one of them.
  await sidecar.close();
  await new Promise<void>((done) => fake.close(() => done()));
});

test.each([
  ["the relay counts one", { type: "phones", count: 1 }],
  ["a live frame arrives from one", { type: "frame", payload: "not-a-frame" }],
])("nothing is streamed into a room the relay says is empty, until %s", async (_how, arrival) => {
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-empty-room-"));
  createThread("Home", stateDir, "quiet-thread");
  writeFileSync(join(stateDir, "devices.json"), JSON.stringify([
    { pub: toBase64Url(generateKeypair().publicKey), signingPub: "phone", pairedAt: 1, lastSeen: 1 },
  ]));
  const seen: Record<string, unknown>[] = [];
  const lines: string[] = [];
  const fake = new WebSocketServer({ port: 0 });
  let macSocket!: import("ws").WebSocket;
  fake.on("connection", (ws) => {
    macSocket = ws;
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Record<string, unknown>;
      seen.push(msg);
      if (msg.type === "register") ws.send(JSON.stringify({ type: "registered", roomId: "r", phones: 0 }));
    });
  });
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${(fake.address() as AddressInfo).port}`,
    stateDir,
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: async () => sse("answered") }),
    log: (line) => void lines.push(line),
  });
  const local = createConnection(localSocketPath(stateDir));
  local.on("data", () => {});
  const finals = (): number => readThreadEvents("quiet-thread", stateDir)
    .filter((event) => event.kind === "message" && event.data.role === "agent" && event.data.done).length;
  const ask = (id: string): void => void local.write(JSON.stringify({ id, threadId: "quiet-thread", ts: Date.now(), agentId: "mac", kind: "message", data: { role: "user", text: "hello" } }) + "\n");
  try {
    await vi.waitFor(() => expect(seen.some((msg) => msg.type === "devices")).toBe(true));
    ask("unheard");
    await vi.waitFor(() => expect(finals()).toBe(1));
    // The wake still goes out: a phone that is away is exactly who a notification is for.
    await vi.waitFor(() => expect(seen.some((msg) => msg.type === "notify")).toBe(true));
    expect(seen.filter((msg) => msg.type === "frame")).toHaveLength(0);

    // The socket is read in order, so a pairing string drawn from the token that follows the
    // arrival is proof the arrival has been taken in.
    const drawn = lines.filter((line) => line.startsWith("PAIR ")).length;
    macSocket.send(JSON.stringify(arrival));
    macSocket.send(JSON.stringify({ type: "token", token: "t" }));
    await vi.waitFor(() => expect(lines.filter((line) => line.startsWith("PAIR "))).toHaveLength(drawn + 1));
    ask("heard");
    await vi.waitFor(() => expect(finals()).toBe(2));
    await vi.waitFor(() => expect(seen.map((msg) => msg.type)).toContain("frame"));
  } finally {
    local.destroy();
    await sidecar.close();
    await new Promise<void>((done) => fake.close(() => done()));
  }
});

test("an open relay socket holds notifications until registration completes", async () => {
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-registering-"));
  createThread("Home", stateDir, "early-thread");
  const identity = generateKeypair();
  const removed = toBase64Url(generateKeypair().publicKey);
  writeFileSync(join(stateDir, "devices.json"), JSON.stringify([
    { pub: toBase64Url(identity.publicKey), signingPub: "phone", pairedAt: 1, lastSeen: 1 },
    { pub: removed, signingPub: "removed-phone", pairedAt: 1, lastSeen: 1 },
  ]));
  const seen: Record<string, unknown>[] = [];
  const fake = new WebSocketServer({ port: 0 });
  let macSocket!: import("ws").WebSocket;
  fake.on("connection", (ws) => {
    macSocket = ws;
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => seen.push(JSON.parse(data.toString())));
  });
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${(fake.address() as AddressInfo).port}`,
    stateDir,
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: async () => sse("answered before registration") }),
    log: () => {},
  });
  const local = createConnection(localSocketPath(stateDir));
  local.on("data", () => {});
  try {
    await vi.waitFor(() => expect(seen.some((msg) => msg.type === "register")).toBe(true));
    local.write(JSON.stringify({ id: "early-turn", threadId: "early-thread", ts: Date.now(), agentId: "mac", kind: "message", data: { role: "user", text: "hello" } }) + "\n");
    await vi.waitFor(() => expect(readThreadEvents("early-thread", stateDir).some((event) => event.kind === "message" && event.data.done)).toBe(true));
    local.write(JSON.stringify({ id: "remove-during-handshake", threadId: "", ts: Date.now(), agentId: "mac", kind: "device_remove", data: { pub: removed } }) + "\n");
    await vi.waitFor(() => expect(loadDevices(join(stateDir, "devices.json"))).toHaveLength(1));
    sidecar.mint();
    // Only authentication may cross an open but unregistered socket. A notify here is lost.
    expect(seen.map((msg) => msg.type)).toEqual(["register"]);
    macSocket.send(JSON.stringify({ type: "registered", roomId: "r" }));
    await vi.waitFor(() => expect(seen.filter((msg) => msg.type === "notify")).toHaveLength(1));
    expect(seen.find((msg) => msg.type === "revoke")).toEqual({ type: "revoke", pubkey: "removed-phone" });
    expect(seen.findIndex((msg) => msg.type === "revoke")).toBeLessThan(seen.findIndex((msg) => msg.type === "notify"));
    expect(seen.find((msg) => msg.type === "notify")).toMatchObject({ class: "reply", threadRef: threadRef("early-thread") });

    const channel = channelFor(identity.privateKey, loadKeys(stateDir).session.publicKey);
    const request = channel.box({ id: "catch-up", threadId: "", ts: Date.now(), agentId: "phone", kind: "sync_request", data: { lastSeen: {} } });
    macSocket.send(JSON.stringify({ type: "frame", payload: request }));
    await vi.waitFor(() => {
      const events = seen.filter((msg) => msg.type === "frame").flatMap((msg) => {
        try { return [channel.open(frameBody(msg.payload as string))]; }
        catch { return []; }
      });
      expect(events.find((event) => event.kind === "sync_delta")).toMatchObject({ data: { events: expect.arrayContaining([expect.objectContaining({ kind: "message", data: { role: "agent", text: "answered before registration", done: true } })]) } });
    });
  } finally {
    local.destroy();
    await sidecar.close();
    await new Promise<void>((done) => fake.close(() => done()));
  }
});

test("a paired device the relay knows no name for holds the announce back", async () => {
  // The list replaces the relay's whole set, so an incomplete one would unpair the device it
  // cannot name — a record kept from before the signing key was. Nothing is sent instead.
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-announce-partial-"));
  writeFileSync(
    join(stateDir, "devices.json"),
    JSON.stringify([{ pub: toBase64Url(generateKeypair().publicKey), lastSeen: 0 }]),
  );

  const seen: string[] = [];
  const fake = new WebSocketServer({ port: 0 });
  fake.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as { type: string };
      seen.push(msg.type);
      if (msg.type === "register") ws.send(JSON.stringify({ type: "registered", roomId: "r" }));
    });
  });

  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${(fake.address() as AddressInfo).port}`,
    stateDir,
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
    log: () => {},
  });

  // `mint` is the message that follows the announce, so waiting for it is waiting past it.
  await vi.waitFor(() => expect(seen).toContain("mint"));
  expect(seen).not.toContain("devices");

  // `close()` waits on the open sockets, and this sidecar's is one of them.
  await sidecar.close();
  await new Promise<void>((done) => fake.close(() => done()));
});

test("a devices.json from before the split still yields its channel counters, minus ones that are not counts", () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-counters-"));
  const pub = toBase64Url(generateKeypair().publicKey);
  writeFileSync(join(dir, "devices.json"), JSON.stringify([
    { pub, lastSeen: 1, sendSeq: 2000, recvSeq: 17 },
    { pub: "other", lastSeen: 1, sendSeq: -1, recvSeq: "17" },
  ]));
  expect(loadDevices(join(dir, "devices.json"))).toEqual([
    { pub, lastSeen: 1, sendSeq: 2000, recvSeq: 17 },
    { pub: "other", lastSeen: 1 },
  ]);
});

test("channel-seq.json is read by device, drops entries that are not two counts, and is undefined when absent", () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-seqfile-"));
  const file = join(dir, "channel-seq.json");
  expect(loadChannelSeqs(file)).toBeUndefined();
  writeFileSync(file, JSON.stringify({ a: { sendSeq: 2000, recvSeq: 17 }, b: { sendSeq: -1, recvSeq: 3 }, c: "x", d: { sendSeq: 1 } }));
  expect(loadChannelSeqs(file)).toEqual({ a: { sendSeq: 2000, recvSeq: 17 } });
  writeFileSync(file, "[1, 2]");
  expect(loadChannelSeqs(file)).toEqual({});
  writeFileSync(file, "{not json");
  expect(loadChannelSeqs(file)).toBeUndefined();
});

test("the state directory is made and kept owner-only", () => {
  const parent = mkdtempSync(join(tmpdir(), "yorozu-statedir-"));
  const fresh = join(parent, "fresh", "nested");
  ensureStateDir(fresh);
  expect(statSync(fresh).mode & 0o777).toBe(0o700);
  // One an older release left open is tightened, not replaced.
  const loose = join(parent, "loose");
  mkdirSync(loose);
  chmodSync(loose, 0o755);
  writeFileSync(join(loose, "keys.json"), "{}");
  ensureStateDir(loose);
  expect(statSync(loose).mode & 0o777).toBe(0o700);
  expect(existsSync(join(loose, "keys.json"))).toBe(true);
});

test.each<[string, unknown, unknown]>([
  ["not a string", 7, null],
  ["not base64url JSON", "%%%", null],
  ["a JSON array", encodeBody([1, 2]), null],
  ["a JSON string", encodeBody("hello"), null],
  ["an unknown t", encodeBody({ t: "ping" }), null],
  ["a hello without pub", encodeBody({ t: "hello" }), null],
  ["a hello with an empty pub", encodeBody({ t: "hello", pub: "" }), null],
  ["a hello whose spub is a number", encodeBody({ t: "hello", pub: "p", spub: 5 }), null],
  ["a hello whose proof is an object", encodeBody({ t: "hello", pub: "p", proof: {} }), null],
  ["a box missing c", encodeBody({ t: "box", n: "n" }), null],
  ["a box whose n is a number", encodeBody({ t: "box", n: 1, c: "c" }), null],
  ["a bare hello", encodeBody({ t: "hello", pub: "p", extra: 1 }), { t: "hello", pub: "p" }],
  ["a full hello", encodeBody({ t: "hello", pub: "p", spub: "s", proof: "x" }), { t: "hello", pub: "p", spub: "s", proof: "x" }],
  ["a box", encodeBody({ t: "box", n: "n", c: "c", junk: true }), { t: "box", n: "n", c: "c" }],
])("a frame body is %s: parsed to its known fields or to nothing", (_name, payload, expected) => {
  expect(parseFrameBody(payload)).toEqual(expected);
});

test("a keys file that will not read is an error, never a new identity", async () => {
  // A corrupt or unreadable file is not a missing one: minting fresh keys here would give this
  // Mac a new room and silently unpair every phone. Only an absent file is a first run.
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-keys-"));
  writeFileSync(join(stateDir, "keys.json"), "{not json");
  expect(() => loadKeys(stateDir)).toThrow();
  writeFileSync(join(stateDir, "keys.json"), JSON.stringify({ session: { priv: "AA", pub: "AA" }, signing: { priv: "AA", pub: "AA" } }));
  expect(() => loadKeys(stateDir)).toThrow(/usable key pair/);
});

test("the Mac tells the relay what class of thing happened, and nothing about it", async () => {
  // A relay that plays enough of the protocol to pair a phone and to record the cleartext
  // side-channel beside the sealed frames. The real relays take `notify` and say nothing back,
  // so a double is the only place the message itself can be read.
  const seen: Record<string, unknown>[] = [];
  const sockets: { mac?: any; phones: any[] } = { phones: [] };
  let registrations = 0;
  let mints = 0;
  const fake = new WebSocketServer({ port: 0 });
  fake.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Record<string, unknown>;
      switch (msg.type) {
        case "register":
          sockets.mac = ws;
          registrations += 1;
          return ws.send(JSON.stringify({ type: "registered", roomId: "r" }));
        case "mint":
          mints += 1;
          return ws.send(
            JSON.stringify({ type: "token", token: "tok", expiresAt: Date.now() + 60_000 }),
          );
        case "join":
          sockets.phones.push(ws);
          return ws.send(JSON.stringify({ type: "joined", roomId: "r", ownerOnline: true }));
        case "notify":
          return void seen.push(msg);
        case "frame": {
          if (ws === sockets.mac) for (const phone of sockets.phones) phone.send(JSON.stringify(msg));
          else sockets.mac?.send(JSON.stringify(msg));
          return;
        }
      }
    });
  });
  const port = (fake.address() as AddressInfo).port;

  const qrs = qrQueue();
  let paired = 0;
  let turn = 0;
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-notify-"));
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${port}`,
    stateDir,
    provider: openaiCompat({
      baseUrl: "https://example.invalid",
      model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => {
        const n = turn++;
        if (n === 0) return sse("the secret reply");
        if (n === 1) throw new Error("provider unavailable");
        // A command, which is gated and local: the card it raises is quick-approvable.
        return shellTurn("echo yorozu-lockscreen");
      }),
    }),
    log: (line) => {
      if (line.startsWith("QR ")) qrs.push(line.slice(3));
      if (line === "STATE paired") paired += 1;
    },
  });

  const qr = await qrs.next();
  const { phone, keys } = await connectPhone(port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });

  const phoneKeys = generateKeypair();
  const channel = channelFor(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  // Preview boxes stay under the shared session key: the notification extension holds no counter.
  const sessionKey = deriveSessionKey(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(hello(qr, toBase64Url(phoneKeys.publicKey), keys.pub), keys);

  // A second phone, under its own keys and the next QR — a proof burns the secret it was made
  // with: a preview is sealed once per device, each under the key only that device holds.
  await vi.waitFor(() => expect(paired).toBe(1));
  const nextQr = await qrs.next();
  const second = await connectPhone(port, nextQr.roomId!, nextQr.token);
  expect(await second.phone.next()).toMatchObject({ type: "joined" });
  const secondKeys = generateKeypair();
  const secondSessionKey = deriveSessionKey(secondKeys.privateKey, fromBase64Url(nextQr.macPubkey));
  second.phone.frame(hello(nextQr, toBase64Url(secondKeys.publicKey), second.keys.pub), second.keys);
  // Both hellos taken before anything is said: a device that paired after an event was
  // emitted is, rightly, sent no box for it.
  await vi.waitFor(() => expect(paired).toBe(2));

  /** Opens the preview box sealed for one device, as that device's notification extension would. */
  const openPreview = (notify: Record<string, unknown>, pub: string, key: Uint8Array) => {
    const box = (notify.previews as Record<string, { n: string; c: string }>)[pub]!;
    return decodeNotificationPreview(Buffer.from(open(key, fromBase64Url(box.n), fromBase64Url(box.c))).toString());
  };

  const sent: YorozuEvent = {
    id: "e1",
    threadId: "thread-one",
    ts: 1,
    agentId: "phone",
    kind: "message",
    data: { role: "user", text: "the secret question" },
  };
  phone.frame(channel.box(sent), keys);

  // The turn ends with the agent's reply, which is the one thing worth waking a phone for.
  await vi.waitFor(() => expect(seen.map((msg) => msg.class)).toContain("reply"));

  const notify = seen.find((msg) => msg.class === "reply")!;
  expect(notify).toMatchObject({
    type: "notify",
    class: "reply",
    threadRef: threadRef("thread-one"),
  });
  expect(notify.eventRef).toMatch(/^[A-Za-z0-9_-]{8}$/);
  // One box per device, and each opens only under its own key to the reply, which names the
  // event it is about and permits no button.
  expect(Object.keys(notify.previews as object).sort()).toEqual([keys.pub, second.keys.pub].sort());
  expect(openPreview(notify, keys.pub, sessionKey))
    .toEqual({ body: "the secret reply", event: notify.eventRef,
      thread: notify.threadRef, class: "reply", quick: false });
  expect(openPreview(notify, second.keys.pub, secondSessionKey))
    .toEqual({ body: "the secret reply", event: notify.eventRef,
      thread: notify.threadRef, class: "reply", quick: false });
  expect(() => openPreview(notify, second.keys.pub, sessionKey)).toThrow();
  expect(JSON.stringify(notify)).not.toContain("the secret reply");

  const failed: YorozuEvent = {
    ...sent,
    id: "e2",
    ts: 2,
    data: { role: "user", text: "another secret question" },
  };
  phone.frame(channel.box(failed), keys);
  await vi.waitFor(() => expect(seen.map((msg) => msg.class)).toContain("failed"));
  const failure = seen.find((msg) => msg.class === "failed")!;
  expect(openPreview(failure, keys.pub, sessionKey)).toMatchObject({
    event: failure.eventRef, thread: failure.threadRef, class: "failed", quick: false,
  });
  expect(readThreadEvents("thread-one", stateDir)).toContainEqual(expect.objectContaining({
    kind: "message", data: expect.objectContaining({ role: "agent", done: true, failed: true }),
  }));
  expect(readThreadEvents("thread-one", stateDir).some((item) => threadRef(item.id) === failure.eventRef)).toBe(true);

  // An approval for something local and below every floor may be answered from the lock
  // screen, and the relay is told so with one bit. The command itself is not in the notify.
  const gated: YorozuEvent = {
    ...sent,
    id: "e3",
    ts: 3,
    data: { role: "user", text: "run the secret script" },
  };
  phone.frame(channel.box(gated), keys);
  await vi.waitFor(() => expect(seen.map((msg) => msg.class)).toContain("approval"));
  const approval = seen.find((msg) => msg.class === "approval")!;
  expect(approval).toMatchObject({ actions: true });
  // The card's line, sealed per device with the Mac's own judgement and the card's reference:
  // what the phone draws Allow and Deny under, and checks before either counts.
  expect(Object.keys(approval.previews as object).sort()).toEqual([keys.pub, second.keys.pub].sort());
  expect(openPreview(approval, keys.pub, sessionKey))
    .toEqual({ body: "Run a command: echo yorozu-lockscreen", event: approval.eventRef,
      thread: approval.threadRef, class: "approval", quick: true });
  expect(openPreview(approval, second.keys.pub, secondSessionKey))
    .toEqual({ body: "Run a command: echo yorozu-lockscreen", event: approval.eventRef,
      thread: approval.threadRef, class: "approval", quick: true });

  // The whole side-channel, everything the relay was ever told in the clear. Neither side of
  // the conversation is in it, and neither is the thread it happened in.
  const wire = JSON.stringify(seen);
  expect(wire).not.toContain("secret");
  expect(wire).not.toContain("thread-one");
  expect(wire).not.toContain("echo");

  // `close()` waits on the open sockets, and this test attached phones to them as well.
  phone.ws.close();
  second.phone.ws.close();
  await sidecar.close();
  await new Promise<void>((done) => fake.close(() => done()));
});

test("a replayed frame is acked once handled, and a turn that ends offline is announced on reconnect", async () => {
  // A relay double that drops the Mac mid-turn: the Mac socket is closed while the model is
  // thinking, a phone frame sent meanwhile is held, and the next registration replays it
  // tagged with a `seq`, the way both real relays now do.
  const seen: Record<string, unknown>[] = [];
  const macSockets: any[] = [];
  let phoneSocket: any;
  let buffered: Record<string, unknown> | null = null;
  const fake = new WebSocketServer({ port: 0 });
  fake.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Record<string, unknown>;
      switch (msg.type) {
        case "register":
          macSockets.push(ws);
          ws.send(JSON.stringify({ type: "registered", roomId: "r" }));
          if (buffered) {
            ws.send(JSON.stringify({ ...buffered, seq: 7 }));
            buffered = null;
          }
          return;
        case "mint":
          return ws.send(
            JSON.stringify({ type: "token", token: "tok", expiresAt: Date.now() + 60_000 }),
          );
        case "join":
          phoneSocket = ws;
          return ws.send(JSON.stringify({ type: "joined", roomId: "r", ownerOnline: true }));
        case "ack":
        case "notify":
          return void seen.push(msg);
        case "frame": {
          if (ws === phoneSocket) {
            const mac = macSockets.at(-1);
            if (mac && mac.readyState === mac.OPEN) mac.send(JSON.stringify(msg));
            else buffered = msg;
          } else {
            phoneSocket?.send(JSON.stringify(msg));
          }
          return;
        }
      }
    });
  });
  const port = (fake.address() as AddressInfo).port;

  let qrLine!: (line: string) => void;
  const qrPrinted = new Promise<string>((resolve) => (qrLine = resolve));
  const lines: string[] = [];
  let turn = 0;
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-held-")),
    provider: openaiCompat({
      baseUrl: "https://example.invalid",
      model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => {
        if (turn++ === 0) {
          // The Mac's relay socket dies while the model is thinking, so the reply lands on a
          // socket that is not open.
          macSockets[0].close();
          await vi.waitFor(() => expect(lines).toContain("STATE disconnected"));
        }
        return sse("answered");
      }),
    }),
    log: (line) => {
      lines.push(line);
      if (line.startsWith("QR ")) qrLine(line.slice(3));
    },
  });

  const qr = decodeQrPayload(await qrPrinted);
  const { phone, keys } = await connectPhone(port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });
  const phoneKeys = generateKeypair();
  const channel = channelFor(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(hello(qr, toBase64Url(phoneKeys.publicKey), keys.pub), keys);
  await vi.waitFor(() => expect(lines).toContain("STATE paired"));

  const ask = (id: string, text: string): void => {
    const event: YorozuEvent = {
      id, threadId: "thread-one", ts: Date.now(), agentId: "phone",
      kind: "message", data: { role: "user", text },
    };
    phone.frame(channel.box(event), keys);
  };
  ask("e1", "a question");

  // The reply happened with no relay socket: there was nobody to tell. The runtime reconnects
  // on its own, and on re-registering the wake-up that could not go out goes out now — the
  // phone will sync the reply itself, but it has to be told to look.
  await vi.waitFor(() => expect(macSockets).toHaveLength(2), { timeout: 10_000 });
  await vi.waitFor(() => expect(seen.map((msg) => msg.class)).toContain("reply"));

  // And a frame the relay replayed with a `seq` is acked once handled.
  macSockets[1].close();
  await vi.waitFor(() => expect(lines.filter((l) => l === "STATE disconnected")).toHaveLength(2));
  ask("e2", "sent while the mac was away");
  await vi.waitFor(() => expect(buffered).not.toBeNull());
  await vi.waitFor(() => expect(seen).toContainEqual({ type: "ack", seq: 7 }), { timeout: 10_000 });

  phone.ws.close();
  await sidecar.close();
  await new Promise<void>((done) => fake.close(() => done()));
});

test("a sync page stops short of the relay's frame limit, and the rest follows on request", async () => {
  relay = await startRelay(0);
  const qrs = qrQueue();
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-serve-")),
    provider: openaiCompat({
      baseUrl: "https://example.invalid",
      model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => sse("pong")),
    }),
    log: (line) => {
      if (line.startsWith("QR ")) qrs.push(line.slice(3));
    },
  });
  const phone = await pairPhone(relay.port, await qrs.next());
  await phone.next("thread_list");
  const chat = "draft-1";
  phone.send(chat, { kind: "thread_create", data: {} });
  await phone.next("thread_list");

  // Two turns that together outgrow one page, though either fits on its own.
  const big = "x".repeat(Math.floor(SYNC_PAGE_BYTES * 0.6));
  const replies: string[] = [];
  for (let n = 0; n < 2; n++) {
    phone.send(chat, { kind: "message", data: { role: "user", text: big } });
    await phone.next("message"); // our own, echoed
    replies.push((await phone.next("message")).id); // pong
  }
  const roles = (delta: YorozuEvent) =>
    delta.kind === "sync_delta"
      ? delta.data.events.map((e) => (e.kind === "message" ? e.data.role : e.kind))
      : delta.kind;

  // From nothing: the first turn only, and word that there is more.
  phone.send(chat, { kind: "sync_request", data: { lastSeen: {}, focusThreadId: chat } });
  const page = await phone.next("sync_delta");
  expect(roles(page)).toEqual(["user", "agent"]);
  expect(page).toMatchObject({ data: { more: true } });
  expect(page.kind === "sync_delta" && page.data.current?.find((event) => event.id === replies[1])).toMatchObject({
    kind: "message", data: { role: "agent", done: true },
  });

  // From the end of that page: the second turn, and that is all.
  phone.send(chat, { kind: "sync_request", data: { lastSeen: { [chat]: replies[0]! }, focusThreadId: chat,
    includeCurrent: false } });
  const rest = await phone.next("sync_delta");
  expect(roles(rest)).toEqual(["user", "agent"]);
  expect(rest.kind === "sync_delta" && rest.data.more).toBeUndefined();
  expect(rest.kind === "sync_delta" && rest.data.current).toBeUndefined();
});

test("catch-up shows a still-actionable card before historical replay", async () => {
  const { send, eventsUntil } = await pairedPhone([() => shellTurn("x".repeat(140_000)), () => sse("done")]);
  send({ kind: "thread_create", data: {} });
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "t1"));
  send({ kind: "message", data: { role: "user", text: "run it" } });
  const card = (await eventsUntil((event) => event.kind === "approval_card")).at(-1)!;
  expect(Buffer.byteLength(JSON.stringify(card))).toBeGreaterThan(SYNC_PAGE_BYTES / 2);
  send({ kind: "sync_request", data: { lastSeen: {}, focusThreadId: "t1" } }, "");
  const snapshot = await eventsUntil((event) => event.kind === "sync_delta");
  expect(snapshot.slice(0, -1).map((event) => event.id)).toContain(card.id);
  if (card.kind !== "approval_card") throw new Error("expected approval card");
  send({ kind: "approval_answer", data: { actionId: card.data.actionId, answer: "no" } });
  await eventsUntil((event) => event.kind === "message" && event.data.done === true);
  send({ kind: "sync_request", data: { lastSeen: {}, focusThreadId: "t1" } }, "");
  const settled = await eventsUntil((event) => event.kind === "sync_delta");
  expect(settled.slice(0, -1).map((event) => event.id)).not.toContain(card.id);
});

test("Stop retires a pending approval on the phone and in the thread log", async () => {
  const { dir, send, eventsUntil } = await pairedPhone([() => shellTurn("echo stop-card"), () => sse("done")], false, {}, true);
  send({ kind: "thread_create", data: {} });
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "t1"));
  const target = send({ kind: "message", data: { role: "user", text: "run it" } });
  const card = (await eventsUntil((event) => event.kind === "approval_card")).at(-1)!;
  if (card.kind !== "approval_card") throw new Error("expected approval card");
  send({ kind: "interrupt", data: { targetEventId: target } });
  await eventsUntil((event) => event.kind === "approval_status" && event.data.actionId === card.data.actionId &&
    event.data.status === "no-longer-needed");
  await eventsUntil((event) => event.kind === "thread_list" &&
    event.data.threads.find((thread) => thread.id === "t1")?.awaitingApproval !== true);
  expect(readThreadEvents("t1", dir)).toContainEqual(expect.objectContaining({ kind: "approval_status",
    data: expect.objectContaining({ actionId: card.data.actionId, status: "no-longer-needed" }) }));
});

test("catch-up excludes an answered question from current state", async () => {
  const ask = () => new Response(`data: ${JSON.stringify({ choices: [{ delta: { tool_calls: [{ index: 0,
    id: "call_ask", function: { name: "ask_user", arguments: JSON.stringify({ question: "Which?", options: ["A", "B"] }) },
  }] }, finish_reason: "tool_calls" }] })}\n\ndata: [DONE]\n\n`, { headers: { "content-type": "text/event-stream" } });
  const { dir, send, eventsUntil } = await pairedPhone([ask, () => sse("done")]);
  send({ kind: "thread_create", data: {} });
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "t1"));
  send({ kind: "message", data: { role: "user", text: "ask me" } });
  const question = (await eventsUntil((event) => event.kind === "question_card")).at(-1)!;
  expect(question.kind).toBe("question_card");
  send({ kind: "sync_request", data: { lastSeen: {}, focusThreadId: "t1" } }, "");
  const active = await eventsUntil((event) => event.kind === "sync_delta");
  const activeDelta = active.at(-1)!;
  expect(activeDelta.kind === "sync_delta" && activeDelta.data.current).toContainEqual(question);
  send({ kind: "thread_archive", data: { archived: true } });
  await vi.waitFor(() => expect(listThreads(dir).find((thread) => thread.id === "t1")?.archived).toBe(true));
  send({ kind: "sync_request", data: { lastSeen: {} } }, "");
  const archived = (await eventsUntil((event) => event.kind === "sync_delta")).at(-1)!;
  expect(archived.kind === "sync_delta" && archived.data.current).toContainEqual(question);
  if (question.kind !== "question_card") throw new Error("expected question card");
  send({ kind: "question_answer", data: { questionId: question.data.questionId, answer: "A" } });
  await eventsUntil((event) => event.kind === "message" && event.data.done === true);
  send({ kind: "sync_request", data: { lastSeen: {}, focusThreadId: "t1" } }, "");
  const settled = await eventsUntil((event) => event.kind === "sync_delta");
  const settledDelta = settled.at(-1)!;
  expect(settledDelta.kind === "sync_delta" ? settledDelta.data.current ?? [] : []).not.toContainEqual(question);
});

test("current snapshot honors the pairing cutoff for live replies", async () => {
  const streamed = Promise.withResolvers<void>();
  const release = Promise.withResolvers<void>();
  let pairedAt = 0;
  const runner: NativeAgentRunner = { run: async (turn) => {
    const clock = vi.spyOn(Date, "now").mockReturnValue(pairedAt - 1);
    turn.onUpdate?.("before pairing");
    clock.mockRestore();
    streamed.resolve();
    turn.signal.addEventListener("abort", () => release.resolve(), { once: true });
    await release.promise;
    return { text: "done", sessionId: "session" };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } });
  await vi.waitFor(() => expect(loadDevices(join(dir, "devices.json"))).toHaveLength(1));
  pairedAt = loadDevices(join(dir, "devices.json"))[0]!.pairedAt!;
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "native");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "native"));
  send({ kind: "message", data: { role: "user", text: "work" } }, "native");
  await streamed.promise;
  try {
    send({ kind: "sync_request", data: { lastSeen: {}, focusThreadId: "native" } }, "");
    const snapshot = (await eventsUntil((event) => event.kind === "sync_delta")).at(-1)!;
    expect(snapshot.kind === "sync_delta" && snapshot.data.current).toBeUndefined();
  } finally { release.resolve(); }
});

test.each([["claude-code", "yes"], ["claude-code", "no"], ["codex", "yes"], ["codex", "no"]] as const)("%s native approval %s round-trips through encrypted relay including lockscreen answers", async (agent, answer) => {
  const runner: NativeAgentRunner = { run: async (turn) => {
    const allowed = await turn.approve!("Bash", { command: "pwd" }, turn.signal);
    const response = await turn.ask!("Which?", ["A", "B"], turn.signal);
    return { text: `${allowed}:${response}`, sessionId: "sdk-session" };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { [agent]: runner } });
  send({ kind: "thread_create", data: { agent, cwd: proj } }, "native");
  send({ kind: "message", data: { role: "user", text: "work" } }, "native");
  const approval = (await eventsUntil((e) => e.kind === "approval_card")).at(-1)!;
  if (approval.kind !== "approval_card") throw new Error("missing approval");
  send({ kind: "approval_answer", data: { actionId: approval.data.actionId, answer, source: "notification" } }, "native");
  const question = (await eventsUntil((e) => e.kind === "question_card")).at(-1)!;
  if (question.kind !== "question_card") throw new Error("missing question");
  send({ kind: "question_answer", data: { questionId: question.data.questionId, answer: "Custom" } }, "native");
  expect((await eventsUntil((e) => e.kind === "message" && e.data.done === true)).at(-1)).toMatchObject({ data: { text: `${answer === "yes"}:Custom` } });
  expect(listRules(dir)).toEqual([]);
  expect(readThreadEvents("native", dir).some((e) => e.kind === "rule_proposal")).toBe(false);
});

test("a lock-screen answer never settles a native card the runtime did not judge quick", async () => {
  // An MCP tool is someone else's integration, which the runtime cannot classify by name: the
  // card it raises is for review in the app, and a button press against it is refused before
  // the native card is even looked up. The card stays up, and the app's own answer settles it.
  const runner: NativeAgentRunner = { run: async (turn) => {
    const allowed = await turn.approve!("mcp__mail__send", { to: "bob@example.com" }, turn.signal);
    return { text: `sent:${allowed}`, sessionId: "sdk-session" };
  } };
  const { send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { "claude-code": runner } }, true);
  send({ kind: "thread_create", data: { agent: "claude-code", cwd: proj } }, "native");
  send({ kind: "message", data: { role: "user", text: "mail bob" } }, "native");
  const card = (await eventsUntil((e) => e.kind === "approval_card")).at(-1)!;
  if (card.kind !== "approval_card") throw new Error("missing approval");
  expect(card.data).toMatchObject({ nativeAgent: "claude-code", actionClass: "mcp__mail__send" });
  send({ kind: "approval_answer", data: { actionId: card.data.actionId, answer: "yes", source: "notification" } }, "native");
  await eventsUntil((event) => event.kind === "approval_status" && event.data.actionId === card.data.actionId &&
    event.data.status === "rejected");
  send({ kind: "approval_answer", data: { actionId: card.data.actionId, answer: "no" } }, "native");
  expect((await eventsUntil((e) => e.kind === "message" && e.data.done === true)).at(-1))
    .toMatchObject({ data: { text: "sent:false" } });
});

test.each(["claude-code", "codex"] as const)("%s native card waiting when YOLO is granted is allowed, and later prompts are not asked", async (agent) => {
  const runner: NativeAgentRunner = { run: async (turn) => {
    const first = await turn.approve!("Bash", { command: "pwd" }, turn.signal);
    const second = await turn.approve!("Bash", { command: "ls" }, turn.signal);
    return { text: `${first}:${second}`, sessionId: "s" };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { [agent]: runner } });
  const mac = await macClient(dir);
  send({ kind: "thread_create", data: { agent, cwd: proj } }, "late");
  send({ kind: "message", data: { role: "user", text: "work" } }, "late");
  const card = (await eventsUntil((e) => e.kind === "approval_card")).at(-1)!;
  if (card.kind !== "approval_card") throw new Error("missing approval");
  mac.send({ kind: "approval_settings", data: { yolo: true } });
  const rest = await eventsUntil((e) => e.kind === "message" && e.data.done === true);
  expect(rest.at(-1)).toMatchObject({ data: { text: "true:true" } });
  expect(rest.filter((e) => e.kind === "approval_card")).toEqual([]);
  expect(rest).toContainEqual(expect.objectContaining({ kind: "approval_answer", data: { actionId: card.data.actionId, answer: "yes" } }));
  mac.close();
});

test.each(["claude-code", "codex"] as const)("%s native bypass shares global YOLO on new and resumed turns", async (agent) => {
  const turns: NativeTurn[] = [];
  const runner: NativeAgentRunner = { run: async (turn) => { turns.push(turn); return { text: "ok", sessionId: "s" }; } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { [agent]: runner } });
  const mac = await macClient(dir);
  send({ kind: "thread_create", data: { agent, cwd: proj } }, "cc");
  for (const bypass of [true, false]) {
    // On is the Mac's to grant; off is the phone's to say.
    if (bypass) mac.send({ kind: "approval_settings", data: { yolo: true } });
    else send({ kind: "approval_settings", data: { yolo: false } });
    const list = (await eventsUntil((e) => e.kind === "thread_list" && e.data.threads.some((t) => t.id === "cc" && t.bypass === bypass))).at(-1)!;
    expect(JSON.stringify(list)).toContain(`"bypass":${bypass}`);
    expect(JSON.parse(readFileSync(join(dir, "approval.json"), "utf8")).yolo).toBe(bypass);
    send({ kind: "message", data: { role: "user", text: "go" } }, "cc");
    await eventsUntil((e) => e.kind === "message" && e.data.done === true);
    expect(turns.at(-1)?.bypass).toBe(bypass);
    send({ kind: "approval_settings", data: {} });
    expect((await eventsUntil((e) => e.kind === "approval_settings")).at(-1)).toMatchObject({ data: { yolo: bypass } });
  }
  mac.close();
});

test.each(["claude-code", "codex"] as const)("startup automatically recovers the same %s turn", async (agent) => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-native-restart-"));
  createThread("Work", dir, "cc", { agent, cwd: proj });
  setThreadSession("cc", "native-before-crash", dir);
  appendThreadEvent({ id: "original", threadId: "cc", ts: 1, agentId: "main", kind: "message",
    data: { role: "user", text: "Finish the report" } }, dir);
  appendThreadEvent({ id: "prior-call", threadId: "cc", ts: 2, agentId: "main", kind: "tool_call",
    data: { callId: "prior", name: "Bash", args: { command: "generate report" } } }, dir);
  appendThreadEvent({ id: "prior-result", threadId: "cc", ts: 3, agentId: "main", kind: "tool_result",
    data: { callId: "prior", ok: true, output: "draft created" } }, dir);
  setNativeTurn("cc", { id: "native:original:final", state: "running", userEventId: "original" }, dir);
  const run = vi.fn<NativeAgentRunner["run"]>().mockResolvedValue({ text: "continued", sessionId: "native-before-crash" });
  const { send, eventsUntil } = await pairedPhone([], false, { stateDir: dir, nativeRunners: { [agent]: { run } } });
  await vi.waitFor(() => expect(readThreadEvents("cc", dir)).toContainEqual(expect.objectContaining({
    id: "native:original:final", kind: "message", data: expect.objectContaining({ done: true, text: "continued" }),
  })));
  expect(run).toHaveBeenCalledWith(expect.objectContaining({
    text: expect.stringContaining("Finish the report"), sessionId: "native-before-crash", cwd: proj,
  }));
  expect(run.mock.calls[0]?.[0].text).toContain("generate report");
  expect(run.mock.calls[0]?.[0].text).toContain("draft created");
  expect(readThreadEvents("cc", dir).filter((event) => event.kind === "message" && event.data.role === "user")).toHaveLength(1);
  send({ kind: "thread_recover", data: { turnId: "native:original:final", action: "continue" } }, "cc");
  send({ kind: "thread_list", data: { threads: [] } });
  await eventsUntil((e) => e.kind === "thread_list");
  expect(run).toHaveBeenCalledTimes(1);
  expect(listThreads(dir)[0]?.nativeTurn).toBeUndefined();
});

test("three failed native recoveries pause across restart until Retry", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-native-budget-"));
  createThread("Work", dir, "cc", { agent: "codex", cwd: proj });
  appendThreadEvent({ id: "original", threadId: "cc", ts: 1, agentId: "main", kind: "message",
    data: { role: "user", text: "Finish the report" } }, dir);
  setNativeTurn("cc", { id: "native:original:final", state: "running", userEventId: "original" }, dir);
  const failed = vi.fn<NativeAgentRunner["run"]>().mockRejectedValue(new Error("backend crashed"));
  await pairedPhone([], false, { stateDir: dir, nativeRunners: { codex: { run: failed } } });
  await vi.waitFor(() => expect(listThreads(dir)[0]?.nativeTurn).toMatchObject({
    state: "interrupted", recoveryAttempts: 3, userEventId: "original",
  }));
  expect(failed).toHaveBeenCalledTimes(3);
  expect(readThreadEvents("cc", dir).some((event) => event.id === "native:original:final")).toBe(false);
  expect(readThreadEvents("cc", dir)).toContainEqual(expect.objectContaining({
    kind: "message", data: expect.objectContaining({ role: "agent", done: true, failed: true,
      text: expect.stringContaining("Retry to continue") }),
  }));
  await sidecar.close();

  const resumed = vi.fn<NativeAgentRunner["run"]>().mockResolvedValue({ text: "completed" });
  const { send, eventsUntil } = await pairedPhone([], false, { stateDir: dir, nativeRunners: { codex: { run: resumed } } });
  const startup = (await eventsUntil((event) => event.kind === "thread_list")).at(-1)!;
  expect(startup).toMatchObject({ data: { threads: [expect.objectContaining({
    interruptedTurnId: "native:original:final", canResume: true,
  })] } });
  expect(resumed).not.toHaveBeenCalled();
  send({ kind: "thread_recover", data: { turnId: "native:original:final", action: "continue" } }, "cc");
  await vi.waitFor(() => expect(readThreadEvents("cc", dir)).toContainEqual(expect.objectContaining({
    id: "native:original:final", data: expect.objectContaining({ done: true, text: "completed" }),
  })));
  expect(resumed).toHaveBeenCalledTimes(1);
  expect(readThreadEvents("cc", dir).filter((event) => event.kind === "message" && event.data.role === "user")).toHaveLength(1);
});

test("new completed tool work resets the native recovery budget", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-native-progress-"));
  createThread("Work", dir, "cc", { agent: "codex", cwd: proj });
  appendThreadEvent({ id: "original", threadId: "cc", ts: 1, agentId: "main", kind: "message",
    data: { role: "user", text: "Finish the report" } }, dir);
  setNativeTurn("cc", { id: "native:original:final", state: "running", userEventId: "original", recoveryAttempts: 2 }, dir);
  const run = vi.fn<NativeAgentRunner["run"]>()
    .mockImplementationOnce(async (turn) => {
      turn.onActivity?.("result:fresh", { kind: "tool_result", data: { callId: "fresh", ok: true, output: "verified" } });
      throw new Error("backend crashed after progress");
    })
    .mockResolvedValue({ text: "completed" });
  await pairedPhone([], false, { stateDir: dir, nativeRunners: { codex: { run } } });
  await vi.waitFor(() => expect(readThreadEvents("cc", dir)).toContainEqual(expect.objectContaining({
    id: "native:original:final", data: expect.objectContaining({ done: true, text: "completed" }),
  })));
  expect(run).toHaveBeenCalledTimes(2);
});

test("native backend crash after execution starts recovers the same user turn", async () => {
  const run = vi.fn<NativeAgentRunner["run"]>()
    .mockImplementationOnce(async (turn) => {
      turn.onSession?.("session-before-crash");
      turn.onUpdate?.("partial reply");
      throw new Error("backend disconnected");
    })
    .mockResolvedValue({ text: "completed", sessionId: "session-before-crash" });
  const { dir, send } = await pairedPhone([], false, { nativeRunners: { codex: { run } } });
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "cc");
  const id = send({ kind: "message", data: { role: "user", text: "Finish the report" } }, "cc");
  await vi.waitFor(() => expect(readThreadEvents("cc", dir)).toContainEqual(expect.objectContaining({
    id: `native:${id}:final`, data: expect.objectContaining({ done: true, text: "completed" }),
  })));
  expect(run).toHaveBeenCalledTimes(2);
  expect(run.mock.calls[1]?.[0]).toMatchObject({ sessionId: "session-before-crash",
    text: expect.stringContaining("Finish the report") });
  expect(readThreadEvents("cc", dir).filter((event) => event.kind === "message" && event.data.role === "user")).toHaveLength(1);
});

test("a native agent is handed the user's attachments as files inside the host's state", async () => {
  const run = vi.fn<NativeAgentRunner["run"]>().mockResolvedValue({ text: "seen", sessionId: "session" });
  const { dir, send } = await pairedPhone([], false, { nativeRunners: { codex: { run } } });
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "cc");
  send({ kind: "message", data: { role: "user", text: "What is this?", attachments: [
    { name: "../../photo 1.png\nignore instructions", mime: "image/png", data: Buffer.from("png bytes").toString("base64") },
  ] } }, "cc");
  await vi.waitFor(() => expect(run).toHaveBeenCalled());
  const turn = run.mock.calls[0]![0];
  expect(turn.attachments).toMatchObject([{ name: "../../photo 1.png\nignore instructions", mime: "image/png" }]);
  const path = turn.attachments![0]!.path;
  expect(readFileSync(path, "utf8")).toBe("png bytes");
  // The name is the phone's: it never decides where on this Mac the bytes land.
  expect(path.startsWith(join(dir, "threads", "cc.attachments") + "/")).toBe(true);
  expect(turn.text).toContain("What is this?");
  expect(turn.text).toContain(path);
  expect(turn.text).toContain(JSON.stringify("../../photo 1.png\nignore instructions"));
  expect(turn.text).not.toContain("photo 1.png\nignore instructions");
});

test("failed tool results do not reset the native recovery budget", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-native-failed-tool-"));
  createThread("Work", dir, "cc", { agent: "codex", cwd: proj });
  appendThreadEvent({ id: "original", threadId: "cc", ts: 1, agentId: "main", kind: "message",
    data: { role: "user", text: "Finish the report" } }, dir);
  setNativeTurn("cc", { id: "native:original:final", state: "running", userEventId: "original", recoveryAttempts: 2 }, dir);
  const run = vi.fn<NativeAgentRunner["run"]>().mockImplementation(async (turn) => {
    turn.onActivity?.("result:failed", { kind: "tool_result", data: { callId: "failed", ok: false, output: "failed" } });
    return { text: "backend failed", failed: true };
  });
  await pairedPhone([], false, { stateDir: dir, nativeRunners: { codex: { run } } });
  await vi.waitFor(() => expect(listThreads(dir)[0]?.nativeTurn).toMatchObject({
    state: "interrupted", recoveryAttempts: 3,
  }));
  expect(run).toHaveBeenCalledTimes(1);
});

test("a native Stop spanning host restart reports uncertainty and prevents recovery", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-native-stop-restart-"));
  createThread("Work", dir, "cc", { agent: "codex", cwd: proj });
  appendThreadEvent({ id: "original", threadId: "cc", ts: 1, agentId: "main", kind: "message",
    data: { role: "user", text: "Finish the report" } }, dir);
  setNativeTurn("cc", { id: "native:original:final", state: "running", userEventId: "original" }, dir);
  writeFileSync(join(dir, "stopped-turns.jsonl"), JSON.stringify({ targetEventId: "original", threadId: "cc",
    status: "requested", requestIds: ["old-stop"] }) + "\n");
  const run = vi.fn<NativeAgentRunner["run"]>();
  const { send, eventsUntil } = await pairedPhone([], false, { stateDir: dir, nativeRunners: { codex: { run } } });
  expect(run).not.toHaveBeenCalled();
  expect(listThreads(dir)[0]?.nativeTurn).toBeUndefined();
  expect(readFileSync(join(dir, "stopped-turns.jsonl"), "utf8")).toContain('"status":"unconfirmed"');
  send({ kind: "interrupt", data: { targetEventId: "original" } }, "cc");
  expect((await eventsUntil((event) => event.kind === "stop_status" && event.data.status === "unconfirmed")).at(-1))
    .toMatchObject({ data: { targetEventId: "original", status: "unconfirmed" } });
});

test("native session and running marker reach disk before completion, and survive sidecar shutdown", async () => {
  let started!: NativeTurn;
  const run: NativeAgentRunner["run"] = async (turn) => {
    expect(started).toBeUndefined(); // queued turn must never start after shutdown
    started = turn;
    turn.onSession!("early-session");
    await new Promise<void>((resolve) => turn.signal.addEventListener("abort", () => resolve(), { once: true }));
    return { text: "", sessionId: "early-session" };
  };
  const { dir, send } = await pairedPhone([], false, { nativeRunners: { "claude-code": { run } } });
  send({ kind: "thread_create", data: { agent: "claude-code", cwd: proj } }, "cc");
  send({ kind: "message", data: { role: "user", text: "work" } }, "cc");
  await vi.waitFor(() => expect(started).toBeDefined());
  expect(listThreads(dir)[0]).toMatchObject({ nativeSessionId: "early-session", nativeTurn: { state: "running" } });
  send({ kind: "message", data: { role: "user", text: "queued" } }, "cc");
  await vi.waitFor(() => expect(readThreadEvents("cc", dir).filter((e) => e.kind === "message" && e.data.role === "user")).toHaveLength(2));
  await sidecar.close();
  expect(started.signal.aborted).toBe(true);
  expect(listThreads(dir)[0]?.nativeTurn?.state).toBe("running");
});

test("agent models publish separately; selections persist and reject another agent's models", async () => {
  const run = vi.fn<NativeAgentRunner["run"]>().mockResolvedValue({ text: "ok", sessionId: "s-model" });
  const models = [{ id: "opus", label: "Opus", providerLabel: "Claude Code", efforts: ["low", "max"] as const }];
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { "claude-code": { run, models: async () => models.map((m) => ({ ...m, efforts: [...m.efforts] })) } } });
  const list = (await eventsUntil((e) => e.kind === "model_list" && !!e.data.agentModels?.["claude-code"])).at(-1)!;
  expect(list).toMatchObject({ data: { agentModels: { "claude-code": models } } });
  send({ kind: "thread_create", data: { agent: "claude-code", cwd: proj } }, "cc");
  send({ kind: "thread_set_model", data: { model: "opus" } }, "cc");
  send({ kind: "thread_set_effort", data: { effort: "max" } }, "cc");
  send({ kind: "message", data: { role: "user", text: "go" } }, "cc");
  await eventsUntil((e) => e.kind === "message" && e.data.done === true);
  expect(run).toHaveBeenLastCalledWith(expect.objectContaining({ model: "opus", effort: "max" }));
  expect(listThreads(dir)[0]).toMatchObject({ model: "opus", effort: "max" });
  send({ kind: "thread_set_model", data: { model: "other-provider/model" } }, "cc");
  send({ kind: "thread_set_effort", data: { effort: "ultra" } }, "cc");
  send({ kind: "message", data: { role: "user", text: "again" } }, "cc");
  await eventsUntil((e) => e.kind === "message" && e.data.done === true);
  expect(run).toHaveBeenLastCalledWith(expect.objectContaining({ model: "opus", effort: "max", sessionId: "s-model" }));
});

test("interrupted turn before native session creation cannot silently Continue into a new session", async () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-native-preinit-"));
  createThread("Work", dir, "cc", { agent: "claude-code", cwd: proj });
  setNativeTurn("cc", { id: "crash", state: "running" }, dir);
  const run = vi.fn<NativeAgentRunner["run"]>().mockResolvedValue({ text: "new" });
  const { send, eventsUntil } = await pairedPhone([], false, { stateDir: dir, nativeRunners: { "claude-code": { run } } });
  expect((await eventsUntil((e) => e.kind === "thread_list")).at(-1)).toMatchObject({ data: { threads: [expect.objectContaining({ canResume: false })] } });
  send({ kind: "thread_recover", data: { turnId: "crash", action: "continue" } }, "cc");
  send({ kind: "thread_list", data: { threads: [] } });
  await eventsUntil((e) => e.kind === "thread_list");
  expect(run).not.toHaveBeenCalled();
  expect(listThreads(dir)[0]?.nativeTurn?.state).toBe("interrupted");
  send({ kind: "thread_recover", data: { turnId: "crash", action: "dismiss" } }, "cc");
  await eventsUntil((e) => e.kind === "thread_list" && !e.data.threads[0]?.interruptedTurnId);
});

test.each(["claude-code", "codex"] as const)("%s full results larger than relay ceiling pull in bounded Unicode-safe chunks after sync", async (agent) => {
  const output = "界🙂".repeat(300000);
  const run: NativeAgentRunner["run"] = async (turn) => {
    turn.onActivity!("result:large", { kind: "tool_result", data: { callId: "large", ok: true, output } });
    return { text: "done" };
  };
  const { send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { [agent]: { run } } });
  send({ kind: "thread_create", data: { agent, cwd: proj } }, "cc");
  send({ kind: "message", data: { role: "user", text: "read" } }, "cc");
  await eventsUntil((e) => e.kind === "message" && e.data.done === true);
  send({ kind: "sync_request", data: { lastSeen: {} } });
  await eventsUntil((e) => e.kind === "sync_delta");
  let offset: number | undefined = 0;
  let joined = "";
  while (offset !== undefined) {
    send({ kind: "tool_result_request", data: { callId: "large", offset } }, "cc");
    const part = (await eventsUntil((e) => e.kind === "tool_result")).at(-1)!;
    if (part.kind !== "tool_result") throw new Error("missing result");
    expect(part.data.chunkOffset).toBe(offset);
    expect(Buffer.byteLength(JSON.stringify(part)) * 4 / 3 + 4096).toBeLessThan(1024 * 1024);
    expect(part.data.output.isWellFormed()).toBe(true);
    joined += part.data.output;
    offset = part.data.nextOffset;
  }
  expect(joined).toBe(output);
});

test.each(["claude-code", "codex"] as const)("%s threads run concurrently with independent cancellation and sessions", async (agent) => {
  const turns = new Map<string, NativeTurn>();
  const releases = new Map<string, () => void>();
  const runner: NativeAgentRunner = { run: async (turn) => {
    turns.set(turn.threadId, turn);
    turn.onSession!(`session-${turn.threadId}`);
    await new Promise<void>((resolve) => {
      releases.set(turn.threadId, resolve);
      turn.signal.addEventListener("abort", () => resolve(), { once: true });
    });
    return { text: turn.signal.aborted ? "" : "done", sessionId: `session-${turn.threadId}` };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { [agent]: runner } });
  const ids = new Map<string, string>();
  for (const id of ["one", "two", "three"]) {
    send({ kind: "thread_create", data: { agent, cwd: proj } }, id);
    ids.set(id, send({ kind: "message", data: { role: "user", text: "work" } }, id));
  }
  await vi.waitFor(() => expect(turns.size).toBe(3));
  send({ kind: "interrupt", data: { targetEventId: ids.get("one")! } }, "one");
  await vi.waitFor(() => expect(turns.get("one")!.signal.aborted).toBe(true));
  expect(turns.get("two")!.signal.aborted).toBe(false);
  expect(turns.get("three")!.signal.aborted).toBe(false);
  releases.get("two")!(); releases.get("three")!();
  await eventsUntil((e) => e.kind === "message" && e.threadId === "three" && e.data.done === true);
  expect(listThreads(dir).map((t) => t.nativeSessionId).sort()).toEqual(["session-one", "session-three", "session-two"]);
});

test("delayed exact-run Stop cannot abort the next turn", async () => {
  const turns: NativeTurn[] = [];
  let releaseSecond!: () => void;
  const runner: NativeAgentRunner = { run: async (turn) => {
    turns.push(turn);
    await new Promise<void>((resolve) => {
      if (turns.length === 2) releaseSecond = resolve;
      turn.signal.addEventListener("abort", () => resolve(), { once: true });
    });
    return { text: turn.signal.aborted ? "" : "second completed" };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } });
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "exact-stop");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "exact-stop"));
  const first = send({ kind: "message", data: { role: "user", text: "first" } }, "exact-stop");
  await eventsUntil((event) => event.kind === "thread_list" &&
    event.data.threads.some((thread) => thread.id === "exact-stop" && thread.activeEventId === first));
  send({ kind: "interrupt", data: { targetEventId: first } }, "exact-stop");
  await eventsUntil((event) => event.kind === "stop_status" && event.data.targetEventId === first && event.data.status === "stopped");
  expect(turns[0]?.signal.aborted).toBe(true);
  const second = send({ kind: "message", data: { role: "user", text: "second" } }, "exact-stop");
  await eventsUntil((event) => event.kind === "thread_list" &&
    event.data.threads.some((thread) => thread.id === "exact-stop" && thread.activeEventId === second));
  send({ kind: "interrupt", data: { targetEventId: first } }, "exact-stop");
  await eventsUntil((event) => event.kind === "stop_status" && event.data.targetEventId === first);
  expect(turns[1]?.signal.aborted).toBe(false);
  send({ kind: "interrupt", data: {} }, "exact-stop");
  await eventsUntil((event) => event.kind === "thought" && event.data.text.includes("Update Yorozu"));
  expect(turns[1]?.signal.aborted).toBe(false);
  expect(readFileSync(join(dir, "stopped-turns.jsonl"), "utf8")).toContain(first);
  releaseSecond();
  await eventsUntil((event) => event.kind === "message" && event.threadId === "exact-stop" && event.data.done === true);
});

test("repeated Stop requests each receive the confirmed outcome", async () => {
  const finish = Promise.withResolvers<void>();
  const runner: NativeAgentRunner = { run: async () => { await finish.promise; return { text: "" }; } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } });
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "multi-stop");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "multi-stop"));
  const target = send({ kind: "message", data: { role: "user", text: "long run" } }, "multi-stop");
  await eventsUntil((event) => event.kind === "thread_list" &&
    event.data.threads.some((thread) => thread.id === "multi-stop" && thread.activeEventId === target));
  const first = send({ kind: "interrupt", data: { targetEventId: target } }, "multi-stop");
  await eventsUntil((event) => event.kind === "stop_status" && event.data.requestId === first && event.data.status === "requested");
  const second = send({ kind: "interrupt", data: { targetEventId: target } }, "multi-stop");
  await eventsUntil((event) => event.kind === "stop_status" && event.data.requestId === second && event.data.status === "requested");
  finish.resolve();
  const outcomes = await eventsUntil((event) => event.kind === "stop_status" && event.data.requestId === second &&
    event.data.status === "stopped");
  expect(outcomes.filter((event) => event.kind === "stop_status" && event.data.status === "stopped")
    .map((event) => event.kind === "stop_status" && event.data.requestId)).toEqual([first, second]);
  expect(readThreadEvents("multi-stop", dir).filter((event) => event.kind === "message" && event.data.role === "agent"))
    .toEqual([expect.objectContaining({ data: expect.objectContaining({ text: "", done: true, interrupted: true }) })]);
});

test("Stop reports uncertainty within three seconds when a runner ignores abort", async () => {
  const terminate = vi.fn();
  const runner: NativeAgentRunner = { run: async (turn) => {
    turn.onUpdate?.("partial answer");
    turn.onTerminate?.(terminate);
    await new Promise<void>(() => {});
    return { text: "" };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } }, true);
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "hung-stop");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "hung-stop"));
  const target = send({ kind: "message", data: { role: "user", text: "long run" } }, "hung-stop");
  await eventsUntil((event) => event.kind === "message" && event.threadId === "hung-stop" && event.data.text === "partial answer");
  const start = Date.now();
  send({ kind: "interrupt", data: { targetEventId: target } }, "hung-stop");
  const result = await eventsUntil((event) => event.kind === "stop_status" && event.data.targetEventId === target &&
    event.data.status === "unconfirmed");
  expect(Date.now() - start).toBeLessThan(4_000);
  expect(terminate).toHaveBeenCalledOnce();
  expect(result).toContainEqual(expect.objectContaining({ kind: "thread_list", data: expect.objectContaining({
    threads: expect.arrayContaining([expect.objectContaining({ id: "hung-stop", turnState: "stopped-unconfirmed" })]),
  }) }));
  expect(readThreadEvents("hung-stop", dir).some((event) => event.kind === "message" &&
    event.data.role === "agent" && event.data.done)).toBe(false);
}, 10_000);

test("Stop confirms when closing the session settles an ignored abort", async () => {
  const runner: NativeAgentRunner = { run: async (turn) => {
    const closed = Promise.withResolvers<void>();
    turn.onTerminate?.(() => closed.resolve());
    await closed.promise;
    return { text: "" };
  } };
  const { send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } }, true);
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "close-stop");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "close-stop"));
  const target = send({ kind: "message", data: { role: "user", text: "long run" } }, "close-stop");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "close-stop" && thread.turnState === "running"));
  send({ kind: "interrupt", data: { targetEventId: target } }, "close-stop");
  const outcome = await eventsUntil((event) => event.kind === "stop_status" && event.data.targetEventId === target &&
    event.data.status === "stopped");
  expect(outcome.some((event) => event.kind === "stop_status" && event.data.status === "unconfirmed")).toBe(false);
}, 10_000);

test("a successful native completion during Stop keeps the full reply and tool result", async () => {
  const finish = Promise.withResolvers<void>();
  let turn!: NativeTurn;
  const runner: NativeAgentRunner = { run: async (current) => {
    turn = current;
    current.onActivity?.("call:work", { kind: "tool_call", data: { callId: "work", name: "Bash", args: {} } });
    await finish.promise;
    current.onActivity?.("result:work", { kind: "tool_result", data: { callId: "work", ok: true, output: "done" } });
    return { text: "full answer", completed: true };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } }, true);
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "race-stop");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "race-stop"));
  const target = send({ kind: "message", data: { role: "user", text: "work" } }, "race-stop");
  await eventsUntil((event) => event.kind === "tool_call" && event.threadId === "race-stop");
  send({ kind: "interrupt", data: { targetEventId: target } }, "race-stop");
  await eventsUntil((event) => event.kind === "stop_status" && event.data.targetEventId === target &&
    event.data.status === "requested");
  expect(turn.signal.aborted).toBe(true);
  finish.resolve();
  const outcome = await eventsUntil((event) => event.kind === "stop_status" && event.data.targetEventId === target &&
    event.data.status === "completed");
  expect(outcome).toContainEqual(expect.objectContaining({ id: `native:${target}:final`, kind: "message",
    data: expect.objectContaining({ text: "full answer", done: true }) }));
  const history = readThreadEvents("race-stop", dir);
  expect(history).toContainEqual(expect.objectContaining({ id: "codex:race-stop:result:work", kind: "tool_result" }));
  expect(history).toContainEqual(expect.objectContaining({ id: `native:${target}:final`, kind: "message",
    data: expect.objectContaining({ text: "full answer", done: true }) }));
  expect(history.some((event) => event.kind === "message" && event.id === `native:${target}:final` &&
    event.data.interrupted === true)).toBe(false);
}, 10_000);

test.each(["approval", "question"] as const)("Stop withdraws an open native %s card before abort", async (kind) => {
  let turn!: NativeTurn;
  const runner: NativeAgentRunner = { run: async (current) => {
    turn = current;
    if (kind === "approval") await current.approve?.("Bash", {}, current.signal);
    else await current.ask?.("Which?", ["A"], current.signal);
    return { text: "" };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: runner } }, true);
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "card-stop");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "card-stop"));
  const target = send({ kind: "message", data: { role: "user", text: "ask" } }, "card-stop");
  const cardKind = kind === "approval" ? "approval_card" : "question_card";
  const card = (await eventsUntil((event) => event.kind === cardKind)).at(-1)!;
  send({ kind: "interrupt", data: { targetEventId: target } }, "card-stop");
  const result = await eventsUntil((event) => event.kind === "stop_status" && event.data.targetEventId === target &&
    event.data.status === "stopped");
  const answer = result.find((event) => event.kind === (kind === "approval" ? "approval_answer" : "question_answer"));
  expect(answer).toMatchObject(kind === "approval"
    ? { data: { actionId: card.kind === "approval_card" ? card.data.actionId : "", answer: "no" } }
    : { data: { questionId: card.kind === "question_card" ? card.data.questionId : "", answer: "Cancelled" } });
  expect(turn.signal.aborted).toBe(true);
  expect(readThreadEvents("card-stop", dir)).toContainEqual(expect.objectContaining({ kind: answer?.kind,
    data: expect.objectContaining(answer?.data ?? {}) }));
});


test.each([true, false])("legacy setup runs only with an injected provider (OpenClaw=%s)", async (openclaw) => {
  const scheduler = vi.spyOn(schedulerModule, "startScheduler");
  const { dir } = await pairedPhone([], openclaw);
  if (!openclaw) await vi.waitFor(() => expect(scheduler).toHaveBeenCalledTimes(1));
  else expect(scheduler).not.toHaveBeenCalled();
  expect(existsSync(join(dir, "agents", "main.md"))).toBe(!openclaw);
});

test.each(["claude-code", "codex"] as const)("a %s thread with no folder to run in is refused a turn, and the agent is never started", async (agent) => {
  const run = vi.fn(async (_turn: NativeTurn) => ({ text: "ran" }));
  // A record from before folders were required: on disk, with an agent and no `cwd`.
  const dir = mkdtempSync(join(tmpdir(), "yorozu-homeless-"));
  writeFileSync(join(dir, "threads.json"), JSON.stringify([
    { id: "legacy", title: "Old", createdAt: new Date().toISOString(), archived: false, agent },
  ]));
  const { send, eventsUntil } = await pairedPhone([], true, { stateDir: dir, nativeRunners: { [agent]: { run } } });

  send({ kind: "message", data: { role: "user", text: "go" } }, "legacy");
  const refused = (await eventsUntil((event) => event.kind === "message" && event.data.done === true)).at(-1)!;
  expect(refused).toMatchObject({ threadId: "legacy", data: { role: "agent", text: `${agent} needs one of this Mac's project folders, and this thread has none.` } });

  // And a folder that has since left `~/Projects` is no longer one this Mac agreed to.
  const gone = join(projectsRoot, `gone-${agent}`);
  mkdirSync(gone);
  send({ kind: "thread_create", data: { agent, cwd: gone } }, "cc");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "cc"));
  rmSync(gone, { recursive: true });
  send({ kind: "message", data: { role: "user", text: "go" } }, "cc");
  const orphaned = (await eventsUntil((event) => event.kind === "message" && event.data.done === true)).at(-1)!;
  expect(orphaned).toMatchObject({ threadId: "cc", data: { role: "agent", text: expect.stringMatching(/needs one of this Mac's project folders/) } });

  expect(run).not.toHaveBeenCalled();
  expect(states.filter((line) => line === "native-cwd-refused")).toHaveLength(2);
  // Refused before the turn was marked running, so nothing is left to recover on restart.
  expect(listThreads(dir).every((thread) => thread.nativeTurn === undefined)).toBe(true);
});

test("a known device cannot move its relay key without proof, and a re-hello mints no new code", async () => {
  relay = await startRelay(0);
  const lines: string[] = [];
  const qrs = qrQueue();
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-rehello-"));
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir,
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
    log: (line) => {
      lines.push(line);
      if (line.startsWith("QR ")) qrs.push(line.slice(3));
    },
  });
  const qr = await qrs.next();
  const { phone, keys } = await connectPhone(relay.port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });
  const pub = toBase64Url(generateKeypair().publicKey);
  const signingPubOf = () => loadDevices(join(stateDir, "devices.json")).find((device) => device.pub === pub)?.signingPub;
  const paired = () => lines.filter((line) => line === "STATE paired").length;
  const qrCount = () => lines.filter((line) => line.startsWith("QR ")).length;

  // First hello, with proof: enrolled, and the burnt token is replaced by the next QR.
  phone.frame(hello(qr, pub, keys.pub), keys);
  await vi.waitFor(() => expect(paired()).toBe(1));
  const next = await qrs.next();
  expect(qrCount()).toBe(2);
  expect(signingPubOf()).toBe(keys.pub);

  // The same device again, no proof: welcome back, same key, and no code was spent.
  phone.frame(encodeBody({ t: "hello", pub, spub: keys.pub }), keys);
  await vi.waitFor(() => expect(paired()).toBe(2));
  // A different relay key without proof: the relay signed this frame, and the relay could be
  // the one asking. The stored key stays, and the runtime says so.
  phone.frame(encodeBody({ t: "hello", pub, spub: "impostor" }), keys);
  await vi.waitFor(() => expect(paired()).toBe(3));
  expect(lines).toContain("STATE hello-spub-ignored");
  expect(signingPubOf()).toBe(keys.pub);
  expect(lines).not.toContain("STATE hello-refused");

  // With proof over the code on screen, the key does move — that is a re-pairing, and it
  // spends the code, so a fresh one follows. Exactly one: the two hellos above minted nothing.
  phone.frame(hello(next, pub, "moved"), keys);
  await vi.waitFor(() => expect(paired()).toBe(4));
  await qrs.next();
  expect(qrCount()).toBe(3);
  expect(signingPubOf()).toBe("moved");
});

test("a relay frame that is not JSON is one bad frame, not the end of the sidecar", async () => {
  const seen: string[] = [];
  const fake = new WebSocketServer({ port: 0 });
  fake.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Record<string, unknown>;
      seen.push(String(msg.type));
      if (msg.type === "register") {
        // Garbage first, then the real answer: both reach the same handler.
        ws.send("this is not json");
        ws.send(JSON.stringify({ type: "registered", roomId: "r" }));
      }
    });
  });
  const lines: string[] = [];
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${(fake.address() as AddressInfo).port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-badframe-")),
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
    log: (line) => void lines.push(line),
  });
  await vi.waitFor(() => expect(lines).toContain("STATE registered"));
  expect(lines.some((line) => line.startsWith("STATE frame-error "))).toBe(true);
  // Still alive and still talking: registration went on to ask for a token.
  await vi.waitFor(() => expect(seen).toContain("mint"));
  await sidecar.close();
  await new Promise<void>((done) => fake.close(() => done()));
});

test("a frame whose body is not a frame is logged and acked, and the relay's own state is surfaced", async () => {
  // A relay double that replays three bodies nothing can handle — a box with a number for a
  // nonce, an array, a payload that is not even a string — each tagged with a buffer seq, and
  // then says something about itself. None may kill the sidecar, and each is acked: an
  // unhandleable frame left unacked would sit at the head of the buffer for ever.
  const acks: number[] = [];
  const seen: string[] = [];
  const fake = new WebSocketServer({ port: 0 });
  fake.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Record<string, unknown>;
      seen.push(String(msg.type));
      if (msg.type === "ack") acks.push(msg.seq as number);
      if (msg.type === "register") {
        ws.send(JSON.stringify({ type: "registered", roomId: "r" }));
        ws.send(JSON.stringify({ type: "frame", payload: encodeBody({ t: "box", n: 5, c: "c" }), seq: 3 }));
        ws.send(JSON.stringify({ type: "frame", payload: encodeBody([1, 2]), seq: 4 }));
        ws.send(JSON.stringify({ type: "frame", payload: 12, seq: 5 }));
        // A well-formed box nobody here can open is handled — to nothing — and acked too.
        ws.send(JSON.stringify({ type: "frame", payload: encodeBody({ t: "box", n: "n", c: "c" }), seq: 6 }));
        ws.send(JSON.stringify({ type: "state", state: "notify rate limit" }));
      }
    });
  });
  const lines: string[] = [];
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${(fake.address() as AddressInfo).port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-malformed-")),
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
    log: (line) => void lines.push(line),
  });
  await vi.waitFor(() => expect(acks).toEqual([3, 4, 5, 6]));
  expect(lines.filter((line) => line === "STATE frame-error malformed body")).toHaveLength(3);
  expect(lines).toContain("STATE relay-notify rate limit");
  // Still alive: a token is still asked for after all that.
  await vi.waitFor(() => expect(seen).toContain("mint"));
  await sidecar.close();
  await new Promise<void>((done) => fake.close(() => done()));
});

test("a seventeenth phone is refused, the list never grows past the cap, and the state dir is tightened", async () => {
  relay = await startRelay(0);
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-cap-"));
  // What an older release left behind: a state directory anyone on the Mac may list.
  chmodSync(stateDir, 0o755);
  const full = Array.from({ length: MAX_DEVICES }, (_, i) => ({
    pub: toBase64Url(generateKeypair().publicKey), signingPub: `s${i}`, pairedAt: 1, lastSeen: 1,
  }));
  writeFileSync(join(stateDir, "devices.json"), JSON.stringify(full));

  const lines: string[] = [];
  let qrLine!: (line: string) => void;
  const qrPrinted = new Promise<string>((resolve) => (qrLine = resolve));
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir,
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
    log: (line) => {
      lines.push(line);
      if (line.startsWith("QR ")) qrLine(line.slice(3));
    },
  });
  expect(statSync(stateDir).mode & 0o777).toBe(0o700);

  const qr = decodeQrPayload(await qrPrinted);
  const { phone, keys } = await connectPhone(relay.port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });
  const phoneKeys = generateKeypair();
  const pub = toBase64Url(phoneKeys.publicKey);
  // Proof and all: it is the count that refuses it, not the enrolment.
  phone.frame(hello(qr, pub, keys.pub), keys);
  await vi.waitFor(() => expect(lines).toContain("STATE hello-refused device-limit"));
  expect(lines).not.toContain("STATE paired");
  expect(loadDevices(join(stateDir, "devices.json")).map((device) => device.pub)).not.toContain(pub);

  const mac = await macClient(stateDir);
  try {
    await vi.waitFor(() => expect(mac.events.some((event) => event.kind === "device_list")).toBe(true));
    const list = mac.events.findLast((event) => event.kind === "device_list")!;
    if (list.kind !== "device_list") throw new Error("unreachable");
    expect(list.data.devices.filter((device) => device.via === "relay")).toHaveLength(MAX_DEVICES);
  } finally {
    mac.close();
  }
});

test("agent_status is answered to the asker with every agent the runtime has", async () => {
  const { send, eventsUntil } = await pairedPhone([], true);
  send({ kind: "agent_status", data: {} }, "");
  const [answer] = (await eventsUntil((event) => event.kind === "agent_status")).slice(-1);
  if (answer?.kind !== "agent_status") throw new Error("no agent_status answer");
  expect(answer.data).not.toHaveProperty("openclaw");
  expect(answer.data.claude).toHaveProperty("ok");
  expect(answer.data.codex).toHaveProperty("ok");
});

/** OpenClaw's `yorozu` channel plugin on `channel.sock`: raw frames, everything it hears. */
async function channelPlugin(dir: string) {
  const socket = createConnection(channelSocketPath(dir));
  const frames: HostFrame[] = [];
  let buffer = "";
  socket.setEncoding("utf8");
  socket.on("data", (chunk: string) => {
    buffer += chunk;
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    for (const line of lines) if (line) frames.push(JSON.parse(line));
  });
  await new Promise<void>((resolve, reject) => { socket.once("connect", resolve); socket.once("error", reject); });
  return { frames, send: (frame: PluginFrame) => socket.write(`${JSON.stringify(frame)}\n`), close: () => socket.destroy() };
}

test("OpenClaw delivers into threads, and user messages wait for the plugin's ack", async () => {
  relay = await startRelay(0);
  const dir = mkdtempSync(join(tmpdir(), "yorozu-channel-"));
  sidecar = serve({ relayUrl: `ws://127.0.0.1:${relay.port}`, stateDir: dir });
  await vi.waitFor(() => expect(existsSync(channelSocketPath(dir))).toBe(true));
  const plugin = await channelPlugin(dir);
  const mac = await macClient(dir);

  // Proactive: a thread OpenClaw names is created, logged and published.
  plugin.send({ type: "deliver", id: "cron-1", threadId: "reports", text: "Nikkei closed up", title: "Reports" });
  await vi.waitFor(() => expect(plugin.frames).toContainEqual({ type: "ack", id: "cron-1" }));
  plugin.send({ type: "deliver", id: "cron-1", threadId: "reports", text: "Nikkei closed up" });
  await vi.waitFor(() => expect(plugin.frames.filter((frame) => frame.type === "ack")).toHaveLength(2));
  expect(readThreadEvents("reports", dir).filter((event) => event.id === "cron-1")).toMatchObject([
    { kind: "message", data: { role: "agent", text: "Nikkei closed up", done: true } }]);
  expect(listThreads(dir).find((thread) => thread.id === "reports")?.title).toBe("Reports");
  await vi.waitFor(() => expect(mac.events.some((event) => event.id === "cron-1")).toBe(true));

  // A native thread is not the channel's to write into.
  createThread(undefined, dir, "code", { agent: "codex", cwd: proj });
  plugin.send({ type: "deliver", id: "x", threadId: "code", text: "no" });
  await vi.waitFor(() => expect(plugin.frames).toContainEqual({ type: "error", id: "x", reason: "not-a-channel-thread" }));

  // Outbound: a user message goes to the plugin, not the Gateway runner, and survives a reconnect until acked.
  mac.send({ kind: "message", data: { role: "user", text: "thanks" }, threadId: "reports" } as never);
  const inbound = () => plugin.frames.find((frame) => frame.type === "inbound");
  await vi.waitFor(() => expect(inbound()).toMatchObject({ message: { threadId: "reports", text: "thanks" } }));
  plugin.close();
  const again = await channelPlugin(dir);
  await vi.waitFor(() => expect(again.frames).toContainEqual(inbound()));
  if (inbound()?.type === "inbound") again.send({ type: "ack", id: (inbound() as { message: { id: string } }).message.id });
  await vi.waitFor(() => expect(JSON.parse(readFileSync(join(dir, "channel-outbox.json"), "utf8"))).toEqual([]));
  again.close();
  mac.close();
});

test("channel threads are titled from their opening message", async () => {
  relay = await startRelay(0);
  const dir = mkdtempSync(join(tmpdir(), "yorozu-channel-title-"));
  sidecar = serve({ relayUrl: `ws://127.0.0.1:${relay.port}`, stateDir: dir, titler: async () => "Weekend plans" });
  await vi.waitFor(() => expect(existsSync(channelSocketPath(dir))).toBe(true));
  const plugin = await channelPlugin(dir);
  const mac = await macClient(dir);

  // Typed by the user: titled like any thread, even though OpenClaw answers with no turn here.
  createThread(undefined, dir, "chat");
  mac.send({ kind: "message", data: { role: "user", text: "what should we do on saturday" }, threadId: "chat" } as never);
  await vi.waitFor(() => expect(listThreads(dir).find((thread) => thread.id === "chat")?.title).toBe("Weekend plans"));

  // Opened by OpenClaw with no title of its own: titled from what it said.
  plugin.send({ type: "deliver", id: "cron-2", threadId: "news", text: "Morning briefing" });
  await vi.waitFor(() => expect(listThreads(dir).find((thread) => thread.id === "news")?.title).toBe("Weekend plans"));
  plugin.close();
  mac.close();
});

test("the direct path is off unless configured: nothing listens and no address is sent", async () => {
  const { eventsUntil, send } = await pairedPhone([]);
  const id = send({ kind: "thread_list", data: { threads: [], peerInfo: localPeerInfo("test") } }, "");
  const list = (await eventsUntil((event) => event.kind === "thread_list" && event.data.peerInfoReplyTo === id)).at(-1)!;
  expect(list.kind === "thread_list" && list.data).not.toHaveProperty("directUrl");
});

test("the direct path takes paired devices only, carries the same sealed boxes, and names itself sealed", async () => {
  const port = await new Promise<number>((resolve) => {
    const probe = createServer().listen(0, "127.0.0.1", () => {
      const { port } = probe.address() as AddressInfo;
      probe.close(() => resolve(port));
    });
  });
  const url = "wss://mac.example.ts.net:8443";
  const { eventsUntil, send, channel, keys, qr } = await pairedPhone([], false, { direct: { port, url } });
  // The address rides only inside the replay-protected thread list.
  const id = send({ kind: "thread_list", data: { threads: [], peerInfo: localPeerInfo("test") } }, "");
  const sealed = (await eventsUntil((event) => event.kind === "thread_list" && event.data.peerInfoReplyTo === id)).at(-1)!;
  expect(sealed.kind === "thread_list" && sealed.data.directUrl).toBe(url);

  // Loopback only.
  const bound = await new Promise<boolean>((resolve) => {
    const other = Object.values(networkInterfaces()).flat().find((i) => i?.family === "IPv4" && !i.internal);
    if (!other) return resolve(false);
    const probe = createConnection(port, other.address);
    probe.once("connect", () => { probe.destroy(); resolve(true); });
    probe.once("error", () => resolve(false));
  });
  expect(bound).toBe(false);

  // A stranger is refused, even with a well-signed join.
  const stranger = await rejoinPhone(port, qr.roomId!, keypair());
  expect(await stranger.closed).toBe(4001);

  // The paired phone rejoins by nonce, and its sealed request is answered on the same socket.
  const direct = await rejoinPhone(port, qr.roomId!, keys);
  expect(await direct.next()).toMatchObject({ type: "joined" });
  direct.frame(channel.box({ id: "direct-sync", threadId: "", ts: Date.now(), agentId: "phone",
    kind: "sync_request", data: { lastSeen: {} } }), keys);
  const answer = await nextModernEnvelope(direct, channel);
  expect(answer.event.kind).toBe("receipt");
  direct.ws.close();
});

test.each(["steer", "unsupported", "declined", "failed"])("follow-up delivery uses %s and reports the effective queue", async (mode) => {
  const ready = Promise.withResolvers<void>();
  const finish = Promise.withResolvers<void>();
  const inputs: { text: string; attachments: NativeTurn["attachments"] }[] = [];
  const run = vi.fn(async (turn: NativeTurn) => {
    if (turn.text === "first") {
      if (mode !== "unsupported") turn.onSteer?.(async (text, attachments) => {
        if (mode === "failed") throw new Error("turn ended");
        if (mode === "declined") return false;
        inputs.push({ text, attachments });
        return true;
      });
      ready.resolve();
      await finish.promise;
    }
    return { text: `reply to ${turn.text}` };
  });
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: { run } } }, true);
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "delivery");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "delivery"));
  const active = send({ kind: "message", data: { role: "user", text: "first" } }, "delivery");
  await ready.promise;
  const follow = randomUUID();
  const ts = Date.now();
  const bytes = Buffer.from("context");
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  send({ kind: "attachment_chunk", data: { messageId: follow, index: 0, offset: 0,
    totalBytes: bytes.length, sha256, deadline: ts + 30 * 60_000, data: bytes.toString("base64") } }, "delivery");
  await eventsUntil((event) => event.kind === "attachment_progress" && event.data.messageId === follow);
  sendRaw({ id: follow, ts, threadId: "delivery", agentId: "phone", kind: "attachment_commit",
    data: { text: "follow", delivery: "steer", admissionDeadline: ts + 30 * 60_000,
      attachments: [{ name: "note.txt", mime: "text/plain", bytes: bytes.length, sha256 }] } });
  await eventsUntil((event) => event.kind === "message" && event.id === follow &&
    event.data.delivery === (mode === "steer" ? "steer" : "queue"));
  // Send now targets the already admitted message; retries cannot inject it twice.
  send({ kind: "steer", data: { targetEventId: follow } }, "delivery");
  const retry = send({ kind: "steer", data: { targetEventId: follow } }, "delivery");
  await eventsUntil((event) => event.kind === "receipt" && event.data.eventId === retry);
  send({ kind: "admission_query", data: { eventId: follow } }, "delivery");
  const status = (await eventsUntil((event) => event.kind === "admission_status" && event.data.eventId === follow)).at(-1);
  expect(status).toMatchObject({ data: { status: mode === "steer" ? "running" : "queued",
    delivery: mode === "steer" ? "steer" : "queue" } });
  expect(run).toHaveBeenCalledTimes(1);
  if (mode === "steer") {
    expect(inputs).toHaveLength(1);
    expect(inputs[0]!.text).toContain("follow\n\n[attached:");
    expect(readFileSync(inputs[0]!.attachments![0]!.path, "utf8")).toBe("context");
    expect(readThreadEvents("delivery", dir).find((event) => event.id === follow))
      .toMatchObject({ clientTs: expect.any(Number), data: { completionId: `native:${active}:final` } });
  } else expect(inputs).toEqual([]);
  finish.resolve();
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "delivery" && thread.turnState === "idle"));
  expect(run).toHaveBeenCalledTimes(mode === "steer" ? 1 : 2);
  const history = readThreadEvents("delivery", dir).filter((event) => event.kind === "message");
  expect(history.map((event) => event.data.role)).toEqual(mode === "steer"
    ? ["user", "user", "agent"] : ["user", "agent", "user", "agent"]);
  await sidecar.close();
  await relay.close();
  const restarted = await pairedPhone([], false, { stateDir: dir, nativeRunners: { codex: { run } } }, true);
  restarted.send({ kind: "admission_query", data: { eventId: follow } }, "delivery");
  expect((await restarted.eventsUntil((event) => event.kind === "admission_status" && event.data.eventId === follow)).at(-1))
    .toMatchObject({ data: { status: "completed", delivery: mode === "steer" ? "steer" : "queue" } });
  expect(run).toHaveBeenCalledTimes(mode === "steer" ? 1 : 2);
});

test("Send now removes only the selected queue entry and holds while a question is open", async () => {
  const ready = Promise.withResolvers<NativeTurn>();
  const finish = Promise.withResolvers<void>();
  const inputs: string[] = [];
  const run = vi.fn(async (turn: NativeTurn) => {
    if (turn.text === "first") {
      turn.onSteer?.(async (text) => { inputs.push(text); return true; });
      ready.resolve(turn);
      await finish.promise;
    }
    return { text: `reply to ${turn.text}` };
  });
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: { run } } }, true);
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "send-now");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "send-now"));
  const active = send({ kind: "message", data: { role: "user", text: "first" } }, "send-now");
  const turn = await ready.promise;
  const next = send({ kind: "message", data: { role: "user", text: "next" } }, "send-now");
  const later = send({ kind: "message", data: { role: "user", text: "later" } }, "send-now");
  await eventsUntil((event) => event.kind === "message" && event.id === later);
  const answer = turn.ask!("Which?", ["A", "B"], turn.signal);
  const card = (await eventsUntil((event) => event.kind === "question_card")).at(-1)!;
  const held = send({ kind: "steer", data: { targetEventId: next } }, "send-now");
  await eventsUntil((event) => event.kind === "receipt" && event.data.eventId === held);
  expect(inputs).toEqual([]);
  if (card.kind !== "question_card") throw new Error("missing question");
  send({ kind: "question_answer", data: { questionId: card.data.questionId, answer: "A" } }, "send-now");
  await answer;
  send({ kind: "steer", data: { targetEventId: next } }, "send-now");
  await eventsUntil((event) => event.kind === "message" && event.id === next && event.data.delivery === "steer");
  expect(inputs).toEqual(["next"]);
  const state = (await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "send-now" && thread.queuedEventIds?.length === 1))).at(-1);
  expect(state).toMatchObject({ data: { threads: expect.arrayContaining([
    expect.objectContaining({ id: "send-now", activeEventId: active, turnState: "running", queuedEventIds: [later] }),
  ]) } });
  finish.resolve();
  await eventsUntil((event) => event.kind === "message" && event.data.text === "reply to later");
  expect(run.mock.calls.map(([turn]) => turn.text)).toEqual(["first", "later"]);
  expect(readThreadEvents("send-now", dir).filter((event) => event.kind === "message").map((event) => event.data.text))
    .toEqual(["first", "next", "reply to first", "later", "reply to later"]);
});

test.each(["claude-code", "codex"])("%s delivers follow-ups through its live native input without another turn", async (agent) => {
  const ready = Promise.withResolvers<void>();
  const finish = Promise.withResolvers<void>();
  const inputs: unknown[] = [];
  let starts = 0;
  let handlers: CodexHandlers;
  const query = (({ prompt }: Parameters<QueryFn>[0]) => {
    starts += 1;
    if (typeof prompt === "string") throw new Error("steering needs streaming input");
    const stream = prompt[Symbol.asyncIterator]();
    return Object.assign((async function* () {
      inputs.push((await stream.next()).value);
      ready.resolve();
      yield { type: "system", subtype: "init", session_id: "session" };
      inputs.push((await stream.next()).value);
      await finish.promise;
      yield { type: "result", subtype: "success", session_id: "session", result: "followed" };
    })(), { close: () => { finish.resolve(); } });
  }) as QueryFn;
  const connect: ConnectCodex = (h) => {
    handlers = h;
    return {
      async request(method, params) {
        if (method === "thread/start") return { thread: { id: "session" } };
        if (method === "turn/start") {
          starts += 1;
          inputs.push(params);
          ready.resolve();
          return { turn: { id: "active-turn" } };
        }
        if (method === "turn/steer") {
          inputs.push(params);
          return { turnId: "active-turn" };
        }
        return {};
      },
      notify() {}, close() {},
    };
  };
  const runner = agent === "claude-code" ? claudeCodeRunner(query) : codexNativeRunner(connect);
  const { send, eventsUntil } = await pairedPhone([], false,
    { nativeRunners: { [agent]: { ...runner, models: async () => [], skills: async () => [] } } }, true);
  send({ kind: "thread_create", data: { agent, cwd: proj } }, "native-steer");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "native-steer"));
  const active = send({ kind: "message", data: { role: "user", text: "start" } }, "native-steer");
  await ready.promise;
  const follow = send({ kind: "message", data: { role: "user", text: "adjust", delivery: "steer",
    attachments: [{ name: "image.png", mime: "image/png", data: "aGk=" }] } }, "native-steer");
  await eventsUntil((event) => event.kind === "message" && event.id === follow && event.data.delivery === "steer");
  await vi.waitFor(() => expect(inputs).toHaveLength(2));
  if (agent === "claude-code") {
    expect(inputs[0]).toMatchObject({ type: "user", message: { role: "user", content: "start" } });
    expect(inputs[1]).toMatchObject({ type: "user", message: { role: "user", content: expect.stringContaining("adjust\n\n[attached:") } });
    finish.resolve();
  } else {
    expect(inputs[1]).toMatchObject({ threadId: "session", expectedTurnId: "active-turn", input: [
      { type: "text", text: expect.stringContaining("adjust\n\n[attached:"), text_elements: [] },
      { type: "localImage", path: expect.stringContaining("image.png") },
    ] });
    handlers!.notify("item/completed", { threadId: "session", item: { type: "agentMessage", id: "reply", text: "followed" } });
    handlers!.notify("turn/completed", { threadId: "session", turn: { id: "active-turn", status: "completed" } });
  }
  await eventsUntil((event) => event.kind === "message" && event.id === `native:${active}:final` && event.data.done === true);
  expect(starts).toBe(1);
});

test.each(["complete", "stop", "withdraw"])("steering confirmation racing %s never starts or withdraws the delivered follow-up", async (action) => {
  const ready = Promise.withResolvers<void>();
  const attempted = Promise.withResolvers<void>();
  const delivered = Promise.withResolvers<boolean>();
  const finish = Promise.withResolvers<void>();
  const run = vi.fn(async (turn: NativeTurn) => {
    turn.onSteer?.(() => { attempted.resolve(); return delivered.promise; });
    turn.signal.addEventListener("abort", () => finish.resolve(), { once: true });
    ready.resolve();
    await finish.promise;
    return { text: "finished" };
  });
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { codex: { run } } }, true);
  send({ kind: "thread_create", data: { agent: "codex", cwd: proj } }, "steer-race");
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "steer-race"));
  const active = send({ kind: "message", data: { role: "user", text: "first" } }, "steer-race");
  await ready.promise;
  const follow = send({ kind: "message", data: { role: "user", text: "follow", delivery: "steer" } }, "steer-race");
  await attempted.promise;
  if (action === "complete") finish.resolve();
  else send({ kind: "interrupt", data: { targetEventId: action === "stop" ? active : follow } }, "steer-race");
  send({ kind: "admission_query", data: { eventId: follow } }, "steer-race");
  await eventsUntil((event) => event.kind === "admission_status" && event.data.eventId === follow);
  delivered.resolve(true);
  await eventsUntil((event) => event.kind === "message" && event.id === follow && event.data.delivery === "steer");
  finish.resolve();
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) =>
    thread.id === "steer-race" && thread.turnState === "idle"));
  const history = readThreadEvents("steer-race", dir);
  expect(history.filter((event) => event.kind === "message").map((event) => event.id))
    .toEqual([active, follow, `native:${active}:final`]);
  expect(history.some((event) => event.kind === "stop_status" && event.data.targetEventId === follow && event.data.status === "withdrawn"))
    .toBe(false);
  expect(run).toHaveBeenCalledTimes(1);
});

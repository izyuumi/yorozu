import { randomUUID } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay, type Relay } from "@yorozu/relay";
import { connectPhone, rejoinPhone } from "@yorozu/relay/dist/testing.js";
import {
  decodeQrPayload,
  deriveSessionKey,
  fromBase64Url,
  generateKeypair,
  helloProof,
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
import { createConnection } from "node:net";
import { afterEach, expect, test, vi } from "vitest";
import { WebSocketServer } from "ws";
import { openaiCompat } from "./provider.js";
import { loadDevices, loadKeys, serve as startSidecar, typedAnswer, type ServeOptions, type Sidecar } from "./serve.js";
import type { NativeAgentRunner, NativeTurn } from "./native.js";
import * as schedulerModule from "./scheduler.js";
import { OpenClawRunner, type OpenClawTurn } from "./openclaw.js";
import { localSocketPath } from "./local.js";
import { SYNC_PAGE_BYTES, setNativeTurn, setThreadSession, appendThreadEvent, createThread, listThreads, readThreadEvents } from "./threads.js";
import { readTranscripts, transcriptDir } from "./transcripts.js";

const serve = (options: ServeOptions): Sidecar => startSidecar({ nativeRunners: {}, ...options });

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
 * The next event sealed for this phone that is not a receipt. Every command is receipted
 * before it is answered, and a test reading frames one at a time is after the answer.
 */
async function nextEvent(
  client: { next: () => Promise<{ payload: string }> },
  sessionKey: Uint8Array,
): Promise<YorozuEvent> {
  for (;;) {
    const body = frameBody((await client.next()).payload);
    const plain = open(sessionKey, fromBase64Url(body.n), fromBase64Url(body.c));
    const event = JSON.parse(Buffer.from(plain).toString()) as YorozuEvent;
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
  const sessionKey = deriveSessionKey(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
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
  const box = seal(sessionKey, Buffer.from(JSON.stringify(sent)));
  phone.frame(
    encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }),
    keys,
  );

  const openNext = (): Promise<YorozuEvent> => nextEvent(phone, sessionKey);

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

  // The same message again — a relay replaying an unacked frame, or a phone retrying a send
  // it never saw land — is not a second turn and not a second line in the thread.
  phone.frame(
    encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }),
    keys,
  );
  await vi.waitFor(() => expect(lines).toContain("STATE duplicate-command"));
  expect(fetchMock).toHaveBeenCalledTimes(1);
  expect(readThreadEvents("t1", stateDir).filter((e) => e.id === "e1")).toHaveLength(1);
});

test.each([false, true])("a phone rejoins without hello and preserves a safe cutoff (legacy=%s)", async (legacy) => {
  relay = await startRelay(0);
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-rejoin-"));
  const fetchMock = vi.fn<typeof fetch>().mockImplementation(async () => sse("pong"));

  // Two sidecars in a row over one state dir: the second is the "restart".
  const start = () => {
    let qrLine!: (line: string) => void;
    const qr = new Promise<string>((resolve) => (qrLine = resolve));
    const cast = serve({
      relayUrl: `ws://127.0.0.1:${relay.port}`,
      stateDir,
      provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: fetchMock }),
      log: (line) => {
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
  const sessionKey = deriveSessionKey(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  const pub = toBase64Url(phoneKeys.publicKey);
  phone.frame(hello(qr, pub, keys.pub), keys);
  // The `hello` is what writes the phone into `devices.json`.
  await vi.waitFor(() =>
    expect(loadDevices(join(stateDir, "devices.json")).map((device) => device.pub)).toEqual([pub]),
  );

  phone.ws.close();
  await first.cast.close();
  const originalPairedAt = loadDevices(join(stateDir, "devices.json"))[0]!.pairedAt;
  if (legacy) writeFileSync(join(stateDir, "devices.json"), JSON.stringify([{ pub, lastSeen: 1 }]));
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
  const sync = seal(sessionKey, Buffer.from(JSON.stringify({ id: "sync", threadId: "", ts: Date.now(), agentId: "phone", kind: "sync_request", data: { lastSeen: {} } })));
  again.frame(encodeBody({ t: "box", n: toBase64Url(sync.nonce), c: toBase64Url(sync.ciphertext) }), keys);
  expect(await nextEvent(again, sessionKey)).toMatchObject({ kind: "sync_delta", data: { events: [] } });

  const sent: YorozuEvent = {
    id: "e2",
    threadId: "home",
    ts: Date.now(),
    agentId: "phone",
    kind: "message",
    data: { role: "user", text: "ping" },
  };
  const box = seal(sessionKey, Buffer.from(JSON.stringify(sent)));
  again.frame(encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }), keys);

  expect(await nextEvent(again, sessionKey)).toMatchObject({
    threadId: "home",
    kind: "message",
    data: { role: "user", text: "ping" },
  });
  expect(await nextEvent(again, sessionKey)).toMatchObject({
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
async function pairedPhone(responses: (() => Response)[], openclaw = false, extra: Partial<ServeOptions> = {}) {
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
  const sessionKey = deriveSessionKey(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(hello(qr, toBase64Url(phoneKeys.publicKey), keys.pub), keys);

  sendRaw = (full: YorozuEvent): void => {
    const box = seal(sessionKey, Buffer.from(JSON.stringify(full)));
    phone.frame(encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }), keys);
  };
  const send = (
    event: Omit<YorozuEvent, "id" | "threadId" | "ts" | "agentId">,
    threadId = "t1",
  ): void => sendRaw({ id: randomUUID(), threadId, ts: Date.now(), agentId: "phone", ...event } as YorozuEvent);

  /** Everything the sidecar sends, up to and including the first event `done` accepts. */
  async function eventsUntil(done: (event: YorozuEvent) => boolean): Promise<YorozuEvent[]> {
    const seen: YorozuEvent[] = [];
    for (;;) {
      const body = frameBody((await phone.next()).payload);
      const plain = open(sessionKey, fromBase64Url(body.n), fromBase64Url(body.c));
      const event = JSON.parse(Buffer.from(plain).toString()) as YorozuEvent;
      seen.push(event);
      if (done(event)) return seen;
    }
  }

  const isReply = (event: YorozuEvent): boolean =>
    event.kind === "message" && event.data.role === "agent";

  return { dir, send, eventsUntil, isReply };
}

test("OpenClaw activity reaches Mac and encrypted phone live, then replays during a running tool", async () => {
  vi.spyOn(OpenClawRunner.prototype, "listModels").mockResolvedValue([]);
  let turn!: OpenClawTurn;
  let finish!: (reply: string) => void;
  vi.spyOn(OpenClawRunner.prototype, "run").mockImplementation(async (value) => {
    turn = value;
    return new Promise<string>((resolve) => { finish = resolve; });
  });
  const { dir, send, eventsUntil } = await pairedPhone([], true);
  const mac = createConnection(localSocketPath(dir));
  const macEvents: YorozuEvent[] = [];
  let buffer = "";
  mac.setEncoding("utf8");
  mac.on("data", (chunk: string) => {
    buffer += chunk;
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    for (const line of lines) if (line) macEvents.push(JSON.parse(line));
  });
  try {
    await new Promise<void>((resolve, reject) => { mac.once("connect", resolve); mac.once("error", reject); });
    send({ kind: "thread_create", data: {} });
    send({ kind: "message", data: { role: "user", text: "inspect" } });
    await vi.waitFor(() => expect(turn).toBeDefined());
    const startup: YorozuEvent = { id: "startup", threadId: "t1", ts: Date.now(), agentId: "main", kind: "thought", data: { text: "Starting OpenClaw…", transient: true } };
    turn.onEvent?.(startup);
    expect((await eventsUntil((event) => event.id === startup.id)).at(-1)).toEqual(startup);
    expect(readThreadEvents("t1", dir)).not.toContainEqual(startup);
    expect(readTranscripts(new Date(0), transcriptDir(dir))).not.toContainEqual(startup);
    const activity: YorozuEvent = { id: "live-call", threadId: "t1", ts: Date.now(), agentId: "main", kind: "tool_call", data: { callId: "call-1", name: "read", args: {} } };
    turn.onEvent?.(activity);
    expect((await eventsUntil((event) => event.id === activity.id)).at(-1)).toEqual(activity);
    await vi.waitFor(() => expect(macEvents).toContainEqual(activity));
    expect(readThreadEvents("t1", dir)).toContainEqual(activity);
    // A reconnecting phone's normal sync sees the in-flight call before a final answer exists.
    send({ kind: "sync_request", data: { lastSeen: {} } });
    const replay = (await eventsUntil((event) => event.kind === "sync_delta")).at(-1)!;
    expect(JSON.stringify(replay)).toContain("live-call");
    const result: YorozuEvent = { ...activity, id: "live-result", kind: "tool_result", data: { callId: "call-1", ok: true, output: "contents" } };
    turn.onEvent?.(result);
    expect((await eventsUntil((event) => event.id === result.id)).at(-1)).toEqual(result);
    finish("Done");
    await eventsUntil((event) => event.kind === "message" && event.data.done === true);
    expect((await threadsAfter(eventsUntil)).find((thread) => thread.id === "t1")?.title).toBe("inspect");
    expect(readThreadEvents("t1", dir).filter((event) => event.kind.startsWith("tool_")).map((event) => event.id)).toEqual(["live-call", "live-result"]);
  } finally {
    mac.destroy();
  }
});

test("a thread is answered by the agent it was created for, and an unknown agent is refused", async () => {
  vi.spyOn(OpenClawRunner.prototype, "listModels").mockResolvedValue([]);
  const run = vi.spyOn(OpenClawRunner.prototype, "run").mockResolvedValue("from openclaw");
  const archive = vi.spyOn(OpenClawRunner.prototype, "setArchived").mockResolvedValue(undefined);
  const { dir, send, eventsUntil } = await pairedPhone([], true, { nativeRunners: {} });

  // Nobody answers a thread for an agent that does not exist, and no thread is made for it.
  send({ kind: "thread_create", data: { agent: "hermes" as never } }, "bad");
  const refused = (await eventsUntil((event) => event.kind === "thought")).at(-1)!;
  expect(refused).toMatchObject({ threadId: "bad", data: { text: expect.stringMatching(/unknown agent "hermes"/) } });
  expect(listThreads(dir).map((thread) => thread.id)).toEqual([]);
  expect(states).toContain('thread-create-error unknown agent "hermes"');
  // Nor is a folder the picker never offered: a path typed into a frame is not a folder this
  // Mac agreed to open an agent in.
  send({ kind: "thread_create", data: { agent: "claude-code", cwd: "/etc" } }, "bad2");
  const refusedFolder = (await eventsUntil((event) => event.kind === "thought")).at(-1)!;
  expect(refusedFolder).toMatchObject({ threadId: "bad2", data: { text: expect.stringMatching(/not one of this Mac's project folders/) } });
  expect(listThreads(dir).map((thread) => thread.id)).toEqual([]);

  // The list carries who answers each thread; a plain thread says nothing, as it always has.
  send({ kind: "thread_create", data: { agent: "claude-code", cwd: proj } }, "cc");
  send({ kind: "thread_create", data: {} }, "t1");
  const threads = (await eventsUntil((event) =>
    event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "t1"),
  )).at(-1)! as YorozuEvent & { kind: "thread_list" };
  expect(threads.data.threads.find((thread) => thread.id === "cc")).toMatchObject({ agent: "claude-code", cwd: proj });
  expect(threads.data.threads.find((thread) => thread.id === "t1")).not.toHaveProperty("agent");

  // A turn in the native thread never reaches OpenClaw: its own backend answers, and where no
  // runner is wired the answer is that it is not, finished, so the composer is not left waiting.
  send({ kind: "message", data: { role: "user", text: "fix the tests" } }, "cc");
  const reply = (await eventsUntil((event) => event.kind === "message" && event.data.done === true)).at(-1)!;
  expect(reply).toMatchObject({ threadId: "cc", data: { role: "agent", text: expect.stringMatching(/claude-code.*not available/i) } });
  expect(run).not.toHaveBeenCalled();
  expect(readThreadEvents("cc", dir).map((event) => event.kind)).toEqual(["message", "message"]);

  // Stop, archive, model and effort all go to the thread's own agent too: none of them is
  // OpenClaw's business here, and archiving does not wait on a Gateway that never saw the thread.
  send({ kind: "interrupt", data: {} }, "cc");
  send({ kind: "thread_set_model", data: { model: "claude/claude-opus-5" } }, "cc");
  send({ kind: "thread_set_effort", data: { effort: "high" } }, "cc");
  send({ kind: "thread_archive", data: { archived: true } }, "cc");
  const archived = (await eventsUntil((event) =>
    event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "cc" && thread.archived),
  )).at(-1)! as YorozuEvent & { kind: "thread_list" };
  // A provider spec is not a native SDK model; unavailable agents publish no effort choices.
  expect(archived.data.threads.find((thread) => thread.id === "cc")?.model).toBeUndefined();
  expect(archived.data.threads.find((thread) => thread.id === "cc")?.effort).toBeUndefined();
  expect(archive).not.toHaveBeenCalled();

  // While the plain thread still goes where it always went.
  send({ kind: "message", data: { role: "user", text: "hello" } }, "t1");
  await eventsUntil((event) => event.kind === "message" && event.data.done === true && event.threadId === "t1");
  expect(run).toHaveBeenCalledTimes(1);
  send({ kind: "thread_archive", data: { archived: true } }, "t1");
  await vi.waitFor(() => expect(archive).toHaveBeenCalledWith("t1", true));
});

test.each(["claude-code", "codex"] as const)("a %s thread runs, resumes and stops its own native session, never OpenClaw's", async (agent) => {
  vi.spyOn(OpenClawRunner.prototype, "listModels").mockResolvedValue([]);
  const openclawRun = vi.spyOn(OpenClawRunner.prototype, "run").mockResolvedValue("from openclaw");
  const turns: NativeTurn[] = [];
  let release!: () => void;
  const runner: NativeAgentRunner = {
    run: vi.fn(async (turn: NativeTurn) => {
      turns.push(turn);
      if (turn.text === "break") throw new Error("claude is not logged in");
      if (turns.length < 3) {
        turn.onUpdate?.("working");
        if (turns.length === 1) {
          turn.onActivity?.("u1:thinking", { kind: "thought", data: { text: "reading the failing test" } });
          turn.onActivity?.("call:toolu_1", { kind: "tool_call", data: { callId: "toolu_1", name: "Bash", args: { command: "cat big.log" } } });
          turn.onActivity?.("result:toolu_1", { kind: "tool_result", data: { callId: "toolu_1", ok: true, output: "L".repeat(5000) } });
        }
        return { text: `reply ${turns.length}`, sessionId: "s-1" };
      }
      // The third turn hangs until stopped, the way a long job would.
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
  await eventsUntil((event) => event.kind === "message" && event.data.done === true);
  expect(turns[1]).toMatchObject({ cwd: proj, sessionId: "s-1" });

  // Stop aborts the running turn; nothing is said, and the session is still the one to resume.
  send({ kind: "message", data: { role: "user", text: "long job" } }, "cc");
  await vi.waitFor(() => expect(turns).toHaveLength(3));
  send({ kind: "sync_request", data: { lastSeen: {} } });
  const busy = (await eventsUntil((event) => event.kind === "sync_delta")).at(-1)! as YorozuEvent & { kind: "sync_delta" };
  expect(busy.data.workingThreadIds).toEqual(["cc"]);
  send({ kind: "interrupt", data: {} }, "cc");
  await vi.waitFor(() => expect(turns[2]!.signal.aborted).toBe(true));
  send({ kind: "sync_request", data: { lastSeen: {} } });
  const idle = (await eventsUntil((event) => event.kind === "sync_delta")).at(-1)! as YorozuEvent & { kind: "sync_delta" };
  expect(idle.data.workingThreadIds).toEqual([]);
  expect(readThreadEvents("cc", dir).filter((event) => event.kind === "message" && event.data.role === "agent")).toHaveLength(2);
  expect(listThreads(dir).find((thread) => thread.id === "cc")?.nativeSessionId).toBe("s-1");
  // A reconnecting phone's sync carries the truncated head, and the request still answers whole.
  send({ kind: "sync_request", data: { lastSeen: {} } });
  const replayed = (await eventsUntil((event) => event.kind === "sync_delta")).at(-1) as YorozuEvent & { kind: "sync_delta" };
  const replayedCut = replayed.data.events.find((event) => event.kind === "tool_result") as YorozuEvent & { kind: "tool_result" };
  expect(replayedCut.data.truncated).toBe(true);
  expect(replayedCut.data.output).toHaveLength(4096);
  expect(openclawRun).not.toHaveBeenCalled();
  // The session id is the Mac's alone.
  expect(JSON.stringify(first)).not.toContain(JSON.stringify("s-1"));
  void release;

  // An agent that cannot run at all still finishes the turn, with the reason in the thread.
  send({ kind: "message", data: { role: "user", text: "break" } }, "cc");
  const failed = (await eventsUntil((event) => event.kind === "message" && event.data.done === true)).at(-1)!;
  expect(failed).toMatchObject({ data: { text: expect.stringMatching(/could not answer: claude is not logged in/) } });
  expect(states).toContain("native-error claude is not logged in");
});

test("client archive and restore reach OpenClaw in order before the canonical list changes", async () => {
  vi.spyOn(OpenClawRunner.prototype, "listModels").mockResolvedValue([]);
  let finishArchive!: () => void;
  const archive = vi.spyOn(OpenClawRunner.prototype, "setArchived").mockImplementationOnce(
    () => new Promise<void>((resolve) => { finishArchive = resolve; }),
  ).mockResolvedValue(undefined);
  const { dir, send, eventsUntil } = await pairedPhone([], true);
  send({ kind: "thread_create", data: {} });
  await eventsUntil((event) => event.kind === "thread_list" && event.data.threads.some((thread) => thread.id === "t1"));
  const mac = createConnection(localSocketPath(dir));
  const macEvents: YorozuEvent[] = [];
  let buffer = "";
  mac.setEncoding("utf8");
  mac.on("data", (chunk: string) => {
    buffer += chunk;
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    for (const line of lines) if (line) macEvents.push(JSON.parse(line));
  });
  await new Promise<void>((resolve, reject) => { mac.once("connect", resolve); mac.once("error", reject); });
  const macArchive = (archived: boolean) => mac.write(JSON.stringify({
    id: randomUUID(), threadId: "t1", ts: Date.now(), agentId: "mac", kind: "thread_archive", data: { archived },
  }) + "\n");
  try {
  send({ kind: "thread_archive", data: { archived: true } });
  await vi.waitFor(() => expect(archive).toHaveBeenCalledWith("t1", true));
  expect(listThreads(dir).find((thread) => thread.id === "t1")?.archived).toBe(false);
  macArchive(false);
  await new Promise((resolve) => setTimeout(resolve, 20));
  expect(archive).toHaveBeenCalledTimes(1);
  finishArchive();
  const first = await threadsAfter(eventsUntil);
  expect(first.find((thread) => thread.id === "t1")?.archived).toBe(true);
  const second = await threadsAfter(eventsUntil);
  expect(second.find((thread) => thread.id === "t1")?.archived).toBe(false);
  expect(archive.mock.calls).toEqual([["t1", true], ["t1", false]]);
  expect(listThreads(dir).find((thread) => thread.id === "t1")?.archived).toBe(false);
  await vi.waitFor(() => expect(macEvents.filter((event) => event.kind === "thread_list").slice(-2)).toMatchObject([
    { data: { threads: [{ id: "t1", archived: true }] } },
    { data: { threads: [{ id: "t1", archived: false }] } },
  ]));

  // A Gateway refusal must not lie to other clients or poison the next ordered request.
  archive.mockRejectedValueOnce(new Error("Session is still active; retry the archive."));
  macArchive(true);
  await vi.waitFor(() => expect(macEvents).toContainEqual(expect.objectContaining({
    kind: "thought", data: { text: "Could not archive this thread. Please retry." },
  })));
  expect((await threadsAfter(eventsUntil)).find((thread) => thread.id === "t1")?.archived).toBe(false);
  send({ kind: "thread_archive", data: {} });
  expect((await threadsAfter(eventsUntil)).find((thread) => thread.id === "t1")?.archived).toBe(true);
  expect(listThreads(dir).find((thread) => thread.id === "t1")?.archived).toBe(true);

  // A newly connected Mac receives the persisted result, not this client's optimistic state.
  const again = createConnection(localSocketPath(dir));
  try {
    const firstChunk = await new Promise<string>((resolve, reject) => {
      again.once("data", (chunk) => resolve(chunk.toString()));
      again.once("error", reject);
    });
    expect(JSON.parse(firstChunk.split("\n")[0]!)).toMatchObject({
      kind: "thread_list", data: { threads: [{ id: "t1", archived: true }] },
    });
  } finally { again.destroy(); }
  } finally { mac.destroy(); }
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
  const { actionId } = cardOf(batch);

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

test("approval settings persist and broadcast their current value", async () => {
  const { dir, send, eventsUntil } = await pairedPhone([]);

  send({ kind: "approval_settings", data: { yolo: true } });
  expect((await eventsUntil((event) => event.kind === "approval_settings")).at(-1)).toMatchObject({
    kind: "approval_settings",
    data: { yolo: true },
  });
  expect(JSON.parse(readFileSync(join(dir, "approval.json"), "utf8"))).toMatchObject({ yolo: true });

  send({ kind: "approval_settings", data: {} });
  expect((await eventsUntil((event) => event.kind === "approval_settings")).at(-1)).toMatchObject({
    kind: "approval_settings",
    data: { yolo: true },
  });
});

test("17: the card the phone gets carries the structured scope and a rule to widen", async () => {
  const cmd = "echo yorozu-scope-ok";
  const { send, eventsUntil } = await pairedPhone([() => shellTurn(cmd), () => sse("Done.")]);

  send({ kind: "message", data: { role: "user", text: "tidy up" } });
  const shown = cardOf(await eventsUntil((event) => event.kind === "approval_card"));

  expect(shown.scope).toMatchObject({ operation: "run" });
  expect(shown.scope?.consequence).toBeTruthy();
  expect(shown.mustConfirm).toBeUndefined();
  // Prefilled with the narrowest thing that covers it, which is this command and not every one.
  expect(shown.suggestedRule).toMatchObject({
    actionClass: "run-command",
    decision: "always",
    scope: { target: { mode: "exact", value: cmd }, operation: { mode: "exact", value: "run" } },
  });
});

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
  send({ kind: "message", data: { role: "user", text: "no" } });
  const tail = await eventsUntil(isReply);
  expect(tail.at(-1)).toMatchObject({ data: { role: "agent", text: "Understood, I will skip it." } });
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
  ]);

  send({ kind: "message", data: { role: "user", text: "tell bob" } });
  const external = cardOf(await eventsUntil((event) => event.kind === "approval_card"));
  expect(external.actionClass).toBe("send-message");
  send({ kind: "approval_answer", data: { actionId: external.actionId, answer: "yes", source: "notification" } });
  // Refused: the card is still up, so the same answer from the card itself settles it.
  await vi.waitFor(() => expect(states).toContain("notification-answer-refused"));
  send({ kind: "approval_answer", data: { actionId: external.actionId, answer: "no" } });
  await eventsUntil(isReply);

  send({ kind: "message", data: { role: "user", text: "run it" } });
  const local = cardOf(await eventsUntil((event) => event.kind === "approval_card"));
  send({ kind: "approval_answer", data: { actionId: local.actionId, answer: "yes", source: "notification" } });
  const tail = await eventsUntil(isReply);
  expect(tail.filter((event) => event.kind === "tool_result")).toHaveLength(1);
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
  const sessionKey = deriveSessionKey(identity.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(hello(qr, toBase64Url(identity.publicKey), keys.pub), keys);

  return {
    send(threadId: string, payload: EventPayload, ts = Date.now()): void {
      const event: YorozuEvent = { id: randomUUID(), threadId, ts, agentId: "phone", ...payload };
      const box = seal(sessionKey, Buffer.from(JSON.stringify(event)));
      phone.frame(
        encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }),
        keys,
      );
    },
    /** The next event of `kind` this phone can open: frames for the other device are not ours. */
    async next(kind: EventKind): Promise<YorozuEvent> {
      for (;;) {
        const frame = await phone.next();
        if (frame?.type !== "frame") continue;
        const body = frameBody(frame.payload);
        let event: YorozuEvent;
        try {
          event = JSON.parse(
            Buffer.from(open(sessionKey, fromBase64Url(body.n), fromBase64Url(body.c))).toString(),
          ) as YorozuEvent;
        } catch {
          continue; // Sealed for the other phone.
        }
        if (event.kind === kind) return event;
      }
    },
  };
}

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

  first.send(chat, { kind: "reaction", data: { messageId: "reply", emoji: "👍" } });
  for (const phone of [first, second]) {
    expect(await phone.next("reaction")).toMatchObject({
      threadId: chat,
      data: { messageId: "reply", emoji: "👍" },
    });
  }

  // Any thread archives now, for every device at once.
  first.send(chat, { kind: "thread_archive", data: {} });
  expect(await second.next("thread_list")).toMatchObject({
    data: { threads: [{ id: chat, archived: true }, { id: groceries, archived: false }] },
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
});

test("a newly paired phone syncs only events created after it paired", async () => {
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
  await first.next("thread_list");
  const chat = "before-second-pairing";
  first.send(chat, { kind: "thread_create", data: {} });
  await first.next("thread_list");
  first.send(chat, { kind: "message", data: { role: "user", text: "old prompt" } });
  await first.next("message");
  await first.next("message");

  await new Promise((resolve) => setTimeout(resolve, 2));
  const second = await pairPhone(relay.port, await qrs.next());
  const greeting = await second.next("thread_list");
  expect(JSON.stringify(greeting)).not.toContain("old prompt");
  second.send(chat, { kind: "sync_request", data: { lastSeen: {} } });
  expect(await second.next("sync_delta")).toMatchObject({ data: { events: [] } });

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

test("the first reply names an untitled thread, and no later turn renames it", async () => {
  const { dir, send, eventsUntil, isReply } = await pairedPhone([
    () => sse("Sure — milk and eggs."),
    // The titler's own completion, with the quotes and the full stop it was told not to use.
    () => sse('"Groceries for the week."\n'),
    () => sse("Added bread."),
  ]);

  // Nobody is asked for a title: the thread arrives empty and the lists draw a placeholder.
  send({ kind: "thread_create", data: {} });
  const [created] = await threadsAfter(eventsUntil);
  expect(created!.title).toBe("");

  send({ kind: "message", data: { role: "user", text: "buy milk" } }, created!.id);
  await eventsUntil(isReply);

  // The title lands after the reply, in a fresh list.
  expect(await threadsAfter(eventsUntil)).toEqual([
    expect.objectContaining({ id: created!.id, title: "Groceries for the week" }),
  ]);

  // A second turn spends no completion on titling, so the queued third response is its reply.
  send({ kind: "message", data: { role: "user", text: "and bread" } }, created!.id);
  const second = await eventsUntil(isReply);
  expect(second.at(-1)).toMatchObject({ data: { role: "agent", text: "Added bread." } });
  expect(storedThreads(dir)[0]!.title).toBe("Groceries for the week");
});

test("a thread the user renamed keeps that title through its first turn", async () => {
  // One response only: a named thread never asks for a second, so a titler call would hang.
  const { dir, send, eventsUntil, isReply } = await pairedPhone([() => sse("Noted.")]);

  send({ kind: "thread_create", data: {} });
  const [created] = await threadsAfter(eventsUntil);

  send({ kind: "thread_rename", data: { title: "  Weekend plans  " } }, created!.id);
  expect(await threadsAfter(eventsUntil)).toEqual([
    expect.objectContaining({ id: created!.id, title: "Weekend plans" }),
  ]);

  send({ kind: "message", data: { role: "user", text: "hi" } }, created!.id);
  await eventsUntil(isReply);
  expect(storedThreads(dir)[0]!.title).toBe("Weekend plans");
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
  const sessionKey = deriveSessionKey(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
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
  const box = seal(sessionKey, Buffer.from(JSON.stringify(remove)));
  phone.frame(encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }), keys);

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

test("a second sidecar on the same state dir is the same Mac: same keys, same room", async () => {
  // What an app update is, from the runtime's side: the bundle is replaced and the sidecar is
  // launched again, on the state directory it always had — nothing in that path is version
  // shaped. The keys are what the room id and every paired phone are pinned to, so a relaunch
  // that generated new ones would silently unpair every device. It must not.
  relay = await startRelay(0);
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-restart-"));
  const paired = { pub: toBase64Url(generateKeypair().publicKey), signingPub: "s", pairedAt: 5, lastSeen: 7 };
  writeFileSync(join(stateDir, "devices.json"), JSON.stringify([paired]));

  const start = async () => {
    let pairing!: (line: string) => void;
    const printed = new Promise<string>((resolve) => (pairing = resolve));
    const started = serve({
      relayUrl: `ws://127.0.0.1:${relay.port}`,
      stateDir,
      provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
      log: (line) => {
        if (line.startsWith("QR ")) pairing(line.slice(3));
      },
    });
    return { started, qr: decodeQrPayload(await printed) };
  };

  const first = await start();
  await first.started.close();
  const second = await start();
  sidecar = second.started;

  expect(second.qr.roomId).toBe(first.qr.roomId);
  expect(second.qr.macPubkey).toBe(first.qr.macPubkey);
  // And the phones it had paired with are still there — the install touched no file of ours.
  expect(loadDevices(join(stateDir, "devices.json"))).toEqual([paired]);
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
  const sockets: { mac?: any; phone?: any } = {};
  const fake = new WebSocketServer({ port: 0 });
  fake.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Record<string, unknown>;
      switch (msg.type) {
        case "register":
          sockets.mac = ws;
          return ws.send(JSON.stringify({ type: "registered", roomId: "r" }));
        case "mint":
          return ws.send(
            JSON.stringify({ type: "token", token: "tok", expiresAt: Date.now() + 60_000 }),
          );
        case "join":
          sockets.phone = ws;
          return ws.send(JSON.stringify({ type: "joined", roomId: "r", ownerOnline: true }));
        case "notify":
          return void seen.push(msg);
        case "frame": {
          const other = ws === sockets.mac ? sockets.phone : sockets.mac;
          return void other?.send(JSON.stringify(msg));
        }
      }
    });
  });
  const port = (fake.address() as AddressInfo).port;

  let qrLine!: (line: string) => void;
  const qrPrinted = new Promise<string>((resolve) => (qrLine = resolve));
  let turn = 0;
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-notify-")),
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
      if (line.startsWith("QR ")) qrLine(line.slice(3));
    },
  });

  const qr = decodeQrPayload(await qrPrinted);
  const { phone, keys } = await connectPhone(port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });

  const phoneKeys = generateKeypair();
  const sessionKey = deriveSessionKey(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(hello(qr, toBase64Url(phoneKeys.publicKey), keys.pub), keys);

  const sent: YorozuEvent = {
    id: "e1",
    threadId: "thread-one",
    ts: 1,
    agentId: "phone",
    kind: "message",
    data: { role: "user", text: "the secret question" },
  };
  const box = seal(sessionKey, Buffer.from(JSON.stringify(sent)));
  phone.frame(
    encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }),
    keys,
  );

  // The turn ends with the agent's reply, which is the one thing worth waking a phone for.
  await vi.waitFor(() => expect(seen.map((msg) => msg.class)).toContain("reply"));

  const notify = seen.find((msg) => msg.class === "reply")!;
  expect(notify).toMatchObject({
    type: "notify",
    class: "reply",
    threadRef: threadRef("thread-one"),
  });
  expect(notify.eventRef).toMatch(/^[A-Za-z0-9_-]{8}$/);
  const preview = (notify.previews as Record<string, { n: string; c: string }>)[keys.pub]!;
  expect(Buffer.from(open(
    sessionKey,
    fromBase64Url(preview.n),
    fromBase64Url(preview.c),
  )).toString()).toBe("the secret reply");
  expect(JSON.stringify(notify)).not.toContain("the secret reply");

  const failed: YorozuEvent = {
    ...sent,
    id: "e2",
    ts: 2,
    data: { role: "user", text: "another secret question" },
  };
  const failedBox = seal(sessionKey, Buffer.from(JSON.stringify(failed)));
  phone.frame(
    encodeBody({ t: "box", n: toBase64Url(failedBox.nonce), c: toBase64Url(failedBox.ciphertext) }),
    keys,
  );
  await vi.waitFor(() => expect(seen.map((msg) => msg.class)).toContain("failed"));

  // An approval for something local and below every floor may be answered from the lock
  // screen, and the relay is told so with one bit. The command itself is not in the notify.
  const gated: YorozuEvent = {
    ...sent,
    id: "e3",
    ts: 3,
    data: { role: "user", text: "run the secret script" },
  };
  const gatedBox = seal(sessionKey, Buffer.from(JSON.stringify(gated)));
  phone.frame(
    encodeBody({ t: "box", n: toBase64Url(gatedBox.nonce), c: toBase64Url(gatedBox.ciphertext) }),
    keys,
  );
  await vi.waitFor(() => expect(seen.map((msg) => msg.class)).toContain("approval"));
  expect(seen.find((msg) => msg.class === "approval")).toMatchObject({ actions: true });

  // The whole side-channel, everything the relay was ever told in the clear. Neither side of
  // the conversation is in it, and neither is the thread it happened in.
  const wire = JSON.stringify(seen);
  expect(wire).not.toContain("secret");
  expect(wire).not.toContain("thread-one");
  expect(wire).not.toContain("echo");

  // `close()` waits on the open sockets, and this test attached a phone to them as well.
  phone.ws.close();
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
  const sessionKey = deriveSessionKey(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(hello(qr, toBase64Url(phoneKeys.publicKey), keys.pub), keys);
  await vi.waitFor(() => expect(lines).toContain("STATE paired"));

  const ask = (id: string, text: string): void => {
    const event: YorozuEvent = {
      id, threadId: "thread-one", ts: Date.now(), agentId: "phone",
      kind: "message", data: { role: "user", text },
    };
    const box = seal(sessionKey, Buffer.from(JSON.stringify(event)));
    phone.frame(
      encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }),
      keys,
    );
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
  phone.send(chat, { kind: "sync_request", data: { lastSeen: {} } });
  const page = await phone.next("sync_delta");
  expect(roles(page)).toEqual(["user", "agent"]);
  expect(page).toMatchObject({ data: { more: true } });

  // From the end of that page: the second turn, and that is all.
  phone.send(chat, { kind: "sync_request", data: { lastSeen: { [chat]: replies[0]! } } });
  const rest = await phone.next("sync_delta");
  expect(roles(rest)).toEqual(["user", "agent"]);
  expect(rest.kind === "sync_delta" && rest.data.more).toBeUndefined();
});

test.each([["claude-code", "yes"], ["claude-code", "no"], ["codex", "yes"], ["codex", "no"]] as const)("%s native approval %s round-trips through encrypted relay including lockscreen answers", async (agent, answer) => {
  const runner: NativeAgentRunner = { run: async (turn) => {
    const allowed = await turn.approve!("Bash", { command: "pwd" }, turn.signal);
    const response = await turn.ask!("Which?", ["A", "B"], turn.signal);
    return { text: `${allowed}:${response}`, sessionId: "sdk-session" };
  } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { [agent]: runner } });
  send({ kind: "thread_create", data: { agent, cwd: proj } }, "native");
  send({ kind: "approval_settings", data: { yolo: true } });
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

test.each(["claude-code", "codex"] as const)("%s native bypass shares global YOLO on new and resumed turns", async (agent) => {
  const turns: NativeTurn[] = [];
  const runner: NativeAgentRunner = { run: async (turn) => { turns.push(turn); return { text: "ok", sessionId: "s" }; } };
  const { dir, send, eventsUntil } = await pairedPhone([], false, { nativeRunners: { [agent]: runner } });
  send({ kind: "thread_create", data: { agent, cwd: proj } }, "cc");
  for (const [kind, bypass] of [["approval_settings", true], ["approval_settings", false], ["thread_set_bypass", true], ["thread_set_bypass", false]] as const) {
    if (kind === "approval_settings") send({ kind, data: { yolo: bypass } });
    else send({ kind, data: { bypass } }, "cc");
    const list = (await eventsUntil((e) => e.kind === "thread_list" && e.data.threads.some((t) => t.id === "cc" && t.bypass === bypass))).at(-1)!;
    expect(JSON.stringify(list)).toContain(`"bypass":${bypass}`);
    expect(JSON.parse(readFileSync(join(dir, "approval.json"), "utf8")).yolo).toBe(bypass);
    send({ kind: "message", data: { role: "user", text: "go" } }, "cc");
    await eventsUntil((e) => e.kind === "message" && e.data.done === true);
    expect(turns.at(-1)?.bypass).toBe(bypass);
    send({ kind: "approval_settings", data: {} });
    expect((await eventsUntil((e) => e.kind === "approval_settings")).at(-1)).toMatchObject({ data: { yolo: bypass } });
  }
  send({ kind: "thread_create", data: {} }, "normal");
  send({ kind: "thread_set_bypass", data: { bypass: true } }, "normal");
  await eventsUntil((e) => e.kind === "receipt");
  expect(listThreads(dir).find((t) => t.id === "normal")?.bypass).toBeUndefined();
});

test.each([
  ["claude-code", "continue"], ["claude-code", "dismiss"], ["codex", "continue"], ["codex", "dismiss"],
] as const)("startup never replays %s turns; %s is an explicit recoverable command", async (agent, action) => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-native-restart-"));
  createThread("Work", dir, "cc", { agent, cwd: proj });
  setThreadSession("cc", "native-before-crash", dir);
  setNativeTurn("cc", { id: "crashed-turn", state: "running" }, dir);
  const run = vi.fn<NativeAgentRunner["run"]>().mockResolvedValue({ text: "continued", sessionId: "native-before-crash" });
  const { send, eventsUntil } = await pairedPhone([], false, { stateDir: dir, nativeRunners: { [agent]: { run } } });
  const startup = (await eventsUntil((e) => e.kind === "thread_list")).at(-1)!;
  expect(startup).toMatchObject({ data: { threads: [expect.objectContaining({ interruptedTurnId: "crashed-turn" })] } });
  expect(run).not.toHaveBeenCalled();
  send({ kind: "thread_recover", data: { turnId: "crashed-turn", action } }, "cc");
  await eventsUntil((e) => e.kind === "thread_list" && e.data.threads.every((t) => !t.interruptedTurnId));
  if (action === "continue") {
    await eventsUntil((e) => e.kind === "message" && e.data.done === true);
    expect(run).toHaveBeenCalledWith(expect.objectContaining({ text: "Continue the interrupted turn.", sessionId: "native-before-crash", cwd: proj }));
    // A second device's stale Continue must not start another turn.
    send({ kind: "thread_recover", data: { turnId: "crashed-turn", action } }, "cc");
    send({ kind: "thread_list", data: { threads: [] } });
    await eventsUntil((e) => e.kind === "thread_list");
    expect(run).toHaveBeenCalledTimes(1);
  } else {
    expect(run).not.toHaveBeenCalled();
    send({ kind: "message", data: { role: "user", text: "New plan" } }, "cc");
    await eventsUntil((e) => e.kind === "message" && e.data.done === true);
    expect(run).toHaveBeenCalledWith(expect.objectContaining({ text: "New plan", sessionId: "native-before-crash" }));
  }
  expect(listThreads(dir)[0]?.nativeTurn).toBeUndefined();
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
  for (const id of ["one", "two", "three"]) {
    send({ kind: "thread_create", data: { agent, cwd: proj } }, id);
    send({ kind: "message", data: { role: "user", text: "work" } }, id);
  }
  await vi.waitFor(() => expect(turns.size).toBe(3));
  send({ kind: "interrupt", data: {} }, "one");
  await vi.waitFor(() => expect(turns.get("one")!.signal.aborted).toBe(true));
  expect(turns.get("two")!.signal.aborted).toBe(false);
  expect(turns.get("three")!.signal.aborted).toBe(false);
  releases.get("two")!(); releases.get("three")!();
  await eventsUntil((e) => e.kind === "message" && e.threadId === "three" && e.data.done === true);
  expect(listThreads(dir).map((t) => t.nativeSessionId).sort()).toEqual(["session-one", "session-three", "session-two"]);
});


test.each([true, false])("legacy setup runs only with an injected provider (OpenClaw=%s)", async (openclaw) => {
  vi.spyOn(OpenClawRunner.prototype, "listModels").mockResolvedValue([]);
  const scheduler = vi.spyOn(schedulerModule, "startScheduler");
  const { dir } = await pairedPhone([], openclaw);
  if (!openclaw) await vi.waitFor(() => expect(scheduler).toHaveBeenCalledTimes(1));
  else expect(scheduler).not.toHaveBeenCalled();
  expect(existsSync(join(dir, "agents", "main.md"))).toBe(!openclaw);
});

import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { registerHooks } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Readable } from "node:stream";
import { after, beforeEach, test, type TestContext } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Message } from "../src/envelope.ts";
import type { HermesClient, RunEvent, RunStatus } from "../src/hermes-client.ts";
import type { Ledger, RunRecord, Store } from "../src/ledger.ts";
import "./genui-hooks.ts";
import { host, yorozuRuntime } from "./genui-host.js";
import { fakeHermes } from "./hermes-server.ts";

globalThis.fetch = (input, init = {}) => new Promise((resolve, reject) => {
  const { signal } = init;
  if (signal?.aborted) return reject(signal.reason);
  const req = request(new URL(String(input)), { method: init.method ?? "GET", headers: init.headers as Record<string, string> }, (res) => {
    const status = res.statusCode ?? 500;
    const headers = new Headers();
    for (const [name, value] of Object.entries(res.headers)) {
      if (value !== undefined) headers.set(name, Array.isArray(value) ? value.join(", ") : value);
    }
    const body = [204, 205, 304].includes(status) ? null : (Readable.toWeb(res) as ReadableStream<Uint8Array>);
    resolve(new Response(body, { status, headers }));
  });
  const abort = () => req.destroy(signal?.reason instanceof Error ? signal.reason : new Error("aborted"));
  signal?.addEventListener("abort", abort, { once: true });
  req.on("error", reject);
  req.on("close", () => signal?.removeEventListener("abort", abort));
  req.end(typeof init.body === "string" ? init.body : undefined);
});

const KEY = "hermes-turn-test-api-key-7f3a";
const home = mkdtempSync(join(tmpdir(), "yorozu-hermes-turn-"));
const previousHome = process.env.HOME;
process.env.HOME = home;
mkdirSync(join(home, ".hermes-yorozu-test"));
writeFileSync(join(home, ".hermes-yorozu-test", "yorozu-plugin.key"), `${KEY}\n`, { mode: 0o600 });
after(() => {
  if (previousHome === undefined) delete process.env.HOME;
  else process.env.HOME = previousHome;
  rmSync(home, { recursive: true, force: true });
});

const src = (path: string) => new URL(`../src/${path}`, import.meta.url).href;
const stub = new URL("./genui-host.js", import.meta.url).href;
const moduleUrl = (source: string) => `data:text/javascript,${encodeURIComponent(source)}`;
const relay = moduleUrl(`
  export * from ${JSON.stringify(stub)};
  export const activity = [];
  export const pushes = [];
  export const activityTurn = (convId, change) => activity.push({ convId, ...change });
  export const notifyReply = async (...args) => { pushes.push(args); };
`);
const runs = moduleUrl(`export const currentLedger = () => globalThis.yorozuTestLedger;`);
const turnParents = new Set([src("conversation.ts"), src("hermes-turn.ts")]);
registerHooks({ resolve(specifier, context, next) {
  if (specifier === src("retry.ts")) return { url: specifier, shortCircuit: true };
  if (context.parentURL === src("hermes-turn.ts") && specifier === "./retry.js") return { url: src("retry.ts"), shortCircuit: true };
  if (context.parentURL && turnParents.has(context.parentURL)) {
    if (specifier === "./relay.js") return { url: relay, shortCircuit: true };
    if (specifier === "./runs.js") return { url: runs, shortCircuit: true };
  }
  return next(specifier, context);
} });

const { createHermesState, hermesKeys } = await import("../src/backends.ts");
const { externalTurn } = await import("../src/conversation.ts");
const { createHermesClient } = await import("../src/hermes-client.ts");
const { hermesClients, INSTRUCTIONS, requestBody, routedRerun, routeMessage } = await import("../src/hermes-turn.ts");
const { createLedger } = await import("../src/ledger.ts");
const { park, runParked } = await import(src("retry.ts")) as typeof import("../src/retry.ts");
const { activity, pushes } = await import(relay) as { activity: { convId: string; kind: string }[]; pushes: unknown[] };

type Deps = Parameters<typeof routeMessage>[0];
type Line = string;
type Sent = { kind: string; data: Record<string, unknown> };
const allLines: Line[] = [];
const store = yorozuRuntime.getRuntime().state.openKeyedStore as <T>(opts: { namespace: string }) => Store<T>;
const runRows = () => store<RunRecord>({ namespace: "runs" });
const sessionKey = (convId: string) => `agent:main:yorozu:direct:owner:thread:${convId}`;
const ledgerHolder = globalThis as typeof globalThis & { yorozuTestLedger?: Ledger };

const allSent: string[] = [];

beforeEach(() => {
  host.calls = [];
  allSent.push(JSON.stringify(host.sent), JSON.stringify(host.batches));
  host.sent.length = 0;
  host.batches.length = 0;
  host.mirrors.length = 0;
  host.register = undefined;
  host.lookup = undefined;
  host.entries = undefined;
  host.delete = undefined;
  host.mirror = undefined;
  host.batchStatus = undefined;
  host.batchHold = undefined;
  host.run = undefined;
  host.queued = false;
  host.stores.get("retry")?.clear();
  activity.length = 0;
  pushes.length = 0;
});

function logger(lines: Line[]) {
  const push = (level: string) => (line: string) => {
    lines.push(`${level}: ${line}`);
    allLines.push(line);
  };
  return { info: push("info"), warn: push("warn"), error: push("error"), debug: push("debug") };
}

function newLedger(lines: Line[], bootId = `boot-${randomUUID()}`) {
  const log = logger(lines);
  const ledger = createLedger({
    runs: runRows, now: () => Date.now(), bootId, log: { info: log.info, warn: log.warn }, inTranscript: () => "missing",
  });
  ledgerHolder.yorozuTestLedger = ledger;
  return ledger;
}

function conversation(withSession = true) {
  const convId = randomUUID();
  const sessionId = randomUUID();
  if (withSession) host.sessions.set(sessionKey(convId), { sessionId, updatedAt: 1 });
  return { convId, sessionId };
}

const message = (convId: string, text = "What is the weather?", extra: Partial<Message> = {}): Message =>
  ({ convId, messageId: randomUUID(), text, ...extra });

const json = (body: unknown, status = 200) => ({
  status, headers: { "Content-Type": "application/json" }, body: JSON.stringify(body),
});
const created = (runId: string, status = "started", replayed = false) => json({ run_id: runId, status, replayed }, 202);
const runStatus = (status: string, extra: Record<string, unknown> = {}) =>
  json({ object: "hermes.run", status, pending_controls: [], ...extra });
const usage = { input_tokens: 120, output_tokens: 45, total_tokens: 165 };
const sse = (...events: Record<string, unknown>[]) => ({
  status: 200,
  headers: { "Content-Type": "text/event-stream" },
  body: ": open\n\n" + events.map((event, seq) => `id: ${seq}\ndata: ${JSON.stringify({ seq, ...event })}\n\n`).join("") + ": stream closed\n\n",
});
const post = (key: string, reply: object) => ({ method: "POST" as const, path: "/v1/runs", key, reply });
const get = (path: string, reply: object) => ({ method: "GET" as const, path, reply });
const postTo = (path: string, reply: object) => ({ method: "POST" as const, path, reply });
const completedTurn = (key: string, runId: string, output = "Sunny and 21°C.") => [
  post(key, created(runId)),
  get(`/v1/runs/${runId}/events`, sse({ event: "run.completed", run_id: runId, output })),
  get(`/v1/runs/${runId}`, runStatus("completed", { output, usage })),
];

type Script = Parameters<typeof fakeHermes>[1];

async function setup(t: TestContext, script: Script, opts: { client?: (client: HermesClient) => HermesClient; bootId?: string } = {}) {
  const server = await fakeHermes(t, script);
  const lines: Line[] = [];
  const log = logger(lines);
  const ledger = newLedger(lines, opts.bootId);
  const turn = { cfg: {}, accountId: "default", log, agent: "main", mediaMaxBytes: 1, presentationSdk: {} } as unknown as Deps["turn"];
  const state = await createHermesState(store, log);
  const real = createHermesClient({ url: server.url, key: KEY });
  const deps: Deps = { client: opts.client ? opts.client(real) : real, apiKey: KEY, state, keys: hermesKeys(), turn, park, log };
  const route = async (m: Message) => {
    ledger.claim(m);
    await routeMessage(deps, m);
  };
  const rerun = (m: Message, attempt: number, d: Deps | undefined = deps) =>
    routedRerun({ keys: hermesKeys(), turn, deps: d, log }, m, attempt);
  const optIn = async (convId: string) => {
    const id = randomUUID();
    await state.setRoute(convId, id);
    return `yorozu-${convId}-${id}`;
  };
  const entry = async (m: Message) => {
    await ledger.idle();
    return (await runRows().lookup(m.messageId))?.state;
  };
  return { server, lines, log, ledger, turn, state, deps, route, rerun, optIn, entry };
}

const kinds = (convId?: string) => (host.sent as Sent[]).filter((event) => !convId || event.data.convId === convId).map((event) => event.kind);
const errors = () => (host.sent as Sent[]).filter((event) => event.kind === "error").map((event) => event.data.message);
const endLines = (lines: Line[]) => lines.filter((line) => line.includes("hermes turn end"));
const createLines = (lines: Line[]) => lines.filter((line) => line.includes("hermes createRun"));
const endLine = (m: Message, run: string, outcome: string, tokens: [unknown, unknown, unknown] = [null, null, null]) =>
  `${outcome === "completed" ? "info" : "warn"}: yorozu: hermes turn end ${m.messageId} run=${run} outcome=${outcome} tokens_in=${tokens[0]} tokens_out=${tokens[1]} tokens_total=${tokens[2]}`;
const keyRow = (m: Message) => hermesKeys().lookup(m.messageId);
const retryRow = (m: Message) => host.stores.get("retry")?.get(m.messageId) as { attempt: number; due: number } | undefined;
const bodyOf = async (server: Awaited<ReturnType<typeof fakeHermes>>, n: number) => JSON.parse((await server.request(n)).body.toString());
const dispatched = () => (host.calls as { kind: string; messageId?: string }[]).filter((call) => call.kind === "dispatch").map((call) => call.messageId);

async function until(condition: () => boolean, label: string | (() => string), turns = 5_000): Promise<void> {
  for (let i = 0; i < turns; i++) {
    if (condition()) return;
    await setImmediate();
  }
  assert.fail(`timed out waiting for ${typeof label === "string" ? label : label()}`);
}

function settledCount(client: HermesClient) {
  const counter = { settled: 0 };
  const wrap = <A extends unknown[], R>(fn: (...args: A) => Promise<R>) => (...args: A) =>
    fn(...args).finally(() => { counter.settled++; });
  const wrapped: HermesClient = {
    createRun: wrap(client.createRun.bind(client)),
    status: wrap(client.status.bind(client)),
    events: client.events.bind(client),
    deny: wrap(client.deny.bind(client)),
    resolveUnknown: wrap(client.resolveUnknown.bind(client)),
    stop: wrap(client.stop.bind(client)),
  };
  return { counter, wrapped };
}

type Wiring = { onMessage(message: Message): void; rerun(message: Message, attempt: number): void };

async function startAccount(cfg: object, lines: Line[]): Promise<Wiring> {
  const { yorozuPlugin } = await import("../src/channel.ts");
  const plugin = yorozuPlugin as unknown as { base: { gateway: { startAccount(ctx: unknown): Promise<void> } } };
  const account = { accountId: "default", agent: "main", relayUrl: "wss://relay.invalid", directPort: null, directBonjour: false };
  const controller = new AbortController();
  host.relay = undefined;
  host.rerun = undefined;
  try {
    await plugin.base.gateway.startAccount({ account, abortSignal: controller.signal, cfg, log: logger(lines), setStatus() {} });
  } finally {
    controller.abort();
  }
  assert.ok(host.relay, "startAccount reached runRelayHost");
  assert.ok(host.rerun, "startAccount started runParked");
  return { onMessage: host.relay.onMessage, rerun: host.rerun };
}

const hermesConfig = (enabled: boolean) => ({ channels: { yorozu: { backends: { hermes: { enabled } } } } });
const hermesLines = (lines: Line[]) => lines.filter((line) => /hermes|\/backend/.test(line));

test("2. with backends absent, messages and reruns reach OpenClaw and no Hermes store opens", async (t) => {
  const server = await fakeHermes(t, []);
  const create = t.mock.method(hermesClients, "create", (backend: { url: URL; key: string }) =>
    createHermesClient({ url: server.url, key: backend.key }));
  const lines: Line[] = [];
  newLedger(lines);
  const { convId } = conversation();
  const wiring = await startAccount({ channels: { yorozu: {} } }, lines);
  const optIn = message(convId, "/backend hermes");
  wiring.onMessage(optIn);
  await until(() => dispatched().includes(optIn.messageId), "onMessage reaches handleMessage");
  const parked = message(convId);
  wiring.rerun(parked, 1);
  await until(() => dispatched().includes(parked.messageId), "runParked reaches handleMessage");

  assert.equal(create.mock.callCount(), 0);
  assert.equal(host.stores.has("backends"), false);
  assert.equal(host.stores.has("hermes-keys"), false);
  assert.deepEqual(host.batches, []);
  assert.deepEqual(hermesLines(lines), []);
});

test("21. with the backend off at a reload, a parked Hermes message fails closed and an OpenClaw one reruns", async (t) => {
  for (const [label, cfg, prepare, expected] of [
    ["enabled: false", hermesConfig(false), () => {}, ["info: yorozu: hermes backend off: disabled"]],
    ["the route store fails to load", hermesConfig(true), () => {
      host.entries = (namespace: string) => {
        if (namespace === "backends") throw new Error("store down");
      };
    }, ["info: yorozu: hermes backend on", "warn: yorozu: hermes state unavailable: Error"]],
  ] as const) {
    await t.test(label, async (t) => {
      const server = await fakeHermes(t, []);
      const create = t.mock.method(hermesClients, "create", (backend: { url: URL; key: string }) =>
        createHermesClient({ url: server.url, key: backend.key }));
      const lines: Line[] = [];
      newLedger(lines);
      prepare();
      const { convId } = conversation();
      const wiring = await startAccount(cfg, lines);
      const hermesParked = message(convId);
      const openclawParked = message(convId);
      await hermesKeys().register(hermesParked.messageId, { keyAttempt: 0 });
      wiring.rerun(hermesParked, 1);
      await until(() => endLines(lines).length === 1, "the parked Hermes message ends");
      wiring.rerun(openclawParked, 1);
      await until(() => dispatched().includes(openclawParked.messageId), "the OpenClaw rerun");
      const plain = message(convId);
      wiring.onMessage(plain);
      await until(() => dispatched().includes(plain.messageId), "a new message reaches OpenClaw");

      assert.deepEqual(errors(), ["The Hermes test backend is off; this message wasn't rerun."]);
      assert.deepEqual(endLines(lines), [endLine(hermesParked, "-", "off")]);
      assert.equal(dispatched().includes(hermesParked.messageId), false);
      assert.equal(create.mock.callCount(), 0);
      assert.deepEqual(hermesLines(lines).filter((line) => !line.includes("turn end")), expected);
    });
  }
});

test("3. with the backend on, an opted-in message reaches Hermes through hermesClients.create and a reload keeps the route", async (t) => {
  const { convId } = conversation();
  const optIn = message(convId, "/backend hermes");
  const first = message(convId);
  const second = message(convId, "And tomorrow?");
  const server = await fakeHermes(t, [
    ...completedTurn(`${first.messageId}:0`, "run-wired-1"),
    ...completedTurn(`${second.messageId}:0`, "run-wired-2"),
  ]);
  const backends: { url: URL; key: string }[] = [];
  t.mock.method(hermesClients, "create", (backend: { url: URL; key: string }) => {
    backends.push(backend);
    return createHermesClient({ url: server.url, key: backend.key });
  });
  const lines: Line[] = [];
  newLedger(lines);
  let wiring = await startAccount(hermesConfig(true), lines);
  wiring.onMessage(optIn);
  await until(() => host.batches.length === 1, "the opt-in notice");
  wiring.onMessage(first);
  await until(() => endLines(lines).length === 1, "the first Hermes turn");
  wiring = await startAccount(hermesConfig(true), lines);
  wiring.onMessage(second);
  await until(() => endLines(lines).length === 2, "the Hermes turn after the reload");

  assert.deepEqual(backends, [
    { url: new URL("http://127.0.0.1:8652/"), key: KEY },
    { url: new URL("http://127.0.0.1:8652/"), key: KEY },
  ]);
  const session = `yorozu-${convId}-${optIn.messageId}`;
  assert.equal((await bodyOf(server, 1)).session_id, session);
  assert.equal((await bodyOf(server, 4)).session_id, session);
  assert.deepEqual(host.batches.map((batch: { payloads: { text: string }[] }) => batch.payloads[0]!.text), [
    "This conversation now uses Hermes (test). Hermes doesn't see the earlier messages.", "Sunny and 21°C.", "Sunny and 21°C.",
  ]);
  assert.deepEqual(dispatched(), []);
});

test("24. startAccount warns once per /backend claimant and once when the claim check fails", async (t) => {
  t.after(() => {
    host.skillCommands = undefined;
    host.chatCommands = undefined;
    host.pluginMatch = undefined;
    host.claimThrows = false;
  });
  const claimed = (lines: Line[]) => lines.filter((line) => line.includes("/backend"));
  host.chatCommands = [
    { key: "help", nativeName: "help", textAliases: ["/help"] },
    { key: "backends", nativeName: "backends", textAliases: ["/backends"] },
  ];
  host.skillCommands = [{ skillName: "backend", name: "backend" }, { skillName: "backend-x", name: "backend-x" }];
  host.pluginMatch = { command: { pluginId: "other-plugin", name: "backend" } };
  const lines: Line[] = [];
  newLedger(lines);
  await startAccount(hermesConfig(false), lines);
  await until(() => claimed(lines).length === 2, "two claim warnings");
  for (let i = 0; i < 20; i++) await setImmediate();
  assert.deepEqual(claimed(lines), [
    "warn: yorozu: /backend is claimed by skill:backend; with the Hermes backend off, /backend hermes won't reach the agent",
    "warn: yorozu: /backend is claimed by plugin:other-plugin/backend; with the Hermes backend off, /backend hermes won't reach the agent",
  ]);

  host.claimThrows = true;
  const failing: Line[] = [];
  await startAccount(hermesConfig(false), failing);
  await until(() => claimed(failing).length === 1, "the skipped check");
  for (let i = 0; i < 20; i++) await setImmediate();
  assert.deepEqual(claimed(failing), ["warn: yorozu: /backend claim check skipped: CLAIM_DOWN"]);
});

test("4. a plain turn streams, replies once, mirrors once and logs one completed turn-end line with tokens", async (t) => {
  const { convId, sessionId } = conversation();
  const runId = "run-plain";
  const m = message(convId);
  const h = await setup(t, [
    post(`${m.messageId}:0`, created(runId)),
    get(`/v1/runs/${runId}/events`, sse(
      { event: "tool.started", run_id: runId, tool_call_id: "call-1", tool: "terminal" },
      { event: "tool.completed", run_id: runId, tool_call_id: "call-1", tool: "terminal", success: true },
      { event: "run.completed", run_id: runId, output: "Sunny and 21°C." },
    )),
    get(`/v1/runs/${runId}`, runStatus("completed", { output: "Sunny and 21°C.", usage })),
  ]);
  const session = await h.optIn(convId);
  await h.route(m);

  assert.deepEqual(kinds(convId), ["run_started", "typing", "tool", "tool", "typing"]);
  assert.deepEqual((host.sent as Sent[]).filter((e) => e.kind === "typing").map((e) => e.data.active), [true, false]);
  assert.deepEqual((host.sent as Sent[]).filter((e) => e.kind === "tool").map((e) => [e.data.callId, e.data.name, e.data.status]), [
    [`hermes:${runId}:call-1`, "terminal", "running"], [`hermes:${runId}:call-1`, "terminal", "done"],
  ]);
  assert.equal(host.batches.length, 1);
  assert.deepEqual(host.batches[0], {
    cfg: {}, channel: "yorozu", to: "owner", accountId: "default", threadId: convId,
    payloads: [{ text: "Sunny and 21°C." }], durability: "best_effort",
    mirror: { sessionKey: sessionKey(convId), agentId: "main", text: "Sunny and 21°C." },
  });
  assert.equal(host.mirrors.length, 1);
  const mirrored = host.mirrors[0];
  assert.deepEqual({ ...mirrored, now: 0, message: { ...mirrored.message, timestamp: 0 } }, {
    agentId: "main", sessionKey: sessionKey(convId), sessionId, config: {}, now: 0,
    message: {
      role: "user", content: [{ type: "text", text: m.text }], timestamp: 0,
      provenance: { kind: "external_user" }, __openclaw: { transport: { messageId: m.messageId } },
    },
  });
  assert.equal(mirrored.message.timestamp, mirrored.now);
  assert.equal("idempotencyKey" in mirrored.message, false);
  assert.deepEqual(activity.filter((a) => a.convId === convId), [{ convId, kind: "step", steps: 1 }, { convId, kind: "done" }]);
  assert.equal(await h.entry(m), "settled");
  assert.deepEqual(createLines(h.lines), [`info: yorozu: hermes createRun ${m.messageId}:0 run=${runId} replayed=false error=-`]);
  assert.deepEqual(endLines(h.lines), [endLine(m, runId, "completed", [120, 45, 165])]);
  assert.deepEqual(pushes, [], "the outbound adapter pushes; the turn makes no push call");
  assert.equal(host.batches[0].payloads.length, 1);
  assert.deepEqual(await bodyOf(h.server, 1), { input: m.text, session_id: session, instructions: INSTRUCTIONS });
  assert.deepEqual(h.state.unsettled(convId), []);
});

test("4. without usage, or when the final status read fails, the completed turn-end line has null token counts", async (t) => {
  for (const [label, final] of [
    ["usage absent", runStatus("completed", { output: "No usage." })],
    ["the final status read fails", json({ error: { code: "internal" } }, 500)],
  ] as const) {
    await t.test(label, async (t) => {
      const { convId } = conversation();
      const m = message(convId);
      const runId = "run-no-usage";
      const h = await setup(t, [
        post(`${m.messageId}:0`, created(runId)),
        get(`/v1/runs/${runId}/events`, sse({ event: "run.completed", run_id: runId, output: "No usage." })),
        get(`/v1/runs/${runId}`, final),
      ]);
      await h.optIn(convId);
      await h.route(m);
      assert.deepEqual(host.batches.map((batch: { payloads: { text: string }[] }) => batch.payloads[0]!.text), ["No usage."]);
      assert.deepEqual(errors(), []);
      assert.deepEqual(endLines(h.lines), [endLine(m, runId, "completed")]);
    });
  }
});

test("25. a mirror that never settles ends the turn after 10 s without a POST and the next message runs", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
  const { convId } = conversation();
  const m = message(convId);
  const next = message(convId, "Second question");
  const h = await setup(t, completedTurn(`${next.messageId}:0`, "run-after-timeout"));
  await h.optIn(convId);
  host.mirror = "hang";
  const first = h.route(m);
  await until(() => host.mirrors.length === 1, "the mirror call");
  t.mock.timers.tick(9_999);
  await setImmediate();
  assert.deepEqual(errors(), []);
  t.mock.timers.tick(1);
  await first;
  assert.deepEqual(errors(), ["The Hermes test couldn't record your message in history; it wasn't sent to Hermes."]);
  assert.deepEqual(h.lines.filter((line) => line.includes("mirror timed out")), [`warn: yorozu: hermes mirror timed out ${m.messageId}`]);
  assert.deepEqual(endLines(h.lines), [endLine(m, "-", "mirror_timeout")]);
  assert.equal(retryRow(m), undefined);
  assert.equal(await h.entry(m), "settled");

  host.mirror = undefined;
  await h.route(next);
  assert.equal(host.batches.length, 1);
  assert.deepEqual(endLines(h.lines).at(-1), endLine(next, "run-after-timeout", "completed", [120, 45, 165]));
});

const OPTED_IN = "This conversation now uses Hermes (test). Hermes doesn't see the earlier messages.";
const SEND_FIRST = "Send one message first, then /backend hermes.";
const ALREADY = "This conversation already uses Hermes.";
const RESET_OFF = "Hermes is off for this conversation; /backend hermes turns it back on.";
const NOT_DROPPED = "Hermes couldn't be turned off for this conversation; nothing was reset.";
const noticeBatch = (convId: string, text: string, mirrored: boolean) => ({
  cfg: {}, channel: "yorozu", to: "owner", accountId: "default", threadId: convId, payloads: [{ text }], durability: "best_effort",
  ...(mirrored ? { mirror: { sessionKey: sessionKey(convId), agentId: "main", text } } : {}),
});
type Harness = Awaited<ReturnType<typeof setup>>;

async function quietNotice(h: Harness, m: Message) {
  assert.equal(await h.entry(m), "settled");
  assert.deepEqual(kinds(m.convId), [], "a notice sends no run_started, typing or error event");
  assert.deepEqual(activity.filter((a) => a.convId === m.convId), []);
  assert.deepEqual(endLines(h.lines), [], "a notice writes no turn-end line");
}

function countTurnEnds(h: Harness) {
  const ended: string[] = [];
  const original = h.ledger.turnEnded;
  h.ledger.turnEnded = (messageId, convId, outcome) => {
    ended.push(messageId);
    original(messageId, convId, outcome);
  };
  return ended;
}

test("1. routing", async (t) => {
  await t.test("/backend hermes with a session entry opts in and mirrors the command and the notice", async (t) => {
    const { convId } = conversation();
    const h = await setup(t, []);
    const m = message(convId, "/backend hermes");
    await h.route(m);
    assert.equal(h.state.routedToHermes(convId), true);
    assert.equal(h.state.session(convId), `yorozu-${convId}-${m.messageId}`);
    assert.deepEqual(host.batches, [noticeBatch(convId, OPTED_IN, true)]);
    assert.deepEqual(host.mirrors.map((call: { message: { content: { text: string }[] } }) => call.message.content[0]!.text), ["/backend hermes"]);
    assert.deepEqual(dispatched(), []);
    await quietNotice(h, m);
  });

  await t.test("/backend hermes with no session entry asks for a first message and mirrors nothing", async (t) => {
    const { convId } = conversation(false);
    const h = await setup(t, []);
    const m = message(convId, "/backend hermes");
    await h.route(m);
    assert.equal(h.state.routedToHermes(convId), false);
    assert.deepEqual(host.batches, [noticeBatch(convId, SEND_FIRST, false)]);
    assert.deepEqual(host.mirrors, []);
    await quietNotice(h, m);
  });

  await t.test("/Backend  Hermes opts in", async (t) => {
    const { convId } = conversation();
    const h = await setup(t, []);
    const m = message(convId, "  /Backend   Hermes ");
    await h.route(m);
    assert.equal(h.state.session(convId), `yorozu-${convId}-${m.messageId}`);
    assert.deepEqual(host.batches, [noticeBatch(convId, OPTED_IN, true)]);
    await quietNotice(h, m);
  });

  await t.test("/backend hermes in an opted-in conversation says it already uses Hermes", async (t) => {
    const { convId } = conversation();
    const h = await setup(t, []);
    const session = await h.optIn(convId);
    const m = message(convId, "/backend hermes");
    await h.route(m);
    assert.equal(h.state.session(convId), session);
    assert.deepEqual(host.batches, [noticeBatch(convId, ALREADY, true)]);
    assert.equal(host.mirrors.length, 1);
    await quietNotice(h, m);
  });

  await t.test("/backend and /backend off pass through to OpenClaw when not opted in", async (t) => {
    const { convId } = conversation();
    const h = await setup(t, []);
    const messages = [message(convId, "/backend"), message(convId, "/backend off")];
    for (const m of messages) await h.route(m);
    assert.deepEqual(dispatched(), messages.map((m) => m.messageId));
    assert.deepEqual(host.batches, []);
    assert.equal(h.state.routedToHermes(convId), false);
  });

  await t.test("/backend and /backend off go to Hermes as text when opted in", async (t) => {
    const { convId } = conversation();
    const messages = [message(convId, "/backend"), message(convId, "/backend off")];
    const h = await setup(t, [...completedTurn(`${messages[0]!.messageId}:0`, "run-b1"), ...completedTurn(`${messages[1]!.messageId}:0`, "run-b2")]);
    await h.optIn(convId);
    for (const m of messages) await h.route(m);
    assert.equal((await bodyOf(h.server, 1)).input, "/backend");
    assert.equal((await bodyOf(h.server, 4)).input, "/backend off");
    assert.deepEqual(dispatched(), []);
  });

  await t.test("/new in an opted-in conversation ends earlier runs, drops the route, resets on OpenClaw and says so", async (t) => {
    const { convId } = conversation();
    const reset = message(convId, "/new");
    const plain = message(convId, "Back on OpenClaw");
    const again = message(convId, "/backend hermes");
    const fresh = message(convId, "Hello again");
    const h = await setup(t, [
      get("/v1/runs/run-old", runStatus("completed")),
      ...completedTurn(`${fresh.messageId}:0`, "run-fresh"),
    ]);
    const ended = countTurnEnds(h);
    await h.optIn(convId);
    await h.state.addUnsettled(convId, "run-old", "earlier-message");
    await h.route(reset);

    assert.equal(h.state.routedToHermes(convId), false);
    assert.equal(host.stores.get("backends")?.has(convId), false);
    assert.deepEqual(dispatched(), [reset.messageId], "OpenClaw got /new once and reset in place");
    assert.deepEqual(host.batches, [noticeBatch(convId, RESET_OFF, true)]);
    assert.deepEqual(host.mirrors, [], "OpenClaw recorded the command itself");
    assert.deepEqual(ended.filter((id) => id === reset.messageId), [reset.messageId], "only handleMessage ended the entry");
    assert.equal(await h.entry(reset), "settled");
    assert.deepEqual(createLines(h.lines), []);

    await h.route(plain);
    assert.deepEqual(dispatched(), [reset.messageId, plain.messageId]);
    await h.route(again);
    assert.equal(h.state.session(convId), `yorozu-${convId}-${again.messageId}`);
    await h.route(fresh);
    assert.equal((await bodyOf(h.server, 2)).session_id, `yorozu-${convId}-${again.messageId}`);
  });

  for (const text of ["/reset", "/new foo", "/NEW"]) {
    await t.test(`${text} in an opted-in conversation drops the route and resets on OpenClaw`, async (t) => {
      const { convId } = conversation();
      const h = await setup(t, []);
      await h.optIn(convId);
      const m = message(convId, text);
      await h.route(m);
      assert.equal(h.state.routedToHermes(convId), false);
      assert.deepEqual(dispatched(), [m.messageId]);
      assert.deepEqual(host.batches, [noticeBatch(convId, RESET_OFF, true)]);
    });
  }

  await t.test("a Hermes message parked before /new fails on its rerun and never reaches OpenClaw or Hermes", async (t) => {
    const { convId } = conversation();
    const h = await setup(t, []);
    await h.optIn(convId);
    const parked = message(convId);
    await hermesKeys().register(parked.messageId, { keyAttempt: 0 });
    await h.route(message(convId, "/new"));
    await h.rerun(parked, 1);
    assert.deepEqual(errors(), ["This conversation is back on OpenClaw; this message wasn't rerun."]);
    assert.deepEqual(endLines(h.lines), [endLine(parked, "-", "off")]);
    assert.equal(dispatched().includes(parked.messageId), false);
  });

  await t.test("a failing route delete keeps the route, says so and sends the message nowhere", async (t) => {
    const { convId } = conversation();
    const h = await setup(t, []);
    await h.optIn(convId);
    host.delete = (namespace: string) => {
      if (namespace === "backends") throw new Error("store down");
    };
    const m = message(convId, "/new");
    await h.route(m);
    assert.equal(h.state.routedToHermes(convId), true);
    assert.deepEqual(host.batches, [noticeBatch(convId, NOT_DROPPED, true)]);
    assert.equal(host.mirrors.length, 1);
    assert.deepEqual(dispatched(), []);
    assert.ok(h.lines.includes("warn: yorozu: hermes route not dropped: Error"));
    await quietNotice(h, m);
  });
});

test("5. handed lands before each POST, a parked rerun hands again, and a failed or slow handed write never blocks the POST", async (t) => {
  await t.test("order", async (t) => {
    const { convId } = conversation();
    const m = message(convId);
    const bootId = `boot-${randomUUID()}`;
    const h = await setup(t, [post(`${m.messageId}:0`, { status: 503 }), ...completedTurn(`${m.messageId}:0`, "run-handed")], { bootId });
    await h.optIn(convId);
    const snapshots: unknown[] = [];
    for (const n of [1, 2]) {
      void h.server.request(n).then(() => {
        host.calls.push({ kind: "post" });
        const row = host.stores.get("runs")?.get(m.messageId) as RunRecord | undefined;
        snapshots.push({ key: host.stores.get("hermes-keys")?.get(m.messageId), state: row?.state, boot: row?.boot });
      });
    }
    await h.route(m);
    assert.equal(retryRow(m)?.attempt, 1);
    await h.rerun(m, 1);
    await h.ledger.idle();
    const marks = (host.calls as { kind: string; namespace?: string; key?: string; value?: RunRecord }[]).flatMap((call) =>
      call.kind === "post" ? ["POST"] : call.namespace === "runs" && call.key === m.messageId ? [call.value!.state] : []);
    assert.deepEqual(marks, ["accepted", "handed", "POST", "parked", "handed", "POST", "started", "settled"]);
    assert.deepEqual(snapshots, [
      { key: { keyAttempt: 0, session: h.state.session(convId) }, state: "handed", boot: bootId },
      { key: { keyAttempt: 0, session: h.state.session(convId) }, state: "handed", boot: bootId },
    ]);
    assert.ok(h.lines.includes(`info: yorozu: run started ${m.messageId} attempt 1 boot ${bootId}`));
    assert.deepEqual(h.lines.filter((line) => /dispatch returned|follow-up started after dispatch/.test(line)), []);
  });

  await t.test("a failed handed write is logged and the POST still goes", async (t) => {
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, completedTurn(`${m.messageId}:0`, "run-write-failed"));
    await h.optIn(convId);
    host.register = (namespace: string, _key: string, value: RunRecord) => {
      if (namespace === "runs" && value.state === "handed") throw new Error("handed store down");
    };
    await h.route(m);
    assert.ok(h.lines.includes("warn: yorozu: run ledger write failed: Error: handed store down"));
    assert.equal(host.batches.length, 1);
  });

  await t.test("a handed write that never lands lets the POST go after 2 s", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, completedTurn(`${m.messageId}:0`, "run-write-slow"));
    await h.optIn(convId);
    const release = Promise.withResolvers<void>();
    t.after(() => release.resolve());
    let blocked = false;
    host.register = (namespace: string, _key: string, value: RunRecord) => {
      if (namespace !== "runs" || value.state !== "handed") return;
      blocked = true;
      return release.promise;
    };
    let posted = false;
    void h.server.request(1).then(() => { posted = true; });
    const turn = h.route(m);
    await until(() => blocked, "the handed write");
    t.mock.timers.tick(1_999);
    for (let i = 0; i < 50; i++) await setImmediate();
    assert.equal(posted, false);
    t.mock.timers.tick(1);
    await until(() => posted, "the POST after the deadline");
    await turn;
    assert.ok(h.lines.includes(`warn: yorozu: run ledger write slow ${m.messageId} handed`));
    assert.equal(host.batches.length, 1);
  });
});

test("6. an unreachable Hermes gets exactly six POSTs on the retry schedule, then one error", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
  const { convId } = conversation();
  const m = message(convId);
  const key = `${m.messageId}:0`;
  const h = await setup(t, Array.from({ length: 6 }, () => post(key, { end: "reset" as const })));
  await h.optIn(convId);
  const controller = new AbortController();
  t.after(() => controller.abort());
  runParked(controller.signal, (msg, attempt) => void h.rerun(msg, attempt));
  const arrivals: number[] = [];
  for (let n = 1; n <= 6; n++) void h.server.request(n).then(() => arrivals.push(Date.now()));
  const ends: number[] = [];
  void h.route(m);
  await until(() => arrivals.length === 1 && retryRow(m)?.attempt === 1, "the first park");
  ends.push(Date.now());
  assert.deepEqual(endLines(h.lines), [], "no turn-end line while parked");
  assert.deepEqual(errors(), []);
  for (let n = 2; n <= 6; n++) {
    while (arrivals.length < n) {
      t.mock.timers.tick(5_000);
      await until(() => arrivals.length >= n || (retryRow(m) !== undefined && retryRow(m)!.due > Date.now()),
        () => `attempt ${n}: ${JSON.stringify({ arrivals, ends, row: retryRow(m), now: Date.now(), lines: h.lines })}`);
    }
    await until(() => (n < 6 ? retryRow(m)?.attempt === n : endLines(h.lines).length === 1), `attempt ${n} ends`);
    ends.push(Date.now());
  }
  const delays = [5_000, 15_000, 30_000, 60_000, 120_000];
  delays.forEach((delay, i) => {
    const waited = arrivals[i + 1]! - ends[i]!;
    assert.ok(waited >= delay && waited <= delay + 5_000, `retry ${i + 1} waited ${waited} ms`);
  });
  assert.deepEqual(createLines(h.lines), Array(6).fill(`warn: yorozu: hermes createRun ${key} run=- replayed=- error=unavailable`));
  const bodies = await Promise.all([1, 2, 3, 4, 5, 6].map(async (n) => (await h.server.request(n)).body.toString()));
  assert.equal(new Set(bodies).size, 1);
  assert.equal(h.lines.filter((line) => line.includes("hermes run parked")).length, 5);
  assert.deepEqual(errors(), ["The Hermes test backend isn't answering."]);
  assert.deepEqual(endLines(h.lines), [endLine(m, "-", "unreachable")]);
  for (let i = 0; i < 120; i++) {
    t.mock.timers.tick(5_000);
    await setImmediate();
  }
  assert.equal(arrivals.length, 6);
});

test("7. a timeout after admission reruns with the same request key and attaches to the replayed run", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
  const { convId } = conversation();
  const m = message(convId);
  const key = `${m.messageId}:0`;
  const runId = "run-admitted";
  const h = await setup(t, [
    post(key, { end: "hang" as const }),
    post(key, created(runId, "running", true)),
    get(`/v1/runs/${runId}`, runStatus("running")),
    get(`/v1/runs/${runId}/events`, sse({ event: "run.completed", run_id: runId, output: "Done once." })),
    get(`/v1/runs/${runId}`, runStatus("completed", { output: "Done once.", usage })),
  ]);
  await h.optIn(convId);
  const first = h.route(m);
  await h.server.request(1);
  t.mock.timers.tick(30_000);
  await first;
  assert.equal(retryRow(m)?.attempt, 1);
  await h.rerun(m, 1);
  assert.deepEqual(createLines(h.lines), [
    `warn: yorozu: hermes createRun ${key} run=- replayed=- error=unavailable`,
    `info: yorozu: hermes createRun ${key} run=${runId} replayed=true error=-`,
  ]);
  assert.equal((await h.server.request(1)).body.toString(), (await h.server.request(2)).body.toString());
  assert.deepEqual(host.batches.map((batch: { payloads: { text: string }[] }) => batch.payloads[0]!.text), ["Done once."]);
  assert.deepEqual(endLines(h.lines), [endLine(m, runId, "completed", [120, 45, 165])]);
});

test("8. a replayed run acts by its status", async (t) => {
  const replay = async (t: TestContext, steps: (key: string) => Script) => {
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, steps(`${m.messageId}:0`));
    await h.optIn(convId);
    await h.route(m);
    return { h, m };
  };
  await t.test("completed delivers once", async (t) => {
    const { h, m } = await replay(t, (key) => [
      post(key, created("run-r1", "completed", true)),
      get("/v1/runs/run-r1", runStatus("completed", { output: "Already done.", usage })),
    ]);
    assert.deepEqual(host.batches.map((batch: { payloads: { text: string }[] }) => batch.payloads[0]!.text), ["Already done."]);
    assert.deepEqual(endLines(h.lines), [endLine(m, "run-r1", "completed", [120, 45, 165])]);
  });
  await t.test("failed from fixtures 11 and 10 is run_failed with no batch", async (t) => {
    const { h, m } = await replay(t, (key) => [
      post(key, { fixture: "11-run-replay-same" }),
      get("/v1/runs/run_fixture_01", { fixture: "10-run-status" }),
    ]);
    assert.equal(errors().length, 1);
    assert.match(String(errors()[0]), /^Hermes: ⚠️ I couldn't connect to the AI model service/);
    assert.deepEqual(host.batches, []);
    assert.deepEqual(endLines(h.lines), [endLine(m, "run_fixture_01", "failed")]);
  });
  await t.test("a replayed temporary failure is never retried", async (t) => {
    const { h, m } = await replay(t, (key) => [
      post(key, created("run-r2", "failed", true)),
      get("/v1/runs/run-r2", runStatus("failed", { output: "Rate limit exceeded (429)" })),
    ]);
    assert.deepEqual(errors(), ["Hermes: Rate limit exceeded (429)"]);
    assert.equal(retryRow(m), undefined);
    assert.deepEqual(await keyRow(m), { keyAttempt: 0, session: h.state.session(m.convId) });
    assert.deepEqual(endLines(h.lines), [endLine(m, "run-r2", "failed")]);
  });
  for (const [status, text] of [["cancelled", "Hermes cancelled this run."], ["interrupted", "Hermes interrupted this run."]] as const) {
    await t.test(`${status} is run_failed`, async (t) => {
      const { h, m } = await replay(t, (key) => [post(key, created("run-r3", status, true)), get("/v1/runs/run-r3", runStatus(status))]);
      assert.deepEqual(errors(), [text]);
      assert.deepEqual(endLines(h.lines), [endLine(m, "run-r3", status)]);
    });
  }
  await t.test("running attaches and delivers", async (t) => {
    const { h, m } = await replay(t, (key) => [
      post(key, created("run-r4", "running", true)),
      get("/v1/runs/run-r4", runStatus("running")),
      get("/v1/runs/run-r4/events", sse({ event: "run.completed", run_id: "run-r4", output: "Caught up." })),
      get("/v1/runs/run-r4", runStatus("completed", { output: "Caught up.", usage })),
    ]);
    assert.deepEqual(host.batches.map((batch: { payloads: { text: string }[] }) => batch.payloads[0]!.text), ["Caught up."]);
    assert.deepEqual(endLines(h.lines), [endLine(m, "run-r4", "completed", [120, 45, 165])]);
  });
  await t.test("unknown resolves with the exact body, then maps", async (t) => {
    const { h, m } = await replay(t, (key) => [
      post(key, created("run-r5", "unknown", true)),
      get("/v1/runs/run-r5", runStatus("unknown", { admission_id: "admission-5", execution_generation: 4 })),
      postTo("/v1/runs/run-r5/resolve-unknown", json({ ok: true })),
      get("/v1/runs/run-r5", runStatus("completed", { output: "Resolved.", usage })),
    ]);
    assert.equal((await h.server.request(3)).body.toString(), '{"admission_id":"admission-5","execution_generation":4}');
    assert.deepEqual(host.batches.map((batch: { payloads: { text: string }[] }) => batch.payloads[0]!.text), ["Resolved."]);
    assert.deepEqual(endLines(h.lines), [endLine(m, "run-r5", "completed", [120, 45, 165])]);
  });
});

test("9. a temporary run.failed with no tool advances the request key and parks; with a tool or a permanent error it fails", async (t) => {
  await t.test("rate limit, no tool: key :1, parked, and the rerun answers", async (t) => {
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, [
      post(`${m.messageId}:0`, created("run-t1")),
      get("/v1/runs/run-t1/events", sse({ event: "run.failed", run_id: "run-t1", error: "Rate limit reached for requests", partial: false })),
      ...completedTurn(`${m.messageId}:1`, "run-t2"),
    ]);
    await h.optIn(convId);
    await h.route(m);
    assert.deepEqual(await keyRow(m), { keyAttempt: 1, session: h.state.session(convId) });
    assert.equal(retryRow(m)?.attempt, 1);
    assert.deepEqual(errors(), []);
    assert.ok(h.lines.includes("info: yorozu: hermes run parked (retry 1 queued): Rate limit reached for requests"));
    assert.equal(await h.entry(m), "parked");
    await h.rerun(m, 1);
    assert.deepEqual(errors(), []);
    assert.equal(host.batches.length, 1);
    assert.deepEqual(endLines(h.lines), [endLine(m, "run-t2", "completed", [120, 45, 165])]);
  });
  await t.test("the same after a tool.started is run_failed", async (t) => {
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, [
      post(`${m.messageId}:0`, created("run-t3")),
      get("/v1/runs/run-t3/events", sse(
        { event: "tool.started", run_id: "run-t3", tool_call_id: "call-1", tool: "terminal" },
        { event: "run.failed", run_id: "run-t3", error: "Rate limit reached for requests" },
      )),
    ]);
    await h.optIn(convId);
    await h.route(m);
    assert.deepEqual(errors(), ["Hermes: Rate limit reached for requests"]);
    assert.deepEqual(await keyRow(m), { keyAttempt: 0, session: h.state.session(convId) });
    assert.equal(retryRow(m), undefined);
    assert.deepEqual(endLines(h.lines), [endLine(m, "run-t3", "failed")]);
  });
  await t.test("fixture 09's permanent error is run_failed at once", async (t) => {
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, [
      post(`${m.messageId}:0`, created("run_fixture_01")),
      get("/v1/runs/run_fixture_01/events", { fixture: "09-run-events" }),
    ]);
    await h.optIn(convId);
    await h.route(m);
    assert.equal(errors().length, 1);
    assert.match(String(errors()[0]), /^Hermes: Hermes is not connected to any AI provider yet\./);
    assert.equal(retryRow(m), undefined);
    assert.deepEqual(endLines(h.lines), [endLine(m, "run_fixture_01", "failed")]);
  });
});

test("10. run.interrupted fails the turn with or without a tool and keeps the request key", async (t) => {
  for (const tool of [false, true]) {
    await t.test(tool ? "after a tool" : "no tool", async (t) => {
      const { convId } = conversation();
      const m = message(convId);
      const events = [
        ...(tool ? [{ event: "tool.started", run_id: "run-i", tool_call_id: "call-1", tool: "terminal" }] : []),
        { event: "run.interrupted", run_id: "run-i" },
      ];
      const h = await setup(t, [post(`${m.messageId}:0`, created("run-i")), get("/v1/runs/run-i/events", sse(...events))]);
      await h.optIn(convId);
      await h.route(m);
      assert.deepEqual(errors(), ["Hermes interrupted this run."]);
      assert.deepEqual(await keyRow(m), { keyAttempt: 0, session: h.state.session(convId) });
      assert.equal(retryRow(m), undefined);
      assert.deepEqual(endLines(h.lines), [endLine(m, "run-i", "interrupted")]);
    });
  }
});

async function polling(t: TestContext, steps: (key: string, runId: string) => Script, ticks: number[]) {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
  const { convId } = conversation();
  const m = message(convId);
  const runId = "run-poll";
  let counter = { settled: 0 };
  const h = await setup(t, steps(`${m.messageId}:0`, runId), {
    client: (client) => {
      const counted = settledCount(client);
      counter = counted.counter;
      return counted.wrapped;
    },
  });
  await h.optIn(convId);
  const turn = h.route(m);
  await until(() => h.lines.some((line) => line.includes(`hermes stream lost ${runId}`)), "the lost stream");
  for (const calls of ticks) {
    const before = counter.settled;
    t.mock.timers.tick(5_000);
    await until(() => counter.settled >= before + calls, "the poll");
    await setImmediate();
  }
  await turn;
  return { h, m, runId };
}

test("11. a lost stream polls the status every 5 s", async (t) => {
  const open = (runId: string) => get(`/v1/runs/${runId}/events`, sse());
  await t.test("running, then completed, delivers once", async (t) => {
    const { h, m, runId } = await polling(t, (key, runId) => [
      post(key, created(runId)), open(runId),
      get(`/v1/runs/${runId}`, runStatus("running")),
      get(`/v1/runs/${runId}`, runStatus("completed", { output: "Polled reply.", usage })),
    ], [1, 1]);
    assert.deepEqual(host.batches.map((batch: { payloads: { text: string }[] }) => batch.payloads[0]!.text), ["Polled reply."]);
    assert.deepEqual(endLines(h.lines), [endLine(m, runId, "completed", [120, 45, 165])]);
  });
  await t.test("a polled temporary failure is run_failed with the request key unchanged", async (t) => {
    const { h, m, runId } = await polling(t, (key, runId) => [
      post(key, created(runId)), open(runId),
      get(`/v1/runs/${runId}`, runStatus("failed", { output: "Rate limit exceeded" })),
    ], [1]);
    assert.deepEqual(errors(), ["Hermes: Rate limit exceeded"]);
    assert.deepEqual(await keyRow(m), { keyAttempt: 0, session: h.state.session(m.convId) });
    assert.equal(retryRow(m), undefined);
    assert.deepEqual(endLines(h.lines), [endLine(m, runId, "failed")]);
  });
  await t.test("a polled approval control is denied", async (t) => {
    const { h } = await polling(t, (key, runId) => [
      post(key, created(runId)), open(runId),
      get(`/v1/runs/${runId}`, runStatus("running", {
        execution_generation: 2, pending_controls: [{ request_id: "req-9", kind: "approval", tool: "browser" }],
      })),
      postTo(`/v1/runs/${runId}/approval`, json({ ok: true })),
      get(`/v1/runs/${runId}`, runStatus("completed", { output: "Partial answer." })),
    ], [2, 1]);
    assert.equal((await h.server.request(4)).body.toString(), '{"request_id":"req-9","execution_generation":2,"choice":"deny"}');
    assert.deepEqual(host.batches.map((batch: { payloads: { text: string }[] }) => batch.payloads[0]!.text), [
      "Partial answer.\n\nDenied: browser needed an approval Yorozu can't show yet.",
    ]);
  });
  await t.test("events answering not_found polls too", async (t) => {
    const { h, m, runId } = await polling(t, (key, runId) => [
      post(key, created(runId)),
      get(`/v1/runs/${runId}/events`, json({ error: { code: "run_not_found" } }, 404)),
      get(`/v1/runs/${runId}`, runStatus("completed", { output: "Found it." })),
    ], [1]);
    assert.ok(h.lines.includes(`info: yorozu: hermes stream lost ${runId}: not_found`));
    assert.deepEqual(endLines(h.lines), [endLine(m, runId, "completed")]);
  });
  await t.test("503, 429 and a refused connection keep polling and a later completed delivers once", async (t) => {
    const { h, m, runId } = await polling(t, (key, runId) => [
      post(key, created(runId)), open(runId),
      get(`/v1/runs/${runId}`, { status: 503 }),
      get(`/v1/runs/${runId}`, { status: 429 }),
      get(`/v1/runs/${runId}`, { end: "reset" as const }),
      get(`/v1/runs/${runId}`, runStatus("completed", { output: "Back again.", usage })),
    ], [1, 1, 1, 1]);
    assert.equal(host.batches.length, 1);
    assert.deepEqual(endLines(h.lines), [endLine(m, runId, "completed", [120, 45, 165])]);
  });
  for (const [label, reply] of [
    ["not_found", json({ error: { code: "run_not_found" } }, 404)],
    ["auth", json({ error: { code: "gateway_auth_failed" } }, 401)],
    ["http", json({ error: { code: "internal" } }, 500)],
  ] as const) {
    await t.test(`a status ${label} ends the turn as lost and keeps the id`, async (t) => {
      const { h, m, runId } = await polling(t, (key, runId) => [
        post(key, created(runId)), open(runId), get(`/v1/runs/${runId}`, reply),
      ], [1]);
      assert.deepEqual(errors(), ["Lost contact with the Hermes run."]);
      assert.deepEqual(endLines(h.lines), [endLine(m, runId, "lost")], JSON.stringify({ lines: h.lines, sent: host.sent }));
      assert.deepEqual(h.state.unsettled(m.convId), [runId]);
    });
  }
});

test("12. the next message ends earlier runs, across a restart, within its bound", async (t) => {
  await t.test("unknown is resolved and running is stopped, then the new run runs", async (t) => {
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, [
      get("/v1/runs/old-unknown", runStatus("unknown", { admission_id: "admission-old", execution_generation: 7 })),
      postTo("/v1/runs/old-unknown/resolve-unknown", json({ ok: true })),
      get("/v1/runs/old-unknown", runStatus("failed", { output: "interrupted by restart" })),
      get("/v1/runs/old-running", runStatus("running")),
      postTo("/v1/runs/old-running/stop", json({ ok: true })),
      get("/v1/runs/old-running", runStatus("cancelled")),
      ...completedTurn(`${m.messageId}:0`, "run-after-restart"),
    ]);
    await h.optIn(convId);
    await h.state.addUnsettled(convId, "old-unknown", "earlier-message");
    await h.state.addUnsettled(convId, "old-running", "earlier-message");
    const restarted = await createHermesState(store, h.log);
    const ledger = newLedger(h.lines);
    await ledger.load();
    ledger.claim(m);
    await routeMessage({ ...h.deps, state: restarted }, m);
    assert.equal((await h.server.request(2)).body.toString(), '{"admission_id":"admission-old","execution_generation":7}');
    assert.deepEqual(restarted.unsettled(convId), []);
    assert.equal(host.batches.length, 1);
  });
  await t.test("statuses that hang stop the check at 60 s, keep the ids and let the POST go", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
    const { convId } = conversation();
    const m = message(convId);
    const calls: string[] = [];
    const h = await setup(t, completedTurn(`${m.messageId}:0`, "run-bounded"), {
      client: (client) => ({
        ...client,
        status: (id: string) => {
          calls.push(id);
          return id.startsWith("old-") ? new Promise(() => {}) : client.status(id);
        },
        events: client.events.bind(client),
      }),
    });
    await h.optIn(convId);
    await h.state.addUnsettled(convId, "old-1", "earlier-message");
    await h.state.addUnsettled(convId, "old-2", "earlier-message");
    let posted = false;
    void h.server.request(1).then(() => { posted = true; });
    const turn = h.route(m);
    await until(() => calls.length === 1, "the first status");
    t.mock.timers.tick(59_999);
    for (let i = 0; i < 50; i++) await setImmediate();
    assert.equal(posted, false);
    t.mock.timers.tick(1);
    await until(() => posted, "the POST after the bound");
    await turn;
    assert.ok(h.lines.includes(`warn: yorozu: hermes earlier runs check stopped ${convId}: timeout, 2 ids kept`));
    assert.deepEqual(calls, ["old-1", "run-bounded"]);
    assert.deepEqual(h.state.unsettled(convId), ["old-1", "old-2"]);
    assert.equal(host.batches.length, 1);
  });
  await t.test("a refused first status stops the check at once", async (t) => {
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, [get("/v1/runs/old-1", { status: 503 }), ...completedTurn(`${m.messageId}:0`, "run-unavailable")]);
    await h.optIn(convId);
    await h.state.addUnsettled(convId, "old-1", "earlier-message");
    await h.state.addUnsettled(convId, "old-2", "earlier-message");
    await h.route(m);
    assert.ok(h.lines.includes(`warn: yorozu: hermes earlier runs check stopped ${convId}: unavailable, 2 ids kept`));
    assert.deepEqual(h.state.unsettled(convId), ["old-1", "old-2"]);
    assert.equal(host.batches.length, 1);
  });
});

test("13. an approval request is denied with a plain line and the run completes", async (t) => {
  const approval = { event: "approval.request", run_id: "run-a" };
  const pending = (controls: unknown[]) => get("/v1/runs/run-a", runStatus("running", { execution_generation: 2, pending_controls: controls }));
  const control = { request_id: "req-1", kind: "approval", tool: "terminal" };
  await t.test("deny, then the Denied line ends the reply", async (t) => {
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, [
      post(`${m.messageId}:0`, created("run-a")),
      get("/v1/runs/run-a/events", sse(approval, { event: "run.completed", run_id: "run-a", output: "Here is the summary." })),
      pending([control]),
      postTo("/v1/runs/run-a/approval", json({ ok: true })),
      get("/v1/runs/run-a", runStatus("completed", { output: "Here is the summary.", usage })),
    ]);
    await h.optIn(convId);
    await h.route(m);
    assert.equal((await h.server.request(4)).body.toString(), '{"request_id":"req-1","execution_generation":2,"choice":"deny"}');
    assert.deepEqual(host.batches.map((batch: { payloads: { text: string }[] }) => batch.payloads), [
      [{ text: "Here is the summary.\n\nDenied: terminal needed an approval Yorozu can't show yet." }],
    ]);
    assert.deepEqual(endLines(h.lines), [endLine(m, "run-a", "completed", [120, 45, 165])]);
  });
  for (const [label, steps] of [
    ["no pending control", [pending([]), postTo("/v1/runs/run-a/stop", json({ ok: true }))]],
    ["a failing deny", [pending([control]), postTo("/v1/runs/run-a/approval", { status: 500 }), postTo("/v1/runs/run-a/stop", json({ ok: true }))]],
  ] as const) {
    await t.test(`${label}: stop, then run_failed`, async (t) => {
      const { convId } = conversation();
      const m = message(convId);
      const h = await setup(t, [post(`${m.messageId}:0`, created("run-a")), get("/v1/runs/run-a/events", sse(approval)), ...steps]);
      await h.optIn(convId);
      await h.route(m);
      assert.deepEqual(errors(), ["Hermes asked for an approval that could not be answered."]);
      assert.deepEqual(host.batches, []);
      assert.deepEqual(endLines(h.lines), [endLine(m, "run-a", "approval")]);
    });
  }
});

test("14. requestBody is byte-identical across reruns and carries the quote, the text and the attachment note", () => {
  const session = "yorozu-conv-optin";
  const parse = (m: Message) => JSON.parse(requestBody(m, session));
  const m = message(randomUUID(), "Question");
  assert.equal(requestBody(m, session), requestBody(structuredClone(m), session));
  assert.equal(requestBody(m, session), JSON.stringify({ input: "Question", session_id: session, instructions: INSTRUCTIONS }));
  assert.equal(INSTRUCTIONS, "You are answering in Yorozu, a chat app on the owner's iPhone, iPad and Mac. Write plain Markdown; tables are fine. Your reply text is the message: don't use a message tool and don't use a card format.");
  assert.equal(parse({ ...m, replyTo: { messageId: randomUUID(), text: "Earlier answer" } }).input, "> Earlier answer\n\nQuestion");
  assert.equal(parse({ ...m, replyTo: { messageId: randomUUID(), text: "line one\n\n  line   two\n" } }).input, "> line one line two\n\nQuestion");
  assert.equal(parse({ ...m, replyTo: { messageId: randomUUID(), text: "x".repeat(600) } }).input, `> ${"x".repeat(500)}\n\nQuestion`);
  assert.equal(parse({ ...m, replyTo: { messageId: randomUUID() } }).input, "> (an earlier message)\n\nQuestion");
  const file = (n: number) => ({ id: `file-${n}`, name: `f${n}.txt`, mime: "text/plain", size: 1 });
  assert.equal(parse({ ...m, attachments: [file(1)] }).input, "Question\n\n[1 attachment(s) not sent to the Hermes test]");
  assert.equal(parse({ ...m, attachments: [file(1), file(2), file(3)] }).input, "Question\n\n[3 attachment(s) not sent to the Hermes test]");
  assert.equal(parse({ ...m, text: "Multi\nline\n\ntext" }).input, "Multi\nline\n\ntext");
});

test("15. a run still running at 30 minutes is stopped and fails with the id kept", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
  const { convId } = conversation();
  const m = message(convId);
  const runId = "run-capped";
  const polls = 347;
  let counter = { settled: 0 };
  const h = await setup(t, [
    post(`${m.messageId}:0`, created(runId)),
    get(`/v1/runs/${runId}/events`, { status: 200, headers: { "Content-Type": "text/event-stream" }, body: ": open\n\n", end: "hang" as const }),
    ...Array.from({ length: polls }, () => get(`/v1/runs/${runId}`, runStatus("running"))),
    postTo(`/v1/runs/${runId}/stop`, json({ ok: true })),
  ], {
    client: (client) => {
      const counted = settledCount(client);
      counter = counted.counter;
      return counted.wrapped;
    },
  });
  await h.optIn(convId);
  const turn = h.route(m);
  await h.server.request(2);
  for (let i = 0; i < 100; i++) await setImmediate();
  t.mock.timers.tick(62_500);
  await until(() => h.lines.some((line) => line.includes(`hermes stream lost ${runId}`)), "the idle stream end");
  for (let i = 0; i < polls; i++) {
    const before = counter.settled;
    t.mock.timers.tick(5_000);
    await until(() => counter.settled > before, `poll ${i + 1}`);
    await setImmediate();
  }
  t.mock.timers.tick(5_000);
  await turn;
  assert.deepEqual(errors(), ["The Hermes run took over 30 minutes."]);
  assert.deepEqual(endLines(h.lines), [endLine(m, runId, "capped")]);
  assert.deepEqual(h.state.unsettled(convId), [runId]);
});

test("16. a plugin reload mid-turn keeps the turn going and delivers its reply once", async (t) => {
  const { convId } = conversation();
  const first = message(convId);
  const second = message(convId, "After the reload");
  const done = { event: "run.completed", run_id: "run-reload-1", output: "Survived the reload.", seq: 0 };
  const h = await setup(t, [
    post(`${first.messageId}:0`, created("run-reload-1")),
    get("/v1/runs/run-reload-1/events", {
      status: 200, headers: { "Content-Type": "text/event-stream" }, body: ": open\n\n",
      chunks: [{ afterMs: 50, body: `data: ${JSON.stringify(done)}\n\n: stream closed\n\n` }],
    }),
    get("/v1/runs/run-reload-1", runStatus("completed", { output: done.output, usage })),
    ...completedTurn(`${second.messageId}:0`, "run-reload-2"),
  ]);
  await h.optIn(convId);
  const turn = h.route(first);
  await h.server.request(2);
  const reloaded: Deps = { ...h.deps, client: createHermesClient({ url: h.server.url, key: KEY }) };
  h.ledger.claim(second);
  await Promise.all([turn, routeMessage(reloaded, second)]);
  assert.deepEqual(host.batches.map((batch: { payloads: { text: string }[] }) => batch.payloads[0]!.text), ["Survived the reload.", "Sunny and 21°C."]);
  assert.equal(endLines(h.lines).length, 2);
});

test("17. restart interplay: before handing, after the POST, and parked", async (t) => {
  const restart = async (h: Harness, bootId: string) => {
    const ledger = newLedger(h.lines);
    await ledger.load();
    const line = ledger.counts().find((count) => count.includes(bootId));
    return { ledger, line };
  };
  await t.test("held before handing: accepted, counted not handed, no event, no rerun", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
    const bootId = `boot-${randomUUID()}`;
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, [], { bootId });
    await h.optIn(convId);
    host.mirror = "hang";
    void h.route(m);
    await until(() => host.mirrors.length === 1, "the hanging mirror");
    await h.ledger.idle();
    assert.equal((await runRows().lookup(m.messageId))?.state, "accepted");
    const sent = host.sent.length;
    const { ledger, line } = await restart(h, bootId);
    assert.equal(line, `yorozu: restart ledger ${bootId}: not handed 1, handed not started 0, started 0, parked 0`);
    assert.equal(host.sent.length, sent);
    assert.equal(retryRow(m), undefined);
    assert.equal(ledger.claim(m), "fresh", "sync 01 lets an accepted entry from an earlier boot through");
    assert.ok(h.lines.includes(`info: yorozu: duplicate message rerun ${m.messageId} accepted boot earlier never handed`));
  });
  await t.test("cut off after the POST: started, counted, no error, no rerun", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
    const bootId = `boot-${randomUUID()}`;
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, [post(`${m.messageId}:0`, created("run-cut"))], {
      bootId,
      client: (client) => ({
        ...client,
        events: () => ({ [Symbol.asyncIterator]: () => ({ next: () => new Promise<never>(() => {}) }) }),
      }),
    });
    await h.optIn(convId);
    void h.route(m);
    await h.server.request(1);
    await until(() => (host.stores.get("runs")?.get(m.messageId) as RunRecord | undefined)?.state === "started", "the started entry");
    const { ledger, line } = await restart(h, bootId);
    assert.equal(line, `yorozu: restart ledger ${bootId}: not handed 0, handed not started 0, started 1, parked 0`);
    assert.deepEqual(errors(), []);
    assert.equal(retryRow(m), undefined);
    assert.equal(ledger.claim(m), "duplicate");
  });
  await t.test("parked: counted parked and rerun through routedRerun with the same request key", async (t) => {
    const bootId = `boot-${randomUUID()}`;
    const { convId } = conversation();
    const m = message(convId);
    const key = `${m.messageId}:0`;
    const h = await setup(t, [
      post(key, { status: 503 }),
      post(key, created("run-parked", "completed", true)),
      get("/v1/runs/run-parked", runStatus("completed", { output: "After the restart.", usage })),
    ], { bootId });
    await h.optIn(convId);
    await h.route(m);
    await h.ledger.idle();
    const { ledger, line } = await restart(h, bootId);
    assert.equal(line, `yorozu: restart ledger ${bootId}: not handed 0, handed not started 0, started 0, parked 1`);
    assert.equal(ledger.claim(m), "duplicate");
    const parked = retryRow(m);
    assert.equal(parked?.attempt, 1);
    const restarted = await createHermesState(store, h.log);
    await h.rerun(m, parked!.attempt, { ...h.deps, state: restarted });
    assert.deepEqual(host.batches.map((batch: { payloads: { text: string }[] }) => batch.payloads[0]!.text), ["After the restart."]);
  });
});

test("18. an OpenClaw-parked message reruns on OpenClaw after the opt-in; a failing key lookup fails closed", async (t) => {
  const { convId } = conversation();
  const h = await setup(t, []);
  await h.optIn(convId);
  const parked = message(convId);
  await h.rerun(parked, 1);
  assert.deepEqual(dispatched(), [parked.messageId]);
  const failing = message(convId);
  host.lookup = (namespace: string) => {
    if (namespace === "hermes-keys") throw new Error("keys down");
  };
  await h.rerun(failing, 1);
  assert.deepEqual(errors(), ["The Hermes request key couldn't be read; this message wasn't rerun."]);
  assert.deepEqual(endLines(h.lines), [endLine(failing, "-", "store")]);
  assert.deepEqual(dispatched(), [parked.messageId]);
});

test("19. each error path writes exactly one turn-end line", async (t) => {
  const single = async (t: TestContext, steps: (key: string) => Script, opts: Parameters<typeof setup>[2] = {}, prepare = () => {}) => {
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, steps(`${m.messageId}:0`), opts);
    await h.optIn(convId);
    prepare();
    await h.route(m);
    return { h, m };
  };
  await t.test("auth from createRun", async (t) => {
    const { h, m } = await single(t, (key) => [post(key, json({ error: { code: "invalid_api_key" } }, 401))]);
    assert.deepEqual(errors(), ["The Hermes test backend refused the API key."]);
    assert.deepEqual(endLines(h.lines), [endLine(m, "-", "refused")]);
  });
  await t.test("conflict from createRun", async (t) => {
    const { h, m } = await single(t, (key) => [post(key, json({ error: { code: "idempotency_key_conflict" } }, 409))]);
    assert.deepEqual(errors(), ["Hermes answered 409 idempotency_key_conflict."]);
    assert.ok(h.lines.includes("warn: yorozu: hermes answered 409 idempotency_key_conflict (conflict)"));
    assert.deepEqual(endLines(h.lines), [endLine(m, "-", "rejected")]);
  });
  await t.test("an empty output", async (t) => {
    const { h, m } = await single(t, (key) => [
      post(key, created("run-empty")), get("/v1/runs/run-empty/events", sse({ event: "run.completed", run_id: "run-empty", output: "  " })),
    ]);
    assert.deepEqual(errors(), ["Hermes finished with an empty reply."]);
    assert.deepEqual(endLines(h.lines), [endLine(m, "run-empty", "empty")]);
  });
  await t.test("a batch status other than sent", async (t) => {
    const { h, m } = await single(t, (key) => [
      post(key, created("run-unsent")), get("/v1/runs/run-unsent/events", sse({ event: "run.completed", run_id: "run-unsent", output: "Lost on the way." })),
    ], {}, () => { host.batchStatus = "failed"; });
    assert.deepEqual(errors(), ["The Hermes reply couldn't be sent: failed."]);
    assert.deepEqual(endLines(h.lines), [endLine(m, "run-unsent", "unsent")]);
  });
  await t.test("a failing key write", async (t) => {
    const { h, m } = await single(t, () => [], {}, () => {
      host.register = (namespace: string) => {
        if (namespace === "hermes-keys") throw new Error("keys down");
      };
    });
    assert.deepEqual(errors(), ["The Hermes request key couldn't be stored."]);
    assert.deepEqual(host.mirrors, []);
    assert.deepEqual(endLines(h.lines), [endLine(m, "-", "store")]);
  });
  await t.test("a failing mirror is logged and the turn goes on", async (t) => {
    const { h, m } = await single(t, (key) => completedTurn(key, "run-mirror-failed"), {}, () => { host.mirror = "reject"; });
    assert.ok(h.lines.includes(`warn: yorozu: hermes mirror failed ${m.messageId}: Error`));
    assert.equal(host.batches.length, 1);
    assert.deepEqual(endLines(h.lines), [endLine(m, "run-mirror-failed", "completed", [120, 45, 165])]);
  });
  await t.test("an unexpected throw fails once and the FIFO's next message still runs", async (t) => {
    const { convId } = conversation();
    const m = message(convId);
    const next = message(convId, "Next");
    const h = await setup(t, completedTurn(`${next.messageId}:0`, "run-next"), {
      client: (client) => ({
        ...client,
        createRun: (req) => req.key.startsWith(m.messageId) ? Promise.reject(new TypeError("boom")) : client.createRun(req),
        events: client.events.bind(client),
      }),
    });
    await h.optIn(convId);
    h.ledger.claim(m);
    h.ledger.claim(next);
    await Promise.all([routeMessage(h.deps, m), routeMessage(h.deps, next)]);
    assert.deepEqual(errors(), ["The Hermes test turn failed."]);
    assert.ok(h.lines.includes("warn: yorozu: hermes turn failed: TypeError"));
    assert.deepEqual(endLines(h.lines), [endLine(m, "-", "crashed"), endLine(next, "run-next", "completed", [120, 45, 165])]);
  });
  await t.test("a throw after the turn ended writes no second line and no second error", async (t) => {
    const { h, m } = await single(t, (key) => completedTurn(key, "run-ended"), {
      client: (client) => ({
        ...client,
        events: (runId, signal) => {
          const stream = client.events(runId, signal)[Symbol.asyncIterator]();
          return { [Symbol.asyncIterator]: () => ({ next: () => stream.next(), return: () => { throw new TypeError("late"); } }) };
        },
      }),
    });
    assert.deepEqual(errors(), []);
    assert.ok(h.lines.includes("warn: yorozu: hermes turn failed: TypeError"));
    assert.deepEqual(endLines(h.lines), [endLine(m, "run-ended", "completed", [120, 45, 165])]);
  });
  await t.test("externalTurn: the first end wins", () => {
    const { convId } = conversation();
    const m = message(convId);
    const turn = externalTurn({ cfg: {}, accountId: "default", log: logger([]), agent: "main", mediaMaxBytes: 1, presentationSdk: {} } as never, m, 0);
    assert.equal(turn.done(), true);
    assert.equal(turn.fail("late"), false);
    assert.equal(turn.done(), false);
    const failed = externalTurn({ cfg: {}, accountId: "default", log: logger([]), agent: "main", mediaMaxBytes: 1, presentationSdk: {} } as never, message(convId), 0);
    assert.equal(failed.fail("first"), true);
    assert.equal(failed.done(), false);
    assert.deepEqual(errors(), ["first"]);
  });
});

test("20. one conversation's messages run in order on its FIFO", async (t) => {
  await t.test("two messages in order", async (t) => {
    const { convId } = conversation();
    const first = message(convId);
    const second = message(convId, "Second");
    const h = await setup(t, [...completedTurn(`${first.messageId}:0`, "run-f1"), ...completedTurn(`${second.messageId}:0`, "run-f2")]);
    await h.optIn(convId);
    let batchesAtSecondPost = -1;
    void h.server.request(4).then(() => { batchesAtSecondPost = host.batches.length; });
    h.ledger.claim(first);
    h.ledger.claim(second);
    await Promise.all([routeMessage(h.deps, first), routeMessage(h.deps, second)]);
    assert.equal(batchesAtSecondPost, 1, "the second POST waited for the first reply");
    assert.equal(endLines(h.lines).length, 2);
  });
  await t.test("a message right after /backend hermes queues behind the opt-in", async (t) => {
    const { convId } = conversation();
    const optIn = message(convId, "/backend hermes");
    const m = message(convId);
    const h = await setup(t, completedTurn(`${m.messageId}:0`, "run-after-optin"));
    h.ledger.claim(optIn);
    h.ledger.claim(m);
    await Promise.all([routeMessage(h.deps, optIn), routeMessage(h.deps, m)]);
    assert.deepEqual(dispatched(), []);
    assert.equal((await bodyOf(h.server, 1)).session_id, `yorozu-${convId}-${optIn.messageId}`);
  });
  await t.test("a throwing link doesn't block the next", async (t) => {
    const { convId } = conversation();
    const h = await setup(t, []);
    let ran = false;
    await h.state.serial(convId, async () => { throw new Error("link"); });
    await h.state.serial(convId, async () => { ran = true; });
    assert.equal(ran, true);
  });
});

test("26. a temporary run.failed advances the request key only on this run's whole stream from seq 0 with no tool", async (t) => {
  const failed = (seq?: number) => ({ event: "run.failed", run_id: "run-w", error: "Rate limit reached for requests", ...(seq !== undefined && { seq }) });
  const events = "/v1/runs/run-w/events";
  const toolNames = () => (host.sent as Sent[]).filter((event) => event.kind === "tool").map((event) => event.data.name);
  for (const [label, steps, tools] of [
    ["a replayed running run", (key: string) => [
      post(key, created("run-w", "running", true)), get("/v1/runs/run-w", runStatus("running")), get(events, sse(failed(8))),
    ], []],
    ["a first event after seq 0", (key: string) => [post(key, created("run-w")), get(events, sse(failed(3)))], []],
    ["a seq gap", (key: string) => [
      post(key, created("run-w")), get(events, sse({ event: "message.delta", run_id: "run-w", delta: "Hi" }, failed(2))),
    ], []],
    ["a tool with a blank name", (key: string) => [
      post(key, created("run-w")), get(events, sse({ event: "tool.started", run_id: "run-w", tool_call_id: "call-1", tool: "  " }, failed())),
    ], ["tool"]],
  ] as const) {
    await t.test(label, async (t) => {
      const { convId } = conversation();
      const m = message(convId);
      const h = await setup(t, steps(`${m.messageId}:0`));
      await h.optIn(convId);
      await h.route(m);
      assert.deepEqual(errors(), ["Hermes: Rate limit reached for requests"]);
      assert.deepEqual(await keyRow(m), { keyAttempt: 0, session: h.state.session(convId) });
      assert.equal(retryRow(m), undefined);
      assert.deepEqual(endLines(h.lines), [endLine(m, "run-w", "failed")]);
      assert.deepEqual(toolNames(), tools);
    });
  }
});

test("27. a message parked before /new and a fresh opt-in ends once without a POST into the new session", async (t) => {
  const { convId } = conversation();
  const m = message(convId);
  const h = await setup(t, [post(`${m.messageId}:0`, { status: 503 })]);
  const first = await h.optIn(convId);
  await h.route(m);
  assert.equal(retryRow(m)?.attempt, 1);
  assert.deepEqual(await keyRow(m), { keyAttempt: 0, session: first });
  await h.route(message(convId, "/new"));
  const again = message(convId, "/backend hermes");
  await h.route(again);
  assert.equal(h.state.session(convId), `yorozu-${convId}-${again.messageId}`);
  await h.rerun(m, 1);
  assert.deepEqual(errors(), ["This conversation started a new Hermes session; this message wasn't rerun."]);
  assert.deepEqual(endLines(h.lines), [endLine(m, "-", "off")]);
});

test("28. a rerun leaves its own earlier attempt's run to the replay and never stops it", async (t) => {
  const { convId } = conversation();
  const m = message(convId);
  const key = `${m.messageId}:0`;
  const runId = "run-own";
  const h = await setup(t, [
    post(key, created(runId, "running", true)),
    get(`/v1/runs/${runId}`, { status: 503 }),
    post(key, created(runId, "completed", true)),
    get(`/v1/runs/${runId}`, runStatus("completed", { output: "Finished once.", usage })),
  ]);
  await h.optIn(convId);
  await h.route(m);
  assert.equal(retryRow(m)?.attempt, 1);
  assert.deepEqual(h.state.unsettled(convId), [runId]);
  await h.rerun(m, 1);
  assert.deepEqual(errors(), []);
  assert.deepEqual(host.batches.map((batch: { payloads: { text: string }[] }) => batch.payloads[0]!.text), ["Finished once."]);
  assert.deepEqual(endLines(h.lines), [endLine(m, runId, "completed", [120, 45, 165])]);
  assert.deepEqual(h.state.unsettled(convId), []);
});

test("29. Hermes failure text reaches logs and the device with the API key redacted, on one log line", async (t) => {
  const single = async (t: TestContext, steps: (key: string) => Script) => {
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, steps(`${m.messageId}:0`));
    await h.optIn(convId);
    await h.route(m);
    assert.deepEqual(h.lines.filter((line) => line.includes(KEY) || line.includes("\n")), []);
    return h;
  };
  await t.test("a temporary failure's retry reason", async (t) => {
    const h = await single(t, (key) => [
      post(key, created("run-k1")),
      get("/v1/runs/run-k1/events", sse({ event: "run.failed", run_id: "run-k1", error: `Rate limit for Bearer ${KEY}\nretry later` })),
    ]);
    assert.ok(h.lines.includes("info: yorozu: hermes run parked (retry 1 queued): Rate limit for Bearer [redacted] retry later"));
    assert.deepEqual(errors(), []);
  });
  await t.test("a failed run's output", async (t) => {
    await single(t, (key) => [
      post(key, created("run-k2", "failed", true)),
      get("/v1/runs/run-k2", runStatus("failed", { output: `Provider rejected ${KEY}\nsee logs` })),
    ]);
    assert.deepEqual(errors(), ["Hermes: Provider rejected [redacted]\nsee logs"]);
  });
  await t.test("an event's error object", async (t) => {
    await single(t, (key) => [
      post(key, created("run-k3")),
      get("/v1/runs/run-k3/events", sse({ event: "run.failed", run_id: "run-k3", error: { code: "bad_auth", detail: KEY } })),
    ]);
    assert.deepEqual(errors(), ['Hermes: {"code":"bad_auth","detail":"[redacted]"}']);
  });
});

test("30. deadlines bound the earlier-run removals and the 30-minute cap abandons pending work", async (t) => {
  await t.test("a removal that never lands stops the check at 60 s and the POST goes", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
    const { convId } = conversation();
    const m = message(convId);
    const h = await setup(t, [get("/v1/runs/old-1", runStatus("completed")), ...completedTurn(`${m.messageId}:0`, "run-after-stall")]);
    await h.optIn(convId);
    await h.state.addUnsettled(convId, "old-1", "earlier-message");
    let stalled = false;
    host.register = (namespace: string) => {
      if (namespace !== "backends" || stalled) return;
      stalled = true;
      return new Promise(() => {});
    };
    let posted = false;
    void h.server.request(2).then(() => { posted = true; });
    const turn = h.route(m);
    await until(() => stalled, "the stalled removal");
    t.mock.timers.tick(59_999);
    for (let i = 0; i < 50; i++) await setImmediate();
    assert.equal(posted, false);
    t.mock.timers.tick(1);
    await until(() => posted, "the POST after the bound");
    await turn;
    assert.ok(h.lines.includes(`warn: yorozu: hermes earlier runs check stopped ${convId}: timeout, 0 ids kept`));
    assert.equal(host.batches.length, 1);
  });

  await t.test("an approval still being read at the cap is abandoned: no deny, one stop, run_failed", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
    const { convId } = conversation();
    const m = message(convId);
    const runId = "run-capped-approval";
    const calls: string[] = [];
    const read = Promise.withResolvers<RunStatus>();
    const approval: IteratorResult<RunEvent> = { done: false, value: { event: "approval.request", seq: 0, data: { run_id: runId } } };
    const fake: HermesClient = {
      createRun: async () => ({ runId, status: "started", replayed: false }),
      status: () => {
        calls.push("status");
        return read.promise;
      },
      events: () => {
        let sent = false;
        return { [Symbol.asyncIterator]: () => ({
          next: () => (sent ? new Promise<IteratorResult<RunEvent>>(() => {}) : ((sent = true), Promise.resolve(approval))),
          return: async () => ({ done: true as const, value: undefined }),
        }) };
      },
      deny: async () => { calls.push("deny"); },
      resolveUnknown: async () => { calls.push("resolveUnknown"); },
      stop: async () => { calls.push("stop"); },
    };
    const h = await setup(t, [], { client: () => fake });
    await h.optIn(convId);
    const turn = h.route(m);
    await until(() => calls.includes("status"), "the approval status read");
    t.mock.timers.tick(30 * 60 * 1000);
    await turn;
    read.resolve({ status: "running", generation: 1, pendingControls: [{ id: "req-1", kind: "approval", tool: "terminal" }] });
    for (let i = 0; i < 50; i++) await setImmediate();
    assert.deepEqual(calls, ["status", "stop"]);
    assert.deepEqual(errors(), ["The Hermes run took over 30 minutes."]);
    assert.deepEqual(endLines(h.lines), [endLine(m, runId, "capped")]);
    assert.deepEqual(host.batches, []);
  });
});

test("23. the route state keeps routes and unsettled ids in the store and undoes failed writes", async () => {
  const open = <T>(opts: { namespace: string }) => store<T>({ namespace: `${opts.namespace}-t23` });
  const rows = () => host.stores.get("backends-t23") as Map<string, unknown>;
  const state = await createHermesState(open);
  const convId = randomUUID();
  const optIn = randomUUID();
  assert.equal(await state.setRoute(convId, optIn), "set");
  assert.equal(state.routedToHermes(convId), true);
  assert.equal(state.session(convId), `yorozu-${convId}-${optIn}`);
  assert.equal(await state.setRoute(convId, randomUUID()), "already");
  await state.addUnsettled(convId, "run-1", "message-1");
  await state.addUnsettled(convId, "run-1", "message-1");
  assert.deepEqual(state.unsettled(convId), ["run-1"]);
  assert.deepEqual(state.unsettled(convId, "message-1"), []);
  assert.deepEqual(state.unsettled(convId, "message-2"), ["run-1"]);
  const restarted = await createHermesState(open);
  assert.equal(restarted.session(convId), `yorozu-${convId}-${optIn}`);
  assert.deepEqual(restarted.unsettled(convId), ["run-1"]);
  assert.deepEqual(rows().get(convId), { session: `yorozu-${convId}-${optIn}`, unsettled: [{ runId: "run-1", messageId: "message-1" }] });
  const legacy = randomUUID();
  rows().set(legacy, { session: `yorozu-${legacy}-x`, unsettled: ["run-legacy"] });
  const loaded = await createHermesState(open);
  assert.deepEqual(loaded.unsettled(legacy), ["run-legacy"]);
  assert.deepEqual(loaded.unsettled(legacy, "message-1"), ["run-legacy"]);
  rows().delete(legacy);

  host.register = (namespace: string) => {
    if (namespace === "backends-t23") throw new Error("store down");
  };
  await assert.rejects(state.addUnsettled(convId, "run-2", "message-2"));
  assert.deepEqual(state.unsettled(convId), ["run-1"]);
  const other = randomUUID();
  await assert.rejects(state.setRoute(other, randomUUID()));
  assert.equal(state.routedToHermes(other), false);
  host.register = undefined;

  await state.removeUnsettled(convId, "run-1");
  assert.deepEqual(state.unsettled(convId), []);
  host.delete = (namespace: string) => {
    if (namespace === "backends-t23") throw new Error("store down");
  };
  await assert.rejects(state.dropRoute(convId));
  assert.equal(state.routedToHermes(convId), true);
  assert.equal(rows().has(convId), true);
  host.delete = undefined;
  await state.dropRoute(convId);
  assert.equal(state.routedToHermes(convId), false);
  assert.equal(rows().has(convId), false);
});

function scripted(runId: string, events: RunEvent[], calls: string[], over: Partial<HermesClient> = {}): HermesClient {
  return {
    createRun: async () => {
      calls.push("createRun");
      return { runId, status: "started", replayed: false };
    },
    status: async () => {
      calls.push("status");
      return { status: "completed", pendingControls: [] };
    },
    events: () => {
      let i = 0;
      return { [Symbol.asyncIterator]: () => ({
        next: () => (i < events.length
          ? Promise.resolve({ done: false as const, value: events[i++]! })
          : new Promise<IteratorResult<RunEvent>>(() => {})),
        return: async () => ({ done: true as const, value: undefined }),
      }) };
    },
    deny: async () => { calls.push("deny"); },
    resolveUnknown: async () => { calls.push("resolveUnknown"); },
    stop: async () => { calls.push("stop"); },
    ...over,
  };
}

test("31. a run id, tool name and approval tool carrying the API key are redacted in logs and on the device", async (t) => {
  const { convId } = conversation();
  const m = message(convId);
  const runId = `run-${KEY}-x`;
  const calls: string[] = [];
  let reads = 0;
  const fake = scripted(runId, [
    { event: "tool.started", seq: 0, data: { tool: `search-${KEY}`, tool_call_id: `call-${KEY}` } },
    { event: "tool.completed", seq: 1, data: { tool: `search-${KEY}`, tool_call_id: `call-${KEY}` } },
    { event: "approval.request", seq: 2, data: {} },
    { event: "run.completed", seq: 3, data: { output: "Done." } },
  ], calls, {
    status: async () => {
      calls.push("status");
      return reads++ === 0
        ? { status: "running", generation: 1, pendingControls: [{ id: "req-1", kind: "approval", tool: `shell-${KEY}` }] }
        : { status: "completed", output: "Done.", usage: { inputTokens: 1, outputTokens: 2, totalTokens: 3 }, pendingControls: [] };
    },
  });
  const h = await setup(t, [], { client: () => fake });
  await h.optIn(convId);
  await h.route(m);
  const shown = "run-[redacted]-x";
  assert.deepEqual(createLines(h.lines), [`info: yorozu: hermes createRun ${m.messageId}:0 run=${shown} replayed=false error=-`]);
  assert.deepEqual(endLines(h.lines), [endLine(m, shown, "completed", [1, 2, 3])]);
  const tools = (host.sent as Sent[]).filter((event) => event.kind === "tool").map((event) => [event.data.callId, event.data.name]);
  assert.deepEqual(tools, [
    [`hermes:${shown}:call-[redacted]`, "search-[redacted]"],
    [`hermes:${shown}:call-[redacted]`, "search-[redacted]"],
  ]);
  assert.match(host.batches[0].payloads[0].text, /Denied: shell-\[redacted\] needed/);
  assert.deepEqual(h.lines.filter((line) => line.includes(KEY)), []);
  assert.equal(JSON.stringify(host.sent).includes(KEY), false);
  assert.equal(JSON.stringify(host.batches).includes(KEY), false);
});

test("32. a removal stalled past /new that later fails leaves the route off and the next message goes to OpenClaw", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
  const { convId } = conversation();
  const calls: string[] = [];
  const h = await setup(t, [], { client: () => scripted("unused", [], calls) });
  await h.optIn(convId);
  await h.state.addUnsettled(convId, "old-1", "earlier-message");
  const removal = Promise.withResolvers<void>();
  let stalled = false;
  host.register = (namespace: string) => {
    if (namespace !== "backends" || stalled) return;
    stalled = true;
    return removal.promise;
  };
  const reset = message(convId, "/new");
  const turn = h.route(reset);
  await until(() => stalled, "the stalled removal");
  t.mock.timers.tick(60_000);
  await turn;
  assert.equal(h.state.routedToHermes(convId), false);
  assert.ok(dispatched().includes(reset.messageId));
  removal.reject(new Error("store down"));
  for (let i = 0; i < 50; i++) await setImmediate();
  assert.equal(h.state.routedToHermes(convId), false);
  assert.equal(h.state.session(convId), undefined);
  const next = message(convId);
  await h.route(next);
  assert.ok(dispatched().includes(next.messageId));
  assert.deepEqual(calls, ["status"]);
  assert.equal(host.stores.get("backends")?.has(convId), false);
});

test("32b. a route write stalled past /new that later succeeds is rejected, so a restart keeps the route off", async (t) => {
  t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
  const { convId } = conversation();
  const h = await setup(t, [], { client: () => scripted("unused", [], []) });
  await h.optIn(convId);
  await h.state.addUnsettled(convId, "old-1", "earlier-message");
  const removal = Promise.withResolvers<void>();
  let stalled = false;
  host.register = (namespace: string) => {
    if (namespace !== "backends" || stalled) return;
    stalled = true;
    return removal.promise;
  };
  const turn = h.route(message(convId, "/new"));
  await until(() => stalled, "the stalled removal");
  t.mock.timers.tick(60_000);
  await turn;
  removal.resolve();
  for (let i = 0; i < 50; i++) await setImmediate();
  assert.equal(host.stores.get("backends")?.has(convId), false);
  const restarted = await createHermesState(store);
  assert.equal(restarted.routedToHermes(convId), false);
});

test("33. after the 30-minute cap, late terminal handlers lose and the outcome stays capped", async (t) => {
  await t.test("a temporary failure whose retry write lands after the cap leaves no retry row", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
    const { convId } = conversation();
    const m = message(convId);
    const runId = "run-capped-park";
    const calls: string[] = [];
    const fake = scripted(runId, [{ event: "run.failed", seq: 0, data: { error: "rate limit exceeded" } }], calls);
    const h = await setup(t, [], { client: () => fake });
    await h.optIn(convId);
    const write = Promise.withResolvers<void>();
    let held = false;
    host.register = (namespace: string) => {
      if (namespace !== "retry") return;
      held = true;
      return write.promise;
    };
    const turn = h.route(m);
    await until(() => held, "the held retry write");
    t.mock.timers.tick(30 * 60 * 1000);
    await turn;
    write.resolve();
    for (let i = 0; i < 50; i++) await setImmediate();
    assert.equal(retryRow(m), undefined);
    assert.deepEqual(calls, ["createRun", "stop"]);
    assert.deepEqual(errors(), ["The Hermes run took over 30 minutes."]);
    assert.deepEqual(endLines(h.lines), [endLine(m, runId, "capped")]);
    assert.deepEqual(h.lines.filter((line) => line.includes("hermes run parked")), []);
  });

  await t.test("a retry row left by a failed cleanup after the cap is dropped on the next tick without a POST", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
    const { convId } = conversation();
    const m = message(convId);
    const runId = "run-capped-cleanup";
    const calls: string[] = [];
    const fake = scripted(runId, [{ event: "run.failed", seq: 0, data: { error: "rate limit exceeded" } }], calls);
    const h = await setup(t, [], { client: () => fake });
    await h.optIn(convId);
    const controller = new AbortController();
    t.after(() => controller.abort());
    runParked(controller.signal, (msg, attempt) => void h.rerun(msg, attempt));
    const write = Promise.withResolvers<void>();
    let held = false;
    host.register = (namespace: string) => {
      if (namespace !== "retry") return;
      held = true;
      return write.promise;
    };
    let failed = false;
    host.delete = (namespace: string) => {
      if (namespace !== "retry" || failed) return;
      failed = true;
      throw new Error("store down");
    };
    const turn = h.route(m);
    await until(() => held, "the held retry write");
    t.mock.timers.tick(30 * 60 * 1000);
    await turn;
    host.register = undefined;
    write.resolve();
    await until(() => failed, "the failed cleanup delete");
    for (let i = 0; i < 50; i++) await setImmediate();
    assert.ok(retryRow(m), "the cleanup left the row");
    t.mock.timers.tick(5_000);
    for (let i = 0; i < 50; i++) await setImmediate();
    assert.equal(retryRow(m), undefined);
    assert.deepEqual(calls, ["createRun", "stop"]);
    assert.deepEqual(errors(), ["The Hermes run took over 30 minutes."]);
    assert.deepEqual(endLines(h.lines), [endLine(m, runId, "capped")]);
  });

  await t.test("a reply batch that finishes after the cap starts no status read and logs capped", async (t) => {
    t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"] });
    const { convId } = conversation();
    const m = message(convId);
    const runId = "run-capped-reply";
    const calls: string[] = [];
    const stop = Promise.withResolvers<void>();
    const fake = scripted(runId, [{ event: "run.completed", seq: 0, data: { output: "Late reply." } }], calls, {
      stop: () => {
        calls.push("stop");
        return stop.promise;
      },
    });
    const h = await setup(t, [], { client: () => fake });
    await h.optIn(convId);
    const batch = Promise.withResolvers<void>();
    host.batchHold = () => batch.promise;
    const turn = h.route(m);
    await until(() => host.batches.length === 1, "the held reply batch");
    t.mock.timers.tick(30 * 60 * 1000);
    await until(() => calls.includes("stop"), "the cap's stop");
    batch.resolve();
    for (let i = 0; i < 50; i++) await setImmediate();
    stop.resolve();
    await turn;
    for (let i = 0; i < 50; i++) await setImmediate();
    assert.deepEqual(calls, ["createRun", "stop"]);
    assert.deepEqual(errors(), ["The Hermes run took over 30 minutes."]);
    assert.deepEqual(endLines(h.lines), [endLine(m, runId, "capped")]);
  });
});

test("22. no log line or device event from these tests contains the API key", () => {
  assert.ok(allLines.length > 100, "expected the earlier tests' log lines");
  assert.deepEqual(allLines.filter((line) => line.includes(KEY)), []);
  assert.deepEqual(allSent.filter((sent) => sent.includes(KEY)), []);
});

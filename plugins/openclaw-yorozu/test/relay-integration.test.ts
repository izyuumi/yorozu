import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { mkdtemp, rm, mkdir, writeFile } from "node:fs/promises";
import { registerHooks } from "node:module";
import os from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { test, type TestContext } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import type { Event, PeerInfo } from "../src/envelope.ts";
import { ownerRuntime } from "./conversation-owner-fixture.ts";
import type { ActivityReport } from "../src/liveactivity.ts";

declare global { var __yorozuDirectFail: boolean | undefined; }
globalThis.__yorozuDirectFail = false;

const sdk = process.env.YOROZU_OPENCLAW_SDK;
const sdkPrefix = "openclaw/plugin-sdk/";
const skip = !sdk ? "set YOROZU_OPENCLAW_SDK to an installed OpenClaw package root"
  : !existsSync(path.join(sdk, "dist/plugin-sdk/websocket-runtime.js")) ? "YOROZU_OPENCLAW_SDK has no dist/plugin-sdk/websocket-runtime.js" : false;
// Relative overrides are relative to this file, just like the default ../src.
const source = process.env.YOROZU_PLUGIN_SRC
  ? pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), process.env.YOROZU_PLUGIN_SRC) + path.sep)
  : new URL("../src/", import.meta.url);
const CONV = "11111111-1111-4111-8111-111111111111";
const JOB = "AAAAAAAAAAAAAAAA";
const REQUESTED_AT_MS = 1_800_000_000_500;
const peer: PeerInfo = { app: "integration-test", protocolMin: 3, protocolMax: 3, capabilities: [] };
const report = (seeded: boolean): ActivityReport => ({
  pushToken: "ab".repeat(32),
  ...(seeded && { activityId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", requestedAtMs: REQUESTED_AT_MS }),
  jobs: [{ token: JOB, kind: "turn", state: "running", steps: 1, startedAt: REQUESTED_AT_MS }],
  turns: { [JOB]: CONV },
});
type HostMessage = { type: string; payload?: string; frames?: { payload: string; sig: string }[]; seq?: number;
  device?: string; token?: string; timestamp?: number; [key: string]: unknown };
type Socket = { send(raw: string): void; close(): void; terminate(): void; on(event: string, callback: (raw: unknown) => void): void };
type Connection = { socket: Socket; messages: HostMessage[]; frames: string[] };

async function until<T>(read: () => T | undefined, description: string, timeout = 5_000): Promise<T> {
  const deadline = Date.now() + timeout;
  do {
    const value = read();
    if (value !== undefined) return value;
    await delay(10);
  } while (Date.now() < deadline);
  assert.fail(`timed out waiting for ${description}`);
}

test("runRelayHost over a real Noise device session", { skip, timeout: 60_000 }, async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "yorozu-relay-integration-"));
  const previous = { HOME: process.env.HOME, OPENCLAW_STATE_DIR: process.env.OPENCLAW_STATE_DIR };
  // Must precede every SDK/plugin import, including SDK modules with import-time state paths.
  process.env.HOME = root;
  process.env.OPENCLAW_STATE_DIR = root;
  t.after(async () => {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    await rm(root, { recursive: true, force: true });
  });

  // Stub every network discovery entry point: only the fake relay may listen (loopback).
  const stub = (code: string) => `data:text/javascript,${encodeURIComponent(code)}`;
  const networkStubs: Record<string, string> = {
    "./direct.js": stub(`export const bindAddresses = () => [];
      export const serveDirect = async () => {
        if (globalThis.__yorozuDirectFail) throw Object.assign(new Error("synthetic bind failure"), {code:"EADDRINUSE"});
        return {listening:false, close:async()=>{}};
      };`),
    "./hints.js": stub("export const watchDirect = async () => async () => {};"),
    "./bonjour.js": stub("export const serveBonjour = async () => ({update:async()=>{}, close:async()=>{}});"),
  };
  const hooks = registerHooks({
    resolve(specifier, context, next) {
      if (context.parentURL === new URL("relay.ts", source).href && networkStubs[specifier]) {
        return { url: networkStubs[specifier]!, shortCircuit: true };
      }
      if (specifier.startsWith(sdkPrefix)) {
        return next(pathToFileURL(path.join(sdk!, "dist/plugin-sdk", `${specifier.slice(sdkPrefix.length)}.js`)).href, context);
      }
      if (specifier.startsWith(".") && specifier.endsWith(".js") && context.parentURL) {
        const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
        if (existsSync(ts)) return next(ts.href, context);
      }
      return next(specifier, context);
    },
  });
  t.after(() => hooks.deregister());
  const { resolveStateDir } = await import(sdkPrefix + "state-paths");
  const stateDir = resolveStateDir();
  assert.ok(path.relative(root, stateDir) === "" || (!path.relative(root, stateDir).startsWith("..") && !path.isAbsolute(path.relative(root, stateDir))), "SDK state must stay inside the temporary HOME");
  const { WebSocketServer } = await import(sdkPrefix + "websocket-runtime");
  const owner = await ownerRuntime(source);
  const { stores } = owner;
  t.after(() => owner.close());
  const { runRelayHost, activityTurn: emitActivityTurn } = await import(new URL("relay.ts", source).href);
  const { encodeEvent, parseEvent } = await import(new URL("envelope.ts", source).href);
  const { applyTurn, plan } = await import(new URL("liveactivity.ts", source).href);
  const { b64u, decodeFrame, ed25519Keypair, encodeFrame, NoiseIK, prologue, roomId, signFrame, x25519Keypair } =
    await import(new URL("wire.ts", source).href);
  const file = path.join(stateDir, "yorozu", "live-activities.json");

  let current: { dispatch: Awaited<ReturnType<typeof owner.launch>["entered"]["promise"]>; run: ReturnType<typeof owner.launch>; steps: number } | undefined;
  function activityTurn(convId: string, change: { kind: "step"; steps: number } | { kind: "done" | "failed" | "gone" }) {
    if (convId !== CONV || !current) return emitActivityTurn(convId, change);
    if (change.kind === "step") {
      while (current.steps < change.steps) current.dispatch.replyOptions.onToolStart({ toolCallId: `wire-tool-${++current.steps}`, name: "read", phase: "start" });
      emitActivityTurn(convId, change);
    } else {
      if (change.kind === "done") current.dispatch.dispatcher.sendFinalReply({ text: "synthetic reply" });
      if (change.kind === "failed") current.run.fail(new Error("synthetic permanent failure"));
      else current.run.exit.resolve();
    }
  }
  async function fixture(t: TestContext, flags: { liveActivity?: boolean; activityTimestamp?: boolean }, state?: "corrupt" | "locked", setupFailure = false, wipedRoom = false) {
    await rm(file, { force: true });
    await rm(`${file}.lock`, { force: true });
    if (state) {
      await mkdir(path.dirname(file), { recursive: true });
      if (state === "corrupt") await writeFile(file, "{broken");
      else await writeFile(`${file}.lock`, JSON.stringify({ pid: process.pid, instance: "synthetic-other-host", startedAt: REQUESTED_AT_MS }));
    }
    stores.clear();
    const now = Date.now;
    Date.now = () => REQUESTED_AT_MS;
    let run: ReturnType<typeof owner.launch>;
    try { run = owner.launch({ convId: CONV, messageId: "99999999-9999-4999-8999-999999999999", text: "/wire-owner", ts: REQUESTED_AT_MS }); }
    finally { Date.now = now; }
    const dispatch = await run.entered.promise;
    current = { run, dispatch, steps: 0 };
    activityTurn(CONV, { kind: "step", steps: 1 });
    t.after(async () => { run.exit.resolve(); await run.done; current = undefined; });
    const signing = ed25519Keypair();
    const keys = { signing, static: x25519Keypair(), room: roomId(signing.publicKey) };
    const device = { signing: ed25519Keypair(), static: x25519Keypair() };
    const deviceKey = b64u(device.signing.publicKey);
    stores.set("devices", new Map([[deviceKey, {
      signingPub: deviceKey, staticPub: b64u(device.static.publicKey), pairedAt: REQUESTED_AT_MS,
    }]]));
    // Opt-in worker storage semantics; existing fixtures retain their original behaviour.
    const pairedRows = new Set<string>();
    const activityTokens = new Map<string, string>();
    const delivered: HostMessage[] = [];
    const connections: Connection[] = [];
    const failures: Error[] = [];
    const receipts: { timestamp: number; persisted: boolean }[] = [];
    const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
    let controller: AbortController | undefined;
    let running: Promise<void> | undefined;
    async function stop() {
      controller?.abort();
      await running;
      controller = undefined;
      running = undefined;
    }
    t.after(async () => {
      try {
        await stop();
      } finally {
        for (const connection of connections) connection.socket.terminate();
        await new Promise<void>((resolve, reject) => server.close((error?: Error) => error ? reject(error) : resolve()));
      }
    });
    server.on("error", (error: Error) => { failures.push(error); });
    server.on("connection", (socket: Socket) => {
      const connection: Connection = { socket, messages: [], frames: [] };
      connections.push(connection);
      socket.on("error", () => { failures.push(new Error("fake relay socket failed")); });
      socket.on("message", (raw) => {
        try {
          const message = JSON.parse(String(raw)) as HostMessage;
          connection.messages.push(message);
          if (message.type === "register") {
            socket.send(JSON.stringify({ type: "registered", ...flags }));
            socket.send(JSON.stringify({ type: "phones", count: 1 }));
          } else if (message.type === "devices" && wipedRoom) {
            for (const device of message.devices as string[]) pairedRows.add(device);
          } else if (message.type === "activityToken" && wipedRoom && message.device) {
            if (message.token === undefined) activityTokens.delete(message.device);
            else if (pairedRows.has(message.device)) activityTokens.set(message.device, message.token);
          } else if (message.type === "ping") socket.send(JSON.stringify({ type: "pong" }));
          else if (message.type === "frame") {
            connection.frames.push(...(message.frames?.map((frame) => frame.payload) ?? (message.payload ? [message.payload] : [])));
          } else if (message.type === "activityPush" && typeof message.timestamp === "number") {
            if (wipedRoom && message.device && activityTokens.has(message.device)) delivered.push(message);
            // Capture at arrival, before any later save could make the assertion pass.
            const data = existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : [];
            const rows = Array.isArray(data) ? data : data.records;
            receipts.push({ timestamp: message.timestamp, persisted: rows.some((row: { device: string; kLast: number }) =>
              row.device === deviceKey && row.kLast === message.timestamp) });
          }
        } catch {
          failures.push(new Error("fake relay could not process a host message"));
        }
      });
      socket.send(JSON.stringify({ type: "nonce", nonce: "synthetic-relay-challenge" }));
    });
    await until(() => server.address() || undefined, "loopback listener");
    const address = server.address();
    assert.ok(address && typeof address !== "string");
    assert.equal(address.address, "127.0.0.1");
    async function start() {
      const index = connections.length;
      controller = new AbortController();
      const task: Promise<void> = runRelayHost({
        relayUrl: `ws://127.0.0.1:${address.port}`, keys, signal: controller.signal,
        liveTurn: owner.conversation.liveTurn, mediaMaxBytes: 1024, onStatus: () => {}, onMessage: () => {}, onReaction: () => {},
      });
      running = task;
      // Observe failures without leaving a rejected promise unhandled during a wait.
      void task.catch(() => { failures.push(new Error("runRelayHost rejected")); });
      return registered(index);
    }
    async function registered(index: number) {
      const connection = await until(() => connections[index], "host connection");
      await until(() => connection.messages.some((m) => m.type === "devices") ? true : undefined, "registered host allowlist");
      return connection;
    }
    let seq = 0;
    async function connect(connection: Connection) {
      const ik = new NoiseIK("initiator", device.static, keys.static.publicKey, prologue(keys.room, device.signing.publicKey));
      const init = ik.writeMessage(Buffer.from(JSON.stringify({ ts: Date.now() })));
      function send(payload: string) {
        const id = ++seq;
        connection.socket.send(JSON.stringify({ type: "frame", payload, sig: signFrame(device.signing.privateKey, payload), seq: id }));
        return id;
      }
      send(encodeFrame({ type: "init", deviceSigningKey: device.signing.publicKey, message: init }));
      const response = decodeFrame(await until(() => connection.frames.shift(), "Noise IK response"));
      assert.ok(response?.type === "response", "host must answer the real Noise IK handshake");
      ik.readMessage(response.message);
      const session = ik.split(init.subarray(0, 8));
      const frame = decodeFrame(await until(() => connection.frames.shift(), "encrypted host peer_info"));
      assert.ok(frame?.type === "box");
      const plain = session.open(frame);
      assert.ok(plain, "device must decrypt host peer_info");
      const hello = parseEvent(plain);
      assert.ok(hello?.kind === "peer_info", "host peer_info must traverse Noise");
      async function event(event: Event) {
        const id = send(session.seal(encodeEvent(event)));
        await until(() => connection.messages.some((m) => m.type === "ack" && m.seq === id) ? true : undefined, "host dispatch acknowledgement");
      }
      await event({ kind: "peer_info", data: peer });
      return { peer: hello.data as PeerInfo, event };
    }
    if (setupFailure) {
      globalThis.__yorozuDirectFail = true;
      try {
        await assert.rejects(runRelayHost({
          relayUrl: `ws://127.0.0.1:${address.port}`, keys, signal: new AbortController().signal,
          directPort: 1, mediaMaxBytes: 1024, onStatus: () => {}, onMessage: () => {}, onReaction: () => {},
        }), { code: "EADDRINUSE" });
      } finally { globalThis.__yorozuDirectFail = false; }
    }
    const connection = await start();
    const phone = await connect(connection);
    const pushes = (c = connection) => c.messages.filter((m) => m.type === "activityPush");
    async function sendReport(seeded: boolean, p = phone, c = connection) {
      await p.event({ kind: "live_activity", data: report(seeded) });
      await until(() => c.messages.find((m) => m.type === "activityToken"), "activity token registration");
      const token = c.messages.find((m) => m.type === "activityToken")!;
      assert.ok(token.device === deviceKey && token.token === report(seeded).pushToken, "report registers the synthetic device's token");
      await delay(100);
      assert.equal(pushes(c).length, 0, "report alone sends no push");
    }
    async function turn(c = connection) {
      activityTurn(CONV, { kind: "step", steps: 2 });
      return until(() => pushes(c)[0], "bound turn activityPush");
    }
    return { pairedRows, activityTokens, delivered, ownerRun: run, ownerDispatch: dispatch, connection, phone, pushes, sendReport, turn, stop, start, connect, registered, receipts, failures, deviceKey };
  }

  for (const order of ["A", "B"] as const) {
    await t.test(`LA-2i M2-${order} [behaviour] activityGone permits same-generation token recovery across restart`, async (t) => {
      const f = await fixture(t, { liveActivity: true, activityTimestamp: true });
      await f.sendReport(true);
      const first = await f.turn();
      const rotated = { ...report(true), pushToken: "cd".repeat(32) };
      async function rotate() {
        await f.phone.event({ kind: "live_activity", data: rotated });
      }
      if (order === "B") {
        await rotate();
        assert.ok(f.connection.messages.some((m) => m.type === "activityToken" && m.token === rotated.pushToken), "T2 must reach relay before delayed T1 invalidation");
      }
      // Worker has already deleted T1 before emitting this notice. In B its notice
      // was queued before the host's T2 registration, then delivered afterwards.
      f.connection.socket.send(JSON.stringify({ type: "activityGone", device: f.deviceKey }));
      await f.phone.event({ kind: "device_list", data: {} }); // Noise/ack barrier after notice.
      await rotate();
      await delay(100);
      const row = JSON.parse(readFileSync(file, "utf8")).records[0];
      assert.equal(row.terminal, false, "activityGone is recoverable token invalidation, not revoke");
      assert.equal(row.kLast, first.timestamp, "token recovery must retain last reservation");
      const originalNow = Date.now;
      const nextTime = originalNow() + 15_000;
      Date.now = () => nextTime;
      try {
        activityTurn(CONV, { kind: "step", steps: 3 });
        await delay(200);
      } finally { Date.now = originalNow; }
      assert.equal(f.pushes().length, 2, "next in-session host change after recovery must push");
      assert.equal(f.pushes()[1].timestamp, first.timestamp! + 1);
      // Restart clears only throttle time; the same live owner and disk remain.
      await f.stop();
      const restarted = await f.start();
      activityTurn(CONV, { kind: "step", steps: 4 });
      await delay(200);
      assert.equal(f.pushes(restarted).length, 1, "next host change after recovery/restart must push");
      assert.equal(f.pushes(restarted)[0].timestamp, first.timestamp! + 2);
      await f.stop();
      const again = await f.start();
      activityTurn(CONV, { kind: "step", steps: 5 });
      await delay(200);
      assert.equal(f.pushes(again).length, 1, "second restart must keep recovered watch");
      const ks = [first.timestamp, f.pushes()[1].timestamp, ...f.pushes(restarted).map((m) => m.timestamp), ...f.pushes(again).map((m) => m.timestamp)];
      assert.deepEqual(ks, [first.timestamp, first.timestamp! + 1, first.timestamp! + 2, first.timestamp! + 3], "timestamps strictly increase across restarts; no k reused");
      assert.ok(f.receipts.every((r) => r.persisted));
    });
  }

  await t.test("LA-2i M2-revoke [behaviour] unpair retains five-field terminal tombstone", async (t) => {
    const f = await fixture(t, { liveActivity: true, activityTimestamp: true });
    await f.sendReport(true);
    const first = await f.turn();
    await f.phone.event({ kind: "device_patch", data: { id: f.deviceKey, removed: true } });
    await delay(100);
    assert.ok(f.connection.messages.some((m) => m.type === "revoke"), "unpair must revoke relay device");
    assert.deepEqual(JSON.parse(readFileSync(file, "utf8")).records, [{ device: f.deviceKey,
      activityId: report(true).activityId, requestedAtMs: REQUESTED_AT_MS, kLast: first.timestamp, terminal: true }]);
  });

  await t.test("LA-2i L2 [behaviour] wiped room restores token after devices announce", async (t) => {
    const f = await fixture(t, { liveActivity: true, activityTimestamp: true }, undefined, false, true);
    await f.sendReport(true);
    await f.turn();
    await f.stop();
    f.pairedRows.clear();
    f.activityTokens.clear();
    const restarted = await f.start(); // Restores real v3 file, no app re-report.
    assert.ok(f.pairedRows.has(f.deviceKey), "devices announce must rebuild p: rows");
    activityTurn(CONV, { kind: "step", steps: 3 });
    await delay(200);
    assert.equal(f.activityTokens.get(f.deviceKey), report(true).pushToken, "wiped relay must retain restored token after devices announce");
    assert.equal(f.delivered.filter((m) => restarted.messages.includes(m)).length, 1, "next Mode H push must be delivered by wiped relay");
  });

  await t.test("LA-2i L4 [design-todo] restored old token cannot overwrite rollback token", {
    todo: "relay protocol has no generation compare; needs design",
  }, async (t) => {
    const f = await fixture(t, { liveActivity: true, activityTimestamp: true }, undefined, false, true);
    await f.sendReport(true);
    await f.stop();
    const newToken = "ef".repeat(32);
    f.activityTokens.set(f.deviceKey, newToken);
    await f.start();
    assert.equal(f.activityTokens.get(f.deviceKey), newToken, "restored T_old must not overwrite relay T_new");
  });

  for (const flags of [{}, { liveActivity: true }, { liveActivity: true, activityTimestamp: true }, { activityTimestamp: true }]) {
    await t.test(`(a) peer_info truthfulness ${JSON.stringify(flags)}`, async (t) => {
      const f = await fixture(t, flags);
      assert.equal(f.phone.peer.capabilities.includes("liveActivityPush"), flags.liveActivity === true);
      assert.equal(f.phone.peer.capabilities.includes("liveActivityHostWriter"), false);
      assert.equal(f.failures.length, 0);
    });
  }

  for (const [name, flags] of [
    ["(b) old report, both relay flags", { liveActivity: true, activityTimestamp: true }],
    ["(c) old report, liveActivity only", { liveActivity: true }],
  ] as const) {
    await t.test(name, async (t) => {
      const f = await fixture(t, flags);
      await f.sendReport(false);
      const before = Date.now();
      const push = await f.turn();
      const after = Date.now();
      assert.equal(Object.hasOwn(push, "timestamp"), false);
      // A step has no time-dependent job fields; staleDate is bounded by the real clock.
      const data = report(false);
      const expected = plan(data.jobs, applyTurn(data.jobs, data.turns, CONV, { kind: "step", steps: 2 }, before), before);
      assert.ok(expected);
      const { staleDate, ...fields } = expected;
      const { device, ...body } = push;
      assert.ok(device === f.deviceKey, "push targets the paired synthetic device");
      assert.deepEqual(body, { type: "activityPush", ...fields, staleDate: push.staleDate });
      assert.ok(typeof push.staleDate === "number" && push.staleDate >= staleDate! && push.staleDate <= staleDate! + Math.ceil((after - before) / 1000));
      await delay(100);
      assert.equal(f.pushes().length, 1);
      assert.equal(f.failures.length, 0);
    });
  }

  await t.test("(d) new report reserves literal timestamp before sending", async (t) => {
    const f = await fixture(t, { liveActivity: true, activityTimestamp: true });
    await f.sendReport(true);
    const push = await f.turn();
    assert.equal(push.timestamp, 1_800_000_002); // ceil(1_800_000_000_500 / 1000) + 1
    assert.deepEqual(f.receipts, [{ timestamp: 1_800_000_002, persisted: true }]);
    assert.equal(f.failures.length, 0);
  });

  await t.test("(e) new report without activityTimestamp sends no push", async (t) => {
    const f = await fixture(t, { liveActivity: true });
    await f.sendReport(true);
    activityTurn(CONV, { kind: "step", steps: 2 });
    await delay(150);
    assert.equal(f.pushes().length, 0);
    assert.equal(f.failures.length, 0);
  });

  await t.test("(f) real reconnect replays token before any push", { timeout: 10_000 }, async (t) => {
    const f = await fixture(t, { liveActivity: true, activityTimestamp: true });
    await f.sendReport(true);
    await f.turn();
    f.connection.socket.close();
    // Production backoff starts at roughly 1 s; keep real time and allow 5 s to reconnect.
    const reconnected = await f.registered(1);
    const first = reconnected.messages[2];
    assert.equal(reconnected.messages[0]?.type, "register");
    // Real relay (apps/relay/src/worker.ts registerActivity) ignores activityToken without a p: row;
    // only the devices announce restores that row in a wiped room.
    assert.equal(reconnected.messages[1]?.type, "devices");
    assert.ok(first?.type === "activityToken" && first.device === f.deviceKey && first.token === report(true).pushToken,
      "the first message after devices must replay the token");
    const phone = await f.connect(reconnected);
    await phone.event({ kind: "device_list", data: {} });
    activityTurn(CONV, { kind: "done" }); // urgent: exercises replay ordering without a 15 s throttle wait
    const push = await until(() => f.pushes(reconnected)[0], "post-reconnect push");
    assert.equal(push.timestamp, 1_800_000_003);
    assert.equal(f.failures.length, 0);
  });

  await t.test("(g) new host resumes persisted timestamp after device re-report", async (t) => {
    const f = await fixture(t, { liveActivity: true, activityTimestamp: true });
    await f.sendReport(true);
    await f.turn();
    await f.stop();
    const restarted = await f.start(); // New runRelayHost, same synthetic keys/store/state dir.
    const phone = await f.connect(restarted);
    await f.sendReport(true, phone, restarted);
    // Mode H row ownership decision (Yorozu, 2026-11-08): restored host already owns steps 2.
    activityTurn(CONV, { kind: "step", steps: 3 });
    const push = await until(() => f.pushes(restarted)[0], "bound turn activityPush");
    assert.equal(push.timestamp, 1_800_000_003); // last sent (1_800_000_002) + 1, not the report seed + 1
    assert.ok(f.receipts.every((receipt) => receipt.persisted), "every timestamp must already be durable on arrival");
    assert.equal(f.failures.length, 0);
  });

  await t.test("(h) same-activity rotation through relay keeps k", async (t) => {
    const f = await fixture(t, { liveActivity: true, activityTimestamp: true });
    await f.sendReport(true);
    assert.equal((await f.turn()).timestamp, 1_800_000_002);
    const initial = report(true);
    await f.phone.event({ kind: "live_activity", data: {
      ...initial, pushToken: "cd".repeat(32), jobs: [{ ...initial.jobs[0]!, steps: 2 }],
    } });
    await until(() => f.connection.messages.find((m) => m.type === "activityToken" && m.token === "cd".repeat(32)), "rotated token registration");
    activityTurn(CONV, { kind: "done" });
    const push = await until(() => f.pushes()[1], "rotated activity end");
    assert.equal(push.timestamp, 1_800_000_003);
    assert.ok(f.receipts.every((receipt) => receipt.persisted));
    assert.equal(f.failures.length, 0);
  });

  for (const state of ["corrupt", "locked"] as const) {
    await t.test(`(i) ${state} state refuses seeded pushes and never advertises host writer`, async (t) => {
      const f = await fixture(t, { liveActivity: true, activityTimestamp: true }, state);
      assert.equal(f.phone.peer.capabilities.includes("liveActivityHostWriter"), false);
      await f.sendReport(true);
      activityTurn(CONV, { kind: "step", steps: 2 });
      activityTurn(CONV, { kind: "done" });
      await delay(150);
      assert.equal(f.pushes().length, 0);
      if (state === "corrupt") assert.equal(readFileSync(file, "utf8"), "{broken");
      assert.equal(f.failures.length, 0);
    });
  }
  const flags = { liveActivity: true, activityTimestamp: true };
  const steppedReport = (): ActivityReport => ({ ...report(true), jobs: [{ ...report(true).jobs[0]!, steps: 2 }] });
  async function endOnce(f: Awaited<ReturnType<typeof fixture>>, connection: Connection, timestamp: number) {
    const before = f.pushes(connection).length;
    activityTurn(CONV, { kind: "done" });
    await delay(200); // Bounded observation, followed by a count assertion (not a timeout failure).
    assert.equal(f.pushes(connection).length, before + 1, "exactly one post-restart activityPush");
    const push = f.pushes(connection)[before]!;
    assert.equal(push.timestamp, timestamp);
    return push;
  }
  function replay(f: Awaited<ReturnType<typeof fixture>>, connection: Connection, token: string) {
    assert.equal(connection.messages[0]?.type, "register");
    // Real relay registerActivity ignores a device without a p: row; the devices announce restores it.
    assert.equal(connection.messages[1]?.type, "devices");
    assert.deepEqual(connection.messages[2], { type: "activityToken", device: f.deviceKey, token });
    assert.deepEqual(connection.messages.filter((m) => m.type === "activityToken"),
      [{ type: "activityToken", device: f.deviceKey, token }]);
  }

  await t.test("(j) restart without re-report updates the existing row", async (t) => {
    const f = await fixture(t, flags);
    await f.sendReport(true);
    assert.equal((await f.turn()).timestamp, 1_800_000_002);
    // Device last reported the step snapshot; restart must retain both it and the binding.
    await f.phone.event({ kind: "live_activity", data: steppedReport() });
    await f.stop();
    const restarted = await f.start(); // Device deliberately never reconnects.
    replay(f, restarted, "abababababababababababababababababababababababababababababababab");
    const originalNow = Date.now;
    const now = 1_800_000_001_000;
    Date.now = () => now;
    try {
      const push = await endOnce(f, restarted, 1_800_000_003);
      assert.equal(push.event, "end");
      const { device, type, timestamp, ...body } = push;
      assert.equal(device, f.deviceKey);
      assert.equal(type, "activityPush");
      const data = steppedReport();
      assert.deepEqual(body, plan(data.jobs, applyTurn(data.jobs, data.turns, CONV, { kind: "done" }, now), now));
      assert.equal((push.state as { jobs: unknown[] }).jobs.length, 1);
    } finally { Date.now = originalNow; }
  });

  // Characterization: pending reports revoke transport until a token-bearing report arrives.
  await t.test("(k) pending restart has no token replay or push", async (t) => {
    const f = await fixture(t, flags);
    await f.sendReport(true);
    await f.turn();
    await f.phone.event({ kind: "live_activity", data: { ...steppedReport(), pushToken: undefined } });
    await f.stop();
    const restarted = await f.start();
    activityTurn(CONV, { kind: "done" });
    await delay(200);
    assert.equal(restarted.messages.filter((m) => m.type === "activityToken").length, 0);
    assert.equal(f.pushes(restarted).length, 0);
  });

  await t.test("(l) terminal restart retains only a redacted tombstone", async (t) => {
    const f = await fixture(t, flags);
    await f.sendReport(true);
    assert.equal((await endOnce(f, f.connection, 1_800_000_002)).event, "end");
    await f.stop();
    const records = JSON.parse(readFileSync(file, "utf8")).records;
    // LA-2h generation ordering: terminal records retain their requested generation.
    assert.deepEqual(records, [{ device: f.deviceKey, activityId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
      requestedAtMs: REQUESTED_AT_MS, kLast: 1_800_000_002, terminal: true }]);
    assert.deepEqual(Object.keys(records[0]).sort(), ["activityId", "device", "kLast", "requestedAtMs", "terminal"]);
    const bytes = readFileSync(file, "utf8");
    assert.equal(bytes.includes("token"), false);
    assert.equal(bytes.includes("rows"), false);
    assert.equal(bytes.includes("jobs"), false);
    const restarted = await f.start();
    activityTurn(CONV, { kind: "done" });
    await delay(200);
    assert.equal(restarted.messages.filter((m) => m.type === "activityToken").length, 0);
    assert.equal(f.pushes(restarted).length, 0);
  });

  await t.test("(m) rotation then restart replays only the new token and advances k", async (t) => {
    const f = await fixture(t, flags);
    await f.sendReport(true);
    assert.equal((await f.turn()).timestamp, 1_800_000_002);
    await f.phone.event({ kind: "live_activity", data: { ...steppedReport(), pushToken: "cd".repeat(32) } });
    await f.stop();
    const restarted = await f.start();
    replay(f, restarted, "cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd");
    assert.equal((await endOnce(f, restarted, 1_800_000_003)).event, "end");
  });

  await t.test("(n) same-token re-report after restart keeps k and one job row", async (t) => {
    const f = await fixture(t, flags);
    await f.sendReport(true);
    await f.turn();
    await f.stop();
    const restarted = await f.start();
    const phone = await f.connect(restarted);
    await phone.event({ kind: "live_activity", data: { ...steppedReport(), requestedAtMs: 1_799_999_000_000 } });
    const push = await endOnce(f, restarted, 1_800_000_003);
    const jobs = (push.state as { jobs: { token: string; steps: number }[] }).jobs;
    assert.equal(jobs.length, 1);
    assert.equal(jobs[0]!.token, "AAAAAAAAAAAAAAAA");
    assert.equal(jobs[0]!.steps, 2);
  });

  await t.test("(o) held report row survives restart", async (t) => {
    const f = await fixture(t, flags);
    await f.sendReport(true);
    assert.equal((await f.turn()).timestamp, 1_800_000_002);
    // A completed second row changes the report at priority 5; done on CONV then urgently ends both.
    await f.phone.event({ kind: "live_activity", data: { ...steppedReport(), jobs: [
      ...steppedReport().jobs,
      { token: "BBBBBBBBBBBBBBBB", kind: "transcribing", state: "done", startedAt: Date.now(), finishedAt: Date.now() },
    ] } });
    await delay(100);
    assert.equal(f.pushes().length, 1, "report change remains held by throttle");
    await f.stop();
    const restarted = await f.start();
    // LA-2g round 1 rule 3: relayRegistered sends the held change at the next allowed opportunity.
    const update = await until(() => f.pushes(restarted)[0], "post-restart held report update");
    activityTurn(CONV, { kind: "done" });
    const end = await until(() => f.pushes(restarted)[1], "post-restart end");
    await delay(200);
    assert.deepEqual(f.pushes(restarted).map((push) => [push.event, push.timestamp]),
      [["update", 1_800_000_003], ["end", 1_800_000_004]]);
    const jobs = (update.state as { jobs: { token: string; state: string }[] }).jobs;
    assert.deepEqual(jobs.map((row) => row.token).sort(), ["AAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBB"]);
    assert.equal(jobs.find((row) => row.token === "BBBBBBBBBBBBBBBB")!.state, "done");
    assert.deepEqual((end.state as { jobs: { token: string }[] }).jobs.map((row) => row.token).sort(),
      ["AAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBB"]);
  });

  await t.test("(p) setup failure releases the lock for another host in the same process", async (t) => {
    const f = await fixture(t, flags, undefined, true);
    await f.sendReport(true);
    activityTurn(CONV, { kind: "step", steps: 2 });
    await delay(200);
    assert.equal(f.pushes().length, 1, "new host must reacquire the lock after EADDRINUSE");
    assert.equal(f.pushes()[0]!.timestamp, 1_800_000_002);
  });

  await t.test("(s) stale device report after host restart preserves host rows in the next needsYou push", async (t) => {
    const f = await fixture(t, { liveActivity: true, activityTimestamp: true });
    await f.sendReport(true);
    const first = await f.turn();
    assert.equal(first.timestamp, 1_800_000_002);
    assert.deepEqual(first.state, { jobs: [
      { token: JOB, kind: "turn", state: "running", steps: 2, startedAt: 821692800.5 },
    ] });
    await f.stop();
    const restarted = await f.start();
    await until(() => restarted.messages.find((m) => m.type === "activityToken"), "durable token replay without a device");
    assert.deepEqual(restarted.messages.filter((m) => m.type === "activityToken"), [
      { type: "activityToken", device: f.deviceKey, token: "ab".repeat(32) },
    ]);
    assert.deepEqual(f.pushes(restarted), []);
    const phone = await f.connect(restarted);
    await f.sendReport(true, phone, restarted); // Original steps-1 snapshot, through real Noise.
    assert.deepEqual(f.pushes(restarted), [], "stale report must not push host steps backwards");
    await phone.event({ kind: "live_activity", data: {
      ...report(true), jobs: [...report(true).jobs,
        { token: "NNNNNNNNNNNNNNNN", kind: "needsYou", state: "running", startedAt: REQUESTED_AT_MS }],
    } });
    const next = await until(() => f.pushes(restarted)[0], "needsYou full snapshot");
    await delay(100);
    assert.equal(f.pushes(restarted).length, 1);
    assert.equal(next.timestamp, 1_800_000_003);
    const state = next.state as { jobs: { token: string }[] };
    assert.deepEqual(state.jobs.toSorted((a, b) => a.token.localeCompare(b.token)), [
      { token: JOB, kind: "turn", state: "running", steps: 2, startedAt: 821692800.5 },
      { token: "NNNNNNNNNNNNNNNN", kind: "needsYou", state: "running", startedAt: 821692800.5 },
    ]);
    assert.deepEqual(f.receipts, [
      { timestamp: 1_800_000_002, persisted: true },
      { timestamp: 1_800_000_003, persisted: true },
    ]);
    assert.deepEqual(f.failures, []);
  });

  // red: behavioural
  await t.test("(t) relay closed terminal survives host restart and device re-report", async (t) => {
    const f = await fixture(t, flags);
    await f.sendReport(true);
    await f.turn();
    // Recording keeps the activity non-terminal so its ended-token set stays inspectable.
    const recording = { token: "RRRRRRRRRRRRRRRR", kind: "recording", state: "running", startedAt: REQUESTED_AT_MS } as const;
    await f.phone.event({ kind: "live_activity", data: { ...report(true), jobs: [...report(true).jobs, recording] } });
    const closed = new Promise<void>((resolve) => f.connection.socket.on("close", () => resolve()));
    f.connection.socket.close();
    await closed;
    activityTurn(CONV, { kind: "done" });
    await f.ownerRun.done;
    await f.stop();
    const saved = JSON.parse(readFileSync(file, "utf8")).records[0];
    assert.ok((saved.ended ?? []).includes(JOB));
    assert.ok(!saved.rows.some((r: { token: string; state: string }) => r.token === JOB && r.state === "running"));
    const restarted = await f.start();
    const phone = await f.connect(restarted);
    await phone.event({ kind: "live_activity", data: { ...report(true), jobs: [...report(true).jobs, recording] } });
    await f.stop(); // Drain persistence and queued sends without adding observation timers.
    assert.ok(f.pushes(restarted).every((p) => !(p.state as { jobs: { token: string; state: string }[] }).jobs.some((r) => r.token === JOB && r.state === "running")));
    assert.ok((JSON.parse(readFileSync(file, "utf8")).records[0].ended ?? []).includes(JOB));
  });

  // red: behavioural
  await t.test("(u) Noise report steps 999 yields owner steps 2", async (t) => {
    const f = await fixture(t, flags);
    activityTurn(CONV, { kind: "step", steps: 2 });
    await f.phone.event({ kind: "live_activity", data: { ...report(true), jobs: [{ ...report(true).jobs[0]!, steps: 999 }] } });
    await f.phone.event({ kind: "live_activity", data: { ...report(true), jobs: [
      { ...report(true).jobs[0]!, steps: 999 },
      { token: "NNNNNNNNNNNNNNNN", kind: "needsYou", state: "running", startedAt: REQUESTED_AT_MS },
    ] } });
    const push = await until(() => f.pushes()[0], "owner snapshot through Noise");
    assert.equal((push.state as { jobs: { token: string; steps: number }[] }).jobs.find((r) => r.token === JOB)!.steps, 2);
  });

  // red: behavioural
  await t.test("(v) 65 ended tokens re-listed over Noise never resurrect", async (t) => {
    const f = await fixture(t, flags);
    const recording = { token: "RRRRRRRRRRRRRRRR", kind: "recording", state: "running", startedAt: REQUESTED_AT_MS } as const;
    // Real owner is absent for each synthetic conversation: admission must tombstone it.
    for (let i = 0; i < 65; i++) {
      const token = i.toString(16).padStart(16, "0");
      const conv = i.toString(16).padStart(8, "0") + "-0000-4000-8000-000000000000";
      await f.phone.event({ kind: "live_activity", data: { ...report(true), jobs: [recording, { ...report(true).jobs[0]!, token }], turns: { [token]: conv } } });
    }
    await f.phone.event({ kind: "live_activity", data: { ...report(true), jobs: [recording, { ...report(true).jobs[0]!, token: "0000000000000000", steps: 7 }], turns: { "0000000000000000": "00000000-0000-4000-8000-000000000000" } } });
    await f.stop();
    const saved = JSON.parse(readFileSync(file, "utf8")).records[0];
    assert.ok((saved.ended ?? []).includes("0000000000000000"));
    assert.ok(!saved.rows.some((r: { token: string }) => r.token === "0000000000000000"));
    assert.equal(Object.hasOwn(saved.bindings, "0000000000000000"), false);
    assert.ok(f.pushes().every((p) => !(p.state as { jobs: { kind: string }[] }).jobs.some((r) => r.kind === "turn")));
  });

  // red: API-adapted (liveTurn option). Same legacy scenario as (b), runtime behavior unchanged.
  await t.test("(w) legacy wire step push remains unchanged with liveTurn", async (t) => {
    const f = await fixture(t, flags);
    await f.sendReport(false);
    const push = await f.turn();
    assert.equal(Object.hasOwn(push, "timestamp"), false);
    assert.deepEqual(push.state, { jobs: [{ token: JOB, kind: "turn", state: "running", steps: 2, startedAt: 821692800.5 }] });
    assert.equal(push.event, "update");
    assert.equal(push.priority, 5);
    assert.equal(f.pushes().length, 1);
  });

  await t.test("(x) generation ordering survives A2 end and real host restart over Noise", async (t) => {
    const f = await fixture(t, flags);
    const a1 = report(true);
    const a2 = { ...a1, activityId: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
      requestedAtMs: REQUESTED_AT_MS + 60_000, pushToken: "cd".repeat(32) };
    await f.sendReport(true);
    await f.phone.event({ kind: "live_activity", data: a2 });
    await until(() => f.connection.messages.find((m) => m.type === "activityToken" && m.token === a2.pushToken), "A2 token registration");
    const afterA2 = f.connection.messages.length;
    const end = await endOnce(f, f.connection, 1_800_000_062);
    assert.equal(end.event, "end");
    await f.stop();
    const bytes = readFileSync(file, "utf8");
    const restarted = await f.start(); // Same state directory, new runRelayHost and Noise session.
    const phone = await f.connect(restarted);
    await phone.event({ kind: "live_activity", data: a1 });
    await phone.event({ kind: "live_activity", data: a2 });
    await delay(200); // Dispatch ack precedes async disk saves; bound observation then assertions.
    const afterEnd = [...f.connection.messages.slice(f.connection.messages.indexOf(end) + 1), ...restarted.messages];
    assert.ok(afterEnd.every((m) => m.type !== "activityPush" || (typeof m.timestamp === "number" && m.timestamp > end.timestamp!)),
      "(x) no activityPush may reuse a timestamp at or below A2 end after restart");
    assert.deepEqual([...f.connection.messages.slice(afterA2), ...afterEnd].filter((m) => m.type === "activityToken" && m.token === a1.pushToken), [],
      "(x) no A1 activityToken after A2 registration");
    assert.equal(readFileSync(file, "utf8"), bytes, "(x) stale A1 and ended A2 leave persisted bytes unchanged");
    const data = JSON.parse(readFileSync(file, "utf8"));
    assert.equal(data.v, 3);
    assert.deepEqual(data.records, [{ device: f.deviceKey, activityId: a2.activityId,
      requestedAtMs: a2.requestedAtMs, kLast: 1_800_000_062, terminal: true }]);
    assert.deepEqual(Object.keys(data.records[0]).sort(), ["activityId", "device", "kLast", "requestedAtMs", "terminal"]);
    assert.ok(f.receipts.every((receipt) => receipt.persisted));
    assert.deepEqual(f.failures, []);
  });

  await t.test("(r) SDK lock diagnostics through real ActivityStore and ActivityWatch", async (t) => {
    const { ActivityStore } = await import(new URL("activitystore.ts", source).href);
    const { ActivityWatch } = await import(new URL("activitywatch.ts", source).href);
    const { acquireFileLock } = await import(sdkPrefix + "file-lock");
    const { spawn } = await import("node:child_process");
    const { once } = await import("node:events");
    async function lockFixture(t: TestContext) {
      const dir = await mkdtemp(path.join(root, "sdk-lock-"));
      const file = path.join(dir, "activities.json");
      const watches: InstanceType<typeof ActivityWatch>[] = [];
      t.after(async () => { for (const watch of watches) await watch.stop(); await rm(dir, { recursive: true, force: true }); });
      async function start() {
        const sent: HostMessage[] = [];
        const warnings: string[] = [];
        const owners = new Map<string, { steps: number; startedAt: number }>();
        const watch = new ActivityWatch({ store: new ActivityStore(file, acquireFileLock),
          warn: (warning: string) => warnings.push(warning), send: (raw: string) => sent.push(JSON.parse(raw)),
          liveTurn: (convId: string) => owners.get(convId), now: () => REQUESTED_AT_MS, setTimer: () => 0, clearTimer: () => {} });
        watches.push(watch);
        await watch.start();
        await watch.relayRegistered(flags);
        return { watch, sent, warnings, owners };
      }
      return { file, start };
    }
    async function seeded(f: Awaited<ReturnType<Awaited<ReturnType<typeof lockFixture>>["start"]>>, available: boolean) {
      f.owners.set(CONV, { steps: 1, startedAt: REQUESTED_AT_MS });
      f.watch.report("deviceSyntheticLock", report(true));
      f.owners.delete(CONV);
      f.watch.turn(CONV, { kind: "done" });
      await delay(200);
      assert.equal(f.watch.hostWriterReady, available);
      const pushes = f.sent.filter((m) => m.type === "activityPush");
      assert.equal(pushes.length, available ? 1 : 0);
      if (available) assert.equal(pushes[0]!.timestamp, 1_800_000_002);
    }
    await t.test("corrupt lock is unreadable, preserved byte-for-byte, and blocks pushes", async (t) => {
      const f = await lockFixture(t);
      await writeFile(`${f.file}.lock`, "{");
      const watch = await f.start();
      await seeded(watch, false);
      assert.match(watch.warnings.join("\n"), /lock/i);
      assert.match(watch.warnings.join("\n"), /unreadable/i);
      assert.equal(readFileSync(`${f.file}.lock`, "utf8"), "{");
    });
    await t.test("PID reuse is reclaimed and seeded push works", async (t) => {
      const f = await lockFixture(t);
      await writeFile(`${f.file}.lock`, JSON.stringify({ pid: 1, createdAt: Date.now(), starttime: 12345 }));
      await seeded(await f.start(), true);
    });
    await t.test("stuck takeover guard with a dead owner permits acquisition", async (t) => {
      const f = await lockFixture(t);
      // Derive a definitely dead PID from a child whose exit has been observed.
      const child = spawn(process.execPath, ["-e", ""], { stdio: "ignore" });
      await once(child, "exit");
      await writeFile(`${f.file}.lock`, JSON.stringify({ pid: child.pid, createdAt: Date.now(), starttime: 12345 }));
      await writeFile(`${f.file}.lock.takeover`, "");
      await seeded(await f.start(), true);
    });
    await t.test("live child owns lock regardless of age; death allows retry", async (t) => {
      const f = await lockFixture(t);
      const moduleURL = pathToFileURL(path.join(sdk!, "dist/plugin-sdk/file-lock.js")).href;
      const child = spawn(process.execPath, ["--input-type=module", "-e", `
        import { acquireFileLock } from ${JSON.stringify(moduleURL)};
        await acquireFileLock(${JSON.stringify(f.file)}, {stale:30000,
          retries:{retries:0,factor:1,minTimeout:10,maxTimeout:10}, staleRecovery:"remove-if-definitely-stale"});
        console.log("held");
        setInterval(() => {}, 1000);
      `], { stdio: ["ignore", "pipe", "pipe"] });
      const exited = once(child, "exit");
      t.after(async () => { if (child.exitCode === null && child.signalCode === null) child.kill("SIGKILL"); await exited; });
      let stdout = "";
      let stderr = "";
      child.stdout.on("data", (bytes) => { stdout += bytes; });
      child.stderr.on("data", (bytes) => { stderr += bytes; });
      await until(() => stdout.includes("held") ? true : undefined, "SDK child held lock");
      assert.equal(stderr, "");
      const first = await f.start();
      await seeded(first, false);
      assert.match(first.warnings.join("\n"), /another live host.*holds/i);
      await first.watch.stop();
      const lock = JSON.parse(readFileSync(`${f.file}.lock`, "utf8"));
      await writeFile(`${f.file}.lock`, JSON.stringify({ ...lock, createdAt: Date.now() - 3_600_000 }));
      const old = await f.start();
      await seeded(old, false);
      assert.match(old.warnings.join("\n"), /another live host.*holds/i);
      child.kill("SIGKILL");
      await exited;
      await old.watch.relayRegistered(flags);
      await seeded(old, true);
    });
  });

});

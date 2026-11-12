import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { registerHooks } from "node:module";
import os from "node:os";
import path from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { test } from "node:test";
import { fileURLToPath, pathToFileURL } from "node:url";
import { ownerRuntime } from "./conversation-owner-fixture.ts";
import { testFileLock } from "./activity-lock.ts";
const sdk = process.env.YOROZU_OPENCLAW_SDK;
const sdkPrefix = "openclaw/plugin-sdk/";
const skip = !sdk ? "set YOROZU_OPENCLAW_SDK to an installed OpenClaw package root"
  : !existsSync(path.join(sdk, "dist/plugin-sdk/websocket-runtime.js")) ? "YOROZU_OPENCLAW_SDK has no dist/plugin-sdk/websocket-runtime.js" : false;
const source = process.env.YOROZU_PLUGIN_SRC
  ? pathToFileURL(path.resolve(path.dirname(fileURLToPath(import.meta.url)), process.env.YOROZU_PLUGIN_SRC) + path.sep)
  : new URL("../src/", import.meta.url);
declare global { var __la2iAcquire: ((file: string, options: unknown) => Promise<{ release(): Promise<void> }>) | undefined; }

test("LA-2i L1 [behaviour] registration remains usable during store retry", { skip, timeout: 15_000 }, async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "yorozu-registration-"));
  const previous = { HOME: process.env.HOME, OPENCLAW_STATE_DIR: process.env.OPENCLAW_STATE_DIR };
  process.env.HOME = root;
  process.env.OPENCLAW_STATE_DIR = root;
  t.after(async () => {
    delete globalThis.__la2iAcquire;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    await rm(root, { recursive: true, force: true });
  });
  const stub = (code: string) => `data:text/javascript,${encodeURIComponent(code)}`;
  const networkStubs: Record<string, string> = {
    "./direct.js": stub("export const bindAddresses=()=>[]; export const serveDirect=async()=>({listening:false,close:async()=>{}});"),
    "./hints.js": stub("export const watchDirect=async()=>async()=>{};"),
    "./bonjour.js": stub("export const serveBonjour=async()=>({update:async()=>{},close:async()=>{}});"),
  };
  const hooks = registerHooks({ resolve(specifier, context, next) {
    if (context.parentURL === new URL("relay.ts", source).href && networkStubs[specifier]) return { url: networkStubs[specifier], shortCircuit: true };
    if (specifier === sdkPrefix + "file-lock") return { url: stub("export const acquireFileLock=(...args)=>globalThis.__la2iAcquire(...args);"), shortCircuit: true };
    if (specifier.startsWith(sdkPrefix)) return next(pathToFileURL(path.join(sdk!, "dist/plugin-sdk", `${specifier.slice(sdkPrefix.length)}.js`)).href, context);
    if (specifier.startsWith(".") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  } });
  t.after(() => hooks.deregister());
  const { resolveStateDir } = await import(sdkPrefix + "state-paths");
  const { WebSocketServer } = await import(sdkPrefix + "websocket-runtime");
  const owner = await ownerRuntime(source);
  t.after(() => owner.close());
  const { runRelayHost, beginPairing, notifyReply } = await import(new URL("relay.ts", source).href);
  const { b64u, ed25519Keypair, x25519Keypair, roomId } = await import(new URL("wire.ts", source).href);
  const file = path.join(resolveStateDir(), "yorozu", "live-activities.json");
  await mkdir(path.dirname(file), { recursive: true });
  for (const mode of ["held", "throws", "reconnect", "stop"] as const) {
    const name = mode === "reconnect" || mode === "stop"
      ? `LA-2i L1/L2-${mode} [behaviour] held restore cannot revive stale registration or leak lock`
      : `LA-2i L1-${mode} [behaviour] lock retry cannot block devices status mint notify`;
    await t.test(name, async (t) => {

      const lock = await testFileLock(file, {});
      t.after(() => lock.release());
      const lifecycle = mode === "reconnect" || mode === "stop";
      const { ActivityWatch } = await import(new URL("activitywatch.ts", source).href);
      let watch: InstanceType<typeof ActivityWatch> | undefined;
      const originalStart = ActivityWatch.prototype.start;
      ActivityWatch.prototype.start = function () { watch = this; return originalStart.call(this); };
      t.after(() => { ActivityWatch.prototype.start = originalStart; });
      let calls = 0;
      let inFlight = 0;
      let maxInFlight = 0;

      let unblock: (() => void) | undefined;
      const gate = new Promise<void>((resolve) => { unblock = resolve; });
      globalThis.__la2iAcquire = async (target, options) => {
        if (++calls === 1) return testFileLock(target, options);
        inFlight++;
        maxInFlight = Math.max(maxInFlight, inFlight);
        try {
          if (mode !== "throws") await gate;
          if (lifecycle) { await lock.release(); return await testFileLock(target, options); }
        } finally { inFlight--; }

        throw Object.assign(new Error("synthetic retry I/O failure"), { code: "EIO" });
      };
      const signing = ed25519Keypair();
      const keys = { signing, static: x25519Keypair(), room: roomId(signing.publicKey) };
      const deviceKey = b64u(ed25519Keypair().publicKey);
      owner.stores.set("devices", new Map([[deviceKey, { signingPub: deviceKey, staticPub: b64u(x25519Keypair().publicKey), pairedAt: Date.now() }]]));
      if (lifecycle) await writeFile(file, JSON.stringify({ v: 3, records: [{ device: deviceKey,
        activityId: "11111111-1111-4111-8111-111111111111", requestedAtMs: 1_800_000_000_500,
        kLast: 1_800_000_001, terminal: false, token: "ab".repeat(32), rows: [], sent: [], bindings: {} }] }));
      const messages: { type: string }[] = [];
      const connections: { socket: any; messages: { type: string }[] }[] = [];

      const statuses: { connected?: boolean }[] = [];
      const sockets = new Set<{ terminate(): void }>();
      const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
      let stopHost = async () => {};
      t.after(async () => {
        await stopHost();
        for (const socket of sockets) socket.terminate();
        await new Promise<void>((resolve) => server.close(() => resolve()));
      });
      await new Promise<void>((resolve, reject) => { server.once("listening", resolve); server.once("error", reject); });
      server.on("connection", (socket: any) => {
        sockets.add(socket);
        const connection = { socket, messages: [] as { type: string }[] };
        connections.push(connection);
        socket.on("message", (raw: unknown) => {
          const msg = JSON.parse(String(raw));
          messages.push(msg);
          connection.messages.push(msg);
          if (msg.type === "register") socket.send(JSON.stringify({ type: "registered", liveActivity: true, activityTimestamp: true }));
          if (msg.type === "mint") socket.send(JSON.stringify({ type: "token", token: "synthetic-pair-token", expiresAt: Date.now() + 60_000 }));
          if (msg.type === "ping") socket.send(JSON.stringify({ type: "pong" }));
        });
        socket.send(JSON.stringify({ type: "nonce", nonce: "synthetic-challenge" }));
      });
      const address = server.address();
      assert.ok(address && typeof address !== "string");
      const controller = new AbortController();
      const running = runRelayHost({ relayUrl: `ws://127.0.0.1:${address.port}`, keys, signal: controller.signal,
        mediaMaxBytes: 1024, onStatus: (status: { connected?: boolean }) => statuses.push(status), onMessage: () => {}, onReaction: () => {} });
      void running.catch(() => {});
      stopHost = async () => {
        unblock?.();
        controller.abort();
        await running;
      };
      const deadline = Date.now() + 1_000;
      while (calls < 2 && Date.now() < deadline) await delay(10);
      assert.equal(calls, 2, "registered must enter lock retry");
      let minted = false;
      const mint = beginPairing().then(() => { minted = true; }, () => {});
      const notify = notifyReply("11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222", "synthetic reply");
      await delay(300);
      assert.deepEqual({ devices: messages.some((m) => m.type === "devices"), connected: statuses.some((s) => s.connected === true),
        mint: minted && messages.some((m) => m.type === "mint"), notify: messages.some((m) => m.type === "notify") },
      { devices: true, connected: true, mint: true, notify: true }, "registration must expose devices, connected status, mint and notify within bound despite store retry");
      await Promise.all([mint, notify]);
      if (!lifecycle) return;
      const errors: unknown[] = [];
      const unhandled = (error: unknown) => errors.push(error);
      process.on("unhandledRejection", unhandled);
      t.after(() => { process.off("unhandledRejection", unhandled); });
      const closed = connections[0]!;
      assert.equal(watch!.hostWriterReady, false);
      if (mode === "reconnect") {
        closed.socket.close();
        const deadline = Date.now() + 5_000;
        while (!connections[1]?.messages.some((m) => m.type === "devices") && Date.now() < deadline) await delay(10);
        assert.ok(connections[1]?.messages.some((m) => m.type === "devices"), "new registration announces devices while restore held");
        assert.equal(calls, 2, "reconnect shares held restore instead of acquiring twice");
        assert.equal(maxInFlight, 1);
        assert.equal(watch!.hostWriterReady, false, "old registration never becomes ready while held");
        unblock!();
        const replayDeadline = Date.now() + 1_000;
        while (!connections[1]!.messages.some((m) => m.type === "activityToken") && Date.now() < replayDeadline) await delay(10);
        const fresh = connections[1]!.messages;
        assert.ok(fresh.findIndex((m) => m.type === "activityToken") > fresh.findIndex((m) => m.type === "devices"));
        assert.equal(watch!.hostWriterReady, true);
        assert.equal(fresh.filter((m) => m.type === "activityToken").length, 1, "only current registration replays");
      } else {
        controller.abort();
        // Let socket close and stop enter before the acquire completes.
        await delay(100);
        const count = messages.length;
        unblock!();
        await running;
        assert.equal(messages.length, count, "nothing sent after stop");
        assert.equal(watch!.hostWriterReady, false);
        const probe = await testFileLock(file, {});
        await probe.release();
      }
      assert.deepEqual(closed.messages.filter((m) => m.type === "activityToken" || m.type === "activityPush"), [], "stale registration never replays onto closed socket");
      await delay(10);
      assert.deepEqual(errors, [], "restore/stop must not leak unhandled rejections");

    });
  }
});

test("LA-2i L5 [behaviour] legacy report and step push during held seeded restore (main parity)", { skip, timeout: 90_000 }, async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "yorozu-registration-legacy-"));
  const previous = { HOME: process.env.HOME, OPENCLAW_STATE_DIR: process.env.OPENCLAW_STATE_DIR };
  process.env.HOME = root;
  process.env.OPENCLAW_STATE_DIR = root;
  const capture = globalThis as typeof globalThis & { __la2iDirectHub?: any };
  t.after(async () => {
    delete globalThis.__la2iAcquire;
    delete capture.__la2iDirectHub;
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key]; else process.env[key] = value;
    }
    await rm(root, { recursive: true, force: true });
  });
  const stub = (code: string) => `data:text/javascript,${encodeURIComponent(code)}`;
  const networkStubs: Record<string, string> = {
    // W1 holds the relay receive queue; reports arrive through a real Noise session on the direct link.
    "./direct.js": stub("export const bindAddresses=()=>[]; export const serveDirect=async({hub})=>{globalThis.__la2iDirectHub=hub;return {listening:false,close:async()=>{}};};"),
    "./hints.js": stub("export const watchDirect=async()=>async()=>{};"),
    "./bonjour.js": stub("export const serveBonjour=async()=>({update:async()=>{},close:async()=>{}});"),
  };
  const hooks = registerHooks({ resolve(specifier, context, next) {
    if (context.parentURL?.split("?")[0] === new URL("relay.ts", source).href && networkStubs[specifier]) return { url: networkStubs[specifier], shortCircuit: true };
    if (specifier === sdkPrefix + "file-lock") return { url: stub("export const acquireFileLock=(...args)=>globalThis.__la2iAcquire(...args);"), shortCircuit: true };
    if (specifier.startsWith(sdkPrefix)) return next(pathToFileURL(path.join(sdk!, "dist/plugin-sdk", `${specifier.slice(sdkPrefix.length)}.js`)).href, context);
    if (specifier.startsWith(".") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  } });
  t.after(() => hooks.deregister());
  const { resolveStateDir } = await import(sdkPrefix + "state-paths");
  const { WebSocketServer } = await import(sdkPrefix + "websocket-runtime");
  const owner = await ownerRuntime(source);
  t.after(() => owner.close());
  const { yorozuRuntime } = await import(new URL("runtime.ts", source).href);
  const runtime = yorozuRuntime.getRuntime();
  const openStore = runtime.state.openKeyedStore;
  runtime.state.openKeyedStore = (options: any) => {
    const store = openStore(options);
    if (options.namespace !== "devices") return store;
    return { ...store, entries: async () => {
      await owner.lookups.get("L5-devices-read")?.();
      return store.entries();
    } };
  };
  t.after(() => { runtime.state.openKeyedStore = openStore; });
  const { runRelayHost, activityTurn, unpairDevice } = await import(new URL("relay.ts?la2i-l5", source).href);
  const { encodeEvent } = await import(new URL("envelope.ts", source).href);
  const { b64u, decodeFrame, encodeFrame, ed25519Keypair, NoiseIK, prologue, roomId, signFrame, x25519Keypair } = await import(new URL("wire.ts", source).href);
  const file = path.join(resolveStateDir(), "yorozu", "live-activities.json");
  await mkdir(path.dirname(file), { recursive: true });
  const realNow = Date.now;
  async function until(read: () => boolean, description: string, bound = 1_000) {
    const deadline = realNow() + bound;
    while (!read() && realNow() < deadline) await delay(10);
    assert.ok(read(), description);
  }
  for (const window of ["W1 devices read", "W2 lock acquire"] as const) {
    for (const flags of [{ liveActivity: true, activityTimestamp: true }, { liveActivity: true }, {}]) {
      for (const fence of (flags.liveActivity ? ["normal", "revoke", "reconnect"] : ["disabled"])) {
        await t.test(`${window}; ${JSON.stringify(flags)}; ${fence}`, async (t) => {
          let now = realNow();
          Date.now = () => now;
          t.after(() => { Date.now = realNow; });
          let releaseRead!: () => void;
          let releaseAcquire!: () => void;
          const readGate = new Promise<void>((resolve) => { releaseRead = resolve; });
          const acquireGate = new Promise<void>((resolve) => { releaseAcquire = resolve; });
          let readHeld = false;
          let connected = false;
          let calls = 0;
          const lock = await testFileLock(file, {});
          t.after(() => lock.release());
          globalThis.__la2iAcquire = async (target, options) => {
            if (++calls === 1) return testFileLock(target, options);
            await acquireGate;
            await lock.release();
            return testFileLock(target, options);
          };
          const signing = ed25519Keypair();
          const keys = { signing, static: x25519Keypair(), room: roomId(signing.publicKey) };
          const device = { signing: ed25519Keypair(), static: x25519Keypair() };
          const deviceKey = b64u(device.signing.publicKey);
          const seededKey = b64u(ed25519Keypair().publicKey);
          const conv = "11111111-1111-4111-8111-111111111111";
          const seededConv = "22222222-2222-4222-8222-222222222222";
          const job = "AAAAAAAAAAAAAAAA";
          const jobs = [{ token: job, kind: "turn" as const, state: "running" as const, steps: 1, startedAt: now }];
          // The seeded record's device is paired too: load tombstones records of unlisted devices.
          owner.stores.set("devices", new Map([[deviceKey, { signingPub: deviceKey, staticPub: b64u(device.static.publicKey), pairedAt: now }],
            [seededKey, { signingPub: seededKey, staticPub: b64u(x25519Keypair().publicKey), pairedAt: now }]]));
          owner.lookups.set("L5-devices-read", async () => {
            if (connected && window === "W1 devices read") { readHeld = true; await readGate; }
          });
          t.after(() => { owner.lookups.delete("L5-devices-read"); });
          await writeFile(file, JSON.stringify({ v: 3, records: [{ device: seededKey,
            activityId: "33333333-3333-4333-8333-333333333333", requestedAtMs: now,
            kLast: Math.ceil(now / 1000), terminal: false, token: "cd".repeat(32), rows: jobs, sent: jobs, bindings: { [job]: seededConv } }] }));
          type Message = { type: string; device?: string; token?: string; timestamp?: number; state?: { jobs: { steps: number }[] } };
          const connections: { socket: any; messages: Message[] }[] = [];
          const statuses: boolean[] = [];
          const server = new WebSocketServer({ host: "127.0.0.1", port: 0 });
          const controller = new AbortController();
          let running: Promise<void> | undefined;
          t.after(async () => {
            releaseRead();
            releaseAcquire();
            controller.abort();
            await running;
            for (const c of connections) c.socket.terminate();
            await new Promise<void>((resolve) => server.close(() => resolve()));
          });
          await new Promise<void>((resolve, reject) => { server.once("listening", resolve); server.once("error", reject); });
          server.on("connection", (socket: any) => {
            const c = { socket, messages: [] as Message[] };
            connections.push(c);
            socket.on("message", (raw: unknown) => {
              const message = JSON.parse(String(raw));
              c.messages.push(message);
              if (message.type === "register") socket.send(JSON.stringify({ type: "registered", ...flags }));
              if (message.type === "ping") socket.send(JSON.stringify({ type: "pong" }));
            });
            socket.send(JSON.stringify({ type: "nonce", nonce: "synthetic-challenge" }));
          });
          const address = server.address();
          assert.ok(address && typeof address !== "string");
          running = runRelayHost({ relayUrl: `ws://127.0.0.1:${address.port}`, keys, signal: controller.signal,
            directPort: 1, directBonjour: false, mediaMaxBytes: 1024,
            liveTurn: (id: string) => id === seededConv ? { steps: 2, startedAt: now } : undefined,
            onStatus: (s: { connected?: boolean }) => { connected = s.connected === true; statuses.push(connected); },
            onMessage: () => {}, onReaction: () => {} });
          void running.catch(() => {});
          await until(() => connected, "relay socket registered");
          if (window === "W1 devices read") await until(() => readHeld, "registered listDevices read held");
          else await until(() => connections[0]?.messages.some((m) => m.type === "devices") === true && (calls === 0 || calls === 2), "devices announced and restore acquire held");
          const first = connections[0]!;
          assert.equal(first.messages.some((m) => m.type === "devices"), window === "W2 lock acquire");
          const frames: string[] = [];
          const link = { path: "direct", send: (payloads: string[]) => frames.push(...payloads), close: () => {} };
          const hub = capture.__la2iDirectHub!;
          const noise = new NoiseIK("initiator", device.static, keys.static.publicKey, prologue(keys.room, device.signing.publicKey));
          const init = noise.writeMessage(Buffer.from(JSON.stringify({ ts: now })));
          const payload = encodeFrame({ type: "init", deviceSigningKey: device.signing.publicKey, message: init });
          await hub.handshake(payload, signFrame(device.signing.privateKey, payload), link);
          const response = decodeFrame(frames.shift()!);
          assert.ok(response?.type === "response");
          noise.readMessage(response.message);
          const session = noise.split(init.subarray(0, 8));
          async function event(event: Parameters<typeof encodeEvent>[0]) {
            const frame = decodeFrame(session.seal(encodeEvent(event)));
            assert.ok(frame?.type === "box");
            const opened = hub.open(frame, link);
            assert.ok(opened, "paired direct session decrypts report");
            await hub.handle(opened);
          }
          await event({ kind: "peer_info", data: { app: "registration-test", protocolMin: 3, protocolMax: 3, capabilities: [] } });
          await event({ kind: "live_activity", data: { pushToken: "ab".repeat(32), jobs, turns: { [job]: conv } } });
          const pushes = (c = first) => c.messages.filter((m) => m.type === "activityPush" && m.device === deviceKey);
          const legacyMessages = () => connections.flatMap((c) => c.messages).filter((m) => m.device === deviceKey && (m.type === "activityToken" || m.type === "activityPush"));
          const seededMessages = () => connections.flatMap((c) => c.messages).filter((m) => m.device === seededKey && (m.type === "activityToken" || m.type === "activityPush"));
          activityTurn(conv, { kind: "step", steps: 2 });
          if (fence === "disabled") {
            await delay(150);
            assert.deepEqual(legacyMessages(), [], "L3a: no legacy token or push without liveActivity");
          } else {
            await until(() => pushes().length === 1, "legacy report then immediate step pushes inside held window");
            assert.deepEqual(legacyMessages().map((m) => m.type), ["activityToken", "activityPush"]);
            assert.equal(legacyMessages()[0]!.token, "ab".repeat(32));
            assert.equal(pushes()[0]!.state!.jobs[0]!.steps, 2);
            assert.equal(Object.hasOwn(pushes()[0]!, "timestamp"), false);
            // Advance the injected wall clock near the 15 s boundary; the real hold timer still fires.
            now += 14_900;
            activityTurn(conv, { kind: "step", steps: 3 });
            await delay(30);
            assert.equal(pushes().length, 1, "second step throttled while window stays held");
            now += 100;
            await until(() => pushes().length === 2, "legacy hold timer fires before releasing read/acquire");
            assert.equal(pushes()[1]!.state!.jobs[0]!.steps, 3);
            assert.equal(Object.hasOwn(pushes()[1]!, "timestamp"), false);
            now += 14_900;
            activityTurn(conv, { kind: "step", steps: 4 });
            if (fence === "revoke") {
              assert.equal(await unpairDevice(deviceKey), true);
              now += 100;
              await delay(150);
              activityTurn(conv, { kind: "step", steps: 5 });
              await delay(50);
              assert.equal(pushes().length, 2, "unpair cancels held timer and later legacy pushes");
            } else if (fence === "reconnect") {
              first.socket.close();
              await until(() => statuses.includes(false), "relay down observed");
              now += 100;
              activityTurn(conv, { kind: "step", steps: 5 });
              await delay(150);
              assert.equal(pushes().length, 2, "closed socket receives no held or later push");
              await until(() => connections.length === 2 && connected, "replacement relay registered", 5_000);
              activityTurn(conv, { kind: "step", steps: 6 });
              await until(() => pushes(connections[1]!).length === 1, "next legacy step pushes on new socket during held restore");
              assert.equal(pushes(connections[1]!)[0]!.state!.jobs[0]!.steps, 6);
              assert.equal(Object.hasOwn(pushes(connections[1]!)[0]!, "timestamp"), false);
            } else {
              now += 100;
              await until(() => pushes().length === 3, "second held timer fires within window");
            }
          }
          assert.deepEqual(seededMessages(), [], "no seeded replay or push before restore completes");
          if (window === "W1 devices read") assert.ok(connections.every((c) => !c.messages.some((m) => m.type === "devices")), "devices announce remains held throughout assertions");
          const count = legacyMessages().length;
          releaseRead();
          await until(() => connections.at(-1)!.messages.some((m) => m.type === "devices"), "allowlist announced after releasing read");
          await delay(30);
          assert.deepEqual(seededMessages(), [], "seeded traffic still fenced by held acquire after devices announce");
          releaseAcquire();
          // Main has no store/replay; identical legacy assertions apply there unchanged.
          if (calls > 0) await until(() => seededMessages().some((m) => m.type === "activityToken"), "seeded replay resumes after restore release");
          await delay(200);
          assert.equal(legacyMessages().length, count, "restore completion never duplicates or replays legacy traffic");
          assert.equal(pushes(first).length, fence === "disabled" ? 0 : fence === "normal" ? 3 : 2);
        });
      }
    }
  }
});

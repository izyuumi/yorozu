import { testFileLock as diskLock } from "./activity-lock.ts";
import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { test } from "node:test";
import { applyTurn, cleanJobs, plan, STEP_INTERVAL_MS, type ActivityReport } from "../src/liveactivity.ts";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  },
});
const { ActivityWatch } = await import("../src/activitywatch.ts");
const { parseEvent } = await import("../src/envelope.ts");

const T0 = 1_800_000_000_000;
const DEVICE = "deviceSynthetic1";
const TOKEN = "AAAAAAAAAAAAAAAA";
const CONV = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-4222-8222-222222222222";
const report = (): ActivityReport => ({
  pushToken: "ab".repeat(32),
  jobs: [{ token: TOKEN, kind: "turn", state: "running", steps: 1, startedAt: T0 }],
  turns: { [TOKEN]: CONV },
});

type OwnerRun = { steps: number; startedAt: number };
const fixtureOwners = () => new Map<string, OwnerRun>([
  [CONV, { steps: 1, startedAt: T0 }], [OTHER, { steps: 1, startedAt: T0 }],
]);
// Existing seeded fixtures represent live host messages; watch-only restarts retain their owner.
const ownersByStore = new WeakMap<object, Map<string, OwnerRun>>();
function fixtureWatch<T>(options: ConstructorParameters<typeof ActivityWatch<T>>[0], owners = ownersByStore.get(options.store) ?? fixtureOwners()) {
  ownersByStore.set(options.store, owners);
  const watch = new ActivityWatch<T>({ ...options, liveTurn: (convId: string) => owners.get(convId) });
  const turn = watch.turn.bind(watch);
  watch.turn = (convId, change) => {
    if (change.kind === "step") {
      const run = owners.get(convId);
      if (run) owners.set(convId, { ...run, steps: change.steps });
    } else owners.delete(convId);
    turn(convId, change);
  };
  return watch;
}

function fixture() {
  const sent: string[] = [];
  const clock = { now: T0 };
  const timers = new Map<number, { callback: () => void; at: number }>();
  let timerId = 0;
  let connected = false;
  const store = memoryStore();
  const watch = fixtureWatch({
    store,
    warn: () => {},
    send: (raw) => { if (connected) sent.push(raw); },
    now: () => clock.now,
    setTimer: (callback, delay) => {
      const id = ++timerId;
      timers.set(id, { callback, at: clock.now + delay });
      return id;
    },
    clearTimer: (id) => { if (id !== undefined) timers.delete(id); },
  });
  return {
    watch, sent, clock, timers, owners: ownersByStore.get(store)!,
    register(liveActivity: unknown = true, activityTimestamp?: unknown) {
      connected = true;
      watch.relayRegistered({ liveActivity, activityTimestamp });
    },
    down() {
      connected = false;
      watch.relayDown();
    },
    fire() {
      assert.equal(timers.size, 1);
      const [id, timer] = [...timers][0]!;
      timers.delete(id);
      clock.now = timer.at;
      timer.callback();
    },
  };
}

for (const registered of [false, true]) {
  test(`report ignored ${registered ? "without liveActivity" : "before relay registration"}`, () => {
    const f = fixture();
    if (registered) f.register(false);
    f.watch.report(DEVICE, report());
    // Enabling later must not reveal a watch saved by the ignored report.
    f.register();
    f.watch.turn(CONV, { kind: "done" });
    assert.deepEqual(f.sent, []);
    assert.equal(f.timers.size, 0);
  });
}

test("report sends only its activityToken, preserving JSON key order", () => {
  const f = fixture();
  f.register();
  f.watch.report(DEVICE, report());
  assert.deepEqual(f.sent, [JSON.stringify({ type: "activityToken", device: DEVICE, token: report().pushToken })]);
  assert.equal(f.timers.size, 0);
});

test("done sends exactly the real plan without timestamp; end removes the watch", () => {
  const f = fixture();
  f.register();
  const data = report();
  f.watch.report(DEVICE, data);
  f.sent.length = 0;
  f.clock.now += 1_000;
  const before = cleanJobs(data.jobs);
  const after = applyTurn(before, data.turns, CONV, { kind: "done" }, f.clock.now);
  const next = plan(before, after, f.clock.now);
  assert.equal(next?.event, "end");
  const expected = { type: "activityPush", device: DEVICE, ...next };
  f.watch.turn(CONV, { kind: "done" });
  assert.equal(f.sent.length, 1);
  assert.deepEqual(JSON.parse(f.sent[0]!), expected);
  assert.equal(f.sent[0], JSON.stringify(expected));
  assert.equal(Object.hasOwn(JSON.parse(f.sent[0]!), "timestamp"), false);
  // A surviving watch would tidy the finished row away and send another end.
  f.clock.now += 1_000_000;
  f.watch.turn(CONV, { kind: "gone" });
  assert.equal(f.sent.length, 1);
});

test("steps share one hold timer, then push latest state once at the interval", () => {
  const f = fixture();
  f.register();
  f.watch.report(DEVICE, report());
  f.sent.length = 0;
  f.watch.turn(OTHER, { kind: "step", steps: 2 });
  assert.deepEqual(f.sent, []);
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  assert.equal(f.sent.length, 1);
  f.clock.now += 1_000;
  f.watch.turn(CONV, { kind: "step", steps: 3 });
  const [id] = f.timers.keys();
  assert.equal([...f.timers.values()][0]?.at, T0 + STEP_INTERVAL_MS);
  f.clock.now += 1_000;
  f.watch.turn(CONV, { kind: "step", steps: 4 });
  assert.deepEqual([...f.timers.keys()], [id]);
  assert.equal(f.sent.length, 1);
  f.fire();
  assert.equal(f.sent.length, 2);
  const pushed = JSON.parse(f.sent[1]!);
  assert.equal(pushed.priority, 5);
  assert.equal(pushed.state.jobs[0].steps, 4);
  assert.equal(f.timers.size, 0);
  f.watch.turn(CONV, { kind: "step", steps: 4 });
  assert.equal(f.sent.length, 2);
});

test("new report cancels held push and retains last push time", () => {
  const f = fixture();
  f.register();
  f.watch.report(DEVICE, report());
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  f.clock.now += 1_000;
  f.watch.turn(CONV, { kind: "step", steps: 3 });
  assert.equal(f.timers.size, 1);
  f.watch.report(DEVICE, report());
  assert.equal(f.timers.size, 0);
  f.sent.length = 0;
  f.watch.turn(CONV, { kind: "step", steps: 4 });
  assert.deepEqual(f.sent, []);
  assert.equal([...f.timers.values()][0]?.at, T0 + STEP_INTERVAL_MS);
  f.fire();
  assert.equal(f.sent.length, 1);
});

test("urgent end bypasses hold and cancels its timer", () => {
  const f = fixture();
  f.register();
  f.watch.report(DEVICE, report());
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  f.clock.now += 1_000;
  f.watch.turn(CONV, { kind: "step", steps: 3 });
  f.sent.length = 0;
  f.watch.turn(CONV, { kind: "done" });
  assert.equal(f.sent.length, 1);
  assert.equal(JSON.parse(f.sent[0]!).event, "end");
  assert.equal(f.timers.size, 0);
});

for (const tellRelay of [true, false]) {
  test(tellRelay ? "report without pushToken forgets and clears relay token" : "forget(false) removes watch silently", () => {
    const f = fixture();
    f.register();
    f.watch.report(DEVICE, report());
    f.watch.turn(CONV, { kind: "step", steps: 2 });
    f.clock.now += 1_000;
    f.watch.turn(CONV, { kind: "step", steps: 3 });
    f.sent.length = 0;
    if (tellRelay) f.watch.report(DEVICE, { jobs: [], turns: {} });
    else f.watch.forget(DEVICE, false);
    assert.deepEqual(f.sent, tellRelay ? [JSON.stringify({ type: "activityToken", device: DEVICE })] : []);
    assert.equal(f.timers.size, 0);
    f.watch.turn(CONV, { kind: "done" });
    assert.equal(f.sent.length, tellRelay ? 1 : 0);
  });
}

test("relay close retains capability and accepts reports, but pushes require a registered sender", () => {
  const f = fixture();
  f.register();
  f.watch.report(DEVICE, report());
  f.down();
  assert.equal(f.watch.liveActivity, true);
  f.sent.length = 0;
  f.watch.report(DEVICE, report());
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  assert.deepEqual(f.sent, []);
  assert.equal(f.timers.size, 0);
  f.register();
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  assert.equal(f.sent.length, 1);
  assert.equal(JSON.parse(f.sent[0]!).state.jobs[0].steps, 2);
  f.down();
  f.register(false);
  assert.equal(f.watch.liveActivity, false);
  // Existing watches still push: the capability gate applies only to reports.
  f.watch.turn(CONV, { kind: "step", steps: 3 });
  assert.equal(f.timers.size, 1);
  f.fire();
  assert.equal(f.sent.length, 2);
});

const seededReport = (): ActivityReport => ({ ...report(), activityId: CONV, requestedAtMs: 1_800_000_000_500 });
const pushes = (f: { sent: string[] }) => f.sent.map((raw) => JSON.parse(raw)).filter((msg) => msg.type === "activityPush");

test("seeded first push reserves the second after the rounded-up seed", async () => {
  const f = fixture();
  await f.watch.start();
  f.register(true, true);
  f.watch.turn(CONV, { kind: "done" });
  await settle();
  assert.deepEqual(pushes(f), []);
  f.owners.set(CONV, { steps: 1, startedAt: T0 });
  f.watch.report(DEVICE, seededReport());
  assert.deepEqual(pushes(f), []);
  f.watch.turn(CONV, { kind: "done" });
  await settle();
  assert.equal(pushes(f).length, 1);
  assert.equal(pushes(f)[0].timestamp, 1_800_000_002);
});

test("seeded reservations increase only when sent, including a held push", async () => {
  const f = fixture();
  await f.watch.start();
  f.register(true, true);
  f.watch.report(DEVICE, seededReport());
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await settle();
  f.clock.now += 1_000;
  f.watch.turn(CONV, { kind: "step", steps: 3 });
  await settle();
  f.watch.turn(CONV, { kind: "step", steps: 4 });
  await settle();
  assert.deepEqual(pushes(f).map((msg) => msg.timestamp), [1_800_000_002]);
  f.fire();
  await settle();
  assert.equal(pushes(f)[1].state.jobs[0].steps, 4);
  f.watch.turn(CONV, { kind: "done" });
  await settle();
  assert.deepEqual(pushes(f).map((msg) => msg.timestamp), [1_800_000_002, 1_800_000_003, 1_800_000_004]);
});

for (const flags of [[true, undefined], [true, false], [true, "true"], [false, true]] as const) {
  test(`seeded gate requires both current relay flags: ${JSON.stringify(flags)}`, async () => {
    const f = fixture();
    await f.watch.start();
    f.register(true, true);
    f.watch.report(DEVICE, seededReport());
    f.watch.turn(CONV, { kind: "step", steps: 2 });
    await settle();
    f.clock.now += 1_000;
    f.watch.turn(CONV, { kind: "step", steps: 3 });
    await settle();
    f.register(...flags);
    f.fire();
    await settle();
    f.watch.turn(CONV, { kind: "step", steps: 4 });
    await settle();
    assert.equal(pushes(f).length, 1);
    assert.equal(f.timers.size, 0);
    f.register(true, true);
    f.watch.turn(CONV, { kind: "done" });
    await settle();
    assert.deepEqual(pushes(f).map((msg) => msg.timestamp), [1_800_000_002, 1_800_000_003]);
    assert.equal(pushes(f)[1].event, "end");
  });
}

test("seeded watch on a relay without timestamp support keeps state without pushing", async () => {
  const f = fixture();
  await f.watch.start();
  f.register();
  f.watch.report(DEVICE, seededReport());
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await settle();
  assert.deepEqual(pushes(f), []);
  assert.equal(f.timers.size, 0);
  f.register(true, true);
  f.watch.turn(CONV, { kind: "done" });
  await settle();
  assert.equal(pushes(f).length, 1);
  assert.equal(pushes(f)[0].timestamp, 1_800_000_002);
});

test("legacy report with both relay flags sends exactly the real plan without timestamp", () => {
  const f = fixture();
  f.register(true, true);
  const data = report();
  f.watch.report(DEVICE, data);
  f.sent.length = 0;
  const before = cleanJobs(data.jobs);
  const after = applyTurn(before, data.turns, CONV, { kind: "done" }, f.clock.now);
  const expected = { type: "activityPush", device: DEVICE, ...plan(before, after, f.clock.now) };
  f.watch.turn(CONV, { kind: "done" });
  assert.deepEqual(f.sent, [JSON.stringify(expected)]);
  assert.deepEqual(pushes(f), [expected]);
  assert.equal(Object.hasOwn(pushes(f)[0], "timestamp"), false);
});

test("seeded end is terminal for the same activity; a new activity gets a fresh seed", async () => {
  const f = fixture();
  await f.watch.start();
  f.register(true, true);
  f.watch.report(DEVICE, seededReport());
  f.watch.turn(CONV, { kind: "done" });
  await settle();
  assert.equal(pushes(f)[0].event, "end");
  assert.equal(pushes(f)[0].timestamp, 1_800_000_002);
  f.watch.report(DEVICE, { ...seededReport(), requestedAtMs: 1_800_000_100_500 });
  f.watch.turn(CONV, { kind: "done" });
  await settle();
  assert.equal(pushes(f).length, 1);
  f.owners.set(CONV, { steps: 1, startedAt: T0 });
  f.watch.report(DEVICE, { ...seededReport(), activityId: OTHER, pushToken: "cd".repeat(32), requestedAtMs: 1_800_000_010_500 });
  f.watch.turn(CONV, { kind: "done" });
  await settle();
  assert.deepEqual(pushes(f).map((msg) => msg.timestamp), [1_800_000_002, 1_800_000_012]);
});

test("same-token re-report never lowers the last reservation", async () => {
  const f = fixture();
  await f.watch.start();
  f.register(true, true);
  f.watch.report(DEVICE, seededReport());
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await settle();
  f.watch.report(DEVICE, { ...seededReport(), requestedAtMs: 1_799_999_000_000 });
  f.watch.turn(CONV, { kind: "done" });
  await settle();
  assert.deepEqual(pushes(f).map((msg) => msg.timestamp), [1_800_000_002, 1_800_000_003]);
});

test("same-token re-report raises the seed when requestedAtMs is newer", async () => {
  const f = fixture();
  await f.watch.start();
  f.register(true, true);
  f.watch.report(DEVICE, seededReport());
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await settle();
  f.watch.report(DEVICE, { ...seededReport(), requestedAtMs: 1_800_000_010_500 });
  f.watch.turn(CONV, { kind: "done" });
  await settle();
  // LA-2h generation ordering: same id cannot change its generation.
  assert.deepEqual(pushes(f).map((msg) => msg.timestamp), [1_800_000_002, 1_800_000_003]);
});

test("live_activity envelope rejects invalid requestedAtMs through normal validation", () => {
  const event = (requestedAtMs: unknown) => Buffer.from(JSON.stringify({ kind: "live_activity", data: { ...report(), activityId: CONV, requestedAtMs } }));
  assert.deepEqual(parseEvent(event(1_800_000_000_500)), { kind: "live_activity", data: seededReport() });
  assert.deepEqual(parseEvent(event(1_800_000_000)), { kind: "invalid", name: "live_activity" });
});

// Durable tests use only synthetic records; every send checks its persistence receipt.
function memoryStore() {
  let records: import("../src/activitystore.ts").ActivityRecord[] = [];
  const saves: typeof records[] = [];
  let release: (() => void) | undefined;
  return {
    saves,
    fail: false,
    unavailable: false,
    hold: false,
    async acquire() { return true; },
    async release() { release?.(); release = undefined; },
    async load() {
      return this.unavailable ? { ok: false as const, reason: "unreadable synthetic store" }
        : { ok: true as const, records: structuredClone(records) };
    },
    async save(next: typeof records) {
      if (this.hold) { this.hold = false; await new Promise<void>((resolve) => { release = resolve; }); }
      if (this.fail) throw Object.assign(new Error("synthetic disk failure"), { code: "ENOSPC" });
      records = structuredClone(next);
      saves.push(structuredClone(next));
    },
  };
}
const settle = () => new Promise<void>((resolve) => setImmediate(resolve));
function durableFixture(store = memoryStore()) {
  const sent: string[] = [];
  const warnings: string[] = [];
  const clock = { now: T0 };
  const timers = new Map<number, () => void>();
  let id = 0;
  const watch = fixtureWatch({
    store, warn: (message) => warnings.push(message), now: () => clock.now,
    send: (raw) => {
      const msg = JSON.parse(raw);
      if (msg.type === "activityPush" && msg.timestamp !== undefined) {
        assert.ok(store.saves.some((rows) => rows.some((row) => row.device === msg.device && row.kLast === msg.timestamp)), "timestamp must have a successful save receipt");
      }
      sent.push(raw);
    },
    setTimer: (callback) => { timers.set(++id, callback); return id; },
    clearTimer: (timer) => { if (timer !== undefined) timers.delete(timer); },
  });
  return { watch, sent, store, warnings, clock, timers };
}
async function running(store = memoryStore()) {
  const f = durableFixture(store);
  await f.watch.start();
  f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  f.watch.report(DEVICE, seededReport());
  await settle();
  return f;
}

test("durable restart resumes after the last persisted reservation", async () => {
  const a = await running();
  a.watch.turn(CONV, { kind: "step", steps: 2 });
  await settle();
  a.clock.now += STEP_INTERVAL_MS;
  a.watch.turn(CONV, { kind: "step", steps: 3 });
  await settle();
  assert.deepEqual(pushes(a).map((msg) => msg.timestamp), [1_800_000_002, 1_800_000_003]);
  const b = await running(a.store);
  b.watch.turn(CONV, { kind: "step", steps: 4 });
  await settle();
  assert.equal(pushes(b)[0].timestamp, 1_800_000_004);
});

test("save failure burns k, degrades readiness, then fresh change recovers", async () => {
  const f = await running();
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await settle();
  f.clock.now += STEP_INTERVAL_MS;
  f.store.fail = true;
  f.watch.turn(CONV, { kind: "step", steps: 3 });
  await settle();
  assert.equal(pushes(f).length, 1);
  assert.equal(f.warnings.length, 1);
  assert.match(f.warnings[0]!, /ENOSPC/);
  assert.equal(f.watch.hostWriterReady, false);
  assert.equal(f.timers.size, 0);
  f.store.fail = false;
  f.watch.turn(CONV, { kind: "step", steps: 4 });
  await settle();
  assert.deepEqual(pushes(f).map((msg) => msg.timestamp), [1_800_000_002, 1_800_000_004]);
  assert.equal(f.watch.hostWriterReady, true);
  assert.equal(pushes(f)[1].state.jobs[0].steps, 4);
});

test("held save serializes changes and sends consecutive snapshots", async () => {
  const f = await running();
  f.store.hold = true;
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await settle();
  assert.equal(pushes(f).length, 0);
  f.clock.now += STEP_INTERVAL_MS;
  f.watch.turn(CONV, { kind: "step", steps: 5 });
  await settle();
  assert.equal(pushes(f).length, 0);
  f.store.release();
  await settle();
  assert.deepEqual(pushes(f).map((msg) => msg.timestamp), [1_800_000_002, 1_800_000_003]);
  assert.deepEqual(pushes(f).map((msg) => msg.state.jobs[0].steps), [2, 5]);
});

for (const replacement of ["new token", "no token"] as const) {
  test(`${replacement} while disconnected discards in-flight old-token push`, async () => {
    const f = await running();
    f.store.hold = true;
    f.watch.turn(CONV, { kind: "step", steps: 2 });
    await settle();
    f.watch.relayDown();
    f.watch.report(DEVICE, replacement === "new token"
      ? { ...seededReport(), pushToken: "cd".repeat(32), requestedAtMs: 1_800_000_010_500 }
      : { jobs: [], turns: {} });
    f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
    f.store.release();
    await settle();
    // LA-2h generation ordering: rejected rotation leaves original reservation/token; forget retains tombstone.
    assert.deepEqual(pushes(f), replacement === "new token" ? [{
      type: "activityPush", device: DEVICE, event: "update", priority: 5,
      state: { jobs: [{ token: TOKEN, kind: "turn", state: "running", steps: 2, startedAt: 821692800 }] },
      staleDate: 1_800_000_900, timestamp: 1_800_000_002,
    }] : []);
    f.watch.turn(CONV, { kind: "step", steps: 3 });
    await settle();
    // LA-2h generation ordering: rejected rotation leaves original reservation/token; forget retains tombstone.
    if (replacement === "new token") {
      assert.equal(f.timers.size, 1);
      f.clock.now += STEP_INTERVAL_MS;
      const [id, callback] = [...f.timers][0]!;
      f.timers.delete(id);
      callback();
      await settle();
    }
    assert.deepEqual(pushes(f).map((msg) => msg.timestamp), replacement === "new token" ? [1_800_000_002, 1_800_000_003] : []);
    // LA-2h generation ordering: rejected rotation leaves original reservation/token; forget retains tombstone.
    const messages = f.sent.map((raw) => JSON.parse(raw));
    const newTokenIndex = messages.findIndex((msg) => msg.type === "activityToken" && msg.token === seededReport().pushToken);
    if (replacement === "new token") {
      assert.ok(newTokenIndex >= 0);
      assert.deepEqual(messages.slice(0, newTokenIndex).filter((msg) => msg.type === "activityPush"), []);
      assert.ok(messages.every((msg, index) => msg.type !== "activityPush" || index > newTokenIndex));
      assert.deepEqual(pushes(f).map((msg) => msg.state.jobs[0].steps), [2, 3]);
    }
    const saved = await f.store.load();
    assert.equal(saved.ok, true);
    if (saved.ok) assert.deepEqual(saved.records.map((row) => row.token), replacement === "new token" ? [seededReport().pushToken] : [undefined]);
  });
}

test("registration replays every active seeded token before an in-flight push", async () => {
  const f = await running();
  f.watch.report("deviceSynthetic2", seededReport());
  f.watch.report("deviceSynthetic3", seededReport());
  await settle();
  // Third activity ends; its token must never be replayed.
  // LA-2g round 1 rule 4: use a fresh token for live OTHER; an admitted token cannot be rebound.
  f.watch.report("deviceSynthetic3", { ...seededReport(), jobs: [{ ...report().jobs[0]!, token: "BBBBBBBBBBBBBBBB" }], turns: { BBBBBBBBBBBBBBBB: OTHER } });
  f.watch.turn(OTHER, { kind: "done" });
  await settle();
  f.store.hold = true;
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await settle();
  f.watch.relayDown();
  f.sent.length = 0;
  f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  assert.deepEqual(f.sent.map((raw) => JSON.parse(raw)), [
    { type: "activityToken", device: DEVICE, token: seededReport().pushToken },
    { type: "activityToken", device: "deviceSynthetic2", token: seededReport().pushToken },
  ]);
  f.store.release();
  await settle();
  assert.equal(pushes(f).length, 2);
});

for (const seeded of [true, false]) {
  test(`${seeded ? "Mode H" : "legacy"} same-token report adding a row`, async () => {
    const f = durableFixture();
    if (seeded) await f.watch.start();
    f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
    const initial = seeded ? seededReport() : report();
    f.watch.report(DEVICE, initial);
    await settle();
    f.watch.report(DEVICE, { ...initial, jobs: [...initial.jobs, { token: "BBBBBBBBBBBBBBBB", kind: "recording", state: "running", startedAt: T0 }] });
    await settle();
    assert.equal(pushes(f).length, seeded ? 1 : 0);
    if (seeded) {
      assert.equal(pushes(f)[0].timestamp, 1_800_000_002);
      assert.equal(pushes(f)[0].state.jobs[1].token, "BBBBBBBBBBBBBBBB");
    } else {
      f.watch.turn(CONV, { kind: "done" });
      assert.equal(Object.hasOwn(pushes(f)[0], "timestamp"), false);
      assert.equal(f.store.saves.length, 0);
    }
  });
}

test("hostWriterReady requires loaded healthy store and both current relay flags", async () => {
  const f = durableFixture();
  f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  assert.equal(f.watch.hostWriterReady, false);
  await f.watch.start();
  assert.equal(f.watch.hostWriterReady, true);
  for (const flags of [{}, { liveActivity: true }, { activityTimestamp: true }, { liveActivity: true, activityTimestamp: "true" }]) {
    f.watch.relayRegistered(flags);
    assert.equal(f.watch.hostWriterReady, false);
  }
  f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  f.watch.relayDown();
  assert.equal(f.watch.hostWriterReady, false);
  const bad = memoryStore();
  bad.unavailable = true;
  const b = durableFixture(bad);
  await b.watch.start();
  b.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  assert.equal(b.watch.hostWriterReady, false);
  b.watch.report(DEVICE, seededReport());
  b.watch.turn(CONV, { kind: "done" });
  await settle();
  assert.deepEqual(pushes(b), []);
  assert.equal(bad.saves.length, 0);
});

test("persisted end survives restart and token clearing without re-seeding", async () => {
  const a = await running();
  a.watch.turn(CONV, { kind: "done" });
  await settle();
  assert.equal(pushes(a)[0].timestamp, 1_800_000_002);
  const loaded = await a.store.load();
  // LA-2h generation ordering: terminal records retain requestedAtMs.
  assert.deepEqual(loaded, { ok: true, records: [{ device: DEVICE, activityId: CONV, requestedAtMs: seededReport().requestedAtMs, kLast: 1_800_000_002, terminal: true }] });
  const b = await running(a.store);
  b.watch.report(DEVICE, { jobs: [], turns: {} });
  b.watch.report(DEVICE, { ...seededReport(), requestedAtMs: 1_800_000_100_500 });
  b.watch.turn(CONV, { kind: "step", steps: 2 });
  b.watch.relayDown();
  b.sent.length = 0;
  b.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  await settle();
  assert.deepEqual(b.sent, []);
});

test("legacy report preserves terminal tombstone and cannot revive the same activity", async () => {
  const f = await running();
  f.watch.turn(CONV, { kind: "done" });
  await settle();
  assert.equal(pushes(f)[0].event, "end");
  // LA-2h generation ordering: terminal records have exactly five fields.
  const tombstone = { ok: true, records: [{ device: DEVICE, activityId: CONV, requestedAtMs: seededReport().requestedAtMs, kLast: 1_800_000_002, terminal: true }] };
  assert.deepEqual(await f.store.load(), tombstone);
  f.sent.length = 0;
  const legacy = { ...report(), pushToken: "cd".repeat(32) };
  f.watch.report(DEVICE, legacy);
  await settle();
  assert.deepEqual(f.sent, [JSON.stringify({ type: "activityToken", device: DEVICE, token: legacy.pushToken })]);
  assert.deepEqual(await f.store.load(), tombstone);
  f.sent.length = 0;
  f.watch.report(DEVICE, { ...seededReport(), requestedAtMs: 1_800_000_100_500 });
  await settle();
  assert.deepEqual(f.sent, []);
  assert.deepEqual(await f.store.load(), tombstone);
});

test("saved reservation is burned if the relay gate closes before send", async () => {
  const f = await running();
  f.store.hold = true;
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await settle();
  f.watch.relayRegistered({ liveActivity: true, activityTimestamp: false });
  f.store.release();
  await settle();
  assert.deepEqual(pushes(f), []);
  assert.equal(f.store.saves.at(-1)?.[0]?.kLast, 1_800_000_002);
  f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  f.watch.turn(CONV, { kind: "step", steps: 3 });
  await settle();
  assert.equal(pushes(f)[0].timestamp, 1_800_000_003);
});

test("different-device reservations preserve both counters in the shared file", async () => {
  const f = await running();
  f.watch.report("deviceSynthetic2", seededReport());
  await settle();
  f.store.hold = true;
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await settle();
  assert.deepEqual(pushes(f), []);
  f.store.release();
  await settle();
  assert.equal(pushes(f).length, 2);
  const b = await running(f.store);
  b.watch.report("deviceSynthetic2", seededReport());
  b.watch.turn(CONV, { kind: "step", steps: 3 });
  await settle();
  assert.deepEqual(pushes(b).map((msg) => [msg.device, msg.timestamp]).sort(), [[DEVICE, 1_800_000_003], ["deviceSynthetic2", 1_800_000_003]]);
});

// Real disk boundary, with failures wrapped around the production save (including post-rename failure).
const { ActivityStore } = await import("../src/activitystore.ts");
const { mkdtemp, readFile, rm, chmod } = await import("node:fs/promises");
const { default: os } = await import("node:os");
const { default: path } = await import("node:path");
const { setTimeout: delay } = await import("node:timers/promises");

class DiskStore extends ActivityStore {
  fail: "before" | "after" | undefined;
  hold = false;
  entered = false;
  unblock: (() => void) | undefined;
  active = 0;
  attempts = 0;
  override async save(rows: import("../src/activitystore.ts").ActivityRecord[]) {
    this.active++;
    this.attempts++;
    try {
      if (this.hold) {
        this.hold = false;
        this.entered = true;
        await new Promise<void>((resolve) => { this.unblock = resolve; });
      }
      if (this.fail === "before") throw Object.assign(new Error("synthetic failure"), { code: "ENOSPC" });
      await super.save(rows);
      if (this.fail === "after") throw Object.assign(new Error("synthetic directory fsync failure"), { code: "EIO" });
    } finally { this.active--; }
  }
}
async function diskFixture(t: import("node:test").TestContext) {
  const dir = await mkdtemp(path.join(os.tmpdir(), "yorozu-watch-"));
  const file = path.join(dir, "live-activities.json");
  const store = new DiskStore(file, diskLock);
  const sent: string[] = [];
  const warnings: string[] = [];
  const clock = { now: T0 };
  const owners = fixtureOwners();
  const stores = new Set<DiskStore>();
  const watches: InstanceType<typeof ActivityWatch<number>>[] = [];
  function make(storage = store) {
    stores.add(storage);
    const watch = fixtureWatch<number>({
      store: storage, now: () => clock.now, send: (raw) => sent.push(raw), warn: (message) => warnings.push(message),
      setTimer: () => { assert.fail("test must advance clock before throttled events"); }, clearTimer: () => {},
    }, owners);
    watches.push(watch);
    return watch;
  }
  const watch = make();
  t.after(async () => {
    store.unblock?.();
    await chmod(dir, 0o700);
    for (const w of watches) await w.stop();
    await rm(dir, { recursive: true, force: true });
  });
  async function idle() {
    // Observe completed I/O and allow queued per-device reservations to enter the store.
    let previous = -1;
    do {
      previous = [...stores].reduce((sum, s) => sum + s.attempts, 0);
      await delay(10);
    } while ([...stores].some((s) => s.active) || previous !== [...stores].reduce((sum, s) => sum + s.attempts, 0));
  }
  await watch.start();
  await watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  return { watch, store, dir, file, sent, warnings, clock, make, idle, owners,
    rows: async () => JSON.parse(await readFile(file, "utf8")).records };
}

test("B1 real store: ten pushes then same-activity token rotation first sends 1800000011", async (t) => {
  const f = await diskFixture(t);
  const initial = { ...seededReport(), requestedAtMs: T0 };
  f.watch.report(DEVICE, initial);
  await f.idle();
  for (let steps = 2; steps <= 11; steps++) {
    f.clock.now += STEP_INTERVAL_MS;
    f.watch.turn(CONV, { kind: "step", steps });
    await f.idle();
  }
  assert.equal(pushes(f).length, 10);
  assert.equal(pushes(f).at(-1).timestamp, 1_800_000_010);
  f.watch.report(DEVICE, { ...initial, pushToken: "cd".repeat(32), jobs: [{ ...initial.jobs[0]!, steps: 11 }] });
  await f.idle();
  assert.equal(JSON.parse(f.sent.at(-1)!).token, "cd".repeat(32));
  f.clock.now += STEP_INTERVAL_MS;
  f.watch.turn(CONV, { kind: "step", steps: 12 });
  await f.idle();
  assert.equal(pushes(f).length, 11);
  assert.equal(pushes(f)[10].timestamp, 1_800_000_011);
});

test("pending clears relay token, retains bindings and resumes after its last k", async (t) => {
  const f = await diskFixture(t);
  f.watch.report(DEVICE, seededReport());
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await f.idle();
  f.watch.report(DEVICE, { activityId: CONV, requestedAtMs: T0, jobs: [], turns: {} });
  await f.idle();
  // LA-2h generation ordering: mismatched pending generation cannot clear the token.
  assert.deepEqual(JSON.parse(f.sent.at(-1)!), {
    type: "activityPush", device: DEVICE, event: "update", priority: 5,
    state: { jobs: [{ token: TOKEN, kind: "turn", state: "running", steps: 2, startedAt: 821692800 }] },
    staleDate: 1_800_000_900, timestamp: 1_800_000_002,
  });
  // Mode H row ownership decision (Yorozu, 2026-11-08): pending retains bindings, host rows and sent state.
  assert.deepEqual(await f.rows(), [{ device: DEVICE, activityId: CONV, requestedAtMs: seededReport().requestedAtMs, kLast: 1_800_000_002, terminal: false, token: seededReport().pushToken, bindings: seededReport().turns, rows: [{ ...seededReport().jobs[0]!, steps: 2 }], sent: [{ ...seededReport().jobs[0]!, steps: 2 }] }]);
  f.clock.now += STEP_INTERVAL_MS;
  f.watch.turn(CONV, { kind: "step", steps: 3 });
  await f.idle();
  // LA-2h generation ordering: original token remains active after rejected pending report.
  assert.equal(pushes(f).length, 2);
  f.watch.report(DEVICE, { ...seededReport(), jobs: [{ ...seededReport().jobs[0]!, steps: 3 }] });
  await f.idle();
  assert.equal(pushes(f)[1].timestamp, 1_800_000_003);
  // Pending state also retains the conversation mapping despite the empty pending report.
  f.watch.turn(CONV, { kind: "done" });
  await f.idle();
  assert.equal(pushes(f)[2].timestamp, 1_800_000_004);
});

for (const pending of [false, true]) {
  test(`A2 ${pending ? "pending" : "reported"} replaces A1 while its save is in flight`, async (t) => {
    const f = await diskFixture(t);
    f.watch.report(DEVICE, seededReport());
    await f.idle();
    f.store.hold = true;
    f.watch.turn(CONV, { kind: "step", steps: 2 });
    while (!f.store.entered) await delay(1);
    const a2 = { ...seededReport(), activityId: OTHER, requestedAtMs: 1_800_000_100_500 };
    f.watch.report(DEVICE, { ...a2, ...(pending ? { pushToken: undefined } : {}) });
    f.store.unblock!();
    await f.idle();
    assert.deepEqual(pushes(f), []);
    assert.equal((await f.rows())[0].activityId, OTHER);
    if (pending) { f.watch.report(DEVICE, a2); await f.idle(); }
    f.watch.turn(CONV, { kind: "done" });
    await f.idle();
    assert.deepEqual(pushes(f).map((m) => m.timestamp), [1_800_000_102]);
  });
}

test("real tombstone redacts token, survives revoke and restart; only A2 replaces it", async (t) => {
  const f = await diskFixture(t);
  f.watch.report(DEVICE, seededReport());
  f.watch.turn(CONV, { kind: "done" });
  await f.idle();
  // LA-2h generation ordering: terminal records have exactly five fields.
  const tombstone = { device: DEVICE, activityId: CONV, requestedAtMs: seededReport().requestedAtMs, kLast: 1_800_000_002, terminal: true };
  assert.deepEqual(await f.rows(), [tombstone]);
  f.watch.forget(DEVICE, false);
  f.watch.report(DEVICE, { ...seededReport(), pushToken: "cd".repeat(32) });
  await f.idle();
  assert.deepEqual(await f.rows(), [tombstone]);
  assert.equal(pushes(f).length, 1);
  await f.watch.stop();
  const restarted = f.make(new DiskStore(f.file, diskLock));
  await restarted.start();
  await restarted.relayRegistered({ liveActivity: true, activityTimestamp: true });
  const count = f.sent.length;
  restarted.report(DEVICE, seededReport());
  restarted.turn(CONV, { kind: "done" });
  await f.idle();
  assert.equal(f.sent.length, count);
  f.owners.set(CONV, { steps: 1, startedAt: T0 });
  restarted.report(DEVICE, { ...seededReport(), activityId: OTHER, pushToken: undefined });
  await f.idle();
  // LA-2h generation ordering: equal-generation A2 cannot replace terminal A1.
  assert.deepEqual(await f.rows(), [tombstone]);
});

for (const fail of ["before", "after", "permissions"] as const) {
  test(`real store save failure (${fail}) burns k, degrades, then fresh event recovers`, async (t) => {
    const f = await diskFixture(t);
    f.watch.report(DEVICE, seededReport());
    await f.idle();
    if (fail === "permissions") await chmod(f.dir, 0o500);
    else f.store.fail = fail;
    f.watch.turn(CONV, { kind: "step", steps: 2 });
    await f.idle();
    assert.deepEqual(pushes(f), []);
    assert.equal(f.watch.hostWriterReady, false);
    assert.match(f.warnings[0]!, fail === "before" ? /ENOSPC/ : fail === "after" ? /EIO/ : /EACCES|EPERM/);
    assert.ok(f.warnings.every((w) => !w.includes(DEVICE) && !w.includes(seededReport().pushToken!)));
    if (fail === "after") assert.equal((await f.rows())[0].kLast, 1_800_000_002);
    f.store.fail = undefined;
    await chmod(f.dir, 0o700);
    f.watch.turn(CONV, { kind: "step", steps: 3 });
    await f.idle();
    assert.equal(f.watch.hostWriterReady, true);
    assert.equal(pushes(f)[0].timestamp, 1_800_000_003);
    f.watch.turn(CONV, { kind: "done" });
    await f.idle();
    assert.deepEqual(pushes(f).map((m) => m.timestamp), [1_800_000_003, 1_800_000_004]);
    assert.equal(new Set(pushes(f).map((m) => m.timestamp)).size, pushes(f).length);
  });
}

test("same-process second host cannot push; registration after first stop acquires and loads", async (t) => {
  const f = await diskFixture(t);
  f.watch.report(DEVICE, seededReport());
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await f.idle();
  const secondStore = new DiskStore(f.file, diskLock);
  const second = f.make(secondStore);
  await second.start();
  await second.relayRegistered({ liveActivity: true, activityTimestamp: true });
  assert.equal(second.hostWriterReady, false);
  assert.match(f.warnings.join("\n"), /another live host holds the Live Activity state/);
  second.report(DEVICE, seededReport());
  second.turn(CONV, { kind: "done" });
  await f.idle();
  assert.equal(pushes(f).length, 1);
  assert.equal(secondStore.attempts, 0);
  const waiter = second;
  await f.watch.stop();
  f.owners.set(CONV, { steps: 2, startedAt: T0 });
  await waiter.relayRegistered({ liveActivity: true, activityTimestamp: true });
  assert.equal(waiter.hostWriterReady, true);
  waiter.report(DEVICE, seededReport());
  waiter.turn(CONV, { kind: "done" });
  await f.idle();
  assert.equal(pushes(f)[1].timestamp, 1_800_000_003);
});

for (const pending of [false, true]) {
  test(`same activity ${pending ? "pending" : "rotation"} invalidates an old-token reservation in flight`, async (t) => {
    const f = await diskFixture(t);
    f.watch.report(DEVICE, seededReport());
    await f.idle();
    f.store.hold = true;
    f.watch.turn(CONV, { kind: "step", steps: 2 });
    while (!f.store.entered) await delay(1);
    f.watch.report(DEVICE, { ...seededReport(), pushToken: pending ? undefined : "cd".repeat(32) });
    f.store.unblock!();
    await f.idle();
    // Mode H row ownership decision (Yorozu, 2026-11-08): undelivered host steps survive rotation and pending.
    assert.deepEqual(pushes(f).filter((m) => m.timestamp === 1_800_000_002), []);
    assert.equal((await f.rows())[0].kLast, pending ? 1_800_000_002 : 1_800_000_003);
    if (pending) { f.watch.report(DEVICE, seededReport()); await f.idle(); }
    assert.equal(pushes(f)[0].state.jobs[0].steps, 2);
    f.watch.turn(CONV, { kind: "done" });
    await f.idle();
    assert.deepEqual(pushes(f).map((m) => m.timestamp), [1_800_000_003, 1_800_000_004]);
  });
}

test("real corrupt store remains unavailable and is never overwritten", async (t) => {
  const f = await diskFixture(t);
  await f.watch.stop();
  const { writeFile } = await import("node:fs/promises");
  await writeFile(f.file, '{"v":99,"records":[]}');
  const corrupt = f.make(new DiskStore(f.file, diskLock));
  await corrupt.start();
  await corrupt.relayRegistered({ liveActivity: true, activityTimestamp: true });
  corrupt.report(DEVICE, seededReport());
  corrupt.turn(CONV, { kind: "done" });
  await f.idle();
  assert.equal(corrupt.hostWriterReady, false);
  assert.deepEqual(pushes(f), []);
  assert.equal(await readFile(f.file, "utf8"), '{"v":99,"records":[]}');
});

// Frozen: the stale continuation sets registered=true and pushes while the relay is down.
test("(q) relayDown invalidates an awaited relayRegistered", async (t) => {
  const store = memoryStore();
  let attempts = 0;
  let acquired!: (value: boolean) => void;
  store.acquire = async () => ++attempts === 1 ? false : attempts === 2
    ? new Promise<boolean>((resolve) => { acquired = resolve; }) : true;
  const sent: string[] = [];
  const watch = fixtureWatch({ store, warn: () => {}, send: (raw) => sent.push(raw),
    now: () => T0, setTimer: () => 0, clearTimer: () => {} });
  t.after(() => watch.stop());
  await watch.start();
  const registering = watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  watch.relayDown();
  acquired(true);
  await registering;
  watch.report(DEVICE, report());
  watch.turn(CONV, { kind: "step", steps: 2 });
  assert.equal(pushes({ sent }).length, 0, "no legacy activityPush while relay is down");
  await watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  watch.turn(CONV, { kind: "step", steps: 3 });
  assert.equal(pushes({ sent }).length, 1);
  assert.deepEqual(pushes({ sent })[0].state.jobs, [{ token: TOKEN, kind: "turn", state: "running", steps: 3, startedAt: 821692800 }]);
  assert.equal(Object.hasOwn(pushes({ sent })[0], "timestamp"), false);
});

// SDK-compatible lock injection; no OpenClaw dependency for restore unit tests.
async function testFileLock(file: string, _options: unknown) {
  const { open, unlink } = await import("node:fs/promises");
  const handle = await open(`${file}.lock`, "wx", 0o600);
  return { async release() { await handle.close(); await unlink(`${file}.lock`); } };
}
async function restoreFixture(t: import("node:test").TestContext) {
  const dir = await mkdtemp(path.join(os.tmpdir(), "yorozu-v2-restore-"));
  const file = path.join(dir, "activities.json");
  const sent: string[] = [];
  const owners = fixtureOwners();
  const watches: InstanceType<typeof ActivityWatch>[] = [];
  const make = () => {
    const watch = fixtureWatch({ store: new ActivityStore(file, testFileLock),
      warn: () => {}, send: (raw) => sent.push(raw), now: () => T0,
      setTimer: () => 0, clearTimer: () => {} }, owners);
    watches.push(watch);
    return watch;
  };
  t.after(async () => { for (const watch of watches) await watch.stop(); await rm(dir, { recursive: true, force: true }); });
  const start = async () => { const watch = make(); await watch.start();
    await watch.relayRegistered({ liveActivity: true, activityTimestamp: true }); return watch; };
  return { file, sent, start };
}

test("v2 restore replays token first and pushes k+1 with the bound row without re-report", async (t) => {
  const f = await restoreFixture(t);
  const first = await f.start();
  first.report(DEVICE, seededReport());
  first.turn(CONV, { kind: "step", steps: 2 });
  for (let i = 0; i < 100 && pushes(f).length === 0; i++) await delay(5);
  assert.equal(pushes(f).length, 1);
  await first.stop(); // Drain real file saves before constructing the new watch.
  assert.equal(pushes(f)[0].timestamp, 1_800_000_002);
  f.sent.length = 0;
  const second = await f.start();
  assert.deepEqual(f.sent.map((raw) => JSON.parse(raw)), [{ type: "activityToken", device: DEVICE, token: "abababababababababababababababababababababababababababababababab" }]);
  second.turn(CONV, { kind: "done" });
  for (let i = 0; i < 100 && pushes(f).length === 0; i++) await delay(5);
  assert.equal(pushes(f).length, 1);
  await second.stop();
  assert.equal(pushes(f)[0].timestamp, 1_800_000_003);
  assert.equal(pushes(f)[0].event, "end");
  assert.deepEqual(pushes(f)[0].state.jobs, [{ token: TOKEN, kind: "turn", state: "done", steps: 2,
    startedAt: 821692800, finishedAt: 821692800 }]);
});

test("v2 end persists only a redacted tombstone", async (t) => {
  const f = await restoreFixture(t);
  const watch = await f.start();
  watch.report(DEVICE, seededReport());
  watch.turn(CONV, { kind: "done" });
  // Wait for send before stop, since stop deliberately suppresses pending sends.
  for (let i = 0; i < 100 && pushes(f).length === 0; i++) await new Promise((resolve) => setTimeout(resolve, 5));
  assert.equal(pushes(f).length, 1);
  await watch.stop();
  // LA-2h generation ordering: terminal records retain their generation.
  assert.deepEqual(JSON.parse(await readFile(f.file, "utf8")).records,
    [{ device: DEVICE, activityId: CONV, requestedAtMs: seededReport().requestedAtMs, kLast: 1_800_000_002, terminal: true }]);
});

test("v2 storage never persists legacy report rows", async (t) => {
  const f = await restoreFixture(t);
  const watch = await f.start();
  watch.report(DEVICE, seededReport());
  // Drain seed persistence, then switch to legacy (which must remove durable rows).
  await watch.stop();
  const next = await f.start();
  next.report(DEVICE, report());
  next.turn(CONV, { kind: "step", steps: 2 });
  await next.stop();
  // LA-2h generation ordering: legacy replacement leaves an ordering tombstone.
  assert.deepEqual(JSON.parse(await readFile(f.file, "utf8")).records, [{ device: DEVICE, activityId: CONV, requestedAtMs: seededReport().requestedAtMs, kLast: 1_800_000_001, terminal: true }]);
});

test("save warning includes operation and error code but no device or token", async () => {
  const f = await running();
  f.store.fail = true;
  f.watch.turn(CONV, { kind: "done" });
  await settle();
  assert.equal(f.warnings.length, 1);
  assert.match(f.warnings[0]!, /reserve.*push/i);
  assert.match(f.warnings[0]!, /ENOSPC/);
  assert.equal(f.warnings[0]!.includes(DEVICE), false);
  assert.equal(f.warnings[0]!.includes(seededReport().pushToken!), false);
  await f.watch.stop();
});

// Mode H: exercise row ownership through real saves, including the save receipt at send time.
async function modeHFixture(t: import("node:test").TestContext) {
  const f = await diskFixture(t);
  await f.watch.stop();
  const receipts: number[] = [];
  const save = f.store.save.bind(f.store);
  f.store.save = async (records) => {
    await save(records);
    receipts.push(...records.map((record) => record.kLast));
  };
  const sent: string[] = [];
  const received: { timestamp: number; saved: boolean }[] = [];
  const watches: InstanceType<typeof ActivityWatch<number>>[] = [];
  const owners = fixtureOwners();
  async function start() {
    const watch = fixtureWatch<number>({
      store: f.store, now: () => f.clock.now, warn: (message) => f.warnings.push(message),
      send: (raw) => {
        const message = JSON.parse(raw);
        if (message.type === "activityPush") received.push({ timestamp: message.timestamp, saved: receipts.includes(message.timestamp) });
        sent.push(raw);
      },
      setTimer: () => { assert.fail("advance clock before non-urgent Mode H changes"); }, clearTimer: () => {},
    }, owners);
    watches.push(watch);
    await watch.start();
    await watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
    assert.equal(watch.hostWriterReady, true);
    return watch;
  }
  t.after(async () => { for (const watch of watches) await watch.stop(); });
  return { ...f, watch: await start(), start, sent, received, owners };
}

const hTurn = { token: TOKEN, kind: "turn", state: "running", steps: 2, startedAt: T0 } as const;
const hNeeds = { token: "NNNNNNNNNNNNNNNN", kind: "needsYou", state: "running", startedAt: T0 } as const;
const hOther = { token: "KKKKKKKKKKKKKKKK", kind: "turn", state: "running", steps: 1, startedAt: T0 } as const;
const hNew = { token: "BBBBBBBBBBBBBBBB", kind: "turn", state: "running", steps: 1, startedAt: T0 } as const;
const hContent = { token: TOKEN, kind: "turn", state: "running", steps: 2, startedAt: 821692800 } as const;

for (const restart of [false, true]) {
  test(`Mode H stale same-binding report ${restart ? "after restart" : "in session"} preserves host steps`, async (t) => {
    const f = await modeHFixture(t);
    let watch = f.watch;
    watch.report(DEVICE, seededReport());
    watch.turn(CONV, { kind: "step", steps: 2 });
    await f.idle();
    assert.equal(pushes(f)[0].timestamp, 1_800_000_002);
    if (restart) { await watch.stop(); watch = await f.start(); }
    f.clock.now += STEP_INTERVAL_MS;
    watch.report(DEVICE, seededReport());
    await f.idle();
    assert.equal(pushes(f).length, 1, "stale report sends no content push");
    assert.deepEqual((await f.rows())[0].rows, [hTurn]);
    watch.turn(CONV, { kind: "done" });
    await f.idle();
    assert.deepEqual(pushes(f)[1].state.jobs, [{ ...hContent, state: "done", finishedAt: 821692815 }], "memory retains host steps too");
  });
}

for (const restart of [false, true]) {
  test(`Mode H terminal re-list ${restart ? "after restart" : "in session"} cannot resurrect a job`, async (t) => {
    const f = await modeHFixture(t);
    const initial = { ...seededReport(), jobs: [...seededReport().jobs, hOther], turns: { [TOKEN]: CONV, [hOther.token]: OTHER } };
    let watch = f.watch;
    watch.report(DEVICE, initial);
    watch.turn(CONV, { kind: "done" });
    await f.idle();
    assert.equal(pushes(f)[0].event, "update", "other running job keeps activity open");
    assert.deepEqual(pushes(f)[0].state.jobs, [
      { ...hOther, startedAt: 821692800 },
      { token: TOKEN, kind: "turn", state: "done", steps: 1, startedAt: 821692800, finishedAt: 821692800 },
    ]);
    if (restart) { await watch.stop(); watch = await f.start(); }
    f.clock.now += STEP_INTERVAL_MS;
    watch.report(DEVICE, initial);
    await f.idle();
    const record = (await f.rows())[0];
    assert.equal(record.rows.some((job: typeof hTurn) => job.token === TOKEN && job.state === "running"), false);
    assert.equal(Object.hasOwn(record.bindings, TOKEN), false, "ended job loses its binding");
    watch.turn(OTHER, { kind: "step", steps: 2 });
    await f.idle();
    assert.equal(pushes(f).at(-1).state.jobs.some((job: typeof hTurn) => job.token === TOKEN && job.state === "running"), false);
  });
}

for (const restart of [false, true]) {
  test(`Mode H rebind after ended job removal ${restart ? "after restart" : "in session"} is ignored`, async (t) => {
    const f = await modeHFixture(t);
    let watch = f.watch;
    const initial = { ...seededReport(), jobs: [...seededReport().jobs, hOther], turns: { [TOKEN]: CONV, [hOther.token]: OTHER } };
    watch.report(DEVICE, initial);
    watch.turn(CONV, { kind: "done" });
    await f.idle();
    watch.report(DEVICE, { ...initial, jobs: [hOther], turns: { [hOther.token]: OTHER } });
    await f.idle();
    assert.deepEqual((await f.rows())[0].rows, [hOther]);
    if (restart) { await watch.stop(); watch = await f.start(); }
    f.clock.now += STEP_INTERVAL_MS;
    watch.report(DEVICE, initial);
    await f.idle();
    assert.deepEqual((await f.rows())[0].rows, [hOther], "removed ended token must stay absent");
    assert.deepEqual((await f.rows())[0].bindings, { [hOther.token]: OTHER });
    watch.turn(OTHER, { kind: "step", steps: 2 });
    await f.idle();
    assert.deepEqual(pushes(f).at(-1).state.jobs, [{ ...hOther, steps: 2, startedAt: 821692800 }]);
  });
}

test("Mode H new job token on an ended conversation is a legitimate turn", async (t) => {
  const f = await modeHFixture(t);
  const initial = { ...seededReport(), jobs: [...seededReport().jobs, hOther], turns: { [TOKEN]: CONV, [hOther.token]: OTHER } };
  f.watch.report(DEVICE, initial);
  f.watch.turn(CONV, { kind: "done" });
  await f.idle();
  f.clock.now += STEP_INTERVAL_MS;
  f.owners.set(CONV, { steps: 1, startedAt: T0 });
  f.watch.report(DEVICE, { ...initial, jobs: [hOther, hNew], turns: { [hOther.token]: OTHER, [hNew.token]: CONV } });
  await f.idle();
  assert.equal(pushes(f)[1].timestamp, 1_800_000_003);
  assert.deepEqual(pushes(f)[1].state.jobs, [{ ...hOther, startedAt: 821692800 }, { ...hNew, startedAt: 821692800 }]);
  assert.deepEqual((await f.rows())[0].bindings, { [hOther.token]: OTHER, [hNew.token]: CONV });
  f.clock.now += STEP_INTERVAL_MS;
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await f.idle();
  assert.equal(pushes(f)[2].timestamp, 1_800_000_004);
  assert.deepEqual(pushes(f)[2].state.jobs, [{ ...hNew, steps: 2, startedAt: 821692800 }, { ...hOther, startedAt: 821692800 }]);
});

test("Mode H report omission removes a running job from snapshot and disk", async (t) => {
  const f = await modeHFixture(t);
  f.watch.report(DEVICE, { ...seededReport(), jobs: [...seededReport().jobs, hOther], turns: { [TOKEN]: CONV, [hOther.token]: OTHER } });
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await f.idle();
  f.watch.report(DEVICE, { ...seededReport(), jobs: [hTurn] });
  await f.idle();
  assert.equal(pushes(f).length, 2);
  assert.equal(pushes(f)[1].timestamp, 1_800_000_003);
  assert.deepEqual(pushes(f)[1].state.jobs, [hContent]);
  assert.deepEqual((await f.rows())[0].rows, [hTurn]);
  assert.deepEqual((await f.rows())[0].bindings, { [TOKEN]: CONV });
});

test("Mode H needsYou add and clear reserve fresh durable snapshots without changing turns", async (t) => {
  const f = await modeHFixture(t);
  f.watch.report(DEVICE, seededReport());
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await f.idle();
  f.watch.report(DEVICE, { ...seededReport(), jobs: [...seededReport().jobs, hNeeds] });
  await f.idle();
  assert.equal(pushes(f).length, 2, "needsYou report sends exactly one push");
  assert.equal(pushes(f)[1].timestamp, 1_800_000_003);
  assert.deepEqual(pushes(f)[1].state.jobs.toSorted((a, b) => a.token.localeCompare(b.token)), [hContent, { ...hNeeds, startedAt: 821692800 }]);
  assert.deepEqual(f.received, [{ timestamp: 1_800_000_002, saved: true }, { timestamp: 1_800_000_003, saved: true }]);
  assert.deepEqual((await f.rows())[0].rows.toSorted((a, b) => a.token.localeCompare(b.token)), [hTurn, hNeeds]);
  f.watch.report(DEVICE, seededReport());
  await f.idle();
  assert.equal(pushes(f).length, 3);
  assert.equal(pushes(f)[2].timestamp, 1_800_000_004);
  assert.deepEqual(pushes(f)[2].state.jobs, [hContent]);
  assert.deepEqual((await f.rows())[0].rows, [hTurn]);
  assert.equal(f.received[2].saved, true);
});

for (const restart of [false, true]) {
  test(`Mode H pending preserves rows bindings and sent ${restart ? "across restart" : "in memory and disk"}`, async (t) => {
    const f = await modeHFixture(t);
    let watch = f.watch;
    watch.report(DEVICE, seededReport());
    watch.turn(CONV, { kind: "step", steps: 2 });
    await f.idle();
    const before = (await f.rows())[0];
    assert.deepEqual(before.rows, [hTurn]);
    assert.deepEqual(before.bindings, { [TOKEN]: CONV });
    assert.deepEqual(before.sent, [hTurn]);
    watch.report(DEVICE, { activityId: CONV, requestedAtMs: 1_800_000_000_500, jobs: [], turns: {} });
    await f.idle();
    const pending = (await f.rows())[0];
    assert.deepEqual({ rows: pending.rows, bindings: pending.bindings, sent: pending.sent },
      { rows: before.rows, bindings: before.bindings, sent: before.sent });
    assert.equal(pushes(f).length, 1);
    if (restart) {
      await watch.stop();
      f.sent.length = 0;
      watch = await f.start();
      assert.deepEqual(f.sent, [], "pending restart has no transport token to replay");
    }
    f.clock.now += STEP_INTERVAL_MS;
    const count = pushes(f).length;
    watch.report(DEVICE, { ...seededReport(), jobs: [hTurn] });
    await f.idle();
    assert.deepEqual(JSON.parse(f.sent.at(-1)!), { type: "activityToken", device: DEVICE, token: "ab".repeat(32) });
    assert.equal(pushes(f).length, count, "token report resumes unchanged in-memory rows without push");
    watch.turn(CONV, { kind: "step", steps: 3 });
    await f.idle();
    assert.equal(pushes(f).at(-1).timestamp, 1_800_000_003);
    assert.deepEqual(pushes(f).at(-1).state.jobs, [{ ...hContent, steps: 3 }]);
  });
}

// These maps are injected owner observations, never app-report reducers.
async function ownerFixture(t: import("node:test").TestContext) {
  const disk = await diskFixture(t);
  await disk.watch.stop();
  const owners = new Map<string, OwnerRun>();
  const sent: string[] = [];
  const watches: InstanceType<typeof ActivityWatch<number>>[] = [];
  const saves: import("../src/activitystore.ts").ActivityRecord[][] = [];
  const save = disk.store.save.bind(disk.store);
  disk.store.save = async (records) => { await save(records); saves.push(structuredClone(records)); };
  async function start(register = true) {
    const watch = new ActivityWatch<number>({
      store: disk.store, liveTurn: (convId: string) => owners.get(convId),
      now: () => disk.clock.now, warn: (message) => disk.warnings.push(message),
      send: (raw) => {
        const msg = JSON.parse(raw);
        if (msg.type === "activityPush") assert.ok(saves.some((records) => records.some((r) => r.kLast === msg.timestamp)), "save before send");
        sent.push(raw);
      },
      setTimer: () => 0, clearTimer: () => {},
    });
    watches.push(watch);
    await watch.start();
    if (register) await watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
    return watch;
  }
  t.after(async () => { for (const watch of watches) await watch.stop(); });
  const live = (convId = CONV, steps = 1, startedAt = T0) => owners.set(convId, { steps, startedAt });
  const reportRows = (watch: InstanceType<typeof ActivityWatch<number>>, jobs: ActivityReport["jobs"], turns: Record<string, string>) => {
    disk.clock.now += STEP_INTERVAL_MS;
    watch.report(DEVICE, { ...seededReport(), jobs, turns });
  };
  return { ...disk, sent, saves, owners, live, start, reportRows, watch: await start() };
}
const tokenAt = (i: number) => i.toString(16).padStart(16, "0");
const convAt = (i: number) => `${i.toString(16).padStart(8, "0")}-0000-4000-8000-000000000000`;
const turnRow = (token = TOKEN, steps = 1): ActivityReport["jobs"][number] => ({ token, kind: "turn", state: "running", steps, startedAt: T0 });
const keeper = { token: "RRRRRRRRRRRRRRRR", kind: "recording", state: "running", startedAt: T0 } as const;

for (const count of [65, 1025]) {
  // red: behavioural
  test(`U1 ${count} ended tokens never resurrect, including on disk restart`, async (t) => {
    const f = await ownerFixture(t);
    for (let i = 0; i < count; i++) {
      f.live(convAt(i));
      f.reportRows(f.watch, [keeper, turnRow(tokenAt(i))], { [tokenAt(i)]: convAt(i) });
      await f.idle();
      f.owners.delete(convAt(i));
      f.watch.turn(convAt(i), { kind: "gone" });
      await f.idle();
    }
    for (const restart of [false, true]) {
      if (restart) { await f.watch.stop(); f.watch = await f.start(); }
      f.live(convAt(0), 7);
      f.reportRows(f.watch, [keeper, turnRow(tokenAt(0), 7)], { [tokenAt(0)]: convAt(0) });
      await f.idle();
      const row = (await f.rows())[0];
      assert.ok(!row.rows.some((r: { token: string }) => r.token === tokenAt(0)));
      assert.equal(Object.hasOwn(row.bindings, tokenAt(0)), false);
      assert.ok((row.ended ?? []).includes(tokenAt(0)));
      const before = pushes(f).length;
      f.live(convAt(0), 8);
      f.watch.turn(convAt(0), { kind: "step", steps: 8 });
      await f.idle();
      assert.equal(pushes(f).length, before);
    }
  });
}

// red: behavioural
test("U2 capacity stores no unseen token, warns once, still ends admitted rows", async (t) => {
  const f = await ownerFixture(t);
  // End 1023 tokens, then admit the final slot. Reports remain small enough for wire limits.
  for (let i = 0; i < 1023; i++) {
    f.reportRows(f.watch, [keeper, turnRow(tokenAt(i))], { [tokenAt(i)]: convAt(i) });
    await f.idle(); // No owner: each token becomes ended.
  }
  f.live(CONV);
  f.reportRows(f.watch, [keeper, turnRow()], { [TOKEN]: CONV });
  await f.idle();
  for (let i = 1023; i < 1025; i++) {
    f.live(convAt(i));
    f.reportRows(f.watch, [keeper, turnRow(), turnRow(tokenAt(i))], { [TOKEN]: CONV, [tokenAt(i)]: convAt(i) });
    await f.idle();
    const r = (await f.rows())[0];
    assert.ok(!r.rows.some((j: { token: string }) => j.token === tokenAt(i)));
    assert.equal(Object.hasOwn(r.bindings, tokenAt(i)), false);
    assert.ok(!(r.ended ?? []).includes(tokenAt(i)));
  }
  assert.equal(f.warnings.length, 1);
  f.owners.delete(CONV);
  f.watch.turn(CONV, { kind: "done" });
  await f.idle();
  assert.equal(pushes(f).at(-1).state.jobs.find((r: { token: string }) => r.token === TOKEN).state, "done");
  assert.ok(((await f.rows())[0].ended ?? []).includes(TOKEN));
});

for (const state of ["running", "done"] as const) {
  // red: behavioural
  test(`U3 owner overrides app ${state}, steps and startedAt forever`, async (t) => {
    const f = await ownerFixture(t);
    f.live(CONV, 2, T0 - 10_000);
    f.reportRows(f.watch, [keeper, { ...turnRow(TOKEN, 999), state }], { [TOKEN]: CONV });
    await f.idle();
    f.reportRows(f.watch, [keeper, { ...turnRow(TOKEN, 999), state }, hNeeds], { [TOKEN]: CONV });
    await f.idle();
    assert.deepEqual(pushes(f).at(-1).state.jobs.find((r: { token: string }) => r.token === TOKEN),
      { token: TOKEN, kind: "turn", state: "running", steps: 2, startedAt: 821692790 });
  });
}

// red: behavioural
test("U3 absent owner tombstones unseen token; later run and reused token stay hidden", async (t) => {
  const f = await ownerFixture(t);
  f.reportRows(f.watch, [keeper, turnRow()], { [TOKEN]: CONV });
  await f.idle();
  assert.ok(((await f.rows())[0].ended ?? []).includes(TOKEN));
  f.watch.turn(CONV, { kind: "gone" });
  f.live(CONV, 7);
  f.reportRows(f.watch, [keeper, turnRow(TOKEN, 7)], { [TOKEN]: CONV });
  await f.idle();
  assert.deepEqual((await f.rows())[0].rows, [keeper]);
  assert.equal(Object.hasOwn((await f.rows())[0].bindings, TOKEN), false);
});

for (const state of ["done", "failed"] as const) {
  // red: behavioural
  test(`U4 unbound ${state} omitted; needsYou follows latest membership`, async (t) => {
    const f = await ownerFixture(t);
    f.live();
    f.reportRows(f.watch, [keeper, { ...turnRow(), state }, hNeeds], {});
    await f.idle();
    assert.deepEqual((await f.rows())[0].rows, [keeper, hNeeds]);
    f.reportRows(f.watch, [keeper], {});
    await f.idle();
    assert.deepEqual((await f.rows())[0].rows, [keeper]);
    assert.deepEqual(pushes(f).at(-1).state.jobs.map((r: { token: string }) => r.token), [keeper.token]);
  });
}

// red: behavioural
test("U5 relayDown done persists without k, survives restart and stale re-report", async (t) => {
  const f = await ownerFixture(t);
  f.live();
  f.reportRows(f.watch, [keeper, turnRow()], { [TOKEN]: CONV });
  await f.idle();
  const k = (await f.rows())[0].kLast;
  f.watch.relayDown();
  f.owners.delete(CONV);
  f.watch.turn(CONV, { kind: "done" });
  await f.watch.stop();
  const saved = (await f.rows())[0];
  assert.equal(saved.kLast, k);
  assert.ok((saved.ended ?? []).includes(TOKEN));
  assert.ok(!saved.rows.some((r: { token: string; state: string }) => r.token === TOKEN && r.state === "running"));
  // LA-2g round 1 rule 1: save the host done row, including its steps and finish time, before the stale app report.
  const doneRow = saved.rows.find((r: { token: string }) => r.token === TOKEN);
  assert.deepEqual(doneRow, { ...turnRow(), state: "done", finishedAt: f.clock.now });
  f.sent.length = 0;
  f.watch = await f.start(false);
  assert.deepEqual(pushes(f), []);
  f.reportRows(f.watch, [keeper, turnRow()], { [TOKEN]: CONV });
  await f.idle();
  await f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  await f.idle();
  assert.ok(pushes(f).length <= 1);
  // LA-2g round 1 rule 1: any pushed TOKEN stays host-done; content dates are seconds since 2001-01-01.
  assert.ok(pushes(f).every((p) => p.timestamp > k));
  for (const p of pushes(f)) {
    for (const row of p.state.jobs.filter((r: { token: string }) => r.token === TOKEN)) {
      assert.deepEqual(row, { ...doneRow, startedAt: (doneRow.startedAt - 978_307_200_000) / 1000, finishedAt: (doneRow.finishedAt - 978_307_200_000) / 1000 });
    }
  }
  // LA-2g round 1 rule 1: reportRows advances only 15 s after done (< 120 s linger), so sorted disk rows retain keeper then host-done.
  assert.deepEqual((await f.rows())[0].rows, [keeper, doneRow]);
});

for (const live of [false, true]) {
  // red: behavioural
  test(`U6/U7 restart ${live ? "in process keeps owner steps" : "empty owner reconciles before any push"}`, async (t) => {
    const f = await ownerFixture(t);
    f.live();
    f.reportRows(f.watch, [keeper, turnRow()], { [TOKEN]: CONV });
    await f.idle();
    await f.watch.stop();
    const k = (await f.rows())[0].kLast;
    if (live) f.live(CONV, 4); else f.owners.clear(); // No watch event delivered.
    f.sent.length = 0;
    f.watch = await f.start(false);
    await f.idle();
    assert.deepEqual(f.sent, []);
    const r = (await f.rows())[0];
    assert.equal(r.kLast, k);
    if (live) assert.deepEqual(r.rows.find((j: { token: string }) => j.token === TOKEN), turnRow(TOKEN, 4));
    else {
      assert.ok((r.ended ?? []).includes(TOKEN));
      assert.equal(Object.hasOwn(r.bindings, TOKEN), false);
      assert.ok(!r.rows.some((j: { token: string }) => j.token === TOKEN));
    }
    await f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
    await f.idle();
    f.reportRows(f.watch, [keeper, hNeeds], {});
    await f.idle();
    assert.ok(pushes(f).length > 0);
    assert.ok(pushes(f).every((p) => p.timestamp > k));
  });
}

for (const finished of [false, true]) {
  // red: behavioural
  test(`U8 report omits ${finished ? "finished lingering" : "running"} row permanently`, async (t) => {
    const f = await ownerFixture(t);
    f.live();
    f.reportRows(f.watch, [keeper, turnRow()], { [TOKEN]: CONV });
    await f.idle();
    if (finished) {
      f.owners.delete(CONV); f.watch.turn(CONV, { kind: "done" }); await f.idle();
      assert.equal(Object.hasOwn((await f.rows())[0].bindings, TOKEN), false, "terminal token immediately loses binding");
    }
    f.reportRows(f.watch, [keeper], {});
    await f.idle();
    const r = (await f.rows())[0];
    assert.deepEqual(r.rows, [keeper]);
    assert.ok((r.ended ?? []).includes(TOKEN));
    assert.equal(Object.hasOwn(r.bindings, TOKEN), false);
    assert.deepEqual(pushes(f).at(-1).state.jobs.map((j: { token: string }) => j.token), [keeper.token]);
    f.live();
    f.reportRows(f.watch, [keeper, turnRow()], { [TOKEN]: CONV });
    await f.idle();
    assert.deepEqual((await f.rows())[0].rows, [keeper]);
  });
}

for (const first of ["done", "failed"] as const) {
  // red: behavioural
  test(`U9 overlapping A ${first}, B gone uses owner then terminal history`, async (t) => {
    const f = await ownerFixture(t);
    f.live(CONV, 1);
    f.reportRows(f.watch, [keeper, turnRow()], { [TOKEN]: CONV });
    await f.idle();
    f.live(CONV, 4, T0 + 100); // B is newest; A still live until following event.
    f.clock.now += STEP_INTERVAL_MS;
    f.watch.turn(CONV, { kind: first }); // A exits; B remains owner.
    await f.idle();
    assert.equal(pushes(f).at(-1).state.jobs.find((j: { token: string }) => j.token === TOKEN).state, "running");
    assert.equal(pushes(f).at(-1).state.jobs.find((j: { token: string }) => j.token === TOKEN).steps, 4);
    f.owners.delete(CONV);
    f.watch.turn(CONV, { kind: "gone" });
    await f.idle();
    const row = pushes(f).at(-1).state.jobs.find((j: { token: string }) => j.token === TOKEN);
    if (first === "done") { assert.equal(row.state, "done"); assert.equal(typeof row.finishedAt, "number"); }
    else assert.equal(row, undefined);
    assert.ok(((await f.rows())[0].ended ?? []).includes(TOKEN));
  });
}

// red: behavioural
test("U10 message before report admits; report before message stays hidden", async (t) => {
  const f = await ownerFixture(t);
  f.live(CONV, 2);
  f.reportRows(f.watch, [keeper, turnRow(), hOther], { [TOKEN]: CONV, [hOther.token]: OTHER });
  await f.idle();
  assert.deepEqual((await f.rows())[0].rows, [keeper, turnRow(TOKEN, 2)]);
  f.live(OTHER, 7);
  f.watch.turn(OTHER, { kind: "step", steps: 7 });
  f.reportRows(f.watch, [keeper, turnRow(), hOther, hNeeds], { [TOKEN]: CONV, [hOther.token]: OTHER });
  await f.idle();
  assert.ok(!pushes(f).at(-1).state.jobs.some((j: { token: string }) => j.token === hOther.token));
});

// red: API-adapted (liveTurn option). Runtime compatibility control stays green on frozen2f.
test("legacy identical literal push sequence with empty liveTurn option", async () => {
  const sent: string[] = [];
  const watch = new ActivityWatch({ store: memoryStore(), liveTurn: () => undefined,
    send: (raw) => sent.push(raw), warn: () => {}, now: () => T0, setTimer: () => 0, clearTimer: () => {} });
  await watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  watch.report(DEVICE, report());
  watch.turn(CONV, { kind: "step", steps: 2 });
  watch.turn(CONV, { kind: "done" });
  assert.deepEqual(sent.map((s) => JSON.parse(s)), [
    { type: "activityToken", device: DEVICE, token: "ab".repeat(32) },
    { type: "activityPush", device: DEVICE, event: "update", priority: 5, state: { jobs: [{ token: TOKEN, kind: "turn", state: "running", steps: 2, startedAt: 821692800 }] }, staleDate: 1800000900 },
    { type: "activityPush", device: DEVICE, event: "end", priority: 10, state: { jobs: [{ token: TOKEN, kind: "turn", state: "done", steps: 2, startedAt: 821692800, finishedAt: 821692800 }] }, staleDate: 1800000120, dismissalDate: 1800000120 },
  ]);
  await watch.stop();
});

// red: behavioural
test("U9 final failed run uses owner steps and records finishedAt", async (t) => {
  const f = await ownerFixture(t);
  f.live(CONV, 2);
  f.reportRows(f.watch, [keeper, turnRow(TOKEN, 999)], { [TOKEN]: CONV });
  await f.idle();
  f.owners.delete(CONV);
  f.watch.turn(CONV, { kind: "failed" });
  await f.idle();
  assert.deepEqual(pushes(f).at(-1).state.jobs.find((j: { token: string }) => j.token === TOKEN), {
    token: TOKEN, kind: "turn", state: "failed", steps: 2,
    startedAt: 821692800, finishedAt: 821692815,
  });
  assert.ok(((await f.rows())[0].ended ?? []).includes(TOKEN));
  assert.equal(Object.hasOwn((await f.rows())[0].bindings, TOKEN), false);
});

for (const state of ["done", "failed"] as const) {
  test(`R1 unbound re-list preserves host ${state} row when needsYou is added`, async (t) => {
    const f = await ownerFixture(t);
    f.live(CONV, 3);
    f.reportRows(f.watch, [keeper, turnRow()], { [TOKEN]: CONV });
    await f.idle();
    f.owners.delete(CONV);
    f.watch.turn(CONV, { kind: state });
    await f.idle();
    const host = { token: TOKEN, kind: "turn", state, steps: 3, startedAt: 821692800, finishedAt: 821692815 };
    assert.deepEqual(pushes(f).at(-1).state.jobs.find((j: { token: string }) => j.token === TOKEN), host);

    f.reportRows(f.watch, [keeper, { ...turnRow(TOKEN, 999), state: "done", finishedAt: T0 }, hNeeds], {});
    await f.idle();
    const jobs = pushes(f).at(-1).state.jobs;
    assert.deepEqual(jobs.find((j: { token: string }) => j.token === TOKEN), host);
    assert.ok(jobs.some((j: { token: string }) => j.token === hNeeds.token));
    assert.deepEqual((await f.rows())[0].rows.find((j: { token: string }) => j.token === TOKEN), {
      token: TOKEN, kind: "turn", state, steps: 3, startedAt: T0, finishedAt: T0 + STEP_INTERVAL_MS,
    });
    assert.equal(Object.hasOwn((await f.rows())[0].bindings, TOKEN), false);
  });
}

test("R2 legacy settled leaves sent sequence, jobs and held timer unchanged", () => {
  const f = fixture();
  f.register();
  f.watch.report(DEVICE, report());
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  f.clock.now += 1_000;
  f.watch.turn(CONV, { kind: "step", steps: 3 });
  const sent = [...f.sent];
  const timers = [...f.timers];
  f.clock.now += 1_000;
  f.watch.turn(CONV, { kind: "settled" });
  assert.deepEqual(f.sent, sent);
  assert.deepEqual([...f.timers], timers);
  f.fire();
  assert.deepEqual(pushes(f).map((p) => p.state.jobs[0].steps), [2, 3]);
  f.watch.turn(CONV, { kind: "done" });
  assert.deepEqual(pushes(f).at(-1).state.jobs, [{
    token: TOKEN, kind: "turn", state: "done", steps: 3, startedAt: 821692800, finishedAt: 821692815,
  }]);
});

for (const replied of [false, true]) {
  test(`R2 re-report settles ownerless running row ${replied ? "with prior reply as done" : "without reply as gone"}`, async (t) => {
    const f = await ownerFixture(t);
    f.live(CONV, 3);
    f.reportRows(f.watch, [keeper, turnRow()], { [TOKEN]: CONV });
    await f.idle();
    if (replied) { f.watch.turn(CONV, { kind: "done" }); await f.idle(); }
    f.owners.delete(CONV); // Owner disappears without a watch event.
    f.reportRows(f.watch, [keeper, turnRow()], { [TOKEN]: CONV });
    await f.idle();
    const row = (await f.rows())[0];
    assert.ok(row.ended.includes(TOKEN));
    assert.equal(Object.hasOwn(row.bindings, TOKEN), false);
    assert.deepEqual(row.rows, replied ? [keeper, {
      token: TOKEN, kind: "turn", state: "done", steps: 3, startedAt: T0, finishedAt: T0 + 2 * STEP_INTERVAL_MS,
    }] : [keeper]);
    assert.deepEqual(pushes(f).at(-1).state.jobs.map((j: { token: string; state: string }) => [j.token, j.state]),
      replied ? [[keeper.token, "running"], [TOKEN, "done"]] : [[keeper.token, "running"]]);
  });
}

test("R3 reconnect pushes offline terminal once at kLast + 1 and unchanged reconnect burns no k", async (t) => {
  const f = await ownerFixture(t);
  f.live(CONV, 3);
  f.reportRows(f.watch, [turnRow()], { [TOKEN]: CONV });
  await f.idle();
  const k = (await f.rows())[0].kLast;
  f.watch.relayDown();
  f.sent.length = 0;
  await f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  await f.idle();
  assert.deepEqual(pushes(f), []);
  assert.equal((await f.rows())[0].kLast, k);

  f.watch.relayDown();
  f.owners.delete(CONV);
  f.watch.turn(CONV, { kind: "done" });
  await f.idle();
  assert.deepEqual(pushes(f), []);
  const persisted = (await f.rows())[0];
  assert.equal(persisted.kLast, k);
  assert.ok(persisted.ended.includes(TOKEN));
  await f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  await f.idle();
  assert.equal(pushes(f).length, 1);
  assert.equal(pushes(f)[0].timestamp, persisted.kLast + 1);
  assert.equal(pushes(f)[0].event, "end");
  assert.deepEqual(pushes(f)[0].state.jobs, [{
    token: TOKEN, kind: "turn", state: "done", steps: 3, startedAt: 821692800, finishedAt: 821692815,
  }]);
  // LA-2h generation ordering: terminal records retain their generation.
  assert.deepEqual((await f.rows())[0], { device: DEVICE, activityId: CONV, requestedAtMs: seededReport().requestedAtMs, kLast: k + 1, terminal: true });
  await f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
  await f.idle();
  assert.equal(pushes(f).length, 1);
  assert.equal((await f.rows())[0].kLast, k + 1);
});

test("R4 admitted token ignores rebind: only original conversation events change it", async (t) => {
  const f = await ownerFixture(t);
  f.live(CONV, 2);
  f.live(OTHER, 7);
  f.reportRows(f.watch, [keeper, turnRow()], { [TOKEN]: CONV });
  await f.idle();
  f.reportRows(f.watch, [keeper, turnRow()], { [TOKEN]: OTHER });
  await f.idle();
  const before = pushes(f).length;
  f.watch.turn(OTHER, { kind: "step", steps: 7 });
  await f.idle();
  assert.equal(pushes(f).length, before);
  assert.equal((await f.rows())[0].bindings[TOKEN], CONV);
  f.live(CONV, 4);
  f.watch.turn(CONV, { kind: "step", steps: 4 });
  await f.idle();
  assert.equal(pushes(f).at(-1).state.jobs.find((j: { token: string }) => j.token === TOKEN).steps, 4);
  f.owners.delete(CONV);
  f.watch.turn(CONV, { kind: "done" });
  await f.idle();
  assert.equal(pushes(f).at(-1).state.jobs.find((j: { token: string }) => j.token === TOKEN).state, "done");
});

const generationReport = (activityId = CONV, requestedAtMs = T0): ActivityReport => ({
  ...seededReport(), activityId, requestedAtMs,
});
const terminalKeys = ["activityId", "device", "kLast", "requestedAtMs", "terminal"];

for (const restart of [false, true]) {
  test(`G1 stale A1 cannot replace ended A2 ${restart ? "after disk restart" : "in session"}`, async (t) => {
    const f = await diskFixture(t);
    const a1 = generationReport();
    const a2 = generationReport(OTHER, T0 + 60_000);
    f.watch.report(DEVICE, a1);
    await f.idle();
    f.watch.report(DEVICE, a2);
    await f.idle();
    f.watch.turn(CONV, { kind: "step", steps: 2 });
    await f.idle();
    f.watch.turn(CONV, { kind: "done" });
    await f.idle();
    const K = 1_800_000_062;
    assert.equal(pushes(f).at(-1).event, "end");
    assert.equal(pushes(f).at(-1).timestamp, K);
    if (restart) {
      await f.watch.stop();
      f.watch = f.make(new DiskStore(f.file, diskLock));
      await f.watch.start();
      await f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
    }
    const bytes = await readFile(f.file, "utf8");
    const before = f.sent.length;
    const healthy = f.watch.hostWriterReady;
    f.watch.report(DEVICE, a1);
    await f.idle();
    assert.equal(await readFile(f.file, "utf8"), bytes, "G1 stale A1 must leave disk bytes identical");
    assert.equal(f.sent.length, before, "G1 stale A1 must send no token or push");
    assert.equal(f.watch.hostWriterReady, healthy, "G1 rejection must preserve health");
    f.watch.report(DEVICE, a2);
    f.watch.turn(CONV, { kind: "done" });
    await f.idle();
    assert.equal(f.sent.length, before, "G1 terminal A2 re-report must be ignored");
    assert.deepEqual(await f.rows(), [{ device: DEVICE, activityId: OTHER, requestedAtMs: T0 + 60_000, kLast: K, terminal: true }]);
    assert.ok(pushes({ sent: f.sent.slice(before) }).every((p) => p.timestamp > K), "G1 no timestamp reuse after A2 end");
  });
}

for (const [first, second] of [[CONV, OTHER], [OTHER, CONV]]) {
  test(`G2 equal generation rejects different id ${first} to ${second}`, async (t) => {
    const f = await diskFixture(t);
    f.watch.report(DEVICE, generationReport(first));
    await f.idle();
    const bytes = await readFile(f.file, "utf8");
    const healthy = f.watch.hostWriterReady;
    const before = f.sent.length;
    f.watch.report(DEVICE, generationReport(second));
    await f.idle();
    assert.equal(await readFile(f.file, "utf8"), bytes, "G2 equal-generation different id must leave bytes unchanged");
    assert.equal(f.watch.hostWriterReady, healthy, "G2 rejection must preserve health");
    assert.equal(f.sent.length, before, "G2 equal-generation different id must send nothing");
  });
}

for (const offset of [1_000, -1_000]) {
  for (const transport of ["rotated", "pending", "same"] as const) {
    test(`G3 same id rejects generation ${offset} with ${transport} token`, async (t) => {
      const f = await diskFixture(t);
      const initial = generationReport();
      f.watch.report(DEVICE, initial);
      f.watch.turn(CONV, { kind: "step", steps: 2 });
      await f.idle();
      const bytes = await readFile(f.file, "utf8");
      const k = (await f.rows())[0].kLast;
      const before = f.sent.length;
      const healthy = f.watch.hostWriterReady;
      f.watch.report(DEVICE, { ...initial, requestedAtMs: T0 + offset,
        pushToken: transport === "pending" ? undefined : transport === "rotated" ? "cd".repeat(32) : initial.pushToken });
      await f.idle();
      assert.equal(await readFile(f.file, "utf8"), bytes, "G3 altered same-id generation must leave disk bytes identical");
      assert.equal(f.sent.length, before, "G3 altered same-id generation must send nothing");
      assert.equal(f.watch.hostWriterReady, healthy, "G3 rejection must preserve health");
      assert.equal((await f.rows())[0].requestedAtMs, T0);
      assert.equal((await f.rows())[0].kLast, k);
      f.clock.now += STEP_INTERVAL_MS;
      f.watch.report(DEVICE, { ...initial, pushToken: "ef".repeat(32) });
      await f.idle();
      assert.ok(f.sent.slice(before).some((raw) => JSON.parse(raw).token === "ef".repeat(32)), "G3 next valid report still registers token");
      f.watch.turn(CONV, { kind: "step", steps: 3 });
      await f.idle();
      assert.equal(pushes(f).at(-1).timestamp, k + 1, "G3 rejected report must not burn k");
    });
  }
}

const frozen2gRecord = () => ({ device: DEVICE, activityId: CONV, token: "ab".repeat(32),
  kLast: 1_800_000_002, terminal: false, rows: seededReport().jobs, bindings: seededReport().turns, sent: seededReport().jobs });
for (const [name, data] of [
  ["frozen2g v2", { v: 2, records: [frozen2gRecord()] }],
  ["v3 missing requestedAtMs", { v: 3, records: [frozen2gRecord()] }],
  ["v3 kLast below rounded generation", { v: 3, records: [{ ...frozen2gRecord(), requestedAtMs: T0 + 2_500 }] }],
] as const) {
  test(`G4 ${name} stays unavailable and byte-identical through start, registration and report`, async (t) => {
    const f = await diskFixture(t);
    await f.watch.stop();
    const { writeFile } = await import("node:fs/promises");
    const bytes = JSON.stringify(data);
    await writeFile(f.file, bytes);
    f.watch = f.make(new DiskStore(f.file, diskLock));
    await f.watch.start();
    assert.equal(await readFile(f.file, "utf8"), bytes);
    await f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
    const ready = f.watch.hostWriterReady;
    f.watch.report(DEVICE, generationReport(OTHER, T0 + 60_000));
    f.watch.turn(CONV, { kind: "done" });
    await f.idle();
    assert.equal(ready, false, "G4 invalid or v2 file must never advertise hostWriterReady");
    assert.equal(f.watch.hostWriterReady, false);
    assert.equal(await readFile(f.file, "utf8"), bytes, "G4 unavailable store must never be deleted or rewritten");
    assert.deepEqual(pushes(f), [], "G4 unavailable store must send no pushes");
  });
}

test("G5 newer A2 replaces held A1 reservation; delayed A1 stays rejected", async (t) => {
  const f = await diskFixture(t);
  const a1 = generationReport();
  const a2 = generationReport(OTHER, T0 + 60_000);
  f.watch.report(DEVICE, a1);
  await f.idle();
  f.store.hold = true;
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  for (let i = 0; i < 100 && !f.store.entered; i++) await delay(1);
  assert.equal(f.store.entered, true, "G5 A1 reservation must be in flight");
  f.watch.report(DEVICE, a2);
  f.store.unblock!();
  await f.idle();
  assert.deepEqual(pushes(f), [], "G5 superseded A1 reservation must never push");
  assert.deepEqual((await f.rows()).map((r: { activityId: string }) => r.activityId), [OTHER]);
  f.watch.turn(CONV, { kind: "done" });
  await f.idle();
  assert.deepEqual(pushes(f).map((p) => p.timestamp), [Math.ceil(a2.requestedAtMs! / 1000) + 1], "G5 A2 starts after its own seed");
  const bytes = await readFile(f.file, "utf8");
  const before = f.sent.length;
  f.watch.report(DEVICE, a1);
  await f.idle();
  assert.equal(await readFile(f.file, "utf8"), bytes, "G5 delayed A1 must leave A2 disk bytes identical");
  assert.equal(f.sent.length, before);
});

test("G6 real terminal disk record has exactly five redacted fields", async (t) => {
  const f = await diskFixture(t);
  f.watch.report(DEVICE, generationReport());
  f.watch.turn(CONV, { kind: "done" });
  await f.idle();
  const data = JSON.parse(await readFile(f.file, "utf8"));
  assert.deepEqual(Object.keys(data.records[0]).sort(), terminalKeys, "G6 terminal tombstone must have exactly five fields");
  assert.equal(data.v, 3);
  assert.deepEqual(data.records, [{ device: DEVICE, activityId: CONV, requestedAtMs: T0, kLast: 1_800_000_001, terminal: true }]);
});

for (const action of ["revoke", "legacy no-token", "legacy token"] as const) {
  test(`G8 ${action} preserves non-terminal A2 generation as tombstone`, async (t) => {
    const f = await diskFixture(t);
    const a1 = generationReport();
    const a2 = generationReport(OTHER, T0 + 60_000);
    f.watch.report(DEVICE, a1);
    await f.idle();
    f.watch.report(DEVICE, a2);
    f.watch.turn(CONV, { kind: "step", steps: 2 });
    await f.idle();
    const k = (await f.rows())[0].kLast;
    if (action === "revoke") f.watch.forget(DEVICE, true);
    else f.watch.report(DEVICE, action === "legacy token" ? report() : { jobs: [], turns: {} });
    await f.idle();
    assert.deepEqual(await f.rows(), [{ device: DEVICE, activityId: OTHER, requestedAtMs: T0 + 60_000, kLast: k, terminal: true }], "G8 forget/legacy must retain A2 five-field tombstone");
    const bytes = await readFile(f.file, "utf8");
    const before = f.sent.length;
    const healthy = f.watch.hostWriterReady;
    f.watch.report(DEVICE, a1);
    await f.idle();
    assert.equal(await readFile(f.file, "utf8"), bytes, "G8 stale A1 cannot replace forgotten A2");
    assert.equal(f.watch.hostWriterReady, healthy, "G8 rejection must preserve health");
    f.watch.report(DEVICE, a2);
    await f.idle();
    assert.equal(await readFile(f.file, "utf8"), bytes);
    assert.equal(f.sent.length, before, "G8 stale A1 and terminal A2 must send nothing");
    assert.ok(pushes({ sent: f.sent.slice(before) }).every((p) => p.timestamp > k), "G8 no k reuse");
  });
}

test("G2 kLast is a reservation, never the generation replacement gate", async (t) => {
  const f = await diskFixture(t);
  f.watch.report(DEVICE, generationReport());
  await f.idle();
  for (let steps = 2; steps <= 4; steps++) {
    f.clock.now += STEP_INTERVAL_MS;
    f.watch.turn(CONV, { kind: "step", steps });
    await f.idle();
  }
  assert.equal((await f.rows())[0].kLast, 1_800_000_003);
  f.watch.report(DEVICE, generationReport(OTHER, T0 + 1_000));
  await f.idle();
  assert.equal((await f.rows())[0].activityId, OTHER, "newer generation must replace even below previous kLast");
  assert.equal((await f.rows())[0].requestedAtMs, T0 + 1_000, "generation must persist independently of kLast");
});

// END counterpart of "same activity rotation invalidates an old-token reservation in flight".
test("LA-2i M1 [behaviour] held END uses rotated token and keeps terminal reservation", async (t) => {
  const f = await diskFixture(t);
  f.watch.report(DEVICE, seededReport());
  await f.idle();
  const k = (await f.rows())[0].kLast + 1;
  const save = f.store.save.bind(f.store);
  let held: import("../src/activitystore.ts").ActivityRecord[] | undefined;
  f.store.save = async (rows) => {
    if (!held && rows.some((row) => row.device === DEVICE && row.terminal)) {
      held = structuredClone(rows);
      f.store.hold = true;
    }
    await save(rows);
  };
  f.watch.turn(CONV, { kind: "done" });
  for (let i = 0; i < 100 && !f.store.entered; i++) await delay(10);
  assert.ok(f.store.entered, "END reservation must enter held save");
  assert.equal(held![0].kLast, k);
  f.watch.report(DEVICE, { ...seededReport(), pushToken: "cd".repeat(32) });
  f.store.unblock!();
  await f.idle();
  const tombstone = { device: DEVICE, activityId: CONV, requestedAtMs: seededReport().requestedAtMs, kLast: k, terminal: true };
  assert.deepEqual(await f.rows(), [tombstone], "held END must retain five-field terminal tombstone");
  const after = f.sent.length;
  f.watch.report(DEVICE, { ...seededReport(), pushToken: "ef".repeat(32) });
  f.watch.report(DEVICE, { ...seededReport(), pushToken: undefined });
  f.watch.turn(CONV, { kind: "gone" });
  await f.idle();
  assert.equal(f.sent.length, after, "terminal re-reports must send neither token nor push");
  assert.deepEqual(await f.rows(), [tombstone]);
  assert.equal(pushes(f).length, 1, "held END must send exactly one push after token rotation");
  assert.equal(pushes(f)[0].event, "end");
  assert.equal(pushes(f)[0].timestamp, k, "END must use held reservation, never reserve a second k");
  const messages = f.sent.map((raw) => JSON.parse(raw));
  assert.ok(messages.findIndex((m) => m.type === "activityPush") > messages.findIndex((m) => m.type === "activityToken" && m.token === "cd".repeat(32)), "END must follow activityToken T2");
});

test("LA-2i L3a [behaviour] disabled relay rejects legacy report despite terminal record", async (t) => {
  const f = await diskFixture(t);
  f.watch.report(DEVICE, seededReport());
  f.watch.turn(CONV, { kind: "done" });
  await f.idle();
  const terminal = await f.rows();
  await f.watch.relayRegistered({ liveActivity: false });
  f.sent.length = 0;
  f.watch.report(DEVICE, report());
  f.clock.now += STEP_INTERVAL_MS;
  f.watch.turn(CONV, { kind: "step", steps: 3 });
  await f.idle();
  assert.deepEqual(f.sent, [], "legacy report with liveActivity false must create no watch or activityToken");
  assert.deepEqual(await f.rows(), terminal);
});

test("LA-2i L3b [behaviour] seeded save failure preserves legacy held step", async () => {
  const f = await running();
  f.watch.report("legacy-device", { ...report(), turns: { [TOKEN]: OTHER } });
  f.watch.turn(OTHER, { kind: "step", steps: 2 });
  f.clock.now += 1_000;
  f.watch.turn(OTHER, { kind: "step", steps: 3 });
  assert.equal(f.timers.size, 1, "legacy step must be held");
  f.store.fail = true;
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await settle();
  assert.equal(f.watch.hostWriterReady, false, "seeded reservation save must fail");
  f.clock.now += STEP_INTERVAL_MS;
  for (const [id, callback] of f.timers) { f.timers.delete(id); callback(); }
  await settle();
  assert.deepEqual(pushes(f).filter((m) => m.device === "legacy-device").map((m) => m.state.jobs[0].steps), [2, 3], "legacy held timer must still send after seeded save failure");
});

for (const variant of ["pending", "replacement", "revoke"] as const) {
  test(`LA-2i M1-${variant} [behaviour] held END cannot leak into changed transport or generation`, async (t) => {
    const f = await diskFixture(t);
    const initial = seededReport();
    f.watch.report(DEVICE, initial);
    await f.idle();
    const k = (await f.rows())[0].kLast + 1;
    const save = f.store.save.bind(f.store);
    let held = false;
    f.store.save = async (rows) => {
      if (!held && rows.some((row) => row.terminal)) { held = true; f.store.hold = true; }
      await save(rows);
    };
    f.watch.turn(CONV, { kind: "gone" });
    for (let i = 0; i < 100 && !f.store.entered; i++) await delay(10);
    assert.ok(f.store.entered, "END reservation must enter held save");
    const replacement = { ...initial, activityId: OTHER, requestedAtMs: initial.requestedAtMs! + 2_000, jobs: [], turns: {} };
    if (variant === "revoke") f.watch.forget(DEVICE, true);
    else f.watch.report(DEVICE, variant === "pending" ? { ...initial, pushToken: undefined } : replacement);
    f.store.unblock!();
    await f.idle();
    assert.deepEqual(pushes(f), [], "old END must not send");
    const rows = await f.rows();
    if (variant === "replacement") {
      assert.equal(rows[0].activityId, OTHER);
      assert.equal(rows[0].requestedAtMs, replacement.requestedAtMs);
      assert.equal(rows[0].kLast, Math.ceil(replacement.requestedAtMs / 1000));
      assert.equal(rows[0].terminal, false);
    } else {
      assert.deepEqual(rows, [{ device: DEVICE, activityId: initial.activityId, requestedAtMs: initial.requestedAtMs, kLast: k, terminal: true }]);
      const after = f.sent.length;
      f.watch.report(DEVICE, initial);
      await f.idle();
      assert.equal(f.sent.length, after, "burned END cannot be reserved or replayed again");
      assert.deepEqual(await f.rows(), rows);
    }
  });
}

for (const kind of ["legacy", "terminal", "absent"] as const) {
  test(`LA-2i M2-${kind} [control] tokenGone preserves main behaviour`, async (t) => {
    const f = await diskFixture(t);
    if (kind === "legacy") f.watch.report(DEVICE, report());
    if (kind === "terminal") {
      f.watch.report(DEVICE, seededReport());
      f.watch.turn(CONV, { kind: "gone" });
      await f.idle();
    }
    const before = existsSync(f.file) ? await readFile(f.file, "utf8") : undefined;
    const attempts = f.store.attempts;
    f.sent.length = 0;
    f.watch.tokenGone(DEVICE);
    f.watch.turn(CONV, { kind: "step", steps: 2 });
    await f.idle();
    assert.deepEqual(f.sent, []);
    assert.equal(f.store.attempts, attempts, "tokenGone control must not write");
    assert.equal(existsSync(f.file) ? await readFile(f.file, "utf8") : undefined, before, "bytes unchanged");
  });
}

for (const mode of ["reconnect", "stop"] as const) {
  test(`LA-2i L1/L2-${mode} [behaviour] held restore is single-flight and cannot revive stale registration`, async () => {
    const store = memoryStore();
    const f = durableFixture(store);
    let calls = 0;
    let acquired = false;
    let unblock!: () => void;
    const gate = new Promise<void>((resolve) => { unblock = resolve; });
    store.acquire = async () => {
      calls++;
      if (calls === 1) return false;
      await gate;
      acquired = true;
      return true;
    };
    store.release = async () => { acquired = false; };
    await f.watch.start();
    const stale = f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
    await settle();
    assert.equal(calls, 2);
    f.watch.relayDown();
    const errors: unknown[] = [];
    const unhandled = (error: unknown) => errors.push(error);
    process.on("unhandledRejection", unhandled);
    try {
      const next = mode === "stop" ? f.watch.stop() : f.watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
      await settle();
      const observedCalls = calls;
      unblock();
      await Promise.all([stale, next]);
      assert.equal(observedCalls, 2, "only one restore acquire may be in flight");
      assert.equal(f.watch.hostWriterReady, mode === "reconnect");
      assert.equal(acquired, mode === "reconnect", "stop releases a lock acquired after stop");
      assert.deepEqual(f.sent, []);
      await settle();
      assert.deepEqual(errors, []);
    } finally { process.off("unhandledRejection", unhandled); await f.watch.stop(); }
  });
}

test("LA-2i M2-seeded [behaviour] tokenGone retains content and resumes above durable k", async () => {
  const f = await running();
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await settle();
  f.clock.now += 1_000;
  f.watch.turn(CONV, { kind: "step", steps: 3 });
  await settle();
  assert.equal(f.timers.size, 1);
  const before = structuredClone(f.store.saves.at(-1)![0]!);
  // Token loss must persist the held snapshot too.
  before.rows = [{ ...seededReport().jobs[0]!, steps: 3 }];
  delete before.token;
  f.sent.length = 0;
  f.watch.tokenGone(DEVICE);
  await settle();
  assert.equal(f.timers.size, 0);
  assert.deepEqual(f.store.saves.at(-1), [before]);
  assert.deepEqual(f.sent, []);
  f.clock.now += STEP_INTERVAL_MS;
  f.watch.report(DEVICE, { ...seededReport(), pushToken: "cd".repeat(32) });
  await settle();
  assert.equal(pushes(f).length, 1);
  assert.equal(pushes(f)[0].timestamp, Math.max(before.kLast, Math.ceil(before.requestedAtMs / 1000)) + 1);
  assert.equal(pushes(f)[0].state.jobs[0].steps, 3);
  assert.equal(f.store.saves.at(-1)![0]!.activityId, before.activityId);
  assert.equal(f.store.saves.at(-1)![0]!.requestedAtMs, before.requestedAtMs);
});

// LA-2k: the relay slot as apps/relay/src/worker.ts keeps it. Every device has a p: row here.
// activityPush reads the slot on arrival (dropped if empty) and is queued; at the start of the
// queued send it goes to the token read on arrival only if the slot still holds it.
// Model: an idle relay queue with zero-latency APNs; each queued send starts before the next
// host message is applied. On the real relay (one activityTail chain per room), a send waits
// for the previous send's APNs round trip. With two or more replaced devices, or a push already
// in flight at reconnect, a later END can see the newer token and be dropped (never misdelivered).
// That residual needs a relay change and is not modelled here.
// After delivery an END clears the slot only if it still holds the sent token.
type Delivery = { device: string; event: string; timestamp?: number; token?: string };
function slotRelay() {
  const slots = new Map<string, string>();
  const wire: { type: string; device: string; token?: string; event?: string; timestamp?: number }[] = [];
  const delivered: Delivery[] = [];
  const dropped: Delivery[] = [];
  const queue: (() => void)[] = [];
  const run = () => { for (let start = queue.shift(); start; start = queue.shift()) start(); };
  return {
    slots, wire, delivered, dropped,
    receive(raw: string) {
      run();
      const message = JSON.parse(raw);
      wire.push(message);
      if (message.type === "activityToken") {
        if (message.token === undefined) slots.delete(message.device); else slots.set(message.device, message.token);
      } else if (message.type === "activityPush") {
        const token = slots.get(message.device);
        const row: Delivery = { device: message.device, event: message.event, timestamp: message.timestamp, token };
        if (token === undefined) { dropped.push(row); return; }
        queue.push(() => {
          if (slots.get(message.device) !== token) { dropped.push(row); return; }
          delivered.push(row);
          setImmediate(() => { if (message.event === "end" && slots.get(message.device) === token) slots.delete(message.device); });
        });
        setImmediate(run);
      }
    },
  };
}
const drain = async () => { for (let i = 0; i < 5; i++) await settle(); };
const short = (wire: ReturnType<typeof slotRelay>["wire"]) => wire.map((m) => m.type === "activityToken"
  ? ["token", m.device, m.token] : ["push", m.device, m.event, m.timestamp]);
const TA = "ab".repeat(32);
const TB = "cd".repeat(32);
const TC = "ef".repeat(32);
const D2 = "deviceSynthetic2";
const both = { liveActivity: true, activityTimestamp: true };
// A newer activity on the same device: seed 1_800_000_011.
const aNew = (pushToken = TB, bound = { jobs: seededReport().jobs, turns: seededReport().turns }): ActivityReport =>
  ({ ...seededReport(), ...bound, activityId: OTHER, requestedAtMs: 1_800_000_010_500, pushToken });
const onOther = { jobs: [hNew], turns: { [hNew.token]: OTHER } };
const tombstoneOf = (activityId: string, requestedAtMs: number, kLast: number) => ({ device: DEVICE, activityId, requestedAtMs, kLast, terminal: true });

function slotFixture(store = memoryStore(), relay = slotRelay(), pairedDevices?: () => Promise<string[]>) {
  const warnings: string[] = [];
  const clock = { now: T0 };
  let connected = false;
  const watch = fixtureWatch({ store, warn: (message) => warnings.push(message), now: () => clock.now,
    send: (raw) => { if (connected) relay.receive(raw); },
    setTimer: () => 0, clearTimer: () => {}, ...(pairedDevices ? { pairedDevices } : {}) });
  return { watch, store, relay, warnings, clock,
    up(flags: { liveActivity?: boolean; activityTimestamp?: boolean } = both) { connected = true; return watch.relayRegistered(flags); },
    down() { connected = false; watch.relayDown(); },
  };
}
async function seeded(relay = slotRelay()) {
  const f = slotFixture(memoryStore(), relay);
  await f.watch.start();
  await f.up();
  f.watch.report(DEVICE, seededReport());
  await drain();
  return f;
}
// Holds the next save that writes DEVICE's tombstone (the END reservation), not the turn's record update.
function holdEnd(f: { store: ReturnType<typeof memoryStore> }) {
  const save = f.store.save;
  f.store.save = async function (rows) {
    if (rows.some((row) => row.device === DEVICE && row.terminal)) { this.save = save; this.hold = true; }
    return save.call(this, rows);
  };
}
// An END whose tombstone save is held while the relay goes down: saved, not sent.
async function unsentEnd(f: Awaited<ReturnType<typeof seeded>>) {
  holdEnd(f);
  f.watch.turn(CONV, { kind: "done" });
  await drain();
  f.down();
  f.store.release();
  await drain();
  const saved = await f.store.load();
  assert.ok(saved.ok);
  assert.deepEqual(saved.records.find((row) => row.device === DEVICE), tombstoneOf(CONV, 1_800_000_000_500, 1_800_000_002));
  assert.deepEqual(f.relay.wire.filter((m) => m.event === "end"), [], "no END while the relay is down");
}

test("LA-2k 1-c [behaviour] reservation after a failed report save sends the reported token first", async () => {
  const f = await seeded();
  const mark = f.relay.wire.length;
  f.store.fail = true;
  f.watch.report(DEVICE, aNew());
  await drain();
  assert.equal(f.watch.hostWriterReady, false);
  f.watch.turn(CONV, { kind: "step", steps: 2 });
  await drain();
  assert.deepEqual(short(f.relay.wire.slice(mark)), [["token", DEVICE, TB]], "a failed reservation save sends nothing");
  f.store.fail = false;
  f.watch.turn(CONV, { kind: "step", steps: 3 });
  await drain();
  assert.deepEqual(short(f.relay.wire.slice(mark)), [["token", DEVICE, TB], ["token", DEVICE, TB], ["push", DEVICE, "update", 1_800_000_013]]);
  assert.deepEqual(f.relay.delivered.at(-1), { device: DEVICE, event: "update", timestamp: 1_800_000_013, token: TB });
  const saved = await f.store.load();
  assert.ok(saved.ok);
  assert.deepEqual(saved.records.map(({ activityId, token, kLast }) => ({ activityId, token, kLast })), [{ activityId: OTHER, token: TB, kLast: 1_800_000_013 }]);
});

test("LA-2k 1-d [behaviour] END with a never-saved token goes to that token; restart replays nothing", async () => {
  const f = await seeded();
  const mark = f.relay.wire.length;
  f.store.fail = true;
  f.watch.report(DEVICE, aNew());
  await drain();
  f.store.fail = false;
  f.watch.turn(CONV, { kind: "done" });
  await drain();
  assert.deepEqual(short(f.relay.wire.slice(mark)), [["token", DEVICE, TB], ["token", DEVICE, TB], ["push", DEVICE, "end", 1_800_000_012]]);
  assert.deepEqual(f.relay.delivered.at(-1), { device: DEVICE, event: "end", timestamp: 1_800_000_012, token: TB });
  assert.deepEqual(await f.store.load(), { ok: true, records: [tombstoneOf(OTHER, 1_800_000_010_500, 1_800_000_012)] });
  f.down();
  await f.watch.stop();
  const g = slotFixture(f.store, f.relay);
  await g.watch.start();
  const restart = f.relay.wire.length;
  await g.up();
  g.watch.turn(CONV, { kind: "step", steps: 2 });
  await drain();
  assert.deepEqual(f.relay.wire.slice(restart), []);
});

test("LA-2k 1-e [control] END after rotation during its save goes to the rotated token", async () => {
  const f = await seeded();
  holdEnd(f);
  f.watch.turn(CONV, { kind: "done" });
  await drain();
  f.watch.report(DEVICE, { ...seededReport(), pushToken: TC });
  f.store.release();
  await drain();
  assert.deepEqual(short(f.relay.wire.slice(-2)), [["token", DEVICE, TC], ["push", DEVICE, "end", 1_800_000_002]]);
  assert.deepEqual(f.relay.delivered, [{ device: DEVICE, event: "end", timestamp: 1_800_000_002, token: TC }]);
});

test("LA-2k 2-a [behaviour] unsent END is sent once at the next registration, before the replay", async () => {
  const f = await seeded();
  f.watch.report(D2, { ...seededReport(), ...onOther, pushToken: TB });
  await drain();
  await unsentEnd(f);
  const mark = f.relay.wire.length;
  await f.up();
  await drain();
  assert.deepEqual(short(f.relay.wire.slice(mark)), [["token", DEVICE, TA], ["push", DEVICE, "end", 1_800_000_002], ["token", D2, TB]]);
  assert.deepEqual(f.relay.delivered, [{ device: DEVICE, event: "end", timestamp: 1_800_000_002, token: TA }]);
  const again = f.relay.wire.length;
  f.down();
  await f.up();
  await drain();
  assert.deepEqual(short(f.relay.wire.slice(again)), [["token", D2, TB]], "a second registration sends no END");
});

test("LA-2k 2-b [behaviour] a newer activity saved before the reconnect keeps the unsent END for the old token", async () => {
  const f = await seeded();
  await unsentEnd(f);
  f.watch.report(DEVICE, aNew(TC, onOther));
  await drain();
  const saved = await f.store.load();
  assert.ok(saved.ok);
  assert.deepEqual(saved.records.map(({ activityId, token }) => ({ activityId, token })), [{ activityId: OTHER, token: TC }], "A_new saved before the reconnect");
  const mark = f.relay.wire.length;
  await f.up();
  await drain();
  assert.deepEqual(short(f.relay.wire.slice(mark)), [["token", DEVICE, TA], ["push", DEVICE, "end", 1_800_000_002], ["token", DEVICE, TC]]);
  assert.deepEqual(f.relay.delivered, [{ device: DEVICE, event: "end", timestamp: 1_800_000_002, token: TA }]);
  assert.equal(f.relay.slots.get(DEVICE), TC);
  f.watch.turn(OTHER, { kind: "step", steps: 2 });
  await drain();
  assert.deepEqual(f.relay.delivered.at(-1), { device: DEVICE, event: "update", timestamp: 1_800_000_012, token: TC });
  assert.equal(f.relay.delivered.length, 2);
});

test("LA-2k 2-c [control] revoke before the reconnect drops the unsent END", async () => {
  const f = await seeded();
  await unsentEnd(f);
  f.watch.forget(DEVICE, true);
  const mark = f.relay.wire.length;
  await f.up();
  f.down();
  await f.up();
  await drain();
  assert.deepEqual(f.relay.wire.slice(mark), []);
  assert.deepEqual(f.relay.delivered, []);
});

test("LA-2k 2-d [behaviour] unsent END waits while a relay flag is off", async () => {
  const f = await seeded();
  await unsentEnd(f);
  const mark = f.relay.wire.length;
  await f.up({ liveActivity: true });
  await drain();
  assert.deepEqual(f.relay.wire.slice(mark), []);
  f.down();
  await f.up();
  await drain();
  assert.deepEqual(short(f.relay.wire.slice(mark)), [["token", DEVICE, TA], ["push", DEVICE, "end", 1_800_000_002]]);
  assert.deepEqual(f.relay.delivered, [{ device: DEVICE, event: "end", timestamp: 1_800_000_002, token: TA }]);
});

test("LA-2k 2-e [behaviour] stop drops unsent ENDs, also across a lock-blocked restart", async (t) => {
  for (const saving of [false, true]) {
    for (const locked of [false, true]) {
      await t.test(`${saving ? "held" : "saved"} END; ${locked ? "lock-blocked" : "successful"} restart`, async () => {
        const f = await seeded();
        if (saving) {
          holdEnd(f);
          f.watch.turn(CONV, { kind: "done" });
          await drain();
          const saved = await f.store.load();
          assert.ok(saved.ok);
          assert.equal(saved.records.find((row) => row.device === DEVICE)?.terminal, false, "END tombstone save has not completed");
          const stopping = f.watch.stop();
          f.store.release();
          await stopping;
        } else {
          await unsentEnd(f);
          await f.watch.stop();
        }
        if (locked) f.store.acquire = async () => false;
        await f.watch.start();
        const mark = f.relay.wire.length;
        await f.up(both);
        await drain();
        assert.equal(f.watch.hostWriterReady, !locked);
        assert.deepEqual(f.relay.wire.slice(mark), [], "no END or activityToken after stop");
      });
    }
  }
});

// The flush at registration empties the entry before A_new can reserve, so A_new's END takes a fresh
// entry; a later END for the device replaces any entry still there (memo v5 §4.2).
test("LA-2k 2-f [behaviour] unsent END of a newer activity is sent with its own token", async () => {
  const f = await seeded();
  await unsentEnd(f);
  f.watch.report(DEVICE, aNew(TC, onOther));
  await drain();
  await f.up();
  await drain();
  assert.deepEqual(f.relay.delivered, [{ device: DEVICE, event: "end", timestamp: 1_800_000_002, token: TA }], "A_old's END flushed first");
  holdEnd(f);
  f.watch.turn(OTHER, { kind: "done" });
  await drain();
  f.down();
  f.store.release();
  await drain();
  const mark = f.relay.wire.length;
  await f.up();
  await drain();
  assert.deepEqual(short(f.relay.wire.slice(mark)), [["token", DEVICE, TC], ["push", DEVICE, "end", 1_800_000_012]]);
  assert.deepEqual(f.relay.delivered.slice(1), [{ device: DEVICE, event: "end", timestamp: 1_800_000_012, token: TC }]);
  assert.equal(f.relay.slots.get(DEVICE), undefined);
});

// Pins the frozen2j early return after the END save; keeping that END in unsentEnd is a follow-up.
test("LA-2k 2-g [known gap] newer activity during the END save drops the END", async () => {
  const f = await seeded();
  holdEnd(f);
  f.watch.turn(CONV, { kind: "done" });
  await drain();
  const mark = f.relay.wire.length;
  f.watch.report(DEVICE, aNew(TC, onOther));
  f.store.release();
  await drain();
  assert.deepEqual(short(f.relay.wire.slice(mark)), [["token", DEVICE, TC]], "A_old's END is neither sent nor kept");
  assert.deepEqual(f.relay.delivered, []);
  assert.equal(f.relay.slots.get(DEVICE), TC);
  const saved = await f.store.load();
  assert.ok(saved.ok);
  assert.deepEqual(saved.records.map(({ activityId, token, kLast, terminal }) => ({ activityId, token, kLast, terminal })),
    [{ activityId: OTHER, token: TC, kLast: 1_800_000_011, terminal: false }]);
  const again = f.relay.wire.length;
  f.down();
  await f.up();
  await drain();
  assert.deepEqual(short(f.relay.wire.slice(again)), [["token", DEVICE, TC]], "no unsent END at the next reconnect");
  assert.deepEqual(f.relay.delivered, []);
});

test("LA-2k 3-b [behaviour] crash between report send and save: restart binds pushes to the disk token", async () => {
  const f = await seeded();
  f.store.fail = true;
  f.watch.report(DEVICE, { ...seededReport(), pushToken: TB });
  await drain();
  assert.equal(f.relay.slots.get(DEVICE), TB, "the relay leads the file");
  f.down();
  f.store.fail = false;
  await f.watch.stop();
  const g = slotFixture(f.store, f.relay);
  await g.watch.start();
  const mark = f.relay.wire.length;
  await g.up();
  assert.deepEqual(short(f.relay.wire.slice(mark)), [["token", DEVICE, TA]]);
  g.watch.turn(CONV, { kind: "step", steps: 2 });
  await drain();
  assert.deepEqual(short(f.relay.wire.slice(mark)), [["token", DEVICE, TA], ["token", DEVICE, TA], ["push", DEVICE, "update", 1_800_000_002]]);
  assert.deepEqual(f.relay.delivered.at(-1), { device: DEVICE, event: "update", timestamp: 1_800_000_002, token: TA });
});

// J1: the disk holds A_old (TA) for DEVICE; the watch is registered and before load in one of two states.
const DROPPED = "yorozu: Live Activity report dropped before state load";
async function beforeLoad(state: "in flight" | "lock failed", pairedDevices?: () => Promise<string[]>) {
  const seed = await seeded();
  seed.down();
  await seed.watch.stop();
  const { store, relay } = seed;
  let acquires = 0;
  let open!: () => void;
  const gate = new Promise<void>((resolve) => { open = resolve; });
  store.acquire = async () => {
    if (++acquires === 1 && state === "in flight") await gate;
    // A failed attempt at start and at the first registration's retry.
    return state === "in flight" || acquires > 2;
  };
  const f = slotFixture(store, relay, pairedDevices);
  const mark = relay.wire.length;
  const starting = f.watch.start();
  const registering = state === "in flight" ? f.up() : starting.then(() => f.up());
  if (state === "lock failed") await registering;
  await drain();
  assert.equal(f.watch.hostWriterReady, false);
  return { ...f, mark,
    async load() {
      if (state === "in flight") { open(); await Promise.all([starting, registering]); } else await f.up();
      await drain();
    },
    async stopBeforeLoad() { const stopping = f.watch.stop(); open(); await Promise.all([stopping, starting, registering]); },
  };
}
const liveA = { ok: true, records: [{ device: DEVICE, activityId: CONV, requestedAtMs: 1_800_000_000_500, kLast: 1_800_000_001, terminal: false,
  token: TA, bindings: seededReport().turns, rows: cleanJobs(seededReport().jobs), sent: cleanJobs(seededReport().jobs) }] };
const tombA = { ok: true, records: [tombstoneOf(CONV, 1_800_000_000_500, 1_800_000_001)] };
const legacyReport = () => ({ ...report(), pushToken: TC });

for (const state of ["in flight", "lock failed"] as const) {
  test(`LA-2k 4-a (${state}) [behaviour] Mode H report before load is dropped; re-report after load is delivered`, async () => {
    const f = await beforeLoad(state);
    assert.deepEqual(await f.store.load(), liveA);
    f.watch.report(DEVICE, aNew());
    f.watch.report(DEVICE, { ...aNew(), pushToken: undefined });
    await drain();
    assert.deepEqual(f.relay.wire.slice(f.mark), [], "no token, no push");
    assert.deepEqual(f.warnings.filter((w) => w === DROPPED), [DROPPED], "one warning per before-load period");
    const saves = f.store.saves.length;
    await f.load();
    assert.equal(f.store.saves.length, saves);
    assert.deepEqual(await f.store.load(), liveA);
    assert.deepEqual(short(f.relay.wire.slice(f.mark)), [["token", DEVICE, TA]]);
    f.watch.report(DEVICE, aNew());
    f.watch.turn(CONV, { kind: "step", steps: 2 });
    await drain();
    assert.deepEqual(f.relay.delivered.at(-1), { device: DEVICE, event: "update", timestamp: 1_800_000_012, token: TB });
  });

  test(`LA-2k 4-b (${state}) [behaviour] revoke before load tombstones the loaded record`, async () => {
    const f = await beforeLoad(state);
    f.watch.forget(DEVICE, true);
    assert.deepEqual(f.relay.wire.slice(f.mark), [{ type: "activityToken", device: DEVICE }], "relay revoke stays immediate");
    await f.load();
    assert.deepEqual(await f.store.load(), tombA);
    f.watch.turn(CONV, { kind: "step", steps: 2 });
    await drain();
    assert.deepEqual(f.relay.wire.slice(f.mark), [{ type: "activityToken", device: DEVICE }], "no replay, no seeded push");
  });

  for (const order of ["legacy", "Mode H then legacy", "legacy then Mode H"] as const) {
    const id = { legacy: "4-c", "Mode H then legacy": "4-d", "legacy then Mode H": "4-e" }[order];
    test(`LA-2k ${id} (${state}) [behaviour] ${order} report before load keeps the legacy watch and tombstones Mode H`, async () => {
      const f = await beforeLoad(state);
      if (order === "Mode H then legacy") f.watch.report(DEVICE, aNew());
      f.watch.report(DEVICE, legacyReport());
      if (order === "legacy then Mode H") f.watch.report(DEVICE, aNew());
      assert.deepEqual(short(f.relay.wire.slice(f.mark)), [["token", DEVICE, TC]], "legacy token is immediate");
      await f.load();
      assert.deepEqual(await f.store.load(), tombA);
      f.watch.turn(CONV, { kind: "step", steps: 2 });
      await drain();
      assert.deepEqual(short(f.relay.wire.slice(f.mark)), [["token", DEVICE, TC], ["push", DEVICE, "update", undefined]], "legacy push, no replay");
      assert.deepEqual(f.relay.delivered, [{ device: DEVICE, event: "update", timestamp: undefined, token: TC }]);
    });
  }

  test(`LA-2k 4-f (${state}) [behaviour] revoke across a restart: the device list tombstones the record`, async () => {
    const paired = async () => ["deviceOther"];
    const f = await beforeLoad(state, paired);
    f.watch.forget(DEVICE, true);
    await f.stopBeforeLoad();
    assert.deepEqual(await f.store.load(), liveA, "the mark died with the process");
    const g = slotFixture(f.store, f.relay, paired);
    await g.watch.start();
    const mark = f.relay.wire.length;
    await g.up();
    g.watch.turn(CONV, { kind: "step", steps: 2 });
    await drain();
    assert.equal(g.watch.hostWriterReady, true);
    assert.deepEqual(await f.store.load(), tombA);
    assert.deepEqual(f.relay.wire.slice(mark), [], "no watch, no replay");
  });

  test(`LA-2k 4-g (${state}) [behaviour] unreadable device list keeps Mode H off until the next registration`, async () => {
    let readable = false;
    const f = await beforeLoad(state, async () => {
      if (!readable) throw Object.assign(new Error("synthetic list failure"), { code: "EIO" });
      return [DEVICE];
    });
    f.watch.forget(DEVICE, true);
    const revoked = f.relay.wire.length;
    await f.load();
    assert.equal(f.watch.hostWriterReady, false);
    assert.ok(f.warnings.includes("yorozu: Live Activity paired-device list unreadable; host writer stays off until the next relay registration"));
    f.watch.report(DEVICE, aNew());
    f.watch.report(D2, { ...report(), turns: { [TOKEN]: OTHER }, pushToken: TC });
    f.watch.turn(OTHER, { kind: "step", steps: 2 });
    f.watch.turn(CONV, { kind: "step", steps: 2 });
    await drain();
    assert.deepEqual(short(f.relay.wire.slice(revoked)), [["token", D2, TC], ["push", D2, "update", undefined]], "legacy works, Mode H off");
    readable = true;
    const mark = f.relay.wire.length;
    await f.up();
    await drain();
    assert.equal(f.watch.hostWriterReady, true);
    assert.deepEqual(await f.store.load(), tombA, "revoke mark survives the failed device-list read");
    assert.deepEqual(f.relay.wire.slice(mark), [], "revoked device has no replay or held push");
  });

  test(`LA-2k 4-g file (${state}) [behaviour] failed file load drops Mode H reports; legacy works`, async () => {
    const f = await beforeLoad(state);
    f.store.unavailable = true;
    await f.load();
    f.watch.report(DEVICE, aNew());
    f.watch.report(D2, { ...report(), turns: { [TOKEN]: OTHER }, pushToken: TC });
    f.watch.turn(OTHER, { kind: "step", steps: 2 });
    await drain();
    assert.equal(f.watch.hostWriterReady, false);
    assert.deepEqual(short(f.relay.wire.slice(f.mark)), [["token", D2, TC], ["push", D2, "update", undefined]]);
  });
}

test("LA-2k D5 [behaviour] failed restore save degrades; a fresh Mode H report is admitted", async () => {
  const f = await beforeLoad("in flight");
  f.watch.forget(DEVICE, true);
  f.store.fail = true;
  await f.load();
  f.store.fail = false;
  assert.equal(f.watch.hostWriterReady, false);
  assert.match(f.warnings.join("\n"), /reconcile restored owners.*ENOSPC/);
  f.watch.report(D2, { ...seededReport(), ...onOther, pushToken: TB });
  f.watch.turn(OTHER, { kind: "step", steps: 2 });
  await drain();
  assert.deepEqual(f.relay.delivered, [{ device: D2, event: "update", timestamp: 1_800_000_002, token: TB }]);
  assert.equal(f.watch.hostWriterReady, true);
  const saved = await f.store.load();
  assert.ok(saved.ok);
  assert.deepEqual(saved.records.find((row) => row.device === DEVICE), tombA.records[0], "later saves rewrite the whole map");
});

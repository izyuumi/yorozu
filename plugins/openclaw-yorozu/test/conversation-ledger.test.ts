import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { registerHooks } from "node:module";
import { beforeEach, test } from "node:test";
import { setImmediate } from "node:timers/promises";
import type { Message } from "../src/envelope.ts";
import type { RunRecord, Store } from "../src/ledger.ts";
import "./genui-hooks.ts";
import { host, yorozuRuntime } from "./genui-host.js";
const { openLedger } = await import("../src/runs.ts");

// Use the real retry store through the stand-in runtime. Fail media preparation after attachment_missing.
const retry = new URL("../src/retry.ts?ledger", import.meta.url).href;
const stub = new URL("./genui-host.js", import.meta.url).href;
const inbound = `data:text/javascript,${encodeURIComponent(`
  import * as standIn from ${JSON.stringify(stub)};
  export * from ${JSON.stringify(stub)};
  export const toInboundMediaFactsWithMetadata = async (...args) => {
    if (standIn.host.mediaError) throw standIn.host.mediaError;
    return standIn.toInboundMediaFactsWithMetadata(...args);
  };
`)}`;
registerHooks({ resolve(specifier, context, next) {
  if (specifier === "./retry.js") return next(retry, context);
  if (specifier === "openclaw/plugin-sdk/channel-inbound") return { url: inbound, shortCircuit: true };
  return next(specifier, context);
} });
const { handleMessage } = await import("../src/conversation.ts");

const message = (): Message => ({ convId: randomUUID(), messageId: randomUUID(), text: "hi" });
const boot = `${process.pid}:${Math.round(performance.timeOrigin)}`;
const store = yorozuRuntime.getRuntime().state.openKeyedStore;
const runs = (): Store<RunRecord> => store({ namespace: "runs" });
const retryStore = (): Store<{ message: Message; attempt: number }> => store({ namespace: "retry" });

beforeEach(() => {
  host.calls = [];
  host.sent.length = 0;
  host.register = undefined;
  host.queued = false;
  host.run = undefined;
  host.mediaError = undefined;
});

async function open() {
  const lines: string[] = [];
  const ctx = {
    cfg: {}, accountId: "default", agent: "main", mediaMaxBytes: 1,
    log: { info: (line: string) => lines.push(line), warn: (line: string) => lines.push(line) },
  } as never;
  const ledger = await openLedger(ctx);
  return {
    lines,
    async run(m: Message) {
      ledger.claim(m);
      await handleMessage(ctx, m);
      await ledger.idle();
      return (await runs().lookup(m.messageId))?.state;
    },
    async rerun(m: Message) {
      const parked = await retryStore().lookup(m.messageId);
      assert.ok(parked, "temporary failure left a retry in the retained store");
      await retryStore().delete(m.messageId);
      await handleMessage(ctx, parked.message, parked.attempt);
      await ledger.idle();
      return (await runs().lookup(m.messageId))?.state;
    },
    async state(m: Message) {
      await ledger.idle();
      return (await runs().lookup(m.messageId))?.state;
    },
  };
}

function runCalls() {
  return host.calls.flatMap((call: { kind: string; namespace?: string; value?: RunRecord }) =>
    call.kind === "dispatch" ? ["dispatch"] : call.namespace === "runs" ? [call.value!.state] : []);
}

test("handed lands before dispatch on the first attempt and parked rerun", async () => {
  const h = await open();
  const m = message();
  host.register = "slow";
  host.queued = true;
  host.run = () => { throw new Error("503 overloaded"); };
  await h.run(m);
  host.queued = false;
  host.run = undefined;
  await h.rerun(m);

  assert.deepEqual(runCalls(), [
    "accepted", "handed", "dispatch", "parked", "handed", "dispatch", "started", "settled",
  ], "both dispatches were preceded by a completed handed write");
  assert.ok(h.lines.includes(`yorozu: run started ${m.messageId} attempt 1 boot ${boot}`));
});

test("a failed handed write is logged and dispatch still runs", async () => {
  const h = await open();
  const m = message();
  host.register = (_namespace: string, _key: string, value: RunRecord) => {
    if (value.state === "handed") throw new Error("handed store down");
  };

  const state = await h.run(m);
  assert.ok(runCalls().includes("dispatch"));
  assert.ok(h.lines.includes("yorozu: run ledger write failed: Error: handed store down"), "the failed handed write was logged");
  assert.equal(state, "settled");
});

test("dispatch runs after the default deadline while the handed write is blocked", async (t) => {
  const h = await open();
  const m = message();
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const release = Promise.withResolvers<void>();
  host.register = (_namespace: string, _key: string, value: RunRecord) => {
    if (value.state === "handed") return release.promise;
  };

  const turn = h.run(m);
  t.after(async () => {
    release.resolve();
    await turn;
  });
  await setImmediate();
  t.mock.timers.tick(1_999);
  await setImmediate();
  assert.deepEqual(runCalls(), ["accepted"]);
  t.mock.timers.tick(1);
  await setImmediate();
  assert.deepEqual(runCalls(), ["accepted", "dispatch"], "dispatch must run at the deadline");
});

test("two messages in one conversation dispatch in order while the handed write is slow", async (t) => {
  const h = await open();
  const m1 = message();
  const m2 = { ...message(), convId: m1.convId };
  t.mock.timers.enable({ apis: ["setTimeout"] });
  const release = Promise.withResolvers<void>();
  t.after(() => release.resolve());
  host.register = (_namespace: string, _key: string, value: RunRecord) => {
    if (value.state === "handed") return release.promise;
  };
  const dispatched = () => host.calls.flatMap(({ kind, messageId }: { kind: string; messageId?: string }) =>
    kind === "dispatch" ? [messageId] : []);

  const first = h.run(m1);
  await setImmediate();
  t.mock.timers.tick(1);
  const second = h.run(m2);
  await setImmediate();

  t.mock.timers.tick(1_998);
  await setImmediate();
  assert.deepEqual(dispatched(), [], "neither message dispatches before its deadline");
  t.mock.timers.tick(1);
  await setImmediate();
  assert.deepEqual(dispatched(), [m1.messageId], "only the first deadline has passed");
  t.mock.timers.tick(1);
  await setImmediate();
  assert.deepEqual(dispatched(), [m1.messageId, m2.messageId], "both dispatch in order while writes are blocked");

  release.resolve();
  assert.deepEqual(await Promise.all([first, second]), ["settled", "settled"]);
});

test("no deferral, steer, and an already-started follow-up settle", async () => {
  const h = await open();
  const states = [];
  for (const [deferredToActiveRun, queued] of [[undefined, false], ["steer", true], ["followup", false]] as const) {
    host.queued = queued;
    host.run = () => ({ deferredToActiveRun });
    states.push(await h.run(message()));
  }
  assert.deepEqual(states, ["settled", "settled", "settled"], "ordinary, steered and started follow-up turns all settle");
});

test("a follow-up stays handed until its own late start", async () => {
  const h = await open();
  const m = message();
  let start!: () => void;
  host.queued = true;
  host.run = (_deliver: unknown, callback: () => void) => {
    start = callback;
    return { deferredToActiveRun: "followup" };
  };
  const queued = await h.run(m);
  start();
  assert.deepEqual([queued, await h.state(m)], ["handed", "started"], "the queued turn becomes started only at its own callback");
  assert.ok(h.lines.includes(`yorozu: follow-up started after dispatch ${m.messageId}`));
});

test("an attachment preparation failure settles without dispatch", async () => {
  const h = await open();
  const m = { ...message(), attachments: [{ id: randomUUID(), name: "missing.txt", mime: "text/plain", size: 1 }] };
  host.mediaError = new Error("media preparation failed");

  const state = await h.run(m);
  assert.ok(host.sent.some((event: { kind: string; data: { code?: string } }) =>
    event.kind === "error" && event.data.code === "attachment_missing"));
  assert.deepEqual(runCalls().filter((call: string) => call === "dispatch"), []);
  assert.equal(state, "settled", "the pre-dispatch failure was recorded as settled");
});

test("a late start cannot move a settled entry back to started", async () => {
  const h = await open();
  const m = message();
  let start!: () => void;
  host.queued = true;
  host.run = (_deliver: unknown, callback: () => void) => { start = callback; };
  const settled = await h.run(m);
  start();
  assert.deepEqual([settled, await h.state(m)], ["settled", "settled"], "settled survives a late callback");
  assert.deepEqual(runCalls(), ["accepted", "handed", "dispatch", "settled"]);
});

test("dispatch logs deferral and own start status", async () => {
  const h = await open();
  const expected: string[] = [];
  for (const [value, label, started] of [
    ["steer", "steer", false], ["followup", "followup", false], [undefined, "none", true], ["future", "other:future", false],
  ] as const) {
    const m = message();
    host.queued = !started;
    host.run = () => ({ deferredToActiveRun: value });
    await h.run(m);
    if (started) expected.push(`yorozu: run started ${m.messageId} attempt 0 boot ${boot}`);
    expected.push(`yorozu: dispatch returned ${m.messageId} deferred ${label} started ${started}`);
  }
  assert.deepEqual(h.lines.filter((line) => /yorozu: (run started|dispatch returned)/.test(line)), expected,
    "all deferral values and the actual start are logged");
});

test("a failed started write is logged and the turn still settles", async () => {
  const h = await open();
  host.register = (_namespace: string, _key: string, value: RunRecord) => {
    if (value.state === "started") throw new Error("started store down");
  };

  const state = await h.run(message());
  assert.ok(h.lines.includes("yorozu: run ledger write failed: Error: started store down"), "the failed started write was logged");
  assert.equal(state, "settled");
});

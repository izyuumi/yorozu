import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { registerHooks } from "node:module";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";
import { deferred, ownerRuntime } from "./conversation-owner-fixture.ts";

const sdk = process.env.YOROZU_OPENCLAW_SDK;
const prefix = "openclaw/plugin-sdk/";
const skip = !sdk ? "set YOROZU_OPENCLAW_SDK to an installed OpenClaw package root"
  : !existsSync(path.join(sdk, "dist/plugin-sdk/websocket-runtime.js")) ? "YOROZU_OPENCLAW_SDK has no dist/plugin-sdk/websocket-runtime.js" : false;
const source = new URL("../src/", import.meta.url);
// Replace only relay routing: real handleMessage events feed the real ActivityWatch.
const activityBridge = `data:text/javascript,${encodeURIComponent(`
  export { broadcast, notifyReply } from ${JSON.stringify(new URL("relay.ts", source).href)};
  let watch;
  export const observeActivity = value => { watch = value; };
  export const activityTurn = (convId, change) => watch?.turn(convId, change);
`)}`;
const CONV = "33333333-3333-4333-8333-333333333333";
const message = (i: number) => ({ convId: CONV, messageId: `${i.toString().padStart(8, "0")}-0000-4000-8000-000000000000`, text: "/owner-fixture", ts: 1_800_000_000_000 });

test("conversation owner registry (real SDK inbound lifecycle)", { skip }, async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "yorozu-conversation-owner-"));
  const previous = process.env.OPENCLAW_STATE_DIR;
  process.env.OPENCLAW_STATE_DIR = root;
  const hooks = registerHooks({ resolve(specifier, context, next) {
    if (context.parentURL === new URL("conversation.ts", source).href && specifier === "./relay.js") {
      return { url: activityBridge, shortCircuit: true };
    }
    if (specifier.startsWith(prefix)) return next(pathToFileURL(path.join(sdk!, "dist/plugin-sdk", `${specifier.slice(prefix.length)}.js`)).href, context);
    if (specifier.startsWith(".") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  } });
  t.after(async () => {
    hooks.deregister();
    if (previous === undefined) delete process.env.OPENCLAW_STATE_DIR; else process.env.OPENCLAW_STATE_DIR = previous;
    await rm(root, { recursive: true, force: true });
  });
  async function fixture(t: import("node:test").TestContext) {
    const f = await ownerRuntime(source);
    t.after(() => f.close());
    t.mock.method(Date, "now", () => 1_800_000_000_000);
    assert.equal(typeof f.conversation.liveTurn, "function", "step B must export liveTurn");
    return f;
  }

  // red: API-adapted
  await t.test("registration visible synchronously before uploadedFiles resolves", async (t) => {
    const f = await fixture(t);
    const lookup = deferred<unknown>();
    f.lookups.set("missing", () => lookup.promise);
    const run = f.launch({ ...message(1), attachments: [{ id: "missing", name: "missing.txt", mime: "text/plain", size: 1 }] });
    try { assert.deepEqual(f.conversation.liveTurn(CONV), { steps: 0, startedAt: 1_800_000_000_000 }); }
    finally { lookup.resolve(undefined); run.exit.resolve(); }
    await run.done;
    assert.equal(f.conversation.liveTurn(CONV), undefined);
  });

  // red: API-adapted
  await t.test("uploadedFiles early rejection removes owner", async (t) => {
    const f = await fixture(t);
    f.lookups.set("missing", async () => { throw new Error("synthetic attachment lookup failure"); });
    const run = f.launch({ ...message(2), attachments: [{ id: "missing", name: "missing.txt", mime: "text/plain", size: 1 }] });
    await assert.rejects(run.done, /synthetic attachment lookup failure/);
    assert.equal(f.conversation.liveTurn(CONV), undefined);
  });

  await t.test("R2 uploadedFiles early rejection settles admitted watch row and persists ended token", async (t) => {
    const f = await fixture(t);
    const { ActivityWatch } = await import("../src/activitywatch.ts");
    const { observeActivity } = await import(activityBridge);
    let records: import("../src/activitystore.ts").ActivityRecord[] = [];
    const sent: string[] = [];
    const watch = new ActivityWatch({
      liveTurn: f.conversation.liveTurn,
      store: {
        acquire: async () => true, release: async () => {},
        load: async () => ({ ok: true, records: structuredClone(records) }),
        save: async (next) => { records = structuredClone(next); },
      },
      send: (raw) => sent.push(raw), warn: () => {}, now: () => 1_800_000_000_000,
      setTimer: () => assert.fail("early settlement must not need a timer"), clearTimer: () => {},
    });
    observeActivity(watch);
    t.after(async () => { observeActivity(undefined); await watch.stop(); });
    await watch.start();
    await watch.relayRegistered({ liveActivity: true, activityTimestamp: true });
    const lookup = deferred();
    f.lookups.set("missing", async () => { await lookup.promise; throw new Error("synthetic attachment lookup failure"); });
    const run = f.launch({ ...message(7), attachments: [{ id: "missing", name: "missing.txt", mime: "text/plain", size: 1 }] });
    const token = "AAAAAAAAAAAAAAAA";
    const keeper = { token: "RRRRRRRRRRRRRRRR", kind: "recording", state: "running", startedAt: 1_800_000_000_000 } as const;
    watch.report("synthetic-device", {
      activityId: CONV, requestedAtMs: 1_800_000_000_000, pushToken: "ab".repeat(32),
      jobs: [keeper, { token, kind: "turn", state: "running", steps: 0, startedAt: 1_800_000_000_000 }],
      turns: { [token]: CONV },
    });
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.ok(records[0]?.rows?.some((row) => row.token === token), "admitted before attachment lookup rejects");
    lookup.resolve();
    await assert.rejects(run.done, /synthetic attachment lookup failure/);
    assert.equal(f.conversation.liveTurn(CONV), undefined);
    await new Promise<void>((resolve) => setImmediate(resolve));
    assert.deepEqual(records[0]?.rows, [keeper]);
    assert.deepEqual(records[0]?.ended, [token]);
    assert.deepEqual(records[0]?.bindings, {});
    const pushes = sent.map((raw) => JSON.parse(raw)).filter((msg) => msg.type === "activityPush");
    assert.equal(pushes.length, 1);
    assert.deepEqual(pushes[0].state.jobs.map((row: { token: string }) => row.token), [keeper.token]);
  });

  // red: API-adapted
  await t.test("tool starts increment unique owner steps; real reply removes owner", async (t) => {
    const f = await fixture(t);
    const run = f.launch(message(3));
    const dispatch = await run.entered.promise;
    dispatch.replyOptions.onToolStart({ toolCallId: "tool-1", name: "read", phase: "start" });
    dispatch.replyOptions.onToolStart({ toolCallId: "tool-1", name: "read", phase: "start" });
    assert.equal(f.conversation.liveTurn(CONV).steps, 1);
    dispatch.replyOptions.onToolStart({ toolCallId: "tool-2", name: "read", phase: "start" });
    assert.equal(f.conversation.liveTurn(CONV).steps, 2);
    dispatch.dispatcher.sendFinalReply({ text: "synthetic reply" });
    run.exit.resolve();
    await run.done;
    assert.equal(f.conversation.liveTurn(CONV), undefined);
  });

  // red: API-adapted
  await t.test("temporary error parks live; same message retry has exactly one owner entry", async (t) => {
    const f = await fixture(t);
    const first = f.launch(message(4));
    await first.entered.promise;
    first.fail(new Error("503 temporarily unavailable"));
    await first.done;
    assert.deepEqual(f.conversation.liveTurn(CONV), { steps: 0, startedAt: 1_800_000_000_000 });
    assert.ok(f.stores.get("retry")?.has(message(4).messageId), "real park wrote retry record");
    const retry = f.launch(message(4), 1);
    await retry.entered.promise;
    retry.exit.resolve(); // gone removes the only entry; duplicate registration would leak.
    await retry.done;
    assert.equal(f.conversation.liveTurn(CONV), undefined);
  });

  // red: API-adapted
  await t.test("overlapping messages expose newest steps then fall back to older run", async (t) => {
    const f = await fixture(t);
    const a = f.launch(message(5));
    const ad = await a.entered.promise;
    ad.replyOptions.onToolStart({ toolCallId: "a1", name: "read", phase: "start" });
    const b = f.launch(message(6));
    const bd = await b.entered.promise;
    assert.equal(f.conversation.liveTurn(CONV).steps, 0);
    bd.replyOptions.onToolStart({ toolCallId: "b1", name: "read", phase: "start" });
    bd.replyOptions.onToolStart({ toolCallId: "b2", name: "read", phase: "start" });
    assert.equal(f.conversation.liveTurn(CONV).steps, 2);
    b.exit.resolve(); await b.done;
    assert.equal(f.conversation.liveTurn(CONV).steps, 1);
    a.exit.resolve(); await a.done;
    assert.equal(f.conversation.liveTurn(CONV), undefined);
  });
});

import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { createModelResponder } from "../models.js";
import { connectYorozu } from "../socket.js";

const until = async (check) => {
  for (let i = 0; i < 200 && !check(); i++) await new Promise((r) => setTimeout(r, 10));
  assert.ok(check());
};

/** A fake Yorozu host: records frames, lets the test write back. */
function fakeHost(path) {
  const frames = [];
  let client;
  const server = createServer((socket) => {
    client = socket;
    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";
      for (const line of lines) if (line) frames.push(JSON.parse(line));
    });
  });
  server.listen(path);
  return {
    frames,
    write: (frame) => client.write(`${JSON.stringify(frame)}\n`),
    close: () => new Promise((done) => { client?.destroy(); server.close(() => done()); }),
  };
}

/** Socket + responder over a fake OpenClaw session store and model catalog. */
async function setup({ sessions = {}, apply, catalogError } = {}) {
  const path = join(mkdtempSync(join(tmpdir(), "yorozu-models-")), "channel.sock");
  const host = fakeHost(path);
  const applied = [];
  const sdk = {
    resolveRoute: ({ peer }) => ({ route: { agentId: "ops", sessionKey: `agent:ops:yorozu:direct:${peer.id}` } }),
    buildModelsData: async () => {
      if (catalogError) throw new Error(catalogError);
      return {
        providers: ["anthropic", "openai"],
        byProvider: new Map([["anthropic", new Set(["opus", "sonnet"])], ["openai", new Set(["gpt-5"])]]),
        modelNames: new Map([["anthropic/opus", "Claude Opus"]]),
        resolvedDefault: { provider: "anthropic", model: "sonnet" },
        modelCatalog: ["catalog"],
      };
    },
    getSessionEntry: ({ sessionKey }) => sessions[sessionKey],
    resolveStorePath: () => "store",
    applySelection: async (params) => {
      applied.push(params);
      if (apply) return apply(params);
      const { provider, model, isDefault } = params.request;
      const key = params.sessionKey;
      sessions[key] = isDefault ? { sessionId: "s" } : { sessionId: "s", providerOverride: provider, modelOverride: model };
      return { status: "applied", effectiveModelRef: `${provider}/${model}` };
    },
  };
  const respond = createModelResponder(sdk);
  const link = connectYorozu({
    path, capabilities: ["run-boundary-v1", "model-select-v1"], onInbound: async () => {},
    onModelRequest: (frame) => respond({ cfg: {}, accountId: "default", frame }),
  });
  await until(() => host.frames.length > 0);
  const ask = async (frame) => {
    const before = host.frames.length;
    host.write(frame);
    await until(() => host.frames.length > before);
    return host.frames.at(-1);
  };
  return { host, link, sessions, applied, ask, done: async () => { link.close(); await host.close(); } };
}

test("hello lists model-select-v1", async () => {
  const t = await setup();
  assert.deepEqual(t.host.frames[0], { type: "hello", capabilities: ["run-boundary-v1", "model-select-v1"] });
  await t.done();
});

test("catalog lists the agent's models in OpenClaw's order", async () => {
  const t = await setup();
  const reply = await t.ask({ type: "model_catalog_request", requestId: "r1", threadId: "t1" });
  assert.deepEqual(reply, {
    type: "model_catalog", requestId: "r1",
    models: [
      { id: "anthropic/opus", label: "Claude Opus", available: true },
      { id: "anthropic/sonnet", label: "sonnet", available: true },
      { id: "openai/gpt-5", label: "gpt-5", available: true },
    ],
  });
  await t.done();
});

test("selection is the thread's override, null without one, including for a draft", async () => {
  const t = await setup({ sessions: { "agent:ops:yorozu:direct:t1": { providerOverride: "openai", modelOverride: "gpt-5" } } });
  assert.deepEqual(await t.ask({ type: "model_selection_request", requestId: "r1", threadId: "t1" }), { type: "model_selection", requestId: "r1", model: "openai/gpt-5" });
  assert.deepEqual(await t.ask({ type: "model_selection_request", requestId: "r2", threadId: "draft" }), { type: "model_selection", requestId: "r2", model: null });
  await t.done();
});

test("select applies to the named thread only, creating a draft's session for its first run", async () => {
  const t = await setup({ sessions: { "agent:ops:yorozu:direct:other": { sessionId: "o" } } });
  const reply = await t.ask({ type: "model_select", requestId: "r1", threadId: "draft", model: "openai/gpt-5" });
  assert.deepEqual(reply, { type: "model_select_result", requestId: "r1", ok: true, model: "openai/gpt-5" });
  assert.equal(t.applied.length, 1);
  assert.equal(t.applied[0].sessionKey, "agent:ops:yorozu:direct:draft");
  assert.equal(t.applied[0].allowCreate, true);
  assert.equal(t.applied[0].canPersistStickyModelSelection, false);
  assert.deepEqual(t.sessions["agent:ops:yorozu:direct:other"], { sessionId: "o" });
  assert.deepEqual(await t.ask({ type: "model_selection_request", requestId: "r2", threadId: "draft" }), { type: "model_selection", requestId: "r2", model: "openai/gpt-5" });
  await t.done();
});

test("select null clears the override", async () => {
  const t = await setup({ sessions: { "agent:ops:yorozu:direct:t1": { sessionId: "s", providerOverride: "openai", modelOverride: "gpt-5" } } });
  const reply = await t.ask({ type: "model_select", requestId: "r1", threadId: "t1", model: null });
  assert.deepEqual(reply, { type: "model_select_result", requestId: "r1", ok: true, model: null });
  assert.equal(t.applied[0].allowCreate, false);
  assert.deepEqual(await t.ask({ type: "model_selection_request", requestId: "r2", threadId: "t1" }), { type: "model_selection", requestId: "r2", model: null });
  await t.done();
});

test("an unknown or refused model gets an error result, not a change", async () => {
  const t = await setup({ apply: async () => ({ status: "rejected", reason: "locked", message: "Model is locked" }) });
  for (const model of ["nope", "openai/gpt-9"]) {
    const reply = await t.ask({ type: "model_select", requestId: model, threadId: "t1", model });
    assert.equal(reply.type, "model_select_result");
    assert.equal(reply.ok, false);
    assert.match(reply.error, /nope|gpt-9/);
  }
  assert.equal(t.applied.length, 0);
  const locked = await t.ask({ type: "model_select", requestId: "r3", threadId: "t1", model: "openai/gpt-5" });
  assert.deepEqual(locked, { type: "model_select_result", requestId: "r3", ok: false, error: "Model is locked" });
  await t.done();
});

test("a failing handler still answers, so the host is never left waiting", async () => {
  const t = await setup({ catalogError: "gateway down" });
  const catalog = await t.ask({ type: "model_catalog_request", requestId: "r1", threadId: "t1" });
  assert.equal(catalog.type, "model_catalog");
  assert.equal(catalog.error, "gateway down");
  assert.ok(!Array.isArray(catalog.models)); // the host rejects this reply at once
  const select = await t.ask({ type: "model_select", requestId: "r2", threadId: "t1", model: null });
  assert.deepEqual(select, { type: "model_select_result", requestId: "r2", ok: false, error: "gateway down" });
  await t.done();
});

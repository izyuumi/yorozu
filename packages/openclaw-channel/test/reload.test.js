import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, rm } from "node:fs/promises";
import { registerHooks } from "node:module";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { sdk, state } from "./support/sdk.js";

// Replace only the external SDK. Exercise the real account callbacks, queue, dispatcher,
// model responder, and socket; no test-only production exports or config mutations.
const fixture = new URL("./support/sdk.js", import.meta.url).href;
const hook = registerHooks({
  resolve(specifier, context, next) {
    return specifier.startsWith("openclaw/plugin-sdk/")
      ? { url: `yorozu-test-sdk:${specifier}`, shortCircuit: true } : next(specifier, context);
  },
  load(url, context, next) {
    if (!url.startsWith("yorozu-test-sdk:")) return next(url, context);
    return { format: "module", shortCircuit: true, source:
      `import { sdk } from ${JSON.stringify(fixture)};\n` + Object.keys(sdk).map((name) =>
        name === "PlatformMessageNotDispatchedError" ? `export const ${name} = sdk.${name};`
          : `export const ${name} = (...args) => sdk.${name}(...args);`).join("\n") };
  },
});
const { yorozuPlugin } = await import("../channel.js");
hook.deregister();

const config = (agent, model) => ({ agent, model, session: { store: `store-${agent}` } });
const message = (id, threadId = "thread") => ({ id, threadId, ts: 1, text: "hello" });
const gate = () => Promise.withResolvers();

async function setup(t) {
  state.config = null;
  state.turns = [];
  state.pipelines = [];
  state.selections = [];
  state.entries.clear();
  state.turn = state.catalog = undefined;
  const dir = await mkdtemp(join(tmpdir(), "yorozu-reload-"));
  const path = join(dir, "channel.sock");
  const frames = [], pending = [], warnings = [];
  let client;
  const server = createServer((socket) => {
    client = socket;
    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      const lines = buffer.split("\n");
      buffer = lines.pop();
      for (const line of lines.filter(Boolean)) {
        const frame = JSON.parse(line);
        frames.push(frame);
        for (const wait of [...pending]) if (wait.match(frame)) {
          pending.splice(pending.indexOf(wait), 1);
          wait.resolve(frame);
        }
      }
    });
  });
  server.listen(path);
  await once(server, "listening");
  const controller = new AbortController();
  const initial = config("old", "old-model");
  const next = (match) => new Promise((resolve) => pending.push({ match, resolve }));
  const hello = next((frame) => frame.type === "hello");
  const account = yorozuPlugin.gateway.startAccount({
    cfg: initial, accountId: "default", account: { socketPath: path },
    abortSignal: controller.signal, setStatus() {}, log: { warn: (warning) => warnings.push(warning) },
  });
  t.after(async () => {
    controller.abort();
    await account;
    client?.destroy();
    await new Promise((resolve) => server.close(resolve));
    await rm(dir, { recursive: true, force: true });
  });
  await hello;
  const send = (frame) => client.write(`${JSON.stringify(frame)}\n`);
  const ask = (type, requestId, model) => {
    const response = next((frame) => frame.requestId === requestId);
    send({ type, requestId, threadId: "thread", ...(model !== undefined ? { model } : {}) });
    return response;
  };
  const inbound = (msg) => {
    const ack = next((frame) => frame.type === "ack" && frame.id === msg.id);
    send({ type: "inbound", message: msg });
    return ack;
  };
  return { initial, frames, warnings, next, send, ask, inbound };
}

test("later messages and all model requests use the replacement runtime snapshot", { timeout: 3000 }, async (t) => {
  const host = await setup(t);
  await host.inbound(message("before"));
  const current = config("new", "new-model");
  state.config = current; // Synthetic accepted reload: replace, never mutate startup config.
  state.entries.set("new:thread", { providerOverride: "fixture", modelOverride: "new-model" });
  await host.inbound(message("after"));
  assert.deepEqual(state.turns.map((plan) => plan.route.agentId), ["old", "new"]);
  assert.equal(state.turns[1].cfg, current);
  assert.equal(state.pipelines[1], current);
  assert.deepEqual(await host.ask("model_catalog_request", "catalog"), {
    type: "model_catalog", requestId: "catalog", models: [{ id: "fixture/new-model", label: "new-model", available: true }],
  });
  assert.equal((await host.ask("model_selection_request", "selection")).model, "fixture/new-model");
  assert.equal((await host.ask("model_select", "select", "fixture/new-model")).ok, true);
  assert.equal(state.selections[0].cfg, current);
  assert.equal(state.selections[0].storePath, "store-new/new");
  assert.equal(state.selections[0].sessionKey, "new:thread");
});

test("queued messages read at execution; in-flight messages and model requests retain their config", { timeout: 3000 }, async (t) => {
  const host = await setup(t);
  const started = gate(), release = gate();
  state.turn = async (plan) => { if (plan.ctxPayload.messageId === "first") { started.resolve(); await release.promise; } };
  const firstAck = host.inbound(message("first"));
  await started.promise;
  const secondAck = host.inbound(message("queued"));
  // A response to the following frame proves the socket has enqueued the earlier inbound.
  await host.ask("model_selection_request", "queued-barrier");
  state.config = config("new", "new-model");
  // A separate thread may execute while the first is still active.
  await host.inbound(message("parallel", "other"));
  assert.equal(state.turns[0].cfg, host.initial);
  release.resolve();
  await Promise.all([firstAck, secondAck]);
  assert.equal(state.turns.find((plan) => plan.ctxPayload.messageId === "queued").route.agentId, "new");
  assert.equal(state.turns.find((plan) => plan.ctxPayload.messageId === "parallel").route.agentId, "new");

  const catalogStarted = gate(), catalogRelease = gate();
  state.catalog = async () => { catalogStarted.resolve(); await catalogRelease.promise; };
  const selecting = host.ask("model_select", "concurrent", "fixture/new-model");
  await catalogStarted.promise;
  state.config = config("newer", "newer-model");
  state.catalog = undefined;
  const latest = await host.ask("model_catalog_request", "latest");
  assert.equal(latest.models[0].id, "fixture/newer-model");
  catalogRelease.resolve();
  assert.equal((await selecting).ok, true);
  assert.equal(state.selections[0].cfg.agent, "new");
  assert.equal(state.selections[0].storePath, "store-new/new");
});

test("no active snapshot falls back to startup config for message and model requests", { timeout: 3000 }, async (t) => {
  const host = await setup(t);
  await host.inbound(message("fallback"));
  assert.equal(state.turns[0].cfg, host.initial);
  assert.equal((await host.ask("model_catalog_request", "fallback-catalog")).models[0].id, "fixture/old-model");
  assert.equal((await host.ask("model_select", "fallback-select", null)).ok, true);
  assert.equal(state.selections[0].cfg, host.initial);
});

test("model failures reply promptly and the next request recovers with current config", { timeout: 3000 }, async (t) => {
  const host = await setup(t);
  state.config = config("new", "new-model");
  state.catalog = async () => { throw new Error("synthetic catalog unavailable"); };
  assert.equal((await host.ask("model_catalog_request", "failed-catalog")).error, "synthetic catalog unavailable");
  assert.deepEqual(await host.ask("model_select", "failed-select", null), {
    type: "model_select_result", requestId: "failed-select", ok: false, error: "synthetic catalog unavailable",
  });
  state.catalog = undefined;
  state.config = config("recovered", "recovered-model");
  assert.equal((await host.ask("model_catalog_request", "recovered")).models[0].id, "fixture/recovered-model");
  assert.equal((await host.ask("model_select", "recovered-select", null)).ok, true);
  assert.equal(state.selections[0].cfg.agent, "recovered");
});

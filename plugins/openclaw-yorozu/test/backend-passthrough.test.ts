import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { once } from "node:events";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { registerHooks } from "node:module";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";
import type { Event, Message } from "../src/envelope.ts";
import { deferred } from "./conversation-owner-fixture.ts";

const sdk = process.env.YOROZU_OPENCLAW_SDK;
const prefix = "openclaw/plugin-sdk/";
const skip = !sdk ? "set YOROZU_OPENCLAW_SDK to an installed OpenClaw package root"
  : !existsSync(path.join(sdk, "dist/plugin-sdk/reply-runtime.js")) ? "YOROZU_OPENCLAW_SDK has no dist/plugin-sdk/reply-runtime.js" : false;
const source = new URL("../src/", import.meta.url);
const relay = `data:text/javascript,${encodeURIComponent(`
  export const sent = [];
  export const broadcast = (events) => { sent.push(...events); return 0; };
  export const activityTurn = () => {};
  export const notifyReply = async () => {};
`)}`;
const REPLY = "The agent saw the message.";

type ModelRequest = { path: string | undefined; body: { stream?: boolean; messages?: { role: string; content: unknown }[] } };

function chunk(delta: object, finish: string | null) {
  return `data: ${JSON.stringify({ id: "chatcmpl-fixture", object: "chat.completion.chunk", created: 0, model: "fixture-model",
    choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
}

async function fakeModel() {
  const requests: ModelRequest[] = [];
  const arrived = deferred();
  const server = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (data: Buffer) => chunks.push(data));
    req.on("end", () => {
      const text = Buffer.concat(chunks).toString();
      const body = text ? JSON.parse(text) as ModelRequest["body"] : {};
      requests.push({ path: req.url, body });
      arrived.resolve();
      if (!req.url?.endsWith("/chat/completions")) {
        res.writeHead(404, { "Content-Type": "application/json" }).end(JSON.stringify({ error: { message: "not found" } }));
        return;
      }
      if (!body.stream) {
        res.writeHead(200, { "Content-Type": "application/json" }).end(JSON.stringify({
          id: "chatcmpl-fixture", object: "chat.completion", created: 0, model: "fixture-model",
          choices: [{ index: 0, message: { role: "assistant", content: REPLY }, finish_reason: "stop" }],
          usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
        }));
        return;
      }
      res.writeHead(200, { "Content-Type": "text/event-stream" });
      res.end(chunk({ role: "assistant", content: REPLY }, null) + chunk({}, "stop") + "data: [DONE]\n\n");
    });
  });
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  assert.ok(address && typeof address !== "string");
  return {
    requests, arrived: arrived.promise, port: address.port,
    close: () => new Promise<void>((resolve) => {
      server.closeAllConnections();
      server.close(() => resolve());
    }),
  };
}

const userTexts = (request: ModelRequest) => (request.body.messages ?? [])
  .filter((entry) => entry.role === "user")
  .map((entry) => typeof entry.content === "string" ? entry.content : JSON.stringify(entry.content));

test("with the Hermes backend off, /backend hermes reaches the agent verbatim and /help gets OpenClaw's command reply", { skip, timeout: 180_000 }, async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "yorozu-backend-passthrough-"));
  const previous = Object.fromEntries(["HOME", "OPENCLAW_HOME", "OPENCLAW_STATE_DIR", "OPENCLAW_CONFIG_PATH"].map((name) => [name, process.env[name]]));
  const model = await fakeModel();
  const hooks = registerHooks({ resolve(specifier, context, next) {
    if (context.parentURL === new URL("conversation.ts", source).href && specifier === "./relay.js") {
      return { url: relay, shortCircuit: true };
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
    await model.close();
    for (const [name, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
    await rm(root, { recursive: true, force: true });
  });

  const workspace = path.join(root, "workspace");
  await mkdir(workspace, { recursive: true });
  process.env.HOME = root;
  process.env.OPENCLAW_HOME = root;
  process.env.OPENCLAW_STATE_DIR = path.join(root, "state");
  process.env.OPENCLAW_CONFIG_PATH = path.join(root, "openclaw.json");
  const cfg = {
    agents: {
      defaults: {
        workspace,
        skipBootstrap: true,
        model: { primary: "fixture/fixture-model" },
        models: { "fixture/fixture-model": { agentRuntime: { id: "openclaw" } } },
      },
      entries: { main: {} },
    },
    models: {
      providers: {
        fixture: {
          baseUrl: `http://127.0.0.1:${model.port}/v1`,
          api: "openai-completions",
          apiKey: "fixture-key",
          models: [{ id: "fixture-model", name: "Fixture model", compat: { supportsTools: false } }],
        },
      },
    },
    plugins: { enabled: false },
    skills: { load: { watch: false } },
  };
  await writeFile(process.env.OPENCLAW_CONFIG_PATH, JSON.stringify(cfg, null, 2));

  const { dispatchInboundMessage } = await import(`${prefix}reply-runtime`) as {
    dispatchInboundMessage: (params: object) => Promise<unknown>;
  };
  const { yorozuRuntime } = await import(new URL("runtime.ts", source).href);
  const stores = new Map<string, Map<string, unknown>>();
  yorozuRuntime.setRuntime({
    version: "passthrough-test",
    state: { openKeyedStore({ namespace }: { namespace: string }) {
      const rows = stores.get(namespace) ?? stores.set(namespace, new Map()).get(namespace)!;
      const lookup = async (key: string) => rows.get(key);
      const register = async (key: string, value: unknown) => { rows.set(key, value); };
      return { lookup, get: lookup, register, set: register,
        entries: async () => [...rows].map(([key, value]) => ({ key, value })), delete: async (key: string) => rows.delete(key) };
    } },
    channel: { reply: { dispatchReplyFromConfig: (params: object) => dispatchInboundMessage(params) } },
  });
  const { handleMessage } = await import(new URL("conversation.ts", source).href);
  const { sent } = await import(relay) as { sent: Event[] };
  const warnings: string[] = [];
  const turn = {
    cfg, accountId: "default", agent: "main", mediaMaxBytes: 1024,
    presentationSdk: { normalize: (raw: unknown) => raw, tableAlt: () => "", chartAlt: () => "" },
    log: { info: () => {}, debug: () => {}, error: (line: string) => warnings.push(line), warn: (line: string) => warnings.push(line) },
  };
  const convId = randomUUID();
  const message = (text: string): Message => ({ convId, messageId: randomUUID(), text });
  const replies = (m: Message) => sent.filter((event): event is Extract<Event, { kind: "reply" }> => event.kind === "reply" && event.data.convId === m.convId);

  const backend = message("/backend hermes");
  await handleMessage(turn, backend);
  const agentRequests = model.requests.filter((request) => request.path?.endsWith("/chat/completions"));
  assert.ok(agentRequests.length > 0, `the agent ran on the model: ${JSON.stringify({ requests: model.requests.map((r) => r.path), warnings })}`);
  const lastUser = userTexts(agentRequests[0]!).at(-1) ?? "";
  assert.ok(lastUser.includes("/backend hermes"), `the agent got /backend hermes verbatim: ${lastUser}`);
  assert.ok(replies(backend).some((event) => event.data.text.includes(REPLY)), "the device got only the agent's reply");
  assert.equal(sent.filter((event) => event.kind === "error").length, 0, JSON.stringify(sent));

  const before = model.requests.length;
  sent.length = 0;
  const help = message("/help");
  await handleMessage(turn, help);
  const helpReplies = replies(help);
  assert.ok(helpReplies.length > 0, `OpenClaw answered /help: ${JSON.stringify({ sent, warnings })}`);
  assert.ok(helpReplies.every((event) => !event.data.text.includes(REPLY)), "the /help reply is OpenClaw's, not the agent's");
  assert.ok(model.requests.slice(before).every((request) => !userTexts(request).some((text) => text.includes("/help"))),
    "/help never reached the agent");
});

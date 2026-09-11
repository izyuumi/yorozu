import { existsSync, mkdtempSync, statSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay, type Relay } from "@yorozu/relay";
import type { EventKind, EventPayload, YorozuEvent } from "@yorozu/shared";
import { afterEach, expect, test, vi } from "vitest";
import { localSocketPath } from "./local.js";
import { openaiCompat } from "./provider.js";
import { serve, type Sidecar } from "./serve.js";

let relay: Relay;
let sidecar: Sidecar;
let socket: Socket | undefined;

afterEach(async () => {
  socket?.destroy();
  await sidecar?.close();
  await relay?.close();
});

const sse = (text: string) =>
  new Response(
    `data: ${JSON.stringify({ choices: [{ delta: { content: text }, finish_reason: "stop" }] })}\n\n` +
      "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );

/** A sidecar with a relay it can reach, so the local channel is the only thing under test. */
async function localSidecar() {
  relay = await startRelay(0);
  const dir = mkdtempSync(join(tmpdir(), "yorozu-local-"));
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: dir,
    provider: openaiCompat({
      baseUrl: "https://example.invalid",
      model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => sse("pong")),
    }),
    log: () => {},
  });
  return { dir, path: localSocketPath(dir) };
}

/** The bind is a tick or two behind `serve()`, so the first connect may be early. */
async function connectLocal(path: string): Promise<Socket> {
  for (let attempt = 0; attempt < 100; attempt++) {
    try {
      return await new Promise<Socket>((resolve, reject) => {
        const pending = createConnection(path);
        pending.once("connect", () => resolve(pending));
        pending.once("error", reject);
      });
    } catch {
      await new Promise((done) => setTimeout(done, 20));
    }
  }
  throw new Error(`no local socket at ${path}`);
}

/** The socket's newline-delimited events, readable one at a time. */
function reader(from: Socket) {
  const queue: YorozuEvent[] = [];
  const waiting: ((event: YorozuEvent) => void)[] = [];
  let buffer = "";

  from.setEncoding("utf8");
  from.on("data", (chunk: string) => {
    buffer += chunk;
    const lines = buffer.split("\n");
    buffer = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      const event = JSON.parse(line) as YorozuEvent;
      const waiter = waiting.shift();
      if (waiter) waiter(event);
      else queue.push(event);
    }
  });

  const next = (): Promise<YorozuEvent> => {
    const ready = queue.shift();
    return ready ? Promise.resolve(ready) : new Promise((resolve) => waiting.push(resolve));
  };

  return {
    next,
    /** The next event of `kind`: the reply is preceded by whatever the turn emitted first. */
    async nextOf(kind: EventKind): Promise<YorozuEvent> {
      for (;;) {
        const event = await next();
        if (event.kind === kind) return event;
      }
    },
  };
}

const send = (to: Socket, threadId: string, payload: EventPayload): void => {
  const event: YorozuEvent = {
    id: `local-${Math.random()}`,
    threadId,
    ts: Date.now(),
    agentId: "mac",
    ...payload,
  };
  to.write(`${JSON.stringify(event)}\n`);
};

test("the local socket round-trips a turn and receives broadcasts, with no relay hop", async () => {
  const { path } = await localSidecar();
  socket = await connectLocal(path);
  const events = reader(socket);

  // Connecting is all the pairing there is: the thread list arrives unasked, as it does for a
  // phone whose `hello` just landed.
  expect(await events.nextOf("thread_list")).toMatchObject({
    kind: "thread_list",
    data: { threads: [{ id: "home", title: "Home", pinned: true }] },
  });

  send(socket, "home", { kind: "message", data: { role: "user", text: "ping" } });
  expect(await events.nextOf("message")).toMatchObject({
    threadId: "home",
    kind: "message",
    data: { role: "agent", text: "pong" },
  });

  // Thread admin is broadcast rather than answered to one device: getting it proves the socket
  // sits in the sidecar's session map like any paired phone.
  send(socket, "home", { kind: "thread_create", data: { title: "Groceries" } });
  const listed = await events.nextOf("thread_list");
  expect(listed.kind === "thread_list" && listed.data.threads.map((t) => t.title)).toEqual([
    "Home",
    "Groceries",
  ]);

  // And a device that holds nothing is given the history it missed.
  send(socket, "home", { kind: "sync_request", data: { lastSeen: {} } });
  const delta = await events.nextOf("sync_delta");
  expect(
    delta.kind === "sync_delta" &&
      delta.data.events.map((e) => (e.kind === "message" ? e.data.text : e.kind)),
  ).toEqual(["ping", "pong"]);
});

test("the socket is readable only by its owner and goes away with the sidecar", async () => {
  const { path } = await localSidecar();
  socket = await connectLocal(path);

  // Plaintext events cross it, so the mode is the whole access control.
  expect(statSync(path).mode & 0o777).toBe(0o600);

  await sidecar.close();
  expect(existsSync(path)).toBe(false);
});

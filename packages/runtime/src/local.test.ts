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
  /** Everything that arrived, kept as well as queued: some things are counted, not awaited. */
  const all: YorozuEvent[] = [];
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
      all.push(event);
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
    all,
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
    data: { threads: [] },
  });

  // A draft, as the Mac's own chat makes one: the create carries the id the message lands in.
  // Named up front, so no auto-title lands a thread list of its own in the middle of this.
  send(socket, "t1", { kind: "thread_create", data: { title: "Chores" } });
  await events.nextOf("thread_list");
  send(socket, "t1", { kind: "message", data: { role: "user", text: "ping" } });
  expect(await events.nextOf("message")).toMatchObject({
    threadId: "t1",
    kind: "message",
    data: { role: "agent", text: "pong" },
  });

  // Thread admin is broadcast rather than answered to one device: getting it proves the socket
  // sits in the sidecar's session map like any paired phone.
  send(socket, "t2", { kind: "thread_create", data: { title: "Groceries" } });
  const listed = await events.nextOf("thread_list");
  expect(
    listed.kind === "thread_list" && listed.data.threads.map((t) => t.title).toSorted(),
  ).toEqual(["Chores", "Groceries"]);

  // And a device that holds nothing is given the history it missed.
  send(socket, "t1", { kind: "sync_request", data: { lastSeen: {} } });
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

test("one reply is one message id, however many deltas streamed it, and the last says done", async () => {
  const { path } = await localSidecar();
  socket = await connectLocal(path);
  const events = reader(socket);
  await events.nextOf("thread_list");

  send(socket, "t1", { kind: "thread_create", data: { title: "Chores" } });
  await events.nextOf("thread_list");
  send(socket, "t1", { kind: "message", data: { role: "user", text: "ping" } });
  expect(await events.nextOf("message")).toMatchObject({ data: { role: "agent", text: "pong" } });

  // Every delta and the finished reply share one id, so a client replaces in place rather
  // than growing a bubble per delta — one reply is one bubble however it was streamed.
  await new Promise((done) => setTimeout(done, 150));
  const replies = events.all.filter(
    (event) => event.kind === "message" && event.data.role === "agent",
  );
  expect(new Set(replies.map((event) => event.id)).size).toBe(1);
  // And the last one carries `done`, which is what stops the composer offering Stop. None of
  // the deltas do: an unfinished turn must never look finished.
  expect(replies.at(-1)).toMatchObject({ data: { done: true } });
  expect(replies.slice(0, -1).every((event) => event.data.done === undefined)).toBe(true);
});

test("the device list names every device, and is pushed when one comes or goes", async () => {
  const { path } = await localSidecar();
  socket = await connectLocal(path);
  const events = reader(socket);
  await events.nextOf("thread_list");

  // Connecting is a change like any other, so the list arrives unasked...
  const opened = await events.nextOf("device_list");
  expect(opened.kind === "device_list" && opened.data.devices).toMatchObject([
    { via: "local", online: true },
  ]);
  // ...and it can be asked for, which is what the Settings window does when it opens.
  send(socket, "", { kind: "device_list", data: { devices: [] } });
  const listed = await events.nextOf("device_list");
  expect(listed.kind === "device_list" && listed.data.devices).toHaveLength(1);

  // A second client is a second device, and everyone's list is stale the moment it connects.
  const second = await connectLocal(path);
  try {
    const pushed = await events.nextOf("device_list");
    expect(pushed.kind === "device_list" && pushed.data.devices).toHaveLength(2);
    second.destroy();
    const after = await events.nextOf("device_list");
    expect(after.kind === "device_list" && after.data.devices).toHaveLength(1);
  } finally {
    second.destroy();
  }
});

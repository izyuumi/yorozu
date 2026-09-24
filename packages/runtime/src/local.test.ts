import { existsSync, mkdtempSync, statSync, writeFileSync } from "node:fs";
import { createConnection, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay, type Relay } from "@yorozu/relay";
import type { EventKind, EventPayload, YorozuEvent } from "@yorozu/shared";
import { afterEach, expect, test, vi } from "vitest";
import { localSocketPath, startLocalChannel } from "./local.js";
import { openaiCompat } from "./provider.js";
import { serve, type Sidecar } from "./serve.js";
import { OpenClawRunner } from "./openclaw.js";
import { appendThreadEvent, createThread, readThreadEvents, threadModel } from "./threads.js";
import { readTranscripts, transcriptDir } from "./transcripts.js";

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

/** A turn in which the model calls one tool, so a test can drive the tools that draw cards. */
const toolTurn = (name: string, args: Record<string, unknown>) =>
  new Response(
    `data: ${JSON.stringify({
      choices: [
        {
          delta: {
            tool_calls: [
              { index: 0, id: `call_${name}`, function: { name, arguments: JSON.stringify(args) } },
            ],
          },
          finish_reason: "tool_calls",
        },
      ],
    })}\n\n` + "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );

/**
 * A sidecar with a relay it can reach, so the local channel is the only thing under test.
 * `responses` is one per model call, in order; it falls back to a plain "pong" turn once the
 * queue runs out, which is what ends a turn that called a tool.
 */
async function localSidecar(responses: (() => Response | Promise<Response>)[] = []) {
  relay = await startRelay(0);
  const dir = mkdtempSync(join(tmpdir(), "yorozu-local-"));
  // Two entries with named models, so `model_list` has something to publish. The turns
  // themselves run on the injected provider, not on these.
  writeFileSync(
    join(dir, "providers.json"),
    JSON.stringify([
      { id: "claude", kind: "claude-cli", label: "Claude", models: ["claude-opus-5"], enabled: true },
      { id: "codex", kind: "codex-cli", label: "Codex", models: ["gpt-5.6"], enabled: true },
    ]),
  );
  const queue = [...responses];
  const fetchMock = vi.fn<typeof fetch>().mockImplementation(async () => (queue.shift() ?? (() => sse("pong")))());
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: dir,
    provider: openaiCompat({
      baseUrl: "https://example.invalid",
      model: "m",
      fetch: fetchMock,
    }),
    log: () => {},
  });
  return { dir, path: localSocketPath(dir), fetchMock };
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

test("terminal is gated, live-only, and blocks host update install while open", async () => {
  const { dir, path } = await localSidecar();
  socket = await connectLocal(path);
  const events = reader(socket);
  send(socket, "", { kind: "terminal", data: { action: "status" } });
  const initial = await events.nextOf("terminal");
  if (initial.kind !== "terminal") throw new Error("missing terminal state");
  expect(initial.data).toMatchObject({ action: "state", enabled: false });
  const epoch = initial.data.epoch!;
  send(socket, "t1", { kind: "thread_create", data: { title: "Terminal test" } });
  await events.nextOf("thread_list");

  send(socket, "t1", { kind: "terminal", data: { action: "create", epoch, cols: 80, rows: 24 } });
  const denied = await events.nextOf("terminal");
  expect(denied.kind === "terminal" && denied.data.error).toContain("disabled");
  send(socket, "", { kind: "terminal", data: { action: "enable", epoch } });
  const enabled = await events.nextOf("terminal");
  expect(enabled.kind === "terminal" && enabled.data.enabled).toBe(true);
  send(socket, "t1", { kind: "terminal", data: { action: "create", epoch, cols: 80, rows: 24 } });
  let opened = await events.nextOf("terminal");
  while (opened.kind !== "terminal" || opened.data.action !== "state" || !opened.data.sessions?.length) {
    opened = await events.nextOf("terminal");
  }
  const id = opened.data.sessions![0]!.id;
  expect(opened.data.sessions![0]!.writable).toBe(true);
  let created = await events.nextOf("terminal");
  while (created.kind !== "terminal" || created.data.action !== "created") {
    created = await events.nextOf("terminal");
  }
  expect(created.data.sessionId).toBe(id);
  expect(readThreadEvents("t1", dir)).toEqual([]);

  send(socket, "", { kind: "update_control", data: { action: "queue", updateId: "u1", version: "1.0" } });
  let status = await events.nextOf("update_status");
  while (status.kind !== "update_status" || status.data.phase !== "waiting") {
    status = await events.nextOf("update_status");
  }
  expect(status.data.openTerminals).toBe(1);
  send(socket, "", { kind: "terminal", data: { action: "close", sessionId: id, epoch } });
  send(socket, "", { kind: "update_control", data: { action: "poll", updateId: "u1" } });
  let after = await events.nextOf("update_status");
  while (after.kind !== "update_status" || after.data.phase !== "countdown") {
    after = await events.nextOf("update_status");
  }
  expect(after.data.openTerminals).toBe(0);
  expect(readThreadEvents("t1", dir)).toEqual([]);
}, 10_000);

test("simultaneous terminal creates reply only to their requesting clients", async () => {
  const { path } = await localSidecar();
  socket = await connectLocal(path);
  const other = await connectLocal(path);
  try {
    const first = reader(socket);
    const second = reader(other);
    send(socket, "", { kind: "terminal", data: { action: "status" } });
    const initial = await first.nextOf("terminal");
    if (initial.kind !== "terminal") throw new Error("missing terminal state");
    const epoch = initial.data.epoch!;
    send(socket, "", { kind: "terminal", data: { action: "enable", epoch } });
    send(socket, "t1", { kind: "thread_create", data: { title: "Concurrent terminals" } });
    let listed = await first.nextOf("thread_list");
    while (listed.kind !== "thread_list" || !listed.data.threads.some((thread) => thread.id === "t1")) {
      listed = await first.nextOf("thread_list");
    }
    send(socket, "t1", { kind: "terminal", data: { action: "create", epoch, cols: 80, rows: 24 } });
    send(other, "t1", { kind: "terminal", data: { action: "create", epoch, cols: 80, rows: 24 } });
    const created = async (events: ReturnType<typeof reader>): Promise<string> => {
      for (;;) {
        const event = await events.nextOf("terminal");
        if (event.kind === "terminal" && event.data.action === "created") return event.data.sessionId!;
      }
    };
    expect(await created(first)).not.toBe(await created(second));
  } finally {
    other.destroy();
  }
}, 10_000);

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
  expect(await events.nextOf("message")).toMatchObject({ data: { role: "user", text: "ping" } });
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

test("messages in one thread run FIFO without overlap", async () => {
  let release!: (response: Response) => void;
  const first = new Promise<Response>((resolve) => { release = resolve; });
  const { path, fetchMock } = await localSidecar([() => first, () => sse("second")]);
  socket = await connectLocal(path);
  const events = reader(socket);
  await events.nextOf("thread_list");
  send(socket, "t1", { kind: "thread_create", data: { title: "Queue" } });
  await events.nextOf("thread_list");

  send(socket, "t1", { kind: "message", data: { role: "user", text: "first" } });
  await events.nextOf("message");
  send(socket, "t1", { kind: "message", data: { role: "user", text: "second" } });
  await events.nextOf("message");
  await new Promise((done) => setTimeout(done, 20));
  expect(fetchMock).toHaveBeenCalledTimes(1);

  release(sse("first"));
  const replies = [];
  while (replies.length < 2) {
    const event = await events.nextOf("message");
    if (event.kind === "message" && event.data.role === "agent") replies.push(event.data.text);
  }
  expect(replies).toEqual(["first", "second"]);
  expect(fetchMock).toHaveBeenCalledTimes(2);
});

test("restart recovery owns FIFO head, restores queued prompts, and acks only after durable final", async () => {
  relay = await startRelay(0);
  const dir = mkdtempSync(join(tmpdir(), "yorozu-recovery-"));
  createThread("Recovery", dir, "recovery");
  const user = (id: string, text: string): YorozuEvent => ({
    id, threadId: "recovery", ts: Date.now(), agentId: "main", kind: "message", data: { role: "user", text },
  });
  appendThreadEvent(user("user-1", "install update"), dir);
  appendThreadEvent(user("user-2", "second prompt"), dir);
  let finishRecovery!: (text: string) => void;
  const recovery = new Promise<string>((resolve) => { finishRecovery = resolve; });
  const runs: string[] = [];
  const fake = {
    pendingTurns: () => [{
      threadId: "recovery", sessionKey: "agent:main:yorozu:recovery", runId: "run-1",
      startedAt: Date.now(), completionId: "final-1", userEventId: "user-1", awaitsAnnouncement: false, state: "active",
      taskIds: [], childRunIds: [], input: { text: "install update", attachments: [] },
    },
      { threadId: "recovery", sessionKey: "agent:main:yorozu:recovery", runId: "run-2",
        startedAt: Date.now() + 1, completionId: "openclaw:user-2:final", userEventId: "user-2",
        awaitsAnnouncement: false, state: "queued", taskIds: [], childRunIds: [],
        input: { text: "second prompt", attachments: [] } }],
    resume: vi.fn(async () => recovery),
    admitUserTurn: vi.fn((turn: { text: string; attachments?: unknown[] }, accept: (stored: unknown) => void) => {
      const stored = { input: { text: turn.text, attachments: turn.attachments ?? [] } };
      accept(stored);
      return stored;
    }),
    run: vi.fn(async ({ text }: { text: string }) => { runs.push(text); return `done: ${text}`; }),
    acknowledge: vi.fn((threadId: string, completionId: string) => {
      expect(readThreadEvents(threadId, dir).some((event) => event.id === completionId)).toBe(true);
    }),
    listModels: vi.fn(async () => []),
    setArchived: vi.fn(async () => {}),
  } as unknown as OpenClawRunner;
  sidecar = serve({ relayUrl: `ws://127.0.0.1:${relay.port}`, stateDir: dir, openclawRunner: fake, log: () => {} });
  socket = await connectLocal(localSocketPath(dir));
  const events = reader(socket);
  await events.nextOf("thread_list");
  socket.write(`${JSON.stringify(user("user-3", "third prompt"))}\n`);
  await new Promise((done) => setTimeout(done, 20));
  expect(runs).toEqual([]);

  finishRecovery("update finished");
  await vi.waitFor(() => expect(runs).toEqual(["second prompt", "third prompt"]));
  expect(fake.acknowledge).toHaveBeenCalledWith("recovery", "final-1");
  const history = readThreadEvents("recovery", dir);
  expect(history.filter((event) => event.id === "final-1")).toHaveLength(1);
  expect(history.filter((event) => event.kind === "message" && event.data.role === "agent" && event.data.done)).toHaveLength(3);
});

test("restart restores queued durable ledger head without an active run", async () => {
  relay = await startRelay(0);
  const dir = mkdtempSync(join(tmpdir(), "yorozu-inbox-gap-"));
  createThread("Gap", dir, "gap");
  appendThreadEvent({
    id: "gap-user", threadId: "gap", ts: Date.now(), agentId: "main", kind: "message",
    data: { role: "user", text: "survive marker gap" },
  }, dir);
  const run = vi.fn(async ({ text }: { text: string }) => `done: ${text}`);
  const fake = {
    pendingTurns: () => [{ threadId: "gap", sessionKey: "agent:main:yorozu:gap", runId: "gap-run",
      startedAt: Date.now(), completionId: "openclaw:gap-user:final", userEventId: "gap-user",
      awaitsAnnouncement: false, taskIds: [], childRunIds: [], state: "queued",
      input: { text: "survive marker gap", attachments: [] } }], admitUserTurn: vi.fn((_: unknown, accept: (stored: unknown) => void) => { accept({}); return {
        input: { text: "survive marker gap", attachments: [] },
      }; }), run, acknowledge: vi.fn(), listModels: vi.fn(async () => []),
    setArchived: vi.fn(async () => {}),
  } as unknown as OpenClawRunner;
  sidecar = serve({ relayUrl: `ws://127.0.0.1:${relay.port}`, stateDir: dir, openclawRunner: fake, log: () => {} });
  await vi.waitFor(() => expect(run).toHaveBeenCalledWith(expect.objectContaining({
    text: "survive marker gap", userEventId: "gap-user",
  })));
  await vi.waitFor(() => expect(readThreadEvents("gap", dir).some((event) =>
    event.kind === "message" && event.data.role === "agent" && event.data.done)).toBe(true));
});

test("startup reconciles transcript independently before acknowledging existing thread final", async () => {
  relay = await startRelay(0);
  const dir = mkdtempSync(join(tmpdir(), "yorozu-final-reconcile-"));
  createThread("Final", dir, "final");
  const final: YorozuEvent = {
    id: "final-id", threadId: "final", ts: Date.now(), agentId: "main", kind: "message",
    data: { role: "agent", text: "durable", done: true },
  };
  appendThreadEvent(final, dir);
  const acknowledge = vi.fn();
  const fake = {
    pendingTurns: () => [{
      threadId: "final", sessionKey: "agent:main:yorozu:final", runId: "run-final",
      startedAt: Date.now(), completionId: "final-id", awaitsAnnouncement: false, taskIds: [],
      childRunIds: [], input: { text: "update", attachments: [] }, state: "active",
    }],
    resume: vi.fn(), run: vi.fn(), acknowledge, admitUserTurn: vi.fn(), listModels: vi.fn(async () => []),
    setArchived: vi.fn(async () => {}),
  } as unknown as OpenClawRunner;
  sidecar = serve({ relayUrl: `ws://127.0.0.1:${relay.port}`, stateDir: dir, openclawRunner: fake, log: () => {} });
  await vi.waitFor(() => expect(acknowledge).toHaveBeenCalledWith("final", "final-id"));
  expect(readTranscripts(new Date(0), transcriptDir(dir)).filter((event) => event.id === "final-id")).toHaveLength(1);
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
  expect(await events.nextOf("message")).toMatchObject({ data: { role: "user", text: "ping" } });
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

/**
 * A reply the model gave in one chunk used to reach the socket twice: once as the text delta
 * and again as the finished message, identical but for `done`. Streaming deliberately runs one
 * delta behind so the finished frame is the only one carrying the whole reply.
 */
test("one turn puts one agent message on the socket when the reply did not stream", async () => {
  const { path } = await localSidecar();
  socket = await connectLocal(path);
  const events = reader(socket);
  await events.nextOf("thread_list");

  send(socket, "t1", { kind: "thread_create", data: { title: "Chores" } });
  await events.nextOf("thread_list");
  send(socket, "t1", { kind: "message", data: { role: "user", text: "ping" } });
  await events.nextOf("message");

  await new Promise((done) => setTimeout(done, 150));
  const replies = events.all.filter(
    (event) => event.kind === "message" && event.data.role === "agent",
  );
  expect(replies).toHaveLength(1);
  expect(replies[0]).toMatchObject({ data: { role: "agent", text: "pong", done: true } });
});

test("ask_user raises a question card and the answer is what the tool call returns", async () => {
  const { path } = await localSidecar([
    () => toolTurn("ask_user", { question: "Which one?", options: ["tea", "coffee"], allowOther: true }),
  ]);
  socket = await connectLocal(path);
  const events = reader(socket);
  await events.nextOf("thread_list");

  send(socket, "t1", { kind: "thread_create", data: { title: "Chores" } });
  await events.nextOf("thread_list");
  send(socket, "t1", { kind: "message", data: { role: "user", text: "make me a drink" } });

  const card = await events.nextOf("question_card");
  expect(card).toMatchObject({
    threadId: "t1",
    kind: "question_card",
    data: { question: "Which one?", options: ["tea", "coffee"], allowOther: true },
  });
  if (card.kind !== "question_card") throw new Error("expected a question card");

  send(socket, "t1", {
    kind: "question_answer",
    data: { questionId: card.data.questionId, answer: "coffee" },
  });

  // The answer is the tool call's result: the turn carries on with what the user chose.
  const result = await events.nextOf("tool_result");
  expect(result).toMatchObject({ kind: "tool_result", data: { ok: true, output: "coffee" } });
  await events.nextOf("message");
});

test("a progress card re-reported under the same id moves in place", async () => {
  const steps = (state: string) => [{ label: "call them", state }];
  const { path } = await localSidecar([
    () => toolTurn("report_progress", { cardId: "job-1", title: "Booking a table", steps: steps("running") }),
    () => toolTurn("report_progress", { cardId: "job-1", title: "Booking a table", steps: steps("done"), percent: 100 }),
  ]);
  socket = await connectLocal(path);
  const events = reader(socket);
  await events.nextOf("thread_list");

  send(socket, "t1", { kind: "thread_create", data: { title: "Chores" } });
  await events.nextOf("thread_list");
  send(socket, "t1", { kind: "message", data: { role: "user", text: "book a table" } });
  await events.nextOf("message");

  const cards = events.all.filter((event) => event.kind === "progress_card");
  expect(cards).toHaveLength(2);
  // One event id for both, which is what makes the second replace the first rather than
  // stacking a second card under it: a client upserts on the id.
  expect(new Set(cards.map((event) => event.id)).size).toBe(1);
  expect(cards[0]).toMatchObject({ data: { steps: [{ label: "call them", state: "running" }] } });
  expect(cards[1]).toMatchObject({
    data: { title: "Booking a table", steps: [{ state: "done" }], percent: 100 },
  });
});

test("the models a thread can run on arrive with the thread list, and one can be picked", async () => {
  const { dir, path } = await localSidecar();
  socket = await connectLocal(path);
  const events = reader(socket);

  // Published unasked, alongside the list: a picker has names before it is ever opened.
  const models = await events.nextOf("model_list");
  expect(models.kind === "model_list" && models.data.models).toEqual([
    { id: "claude/claude-opus-5", label: "claude-opus-5", providerLabel: "Claude" },
    { id: "codex/gpt-5.6", label: "gpt-5.6", providerLabel: "Codex" },
  ]);

  send(socket, "t1", { kind: "thread_create", data: { title: "Kyoto" } });
  await events.nextOf("thread_list");

  send(socket, "t1", { kind: "thread_set_model", data: { model: "codex/gpt-5.6" } });
  const listed = await events.nextOf("thread_list");
  expect(listed.kind === "thread_list" && listed.data.threads[0]?.model).toBe("codex/gpt-5.6");
  // It is the thread's, so it outlives the socket that set it.
  expect(threadModel("t1", dir)).toBe("codex/gpt-5.6");

  // And "Default" is the same frame with nothing in it.
  send(socket, "t1", { kind: "thread_set_model", data: { model: null } });
  const back = await events.nextOf("thread_list");
  expect(back.kind === "thread_list" && back.data.threads[0]?.model).toBeUndefined();
});

test("a thread set to a model the user has since deleted still gets an answer", async () => {
  const { path } = await localSidecar();
  socket = await connectLocal(path);
  const events = reader(socket);
  await events.nextOf("thread_list");

  send(socket, "t1", { kind: "thread_create", data: { title: "Kyoto" } });
  await events.nextOf("thread_list");
  send(socket, "t1", { kind: "thread_set_model", data: { model: "gone/x" } });
  await events.nextOf("thread_list");

  // The spec cannot be built at all, so the turn falls all the way back to the configured
  // chain: an answer from the default beats no answer.
  send(socket, "t1", { kind: "message", data: { role: "user", text: "ping" } });
  expect(await events.nextOf("message")).toMatchObject({ data: { role: "user", text: "ping" } });
  expect(await events.nextOf("message")).toMatchObject({ data: { role: "agent", text: "pong" } });
});

/** A channel with nothing listening on the other end: only the file modes are under test. */
const bareChannel = (path: string) =>
  startLocalChannel({ path, onOpen: () => {}, onEvent: () => {}, onClose: () => {} });

test("the state dir and socket are created owner-only, and the umask is put back", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "yorozu-modes-"));
  const path = join(tmp, "state", "local.sock");
  const before = process.umask();
  const channel = bareChannel(path);
  try {
    // The bind is synchronous but the listen callback, which restores the umask, is a tick later.
    await vi.waitFor(() => expect(process.umask()).toBe(before));
    // Keys and plaintext logs live in the state dir, so nobody but the owner may even list it.
    expect(statSync(join(tmp, "state")).mode & 0o777).toBe(0o700);
    expect(statSync(path).mode & 0o777).toBe(0o600);
  } finally {
    await channel.close();
  }
});

test("a wide-open umask still yields a 0600 socket, and is restored as found rather than reset", async () => {
  const original = process.umask(0o000);
  try {
    const tmp = mkdtempSync(join(tmpdir(), "yorozu-umask-"));
    const path = join(tmp, "state", "local.sock");
    const channel = bareChannel(path);
    try {
      // What the channel puts back must be what it found, not some hard-coded default.
      await vi.waitFor(() => expect(process.umask()).toBe(0o000));
      expect(statSync(path).mode & 0o777).toBe(0o600);
      expect(statSync(join(tmp, "state")).mode & 0o777).toBe(0o700);
    } finally {
      await channel.close();
    }
  } finally {
    process.umask(original);
  }
});

test("a channel closed before it ever listened still puts the umask back", async () => {
  const tmp = mkdtempSync(join(tmpdir(), "yorozu-early-close-"));
  const before = process.umask();
  // No tick between start and close: Node never emits `listening` for a server closed this
  // early, so the listen callback is not where the restore can be relied on to happen.
  await bareChannel(join(tmp, "state", "local.sock")).close();
  expect(process.umask()).toBe(before);
});

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { env } from "node:process";
import type { YorozuEvent } from "@yorozu/shared";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import {
  DELEGATE_TOOL,
  DelegationCapacity,
  MAX_CONCURRENT_DELEGATIONS,
  delegateTool,
  type DelegateOptions,
} from "./delegate.js";
import { defaultTools, echoTool, type Tool, type TurnContext } from "./index.js";
import type { Provider, ProviderEvent, ToolDef } from "./provider.js";

let dir: string;
let previousStateDir: string | undefined;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "yorozu-delegate-"));
  previousStateDir = env.YOROZU_STATE_DIR;
  env.YOROZU_STATE_DIR = dir;
  mkdirSync(join(dir, "agents"), { recursive: true });
  writeFileSync(
    join(dir, "agents", "calendar.md"),
    "---\ndescription: reads the calendar\n---\n\nYou handle calendars.",
  );
  writeFileSync(join(dir, "agents", "main.md"), "You are Yorozu.");
});

afterEach(() => {
  if (previousStateDir === undefined) delete env.YOROZU_STATE_DIR;
  else env.YOROZU_STATE_DIR = previousStateDir;
  rmSync(dir, { recursive: true, force: true });
});

const CONTEXT: TurnContext = { threadId: "home", agentId: "main" };

/** A provider that replays one scripted turn per call and records the tools it was offered. */
function scripted(turns: ProviderEvent[][]): {
  provider: Provider;
  offered: ToolDef[][];
  systems: string[];
} {
  const offered: ToolDef[][] = [];
  const systems: string[] = [];
  return {
    offered,
    systems,
    provider: {
      auth: async () => ({ ok: true }),
      async *stream(messages, tools) {
        offered.push(tools);
        systems.push(messages.find((m) => m.role === "system")?.content ?? "");
        for (const event of turns.shift() ?? []) yield event;
        yield { type: "done" };
      },
    },
  };
}

const text = (value: string): ProviderEvent[] => [{ type: "text", text: value }];

const call = (name: string, args = "{}"): ProviderEvent[] => [
  { type: "tool_call", call: { id: "c1", name, arguments: args } },
];

function options(provider: Provider, extra: Partial<DelegateOptions> = {}): DelegateOptions {
  return {
    provider,
    tools: [echoTool],
    main: { name: "main", prompt: "You are Yorozu." },
    emit: () => {},
    turn: async () => {},
    dir: join(dir, "agents"),
    ...extra,
  };
}

test("a sync delegation runs the specialist and returns its final text", async () => {
  const { provider, systems } = scripted([text("Tuesday at 3pm is free.")]);
  const events: YorozuEvent[] = [];
  const tool = delegateTool(options(provider, { emit: (event) => events.push(event) }));

  expect(await tool.run({ agent: "calendar", task: "when am I free?" }, CONTEXT)).toBe(
    "Tuesday at 3pm is free.",
  );
  // The specialist's own file is its system prompt, and it only sees the task.
  expect(systems[0]).toContain("You handle calendars.");

  expect(events).toEqual([
    expect.objectContaining({
      threadId: "home",
      agentId: "calendar",
      parentAgentId: "main",
      kind: "message",
      // `done` closes the phone's inline card for this delegation.
      data: { role: "agent", text: "Tuesday at 3pm is free.", done: true },
    }),
  ]);
  // The list of agents reaches the model, so it can pick one.
  expect(tool.description).toContain("calendar (reads the calendar)");
});

test("the specialist's events cover its tool calls too", async () => {
  const { provider } = scripted([call("echo", '{"text":"hi"}'), text("hi")]);
  const events: YorozuEvent[] = [];
  await delegateTool(options(provider, { emit: (event) => events.push(event) })).run(
    { agent: "calendar", task: "echo hi" },
    CONTEXT,
  );

  expect(
    events.map((event) => [event.kind, event.agentId, event.parentAgentId]),
  ).toEqual([
    ["tool_call", "calendar", "main"],
    ["tool_result", "calendar", "main"],
    ["message", "calendar", "main"],
  ]);
  expect(events[0]).toMatchObject({ data: { name: "echo", args: { text: "hi" } } });
  expect(events[1]).toMatchObject({ data: { ok: true, output: "hi" } });
});

test("depth is 2: a specialist is never offered delegate", async () => {
  const { provider, offered } = scripted([text("done")]);
  const parentDelegate = delegateTool(options(provider));
  const tool = delegateTool(options(provider, { tools: [echoTool, parentDelegate] }));

  await tool.run({ agent: "calendar", task: "anything" }, CONTEXT);
  expect(offered[0]!.map((t) => t.name)).toEqual(["echo"]);
});

test("a tools allowlist restricts the specialist further", async () => {
  writeFileSync(join(dir, "agents", "calendar.md"), "---\ntools: [echo]\n---\n\nCalendars.");
  const other: Tool = { ...echoTool, name: "shell" };
  const { provider, offered } = scripted([text("done")]);

  await delegateTool(options(provider, { tools: [echoTool, other] })).run(
    { agent: "calendar", task: "anything" },
    CONTEXT,
  );
  expect(offered[0]!.map((t) => t.name)).toEqual(["echo"]);
});

test("a background delegation returns at once and reports back as a new turn", async () => {
  const { provider } = scripted([text("booked")]);
  const turn = vi.fn<(threadId: string, text: string) => Promise<void>>();
  let reported!: () => void;
  const done = new Promise<void>((resolve) => (reported = resolve));
  turn.mockImplementation(async () => void reported());

  const started = await delegateTool(options(provider, { turn })).run(
    { agent: "calendar", task: "book it", background: true },
    CONTEXT,
  );
  const id = /delegation (\S+) started/.exec(started)?.[1];
  expect(id).toBeTruthy();
  expect(turn).not.toHaveBeenCalled();

  await done;
  expect(turn).toHaveBeenCalledWith("home", `delegation ${id} finished: booked`);
});

test("an abort cancels the child mid-run", async () => {
  const controller = new AbortController();
  const stop: Tool = {
    name: "stop",
    description: "Aborts the tree, as an inbound interrupt does.",
    parameters: { type: "object", properties: {}, required: [] },
    run: () => {
      controller.abort();
      return "stopped";
    },
  };
  // Two scripted turns: the second must never be asked for.
  const { provider, offered } = scripted([call("stop"), text("should not happen")]);

  const result = await delegateTool(
    options(provider, { tools: [stop], signal: controller.signal }),
  ).run({ agent: "calendar", task: "long job" }, CONTEXT);

  expect(result).toBe("delegation to calendar was interrupted");
  expect(offered).toHaveLength(1);
});

test("an unknown agent is reported, not guessed at", async () => {
  const { provider, offered } = scripted([text("nope")]);
  const tool = delegateTool(options(provider));

  expect(await tool.run({ agent: "../../etc/passwd", task: "x" }, CONTEXT)).toBe(
    "no such agent: ../../etc/passwd",
  );
  // main is the caller, never a delegation target.
  expect(await tool.run({ agent: "main", task: "x" }, CONTEXT)).toBe("no such agent: main");
  expect(offered).toEqual([]);
});

test("a background delegation shows a progress card and moves it to done", async () => {
  const { provider } = scripted([text("booked")]);
  const events: YorozuEvent[] = [];
  let reported!: () => void;
  const finished = new Promise<void>((resolve) => (reported = resolve));

  const started = await delegateTool(
    options(provider, {
      emit: (event) => events.push(event),
      turn: async () => void reported(),
    }),
  ).run({ agent: "calendar", task: "book it", background: true }, CONTEXT);
  const id = /delegation (\S+) started/.exec(started)?.[1];

  // Nobody is watching a background job, so it says it has started before it returns.
  expect(events.filter((event) => event.kind === "progress_card")).toMatchObject([
    { id, data: { cardId: id, title: "book it", steps: [{ label: "calendar", state: "running" }] } },
  ]);

  await finished;
  const cards = events.filter((event) => event.kind === "progress_card");
  expect(cards).toHaveLength(2);
  // One event id for both: the card moves rather than a second one appearing under it.
  expect(cards[1]).toMatchObject({
    id,
    threadId: "home",
    data: { steps: [{ label: "calendar", state: "done" }], percent: 100 },
  });
  // Top-level, not folded into the delegation's own card: the point of it is to be seen.
  expect(cards[1]!.parentAgentId).toBeUndefined();
});

/** A provider that cannot be reached at all, which is what a specialist failing looks like. */
const broken = (): Provider => ({
  auth: async () => ({ ok: true }),
  // eslint-disable-next-line require-yield
  async *stream() {
    throw new Error("provider is down");
  },
});

test("a specialist that throws closes its card on the way out", async () => {
  const events: YorozuEvent[] = [];
  const tool = delegateTool(options(broken(), { emit: (event) => events.push(event) }));

  await expect(tool.run({ agent: "calendar", task: "x" }, CONTEXT)).rejects.toThrow(
    "provider is down",
  );
  // Otherwise the phone's inline card for this delegation spins for ever.
  expect(events.at(-1)).toMatchObject({
    agentId: "calendar",
    kind: "message",
    data: { role: "agent", done: true },
  });
});

test("a background delegation that fails moves its card to failed and reports back", async () => {
  const events: YorozuEvent[] = [];
  const turns: string[] = [];
  let reported!: () => void;
  const finished = new Promise<void>((resolve) => (reported = resolve));

  const started = await delegateTool(
    options(broken(), {
      emit: (event) => events.push(event),
      turn: async (_threadId, text) => {
        turns.push(text);
        reported();
      },
    }),
  ).run({ agent: "calendar", task: "book it", background: true }, CONTEXT);
  const id = /delegation (\S+) started/.exec(started)?.[1];

  await finished;
  // Nobody is watching, so the failure has to arrive as both a card and a turn.
  expect(events.filter((event) => event.kind === "progress_card").at(-1)).toMatchObject({
    id,
    data: { steps: [{ label: "calendar", state: "failed" }], percent: 100 },
  });
  expect(turns).toEqual([`delegation ${id} failed: provider is down`]);
});

test("an empty task is still a delegation, not one silently dropped", async () => {
  const { provider, systems } = scripted([text("nothing to do")]);

  expect(await delegateTool(options(provider)).run({ agent: "calendar" }, CONTEXT)).toBe(
    "nothing to do",
  );
  expect(systems).toHaveLength(1);
});

test("delegate names itself and the specialists the model may pick from", () => {
  const tool = delegateTool(options(scripted([]).provider));

  expect(tool.name).toBe(DELEGATE_TOOL);
  expect(tool.parameters).toMatchObject({
    type: "object",
    required: ["agent", "task"],
    // The enum is built from the agents on disk, so the model cannot invent one.
    properties: { agent: { enum: ["calendar"] } },
  });
});

test("delegation capacity bounds concurrent workers and frees a slot on completion", async () => {
  let release!: () => void;
  const held = new Promise<void>((resolve) => (release = resolve));
  const provider: Provider = {
    auth: async () => ({ ok: true }),
    async *stream() {
      await held;
      yield { type: "text", text: "done" };
      yield { type: "done" };
    },
  };
  const capacity = new DelegationCapacity();
  // Separate tool instances model separate main-agent turns in the same sidecar.
  const tool = delegateTool(options(provider, { capacity }));
  const nextTurnTool = delegateTool(options(provider, { capacity }));
  const running = Array.from({ length: MAX_CONCURRENT_DELEGATIONS }, (_, index) =>
    (index % 2 ? tool : nextTurnTool).run(
      { agent: "calendar", task: `slice ${index}` },
      CONTEXT,
    ),
  );

  expect(await nextTurnTool.run({ agent: "calendar", task: "overflow" }, CONTEXT)).toBe(
    `delegation capacity reached (${MAX_CONCURRENT_DELEGATIONS}); retry when a worker finishes`,
  );
  release();
  await expect(Promise.all(running)).resolves.toEqual(
    Array(MAX_CONCURRENT_DELEGATIONS).fill("done"),
  );
  await expect(nextTurnTool.run({ agent: "calendar", task: "next" }, CONTEXT)).resolves.toBe(
    "done",
  );
});

test("delegate is built per turn, not shared, and a call by name reaches it", async () => {
  // The CLI has no specialists to hand work to, so the shared list must not carry delegate.
  expect(defaultTools.map((tool) => tool.name)).not.toContain(DELEGATE_TOOL);

  const { provider } = scripted([text("done")]);
  const tools = [...defaultTools, delegateTool(options(provider))];
  const registered = tools.find((tool) => tool.name === DELEGATE_TOOL)!;

  expect(await registered.run({ agent: "calendar", task: "anything" }, CONTEXT)).toBe("done");
});

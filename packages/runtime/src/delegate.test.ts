import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { env } from "node:process";
import type { YorozuEvent } from "@yorozu/shared";
import { afterEach, beforeEach, expect, test, vi } from "vitest";
import { delegateTool, type DelegateOptions } from "./delegate.js";
import { echoTool, type Tool, type TurnContext } from "./index.js";
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
      data: { role: "agent", text: "Tuesday at 3pm is free." },
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

import { readFile } from "node:fs/promises";
import { beforeEach, expect, test, vi } from "vitest";
import type { ProviderEvent, ToolDef } from "./provider.js";
import { defaultTools, runAgent } from "./index.js";

const { codexMock, startThreadMock, runStreamedMock } = vi.hoisted(() => {
  const runStreamedMock = vi.fn();
  const startThreadMock = vi.fn(() => ({ runStreamed: runStreamedMock }));
  return {
    runStreamedMock,
    startThreadMock,
    codexMock: vi.fn(() => ({ startThread: startThreadMock })),
  };
});

vi.mock("@openai/codex-sdk", () => ({ Codex: codexMock }));

const { codexCli } = await import("./codex.js");
const { callAdapter } = await import("./mcp-bridge.js");
const { composeProviders } = await import("./chain.js");

const ECHO: ToolDef = {
  name: "echo",
  description: "Echo the given text back to the caller.",
  parameters: { type: "object", properties: { text: { type: "string" } } },
};

beforeEach(() => {
  vi.clearAllMocks();
});

/** Polls until `read` returns something, so the test never guesses at a delay. */
async function until<T>(read: () => T | undefined): Promise<T> {
  for (let i = 0; i < 200; i++) {
    const value = read();
    if (value !== undefined) return value;
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  throw new Error("timed out");
}

test("a bridge call becomes a tool_call, and the loop's result goes back down the socket", async () => {
  // The Codex turn says nothing until the tool call it is waiting on has been answered.
  let release: () => void = () => {};
  const answered = new Promise<void>((resolve) => (release = resolve));
  runStreamedMock.mockResolvedValue({
    events: (async function* () {
      await answered;
      yield { type: "item.completed", item: { type: "agent_message", text: "pong" } };
      yield { type: "turn.completed", usage: {} };
    })(),
  });

  const provider = codexCli();
  const first: ProviderEvent[] = [];
  const turn = (async () => {
    for await (const event of provider.stream([{ role: "user", content: "say pong" }], [ECHO]))
      first.push(event);
  })();

  // The bridge is registered as an MCP server, spawned with the file holding this turn's
  // socket path and catalog.
  const spawn = await until(
    () =>
      (
        codexMock.mock.calls[0]?.[0] as
          | {
              config?: {
                mcp_servers: {
                  yorozu: {
                    command: string;
                    args: string[];
                    default_tools_approval_mode: string;
                  };
                };
              };
            }
          | undefined
      )?.config?.mcp_servers.yorozu,
  );
  expect(spawn.args[0]).toMatch(/mcp-bridge\.js$/);
  // Codex approves its own MCP calls; the gate that matters is the loop's.
  expect(spawn.default_tools_approval_mode).toBe("approve");
  const bridge = JSON.parse(await readFile(spawn.args[1]!, "utf8")) as {
    socket: string;
    tools: ToolDef[];
  };
  expect(bridge.tools).toEqual([ECHO]);

  // Standing in for the bridge: forward a call and hold the MCP reply until it is answered.
  const forwarded = callAdapter(bridge.socket, { name: "echo", arguments: { text: "ping" } });

  await turn;
  expect(first).toEqual([
    {
      type: "tool_call",
      call: { id: "codex_1", name: "echo", arguments: '{"text":"ping"}' },
    },
    { type: "done", reason: "tool_calls" },
  ]);

  // What the loop does next: dispatch, then stream again with the result in the history.
  release();
  const second = await Array.fromAsync(
    provider.stream(
      [
        { role: "user", content: "say pong" },
        { role: "assistant", content: "", tool_calls: [{ id: "codex_1", name: "echo", arguments: "{}" }] },
        { role: "tool", tool_call_id: "codex_1", content: "ping" },
      ],
      [ECHO],
    ),
  );

  expect(await forwarded).toBe("ping");
  expect(second).toEqual([
    { type: "text", text: "pong" },
    { type: "done", reason: "stop" },
  ]);
  // One Codex turn for the whole exchange, not one per tool call.
  expect(runStreamedMock).toHaveBeenCalledTimes(1);
});

test("a bridge that fails before the first token lets the chain advance", async () => {
  runStreamedMock.mockRejectedValue(new Error("spawn node ENOENT"));

  const fallback = {
    auth: async () => ({ ok: true }),
    async *stream(): AsyncGenerator<ProviderEvent> {
      yield { type: "text", text: "from the fallback" };
      yield { type: "done", reason: "stop" };
    },
  };

  expect(
    await Array.fromAsync(
      composeProviders(codexCli(), [fallback]).stream([{ role: "user", content: "ping" }], [ECHO]),
    ),
  ).toEqual([
    { type: "text", text: "from the fallback" },
    { type: "done", reason: "stop" },
  ]);
});

test("Codex bridge browser_open reaches the registered browser implementation", async () => {
  let release: () => void = () => {};
  const answered = new Promise<void>((resolve) => (release = resolve));
  runStreamedMock.mockResolvedValue({
    events: (async function* () {
      await answered;
      yield { type: "turn.completed", usage: {} };
    })(),
  });
  const browserOpen = defaultTools.find((tool) => tool.name === "browser.open")!;
  const open = vi.spyOn(browserOpen, "run").mockResolvedValue("tab-1");
  try {
    const turn = Array.fromAsync(runAgent({
      provider: codexCli(), system: "Open the page.",
      messages: [{ role: "user", content: "Open https://example.com" }],
    }));
    const configFile = await until(() =>
      (codexMock.mock.calls[0]?.[0] as { config?: { mcp_servers: { yorozu: { args: string[] } } } } | undefined)
        ?.config?.mcp_servers.yorozu.args[1],
    );
    const bridge = JSON.parse(await readFile(configFile, "utf8")) as { socket: string };
    const result = await callAdapter(bridge.socket, { name: "browser_open", arguments: { url: "https://example.com" } });
    release();
    await turn;
    expect(result).toBe("tab-1");
    expect(open).toHaveBeenCalledWith({ url: "https://example.com" }, undefined);
  } finally {
    release();
    open.mockRestore();
  }
});

test("a bridge that fails after the first token fails the turn", async () => {
  runStreamedMock.mockResolvedValue({
    events: (async function* () {
      yield { type: "item.completed", item: { type: "agent_message", text: "half a" } };
      yield { type: "error", message: "yorozu bridge: the adapter closed the socket" };
    })(),
  });

  const events: ProviderEvent[] = [];
  await expect(async () => {
    for await (const event of composeProviders(codexCli()).stream(
      [{ role: "user", content: "ping" }],
      [ECHO],
    ))
      events.push(event);
  }).rejects.toThrow("closed the socket");
  expect(events).toEqual([{ type: "text", text: "half a" }]);
});

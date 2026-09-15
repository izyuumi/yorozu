import { readFile } from "node:fs/promises";
import { beforeEach, expect, test, vi } from "vitest";
import { echoTool, runAgent, type Tool } from "./index.js";

const { codexMock, runStreamedMock } = vi.hoisted(() => {
  const runStreamedMock = vi.fn();
  return {
    runStreamedMock,
    codexMock: vi.fn(() => ({ startThread: () => ({ runStreamed: runStreamedMock }) })),
  };
});
vi.mock("@openai/codex-sdk", () => ({ Codex: codexMock }));
const { codexCli } = await import("./codex.js");
const { callAdapter } = await import("./mcp-bridge.js");

beforeEach(() => vi.clearAllMocks());

async function socketFor(index: number): Promise<string> {
  await vi.waitFor(() => expect(codexMock.mock.calls.length).toBeGreaterThan(index));
  const config = codexMock.mock.calls[index]![0] as {
    config: { mcp_servers: { yorozu: { args: string[] } } };
  };
  return (JSON.parse(await readFile(config.config.mcp_servers.yorozu.args[1]!, "utf8")) as { socket: string }).socket;
}

function heldTurn(text: string) {
  const ready = Promise.withResolvers<void>();
  const returned = vi.fn(async () => ({ done: true as const, value: undefined }));
  const next = vi.fn(async () => {
    await ready.promise;
    return { done: false as const, value: next.mock.calls.length === 1
      ? { type: "item.completed", item: { type: "agent_message", text } }
      : { type: "turn.completed" } };
  });
  runStreamedMock.mockResolvedValueOnce({ events: { next, return: returned } });
  return { release: () => ready.resolve(), returned };
}

test("a delegated Codex loop preserves its parent's paused session and tool result", async () => {
  const parent = heldTurn("parent done");
  const child = heldTurn("child done");
  const provider = codexCli();
  const delegate: Tool = {
    name: "delegate", description: "delegate", parameters: {},
    run: async () => {
      const events = await Array.fromAsync(runAgent({
        provider, system: "", messages: [{ role: "user", content: "child" }], tools: [echoTool],
      }));
      return events.findLast((event) => event.type === "final")!.text;
    },
  };
  const running = Array.fromAsync(runAgent({
    provider, system: "", messages: [{ role: "user", content: "parent" }], tools: [delegate],
  }));
  const parentReply = callAdapter(await socketFor(0), { name: "delegate", arguments: {} });
  const parentAnswered = parentReply.then((result) => { parent.release(); return result; });
  const childSocket = await socketFor(1);
  expect(parent.returned).not.toHaveBeenCalled();
  const childReply = callAdapter(childSocket, { name: "echo", arguments: { text: "child result" } });
  expect(await childReply).toBe("child result");
  child.release();
  expect(await parentAnswered).toBe("child done");
  expect((await running).at(-1)).toEqual({ type: "final", text: "parent done" });
  expect(runStreamedMock).toHaveBeenCalledTimes(2);
  expect(parent.returned).toHaveBeenCalledTimes(1);
  expect(child.returned).toHaveBeenCalledTimes(1);
});

test("ending a loop at its tool-turn limit closes the waiting bridge socket", async () => {
  const turn = heldTurn("unused");
  const provider = codexCli();
  const running = Array.fromAsync(runAgent({
    provider, system: "", messages: [{ role: "user", content: "echo" }],
    tools: [echoTool], maxTurns: 1,
  }));
  const reply = callAdapter(await socketFor(0), { name: "echo", arguments: { text: "hello" } });
  const rejected = expect(reply).rejects.toThrow("closed the socket");
  await running;
  await rejected;
  expect(turn.returned).toHaveBeenCalledTimes(1);
});

test("abort closes an active Codex stream even while no events arrive", async () => {
  const turn = heldTurn("unused");
  const controller = new AbortController();
  const running = Array.fromAsync(runAgent({
    provider: codexCli(), system: "", messages: [{ role: "user", content: "wait" }],
    tools: [echoTool], signal: controller.signal,
  }));
  await socketFor(0);
  controller.abort();
  await running;
  expect(turn.returned).toHaveBeenCalledTimes(1);
});

import { beforeEach, expect, test, vi } from "vitest";

const { queryMock, createServerMock, execFileMock, accessSyncMock } = vi.hoisted(() => ({
  queryMock: vi.fn(),
  createServerMock: vi.fn(() => ({ type: "sdk", name: "yorozu" })),
  execFileMock: vi.fn(),
  accessSyncMock: vi.fn(),
}));

vi.mock("@anthropic-ai/claude-agent-sdk", () => ({
  query: queryMock,
  createSdkMcpServer: createServerMock,
}));
vi.mock("node:child_process", () => ({ execFile: execFileMock }));
vi.mock("node:fs", () => ({ accessSyncMock, accessSync: accessSyncMock, constants: { X_OK: 1 } }));

const { claudeCli } = await import("./claude.js");

/** A stand-in for the SDK's Query: an async iterable of messages plus close(). */
function session(messages: unknown[], failsWith?: Error) {
  const iterator = (async function* () {
    for (const message of messages) yield message;
    if (failsWith) throw failsWith;
  })();
  return Object.assign(iterator, { close: vi.fn() });
}

const echo = {
  name: "echo",
  description: "Echo the given text back to the caller.",
  parameters: {
    type: "object",
    properties: { text: { type: "string" } },
    required: ["text"],
  },
};

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("PATH", "/bin");
});

test("maps assistant text and a tool call, leaving dispatch to the loop", async () => {
  // The denial interrupts the turn, so the SDK's own error lands after the tool call.
  queryMock.mockReturnValue(
    session(
      [
        {
          type: "assistant",
          message: {
            content: [
              { type: "text", text: "on it" },
              {
                type: "tool_use",
                id: "toolu_1",
                name: "mcp__yorozu__echo",
                input: { text: "hi" },
              },
            ],
          },
        },
      ],
      new Error("interrupted by user"),
    ),
  );

  const events = await Array.fromAsync(
    claudeCli({ model: "claude-sonnet-5" }).stream(
      [
        { role: "system", content: "sys" },
        { role: "user", content: "echo hi" },
      ],
      [echo],
      { effort: "medium" },
    ),
  );

  expect(events).toEqual([
    { type: "text", text: "on it" },
    { type: "tool_call", call: { id: "toolu_1", name: "echo", arguments: '{"text":"hi"}' } },
    { type: "done", reason: "tool_calls" },
  ]);

  // Our tools went in as in-process MCP tools, and nothing of Claude Code's own.
  const server = createServerMock.mock.calls[0]![0] as { tools: { name: string }[] };
  expect(server.tools.map((t) => t.name)).toEqual(["echo"]);

  const options = (queryMock.mock.calls[0]![0] as { options: Record<string, any> }).options;
  expect(options.model).toBe("claude-sonnet-5");
  expect(options.effort).toBe("medium");
  expect(options.systemPrompt).toBe("sys");
  expect(options.tools).toEqual([]);
  expect(options.settingSources).toEqual([]);
  // Listing the tool in allowedTools would auto-approve and run it in-process.
  expect(options.allowedTools).toBeUndefined();
  expect(await options.canUseTool("mcp__yorozu__echo", {})).toMatchObject({
    behavior: "deny",
    interrupt: true,
  });
});

test("a failure with no tool call to show for it propagates to the chain", async () => {
  queryMock.mockReturnValue(session([], new Error("401 unauthorized")));

  await expect(
    Array.fromAsync(claudeCli().stream([{ role: "user", content: "hi" }], [])),
  ).rejects.toThrow("401");
});

test("auth is ok when the CLI is on PATH and logged in", async () => {
  execFileMock.mockImplementation((_file, _args, _options, done) =>
    done(null, '{"loggedIn":true,"authMethod":"oauth_token"}', ""),
  );

  expect(await claudeCli().auth()).toEqual({ ok: true });
  expect(execFileMock.mock.calls[0]![1]).toEqual(["auth", "status", "--json"]);
});

test("auth fails when the CLI is installed but logged out", async () => {
  execFileMock.mockImplementation((_file, _args, _options, done) =>
    done(null, '{"loggedIn":false}', ""),
  );

  expect(await claudeCli().auth()).toEqual({
    ok: false,
    reason: "claude is installed but not logged in",
  });
});

test("auth fails when the binary is missing", async () => {
  accessSyncMock.mockImplementation(() => {
    throw new Error("ENOENT");
  });

  expect(await claudeCli().auth()).toEqual({ ok: false, reason: "claude is not on PATH" });
  expect(execFileMock).not.toHaveBeenCalled();
});

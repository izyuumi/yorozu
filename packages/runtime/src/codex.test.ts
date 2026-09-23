import { beforeEach, expect, test, vi } from "vitest";

const { codexMock, startThreadMock, runStreamedMock, execFileMock, accessSyncMock } =
  vi.hoisted(() => {
    const runStreamedMock = vi.fn();
    const startThreadMock = vi.fn(() => ({ runStreamed: runStreamedMock }));
    return {
      runStreamedMock,
      startThreadMock,
      codexMock: vi.fn(function () { return { startThread: startThreadMock }; }),
      execFileMock: vi.fn(),
      accessSyncMock: vi.fn(),
    };
  });

vi.mock("@openai/codex-sdk", () => ({ Codex: codexMock }));
vi.mock("node:child_process", () => ({ execFile: execFileMock }));
vi.mock("node:fs", () => ({ accessSync: accessSyncMock, constants: { X_OK: 1 } }));

const { codexCli } = await import("./codex.js");

const streamOf = (events: unknown[]) => ({
  events: (async function* () {
    for (const event of events) yield event;
  })(),
});

beforeEach(() => {
  vi.clearAllMocks();
  vi.stubEnv("PATH", "/bin");
});

test("maps an agent message and a completed turn", async () => {
  runStreamedMock.mockResolvedValue(
    streamOf([
      { type: "thread.started", thread_id: "t1" },
      { type: "turn.started" },
      { type: "item.completed", item: { id: "i1", type: "reasoning", text: "thinking" } },
      { type: "item.completed", item: { id: "i2", type: "agent_message", text: "pong" } },
      { type: "turn.completed", usage: {} },
    ]),
  );

  const events = await Array.fromAsync(
    codexCli({ model: "gpt-5.6" }).stream(
      [
        { role: "system", content: "sys" },
        { role: "user", content: "ping" },
      ],
      [],
      { effort: "high" },
    ),
  );

  expect(events).toEqual([
    { type: "text", text: "pong" },
    { type: "done", reason: "stop" },
  ]);
  // The user's own logged-in binary, not the one the SDK bundles.
  expect(codexMock.mock.calls[0]![0]).toEqual({ codexPathOverride: "/bin/codex" });
  expect(startThreadMock.mock.calls[0]![0]).toMatchObject({
    model: "gpt-5.6",
    modelReasoningEffort: "high",
  });
  // System prompt and transcript arrive as the one prompt the CLI takes.
  expect(runStreamedMock.mock.calls[0]![0]).toBe("sys\n\nUser: ping");
});

test("a usage limit fails the turn so the chain can advance", async () => {
  runStreamedMock.mockResolvedValue(
    streamOf([
      { type: "turn.started" },
      { type: "turn.failed", error: { message: "You've hit your usage limit." } },
    ]),
  );

  await expect(
    Array.fromAsync(codexCli().stream([{ role: "user", content: "ping" }], [])),
  ).rejects.toThrow("usage limit");
});

test("auth is ok when the CLI is on PATH and logged in", async () => {
  // The real CLI reports this on stderr and exits 0.
  execFileMock.mockImplementation((_file, _args, _options, done) =>
    done(null, "", "Logged in using ChatGPT\n"),
  );

  expect(await codexCli().auth()).toEqual({ ok: true });
  expect(execFileMock.mock.calls[0]![1]).toEqual(["login", "status"]);
});

test("auth fails when the CLI is installed but logged out", async () => {
  execFileMock.mockImplementation((_file, _args, _options, done) =>
    done(null, "", "Not logged in\n"),
  );

  expect(await codexCli().auth()).toEqual({
    ok: false,
    reason: "codex is installed but not logged in",
  });
});

test("auth fails when the binary is missing", async () => {
  accessSyncMock.mockImplementation(() => {
    throw new Error("ENOENT");
  });

  expect(await codexCli().auth()).toEqual({ ok: false, reason: "codex is not on PATH" });
  expect(execFileMock).not.toHaveBeenCalled();
});

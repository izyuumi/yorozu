import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test, vi } from "vitest";
import { defaultTools, describeEvent, echoTool, eventPayload, runAgent, type Tool } from "./index.js";
import { openaiCompat } from "./provider.js";

test("describes an event", () => {
  expect(describeEvent({ id: "e1", threadId: "home", kind: "thought" })).toBe(
    "[home] thought",
  );
});

test("tool events become wire payloads; the turn's own text does not", () => {
  expect(
    eventPayload({ type: "tool_call", call: { id: "c1", name: "echo", arguments: '{"text":"hi"}' } }),
  ).toEqual({ kind: "tool_call", data: { callId: "c1", name: "echo", args: { text: "hi" } } });

  // Arguments are raw model output: unparseable JSON travels as-is rather than killing the event.
  expect(
    eventPayload({ type: "tool_call", call: { id: "c2", name: "echo", arguments: "{oops" } }),
  ).toMatchObject({ data: { args: { raw: "{oops" } } });

  expect(eventPayload({ type: "tool_result", id: "c1", name: "echo", result: "hi" })).toEqual({
    kind: "tool_result",
    data: { callId: "c1", ok: true, output: "hi" },
  });
  expect(
    eventPayload({ type: "tool_result", id: "c1", name: "echo", result: "error: boom" }),
  ).toMatchObject({ data: { ok: false } });

  expect(eventPayload({ type: "text", text: "hi" })).toBeNull();
  expect(eventPayload({ type: "final", text: "hi" })).toBeNull();
});

/** An SSE response body built from scripted chat-completion chunks. */
function sse(chunks: unknown[]): Response {
  const body = chunks.map((c) => `data: ${JSON.stringify(c)}\n\n`).join("");
  return new Response(`${body}data: [DONE]\n\n`, {
    headers: { "content-type": "text/event-stream" },
  });
}

const toolCallTurn = [
  {
    choices: [
      {
        delta: {
          tool_calls: [
            { index: 0, id: "call_1", function: { name: "ec", arguments: '{"te' } },
          ],
        },
      },
    ],
  },
  {
    choices: [
      {
        delta: {
          tool_calls: [
            { index: 0, function: { name: "ho", arguments: 'xt":"hi"}' } },
          ],
        },
        finish_reason: "tool_calls",
      },
    ],
  },
];

const finalTurn = [
  { choices: [{ delta: { content: "echoed: " } }] },
  { choices: [{ delta: { content: "hi" } }, { finish_reason: "stop" }] },
];

test("loop dispatches a streamed tool call and returns final text", async () => {
  const fetchMock = vi
    .fn<typeof fetch>()
    .mockResolvedValueOnce(sse(toolCallTurn))
    .mockResolvedValueOnce(sse(finalTurn));

  const provider = openaiCompat({
    baseUrl: "https://example.invalid",
    apiKey: "k",
    model: "m",
    fetch: fetchMock,
  });

  const events = await Array.fromAsync(
    runAgent({
      provider,
      system: "sys",
      messages: [{ role: "user", content: "echo hi" }],
    }),
  );

  expect(events).toEqual([
    {
      type: "tool_call",
      call: { id: "call_1", name: "echo", arguments: '{"text":"hi"}' },
    },
    { type: "tool_result", id: "call_1", name: "echo", result: "hi" },
    { type: "text", text: "echoed: " },
    { type: "text", text: "hi" },
    { type: "final", text: "echoed: hi" },
  ]);

  // Second request carries the assistant tool call and the tool result.
  const [url, init] = fetchMock.mock.calls[1]!;
  expect(url).toBe("https://example.invalid/v1/chat/completions");
  const sent = JSON.parse(String(init!.body)) as {
    messages: unknown[];
    tools: { function: { name: string } }[];
  };
  expect(sent.tools.map((t) => t.function.name)).toEqual([
    "echo",
    "remember",
    "schedule",
    "unschedule",
    "list_schedule",
    "read_transcripts",
    "shell",
    "fs_read",
    "fs_write",
    "fs_list",
    "screen_read",
    "screen_capture",
    "input_click",
    "input_type",
    "input_key",
    "browser.open",
    "browser.snapshot",
    "browser.click",
    "browser.type",
    "browser.eval",
    "browser.close",
    "skill",
    "auto_assign_models",
    "calendar_list",
    "calendar_events",
    "calendar_create",
    "calendar_update",
    "calendar_delete",
    "reminders_list",
    "reminders_create",
    "reminders_complete",
    "mail_unread",
    "mail_read",
    "mail_send",
    "request_permission",
    "fetch",
    "web_search",
  ]);
  expect(sent.messages.at(-2)).toEqual({
    role: "assistant",
    content: "",
    tool_calls: [
      {
        id: "call_1",
        type: "function",
        function: { name: "echo", arguments: '{"text":"hi"}' },
      },
    ],
  });
  expect(sent.messages.at(-1)).toEqual({
    role: "tool",
    tool_call_id: "call_1",
    content: "hi",
  });
});

test("listModels and auth hit /v1/models", async () => {
  const fetchMock = vi
    .fn<typeof fetch>()
    // A fresh Response per call: a body can only be read once.
    .mockImplementation(async () =>
      Response.json({ data: [{ id: "m1" }, { id: "m2" }] }),
    );
  const provider = openaiCompat({
    baseUrl: "https://example.invalid/v1/",
    model: "m",
    fetch: fetchMock,
  });

  expect(await provider.listModels()).toEqual(["m1", "m2"]);
  expect(fetchMock.mock.calls[0]![0]).toBe("https://example.invalid/v1/models");
  expect(await provider.auth()).toEqual({ ok: true });
});

test("auth reports why it failed", async () => {
  const provider = openaiCompat({
    baseUrl: "https://example.invalid",
    model: "m",
    fetch: vi
      .fn<typeof fetch>()
      .mockResolvedValue(new Response("nope", { status: 401 })),
  });
  const result = await provider.auth();
  expect(result.ok).toBe(false);
  expect(result.reason).toContain("401");
});

test("OpenAI-compatible requests carry selected reasoning effort", async () => {
  const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(sse(finalTurn));
  const provider = openaiCompat({
    baseUrl: "https://example.invalid",
    model: "m",
    fetch: fetchMock,
  });

  await Array.fromAsync(provider.stream([{ role: "user", content: "think" }], [], { effort: "high" }));

  expect(JSON.parse(String(fetchMock.mock.calls[0]![1]!.body))).toMatchObject({
    reasoning_effort: "high",
  });
});

test("images go out as content parts, and only when there are any", async () => {
  const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(sse(finalTurn));
  const provider = openaiCompat({
    baseUrl: "https://example.invalid",
    model: "m",
    fetch: fetchMock,
  });
  expect(provider.vision).toBe(true);

  await Array.fromAsync(
    provider.stream(
      [
        { role: "user", content: "what is this?", images: [{ mime: "image/png", data: "aGk=" }] },
        { role: "user", content: "plain" },
      ],
      [],
    ),
  );

  const sent = JSON.parse(String(fetchMock.mock.calls[0]![1]!.body)) as {
    messages: unknown[];
  };
  expect(sent.messages[0]).toEqual({
    role: "user",
    content: [
      { type: "text", text: "what is this?" },
      { type: "image_url", image_url: { url: "data:image/png;base64,aGk=" } },
    ],
  });
  // `images` is ours, not the wire's, and a message without any keeps its plain string content.
  expect(sent.messages[1]).toEqual({ role: "user", content: "plain" });
});

test("a provider told its model cannot see says so, and is then never handed images", () => {
  expect(
    openaiCompat({ baseUrl: "https://example.invalid", model: "m", vision: false }).vision,
  ).toBe(false);
});

/** Two tool calls in one turn: one gated, one not. */
const twoCallTurn = [
  {
    choices: [
      {
        delta: {
          tool_calls: [
            { index: 0, id: "gated", function: { name: "mail_send", arguments: '{"to":"bob"}' } },
            { index: 1, id: "free", function: { name: "look", arguments: "{}" } },
          ],
        },
        finish_reason: "tool_calls",
      },
    ],
  },
];

test("30: a call waiting on approval does not hold up the independent call beside it", async () => {
  // The gate writes its decision log, and that must land in a throwaway directory rather than
  // in the real one this machine's Yorozu uses.
  vi.stubEnv("YOROZU_STATE_DIR", mkdtempSync(join(tmpdir(), "yorozu-branch-")));

  const provider = openaiCompat({
    baseUrl: "https://example.invalid",
    apiKey: "k",
    model: "m",
    fetch: vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(sse(twoCallTurn))
      .mockResolvedValueOnce(sse(finalTurn)),
  });

  /** Set the moment the ungated tool actually runs. */
  let looked = false;
  /** What the card saw of the world at the moment it was answered. */
  let lookedBeforeAnswering = false;

  const mailer: Tool = {
    name: "mail_send",
    description: "",
    parameters: {},
    actionClass: "send-message",
    action: ({ to }) => ({ target: String(to ?? ""), recipient: String(to ?? "") }),
    run: () => "sent",
  };
  const reader: Tool = {
    name: "look",
    description: "",
    parameters: {},
    run: () => {
      looked = true;
      return "looked";
    },
  };

  const events = await Array.fromAsync(
    runAgent({
      provider,
      system: "sys",
      messages: [{ role: "user", content: "mail bob and look something up" }],
      tools: [mailer, reader],
      ask: async () => {
        // A card is up. Whatever else the turn had to do should be getting on with it, so
        // this yields the microtask queue a few times rather than answering instantly.
        for (let i = 0; i < 5; i++) await Promise.resolve();
        lookedBeforeAnswering = looked;
        return { answer: "yes" };
      },
    }),
  );

  expect(lookedBeforeAnswering).toBe(true);
  // Both still come back, in the order the model asked for them, so the model reads them the
  // way it wrote them.
  expect(
    events.filter((event) => event.type === "tool_result").map((event) => event.id),
  ).toEqual(["gated", "free"]);

  vi.unstubAllEnvs();
});

// MARK: echo

test("echo hands back the text it was given, unchanged", () => {
  expect(echoTool.run({ text: "hi" })).toBe("hi");
  // Unicode and line breaks cross the tool boundary character for character.
  expect(echoTool.run({ text: "こんにちは 🐈\nsecond line" })).toBe("こんにちは 🐈\nsecond line");
});

test("echo has nothing to say when the model gave it nothing", () => {
  for (const args of [{}, { text: "" }, { text: null }, { text: undefined }]) {
    expect(echoTool.run(args)).toBe("");
  }
});

/** Arguments are model output: a number where a string was asked for is text, not a crash. */
test("echo coerces a non-string rather than throwing at the model", () => {
  expect(echoTool.run({ text: 42 })).toBe("42");
  expect(echoTool.run({ text: false })).toBe("false");
});

test("echo's schema names one required string parameter", () => {
  expect(echoTool.name).toBe("echo");
  expect(echoTool.parameters).toEqual({
    type: "object",
    properties: { text: { type: "string" } },
    required: ["text"],
  });
});

test("echo is registered in the shared tool list, and a call by name reaches it", () => {
  // The list above pins the whole registry; this pins that the name resolves to this object.
  const registered = defaultTools.find((tool) => tool.name === "echo");
  expect(registered).toBe(echoTool);
  expect(registered!.run({ text: "through the registry" })).toBe("through the registry");
});

/** One tool call whose arguments are not JSON at all. */
const brokenCallTurn = [
  {
    choices: [
      {
        delta: {
          tool_calls: [{ index: 0, id: "bad", function: { name: "echo", arguments: "{not json" } }],
        },
        finish_reason: "tool_calls",
      },
    ],
  },
];

const unknownCallTurn = [
  {
    choices: [
      {
        delta: {
          tool_calls: [{ index: 0, id: "who", function: { name: "telepathy", arguments: "{}" } }],
        },
        finish_reason: "tool_calls",
      },
    ],
  },
];

/** The registry parses the arguments before it dispatches, so a broken call never executes. */
test("a malformed tool call is refused before the tool runs, as a result the model can read", async () => {
  const ran = vi.fn(() => "should not have run");
  const spy: Tool = { name: "echo", description: "", parameters: {}, run: ran };
  const provider = openaiCompat({
    baseUrl: "https://example.invalid",
    apiKey: "k",
    model: "m",
    fetch: vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(sse(brokenCallTurn))
      .mockResolvedValueOnce(sse(finalTurn)),
  });

  const events = await Array.fromAsync(
    runAgent({
      provider,
      system: "sys",
      messages: [{ role: "user", content: "echo hi" }],
      tools: [spy],
    }),
  );

  expect(events.find((event) => event.type === "tool_result")).toMatchObject({
    id: "bad",
    result: expect.stringMatching(/^error: /),
  });
  expect(ran).not.toHaveBeenCalled();
});

test("a call naming a tool the registry does not have is reported, not guessed at", async () => {
  const provider = openaiCompat({
    baseUrl: "https://example.invalid",
    apiKey: "k",
    model: "m",
    fetch: vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(sse(unknownCallTurn))
      .mockResolvedValueOnce(sse(finalTurn)),
  });

  const events = await Array.fromAsync(
    runAgent({
      provider,
      system: "sys",
      messages: [{ role: "user", content: "read my mind" }],
      tools: [echoTool],
    }),
  );

  expect(events.find((event) => event.type === "tool_result")).toMatchObject({
    result: "unknown tool: telepathy",
  });
});

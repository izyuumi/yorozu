import { expect, test, vi } from "vitest";
import { describeEvent, runAgent } from "./index.js";
import { openaiCompat } from "./provider.js";

test("describes an event", () => {
  expect(describeEvent({ id: "e1", threadId: "home", kind: "thought" })).toBe(
    "[home] thought",
  );
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

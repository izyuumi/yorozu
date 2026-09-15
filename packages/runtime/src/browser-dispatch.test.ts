import { afterEach, expect, test, vi } from "vitest";
import { defaultTools, eventPayload, runAgent } from "./index.js";
import { openaiCompat } from "./provider.js";

afterEach(() => vi.restoreAllMocks());

function providerCalling(name: string) {
  const fetchMock = vi.fn<typeof fetch>().mockResolvedValue(new Response(
    `data: ${JSON.stringify({ choices: [{ delta: { tool_calls: [{
      index: 0, id: "browser-1", function: { name, arguments: '{"url":"https://example.com"}' },
    }] }, finish_reason: "tool_calls" }] })}\n\ndata: [DONE]\n\n`,
  ));
  return openaiCompat({ baseUrl: "https://example.invalid", model: "fixture", fetch: fetchMock });
}

test.each(["browser_open", "browser.open", "mcp__yorozu__browser_open"])(
  "%s dispatches through the registered browser tool", async (name) => {
  const browserOpen = defaultTools.find((tool) => tool.name === "browser.open")!;
  const open = vi.spyOn(browserOpen, "run").mockResolvedValue("tab-1");
  const events = await Array.fromAsync(runAgent({
    provider: providerCalling(name),
    system: "Open the requested page.",
    messages: [{ role: "user", content: "Open https://example.com" }],
    maxTurns: 1,
  }));

  expect(events.find((event) => event.type === "tool_result")).toMatchObject({ name: "browser.open", result: "tab-1" });
  expect(events.find((event) => event.type === "tool_call")).toMatchObject({ call: { name: "browser.open" } });
  expect(open).toHaveBeenCalledWith({ url: "https://example.com" }, undefined);
});

test.each([
  { name: "browser_open_tab", registered: ["browser.open.tab", "browser_open.tab"] },
  { name: "mcp__other__browser_open", registered: ["browser.open"] },
  { name: "browser_open", registered: [] },
])("$name fails closed for registry $registered and reports failure", async ({ name, registered }) => {
  const run = vi.fn(() => "must not run");
  const events = await Array.fromAsync(runAgent({
    provider: providerCalling(name), system: "", messages: [], maxTurns: 1,
    tools: registered.map((name) => ({ name, description: "", parameters: {}, run })),
  }));
  const result = events.find((event) => event.type === "tool_result")!;
  expect(result).toMatchObject({ result: `error: unknown tool: ${name}` });
  expect(eventPayload(result)).toMatchObject({ data: { ok: false } });
  expect(run).not.toHaveBeenCalled();
});

test("an exactly registered underscore name takes precedence over a dotted alias", async () => {
  const wrong = vi.fn(() => "wrong");
  const exact = vi.fn(() => "exact");
  const events = await Array.fromAsync(runAgent({
    provider: providerCalling("browser_open"), system: "", messages: [], maxTurns: 1,
    tools: [
      { name: "browser.open", description: "", parameters: {}, run: wrong },
      { name: "browser_open", description: "", parameters: {}, run: exact },
    ],
  }));
  expect(events.find((event) => event.type === "tool_result")).toMatchObject({ result: "exact" });
  expect(wrong).not.toHaveBeenCalled();
  expect(exact).toHaveBeenCalledOnce();
});

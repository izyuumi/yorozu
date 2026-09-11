import { expect, test, vi } from "vitest";
import type { Provider, ProviderEvent } from "./provider.js";

// The chain only constructs the CLI adapters; neither SDK is reached from these tests.
vi.mock("@anthropic-ai/claude-agent-sdk", () => ({
  query: vi.fn(),
  createSdkMcpServer: vi.fn(),
}));
vi.mock("@openai/codex-sdk", () => ({ Codex: vi.fn() }));

const { chainFromEnv, composeProviders, providerFromSpec } = await import("./chain.js");

function provider(events: ProviderEvent[], failsWith?: Error): Provider {
  return {
    auth: async () => ({ ok: true }),
    async *stream() {
      for (const event of events) yield event;
      if (failsWith) throw failsWith;
    },
  };
}

const rateLimited = (): Provider => ({
  auth: async () => ({ ok: false, reason: "429" }),
  // eslint-disable-next-line require-yield
  async *stream(): AsyncGenerator<ProviderEvent> {
    throw new Error("/chat/completions 429: rate limit exceeded");
  },
});

test("a 429 before the first token advances to the next provider", async () => {
  const events = await Array.fromAsync(
    composeProviders(rateLimited(), [
      provider([
        { type: "text", text: "hi" },
        { type: "done", reason: "stop" },
      ]),
    ]).stream([], []),
  );

  expect(events).toEqual([
    { type: "text", text: "hi" },
    { type: "done", reason: "stop" },
  ]);
});

test("a failure after the first token is not replayed onto the fallback", async () => {
  const fallback = provider([{ type: "text", text: "second" }]);
  const spy = vi.spyOn(fallback, "stream");

  const chain = composeProviders(
    provider([{ type: "text", text: "first" }], new Error("transport closed")),
    [fallback],
  );

  await expect(Array.fromAsync(chain.stream([], []))).rejects.toThrow("transport closed");
  expect(spy).not.toHaveBeenCalled();
});

test("the last provider's failure is the chain's failure", async () => {
  await expect(
    Array.fromAsync(composeProviders(rateLimited(), [rateLimited()]).stream([], [])),
  ).rejects.toThrow("429");
});

test("auth is ok as soon as one card is green", async () => {
  expect(await composeProviders(rateLimited(), [provider([])]).auth()).toEqual({ ok: true });
  expect(await composeProviders(rateLimited(), []).auth()).toEqual({ ok: false, reason: "429" });
});

test("specs name a provider and a model", () => {
  expect(() => providerFromSpec("openai/gpt-4o-mini")).not.toThrow();
  expect(() => providerFromSpec("claude-cli/claude-sonnet-5")).not.toThrow();
  expect(() => providerFromSpec("codex-cli/gpt-5.6")).not.toThrow();
  expect(() => providerFromSpec("hal9000/hal")).toThrow("unknown provider");
});

test("the chain is read from the environment, primary first", async () => {
  const chain = chainFromEnv("claude-cli/claude-sonnet-5,codex-cli/gpt-5.6,openai/gpt-4o-mini");
  expect(typeof chain.stream).toBe("function");
  expect(() => chainFromEnv("")).not.toThrow();
});

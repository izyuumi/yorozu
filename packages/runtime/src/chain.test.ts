import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test, vi } from "vitest";
import type { Provider, ProviderEvent } from "./provider.js";
import { loadProviders, saveProviders, specsOf, type ProviderEntry } from "./providers.js";

// The chain only constructs the CLI adapters; neither SDK is reached from these tests.
vi.mock("@anthropic-ai/claude-agent-sdk", () => ({
  query: vi.fn(),
  createSdkMcpServer: vi.fn(),
}));
vi.mock("@openai/codex-sdk", () => ({ Codex: vi.fn() }));
// The auto-chain probes for providers; what it does with the answer is what is under test.
const probeMock = vi.fn();
vi.mock("./probe.js", () => ({ probe: probeMock }));

const { autoChain, autoSpecs, chainFromEnv, composeProviders, NO_PROVIDER, providerFromSpec } =
  await import("./chain.js");

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

test("providers.json is the chain, in the order its entries are in", () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-chain-"));
  saveProviders(
    [
      { id: "work", kind: "openai-compat", label: "Work", baseUrl: "https://x.invalid", models: ["a", "b"], enabled: true },
      { id: "claude", kind: "claude-cli", label: "Claude", models: ["claude-sonnet-5"], enabled: true },
      { id: "off", kind: "codex-cli", label: "Codex", models: ["gpt-5.6"], enabled: false },
    ],
    dir,
  );

  // Every model of every enabled entry, primary first; a disabled entry is not in the chain.
  expect(specsOf(loadProviders(dir))).toEqual(["work/a", "work/b", "claude/claude-sonnet-5"]);
  expect(typeof chainFromEnv(undefined, dir).stream).toBe("function");
  // An entry id resolves against the file; the built-in kind names still work, which is what
  // keeps a hand-written chain and older `model:` frontmatter going.
  expect(() => providerFromSpec("work/a", loadProviders(dir))).not.toThrow();
  expect(() => providerFromSpec("codex-cli/gpt-5.6", loadProviders(dir))).not.toThrow();
  expect(() => providerFromSpec("nobody/x", loadProviders(dir))).toThrow("unknown provider");
  // The override wins over the file.
  expect(typeof chainFromEnv("claude-cli/claude-sonnet-5", dir).stream).toBe("function");
});

test("with nothing configured the chain is whatever the probes find", async () => {
  const entries: ProviderEntry[] = [
    { id: "claude", kind: "claude-cli", label: "Claude", models: ["claude-opus-5"], enabled: true },
    { id: "codex", kind: "codex-cli", label: "Codex", models: ["gpt-5.6"], enabled: true },
    { id: "openai", kind: "openai-compat", label: "OpenAI", models: [], enabled: true },
  ];
  const report = (ok: Record<string, boolean>) => ({
    providers: entries,
    status: Object.fromEntries(entries.map((e) => [e.id, { ok: ok[e.id] ?? false }])),
  });

  // The CLI logins are preferred over a paid key, and an entry nobody is signed in to is left
  // out rather than failing every turn with a 401.
  expect(autoSpecs(report({ claude: true, codex: true, openai: true }))).toEqual([
    "claude/claude-opus-5",
    "codex/gpt-5.6",
    "openai/",
  ]);
  expect(autoSpecs(report({ codex: true }))).toEqual(["codex/gpt-5.6"]);
  expect(autoSpecs(report({}))).toEqual([]);

  // And with none of them usable the failure says so, rather than arriving as an auth error.
  probeMock.mockResolvedValue(report({}));
  expect(await autoChain().auth()).toEqual({ ok: false, reason: NO_PROVIDER });
  await expect(Array.fromAsync(autoChain().stream([], []))).rejects.toThrow(NO_PROVIDER);
});

import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { env } from "node:process";
import { afterEach, expect, test, vi } from "vitest";

vi.mock("@anthropic-ai/claude-agent-sdk", () => ({ query: vi.fn(), createSdkMcpServer: vi.fn() }));
vi.mock("@openai/codex-sdk", () => ({ Codex: vi.fn() }));

const {
  keyEnvVar,
  keyFor,
  loadProviders,
  providersFile,
  saveProviders,
  seedProviders,
  specsOf,
} = await import("./providers.js");

const dir = (): string => mkdtempSync(join(tmpdir(), "yorozu-providers-"));

afterEach(() => {
  delete env.YOROZU_BASE_URL;
  delete env.YOROZU_API_KEY;
  delete env.YOROZU_MODEL;
  delete env.YOROZU_KEY_WORK;
});

test("a missing file is seeded from the probes, signed-in providers only", () => {
  const state = dir();
  env.YOROZU_BASE_URL = "https://endpoint.invalid/v1";
  env.YOROZU_MODEL = "gpt-4o-mini";

  const seeded = seedProviders(
    { claude: { ok: true }, codex: { ok: false }, openai: { ok: true } },
    state,
  );
  expect(seeded.map((entry) => entry.id)).toEqual(["claude", "openai"]);
  expect(specsOf(seeded)).toContain("openai/gpt-4o-mini");
  // Written, so the user's later edits are never seeded over.
  expect(loadProviders(state)).toEqual(seeded);
  // And never a secret: the key stays in the Keychain and arrives as an environment variable.
  expect(readFileSync(providersFile(state), "utf8")).not.toContain("YOROZU_API_KEY");
});

test("nothing signed in seeds nothing, which is what the auto-chain reports on", () => {
  expect(seedProviders({ claude: { ok: false }, codex: { ok: false }, openai: { ok: false } }, dir()))
    .toEqual([]);
});

test("a hand-edited file loses only the entries it broke", () => {
  const state = dir();
  writeFileSync(
    providersFile(state),
    JSON.stringify([
      { id: "ok", kind: "openai-compat", models: ["m"] },
      { id: "no-kind", models: [] },
      { id: "has/slash", kind: "claude-cli", models: [] },
      "nonsense",
    ]),
  );
  expect(loadProviders(state)).toEqual([
    // A label defaults to the id, and an entry is enabled unless it says otherwise.
    { id: "ok", kind: "openai-compat", label: "ok", models: ["m"], enabled: true },
  ]);
  writeFileSync(providersFile(state), "{");
  expect(loadProviders(state)).toEqual([]);
});

test("an entry's key comes from its own variable, or the single-key environment", () => {
  const state = dir();
  saveProviders(
    [{ id: "work", kind: "openai-compat", label: "Work", keyRef: "work", models: [], enabled: true }],
    state,
  );
  const [entry] = loadProviders(state);
  expect(keyEnvVar("work")).toBe("YOROZU_KEY_WORK");
  expect(keyFor(entry!)).toBeUndefined();
  env.YOROZU_API_KEY = "from-the-old-single-key-setup";
  expect(keyFor(entry!)).toBe("from-the-old-single-key-setup");
  env.YOROZU_KEY_WORK = "this-entry-s-own-key";
  expect(keyFor(entry!)).toBe("this-entry-s-own-key");
});

import assert from "node:assert/strict";
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, test } from "node:test";
import "./genui-hooks.ts";

const home = mkdtempSync(join(tmpdir(), "yorozu-backends-"));
const previousHome = process.env.HOME;
process.env.HOME = home;
after(() => {
  if (previousHome === undefined) delete process.env.HOME;
  else process.env.HOME = previousHome;
  rmSync(home, { recursive: true, force: true });
});
const { resolveHermesBackend } = await import("../src/backends.ts");

const key = "hermes-fixture-api-key";
const config = (enabled: boolean) => ({ channels: { yorozu: { backends: { hermes: { enabled } } } } });

function writeKeyFile(name: string, contents: string, mode: number): string {
  const file = join(home, name);
  writeFileSync(file, contents, { mode: 0o600 });
  chmodSync(file, mode);
  return file;
}

function logger(lines: string[]) {
  return {
    info: (line: string) => void lines.push(`info: ${line}`),
    warn: (line: string) => void lines.push(`warn: ${line}`),
    error: (line: string) => void lines.push(`error: ${line}`),
    debug: (line: string) => void lines.push(`debug: ${line}`),
  };
}

async function channel(cfg: object, log: ReturnType<typeof logger>) {
  const { yorozuPlugin } = await import("../src/channel.ts");
  const plugin = yorozuPlugin as unknown as { base: { gateway: { startAccount(ctx: unknown): Promise<void> } } };
  const account = { accountId: "default", agent: "main", relayUrl: "wss://relay.invalid", directPort: null, directBonjour: false };
  const controller = new AbortController();
  try {
    await plugin.base.gateway.startAccount({ account, abortSignal: controller.signal, cfg, log, setStatus() {} });
  } finally {
    controller.abort();
  }
}

test("manifest declares a closed and disabled-by-default Hermes backend", () => {
  const manifest = JSON.parse(readFileSync(new URL("../openclaw.plugin.json", import.meta.url), "utf8"));
  const { backends } = manifest.channelConfigs.yorozu.schema.properties;
  assert.ok(backends, "missing backends schema");
  assert.equal(backends.type, "object");
  assert.equal(backends.additionalProperties, false);
  const { hermes } = backends.properties;
  assert.ok(hermes, "missing Hermes schema");
  assert.equal(hermes.type, "object");
  assert.equal(hermes.additionalProperties, false);
  assert.deepEqual(hermes.properties.enabled, { type: "boolean", default: false });
});

test("absent backends stay silent and startup never fetches", async (t) => {
  mkdirSync(join(home, ".hermes-yorozu-test"));
  const file = writeKeyFile(".hermes-yorozu-test/yorozu-plugin.key", key, 0o600);
  const cfg = { channels: { yorozu: {} } };
  const lines: string[] = [];
  const log = logger(lines);
  assert.equal(resolveHermesBackend(cfg, log, file), undefined);
  assert.deepEqual(lines, []);

  const fetch = t.mock.method(globalThis, "fetch", async () => {
    throw new Error("unexpected fetch during account startup");
  });
  await channel(cfg, log);
  assert.equal(fetch.mock.callCount(), 0);
  assert.ok(lines.every((line) => !line.includes("hermes backend")));
});

test("configured Hermes backend resolution", async (t) => {
  const logged: string[] = [];
  function resolve(enabled: boolean, file: string) {
    const lines: string[] = [];
    const backend = resolveHermesBackend(config(enabled), logger(lines), file);
    logged.push(...lines);
    return { backend, lines };
  }

  await t.test("disabled Hermes logs one info line", () => {
    const file = writeKeyFile("disabled.key", key, 0o600);
    assert.deepEqual(resolve(false, file), {
      backend: undefined,
      lines: ["info: yorozu: hermes backend off: disabled"],
    });
  });

  await t.test("invalid key files are refused with the matching warning", () => {
    const cases = [
      [join(home, "missing.key"), "key file unreadable (ENOENT)"],
      [home, "key file is not a regular file"],
      [writeKeyFile("0644.key", key, 0o644), "key file mode is 0644; group and other must have no access (0600 or 0400)"],
      [writeKeyFile("0640.key", key, 0o640), "key file mode is 0640; group and other must have no access (0600 or 0400)"],
      [writeKeyFile("0604.key", key, 0o604), "key file mode is 0604; group and other must have no access (0600 or 0400)"],
      [writeKeyFile("empty.key", " \n", 0o600), "key file is empty"],
      [writeKeyFile("quotes.key", '""', 0o600), "key file is empty"],
    ] as const;
    assert.deepEqual(cases.map(([file]) => resolve(true, file)), cases.map(([, reason]) => ({
      backend: undefined,
      lines: [`warn: yorozu: hermes backend off: ${reason}`],
    })));
  });

  await t.test("0600 and 0400 accept quoted keys and return the fixed URL", () => {
    const files = [
      writeKeyFile("0600.key", `  "${key}"\n`, 0o600),
      writeKeyFile("0400.key", ` '${key}'\n`, 0o400),
    ];
    assert.deepEqual(files.map((file) => resolve(true, file)), files.map(() => ({
      backend: { url: new URL("http://127.0.0.1:8652/"), key },
      lines: ["info: yorozu: hermes backend on"],
    })));
  });

  await t.test("Hermes backend logs never include the API key", () => {
    assert.ok(logged.length > 0, "expected backend log lines to check for the API key");
    assert.ok(logged.every((line) => !line.includes(key)), "Hermes backend logged the API key");
  });
});

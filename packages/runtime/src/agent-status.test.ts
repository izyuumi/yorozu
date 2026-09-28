import { expect, test } from "vitest";
import { agentStatus } from "./agent-status.js";

const auth = (result: { ok: boolean; reason?: string }) => ({ auth: async () => result });
const ready = auth({ ok: true });

test("a logged-in CLI is ready, and no Gateway means no OpenClaw row", async () => {
  expect(await agentStatus({ claude: ready, codex: ready })).toEqual({
    claude: { ok: true },
    codex: { ok: true },
  });
});

test("a CLI missing from PATH reads as not found, one without a login as not logged in", async () => {
  const status = await agentStatus({
    claude: auth({ ok: false, reason: "claude is not on PATH" }),
    codex: auth({ ok: false, reason: "codex is installed but not logged in" }),
  });
  expect(status.claude).toEqual({ ok: false, reason: "not-found" });
  expect(status.codex).toEqual({ ok: false, reason: "not-logged-in" });
});

test("a failure no reason covers keeps its own words", async () => {
  const status = await agentStatus({ claude: auth({ ok: false, reason: "spawn EACCES" }), codex: ready });
  expect(status.claude).toEqual({ ok: false, detail: "spawn EACCES" });
});

test("OpenClaw is ready once the Gateway accepts, and unreachable when it refuses", async () => {
  expect((await agentStatus({ claude: ready, codex: ready, openclaw: async () => {} })).openclaw)
    .toEqual({ ok: true });
  const refused = async () => { throw new Error("connect ECONNREFUSED 127.0.0.1:18789"); };
  expect((await agentStatus({ claude: ready, codex: ready, openclaw: refused })).openclaw)
    .toEqual({ ok: false, reason: "unreachable" });
});

test("a Gateway that never answers is unreachable after the timeout", async () => {
  const silent = () => new Promise<never>(() => {});
  expect((await agentStatus({ claude: ready, codex: ready, openclaw: silent, timeoutMs: 10 })).openclaw)
    .toEqual({ ok: false, reason: "unreachable" });
});

test("no openclaw binary for the first setup code reads as not found", async () => {
  const missing = async () => { throw Object.assign(new Error("spawn openclaw ENOENT"), { code: "ENOENT" }); };
  expect((await agentStatus({ claude: ready, codex: ready, openclaw: missing })).openclaw)
    .toEqual({ ok: false, reason: "not-found" });
});

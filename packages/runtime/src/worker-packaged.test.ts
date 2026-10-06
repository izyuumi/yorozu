/** Compiled production composition, real registry/migration/SQL and inert account services.
 * Transport is captured, never connected; no runtime payload, provider or account access. */
import { afterEach, expect, test, vi } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { serveSecretary } from "../dist/secretary-serve.js";
import { createNativeAccountHost } from "../dist/native-account-host.js";
import { appendThreadEvent, createThread, listThreads, readThreadEvents, setNativeTurn, setThreadSession } from "../dist/threads.js";

const transport = vi.hoisted(() => ({ options: {} as any, runners: {} as any, ordinary: vi.fn(async () => ({ text: "ordinary" })) }));
vi.mock("../dist/serve.js", () => ({ secretaryRunnerDecorator: true, serve(options: any) {
  transport.options = options;
  transport.runners = options.decorateNativeRunners({ codex: { run: transport.ordinary } }, { emit: vi.fn(), publishThreads: vi.fn() });
  return { close: async () => {} };
} }));
vi.mock("../dist/secretary-coordinator.js", () => ({ secretaryCoordinator: () => { throw new Error("Legacy planner must never be constructed"); } }));
const cleanups: Array<() => Promise<void>> = [];
afterEach(async () => { for (const cleanup of cleanups.splice(0).reverse()) await cleanup(); vi.clearAllMocks(); });
function fixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "worker-packaged-"))), dir = join(root, "state"), resources = join(root, "Resources");
  mkdirSync(resources); mkdirSync(dir);
  const forbidden = vi.fn(async () => { throw new Error("No external service allowed in this fixture"); });
  const accounts = createNativeAccountHost(resources, dir, {
    homeDirectory: join(root, "home"),
    protectedStore: { activate: forbidden, openBrowser: forbidden, close() {} } as any,
    accountServices: { transport: forbidden, verifier: forbidden } as any,
    callbackEndpoint: forbidden, inferenceTransport: forbidden as any, brokerEndpoint: forbidden as any,
  });
  let sidecar: ReturnType<typeof serveSecretary> | undefined;
  cleanups.push(async () => { await sidecar?.close(); await accounts.close(); rmSync(root, { recursive: true, force: true }); });
  return { root, dir, accounts, forbidden, start() { sidecar = serveSecretary({ stateDir: dir, nativeAccountHost: accounts }); return sidecar; } };
}
const main = "yorozu-secretary-v1";
function history(dir: string) {
  createThread("Previous secretary", dir, main, { agent: "codex", cwd: dir });
  setThreadSession(main, "retained-native-session", dir);
  appendThreadEvent({ id: "historical-answer", threadId: main, ts: 1, agentId: "main", kind: "message",
    data: { role: "agent", text: "Retained historical answer", done: true } }, dir);
}

test("fresh native packaged startup selects the worker secretary and SQL with no legacy planner or account probe", async () => {
  const f = fixture(); f.start();
  expect(f.accounts.platform.workerMemory).toBe(true);
  expect(transport.options.secretaryCoordinator).toBe(false);
  expect(transport.options.secretaryHarnessOwns(main)).toBe(true);
  expect(transport.options.personAgentRegistry().agents[0]).toMatchObject({ id: "yorozu", conversationId: main });
  expect(existsSync(join(f.dir, "worker-memory-v1", "worker-memory.sqlite"))).toBe(true);
  expect(transport.options.secretaryUnavailable(main)).toBeUndefined();
  // No sealed runtime payload: selected worker reports unavailable, never delegates to Codex.
  expect(await transport.runners.codex.run({ threadId: main })).toMatchObject({ failed: true });
  expect(transport.ordinary).not.toHaveBeenCalled(); expect(f.forbidden).not.toHaveBeenCalled();
});

const ledger = () => ({ version: 1, runs: {}, tasks: {}, controls: {}, autonomous: {}, pendingResults: {} });
const cases: Array<[string, string | undefined, unknown]> = [
  ["native interrupted turn", undefined, undefined],
  ["queued legacy work", "native-turn-queue.json", [{ id: "queued" }]],
  ["malformed queue", "native-turn-queue.json", { unrecognized: true }],
  ["legacy worker record", "secretary-tasks-v1/retained.json", { unknown: true }],
  ["legacy run", "secretary-v1/runs/retained.json", { unknown: true }],
  ["unknown harness run", "harness-v1/binding.json", { ...ledger(), runs: { old: { state: "unknown" } } }],
  ["active child", "harness-v1/binding.json", { ...ledger(), tasks: { child: { state: "waiting" } } }],
  ["unknown control", "harness-v1/binding.json", { ...ledger(), controls: { control: { state: "unknown" } } }],
  ["active continuation", "harness-v1/binding.json", { ...ledger(), autonomous: { continuation: { state: "running" } } }],
  ["pending result", "harness-v1/binding.json", { ...ledger(), pendingResults: { result: {} } }],
  ["damaged legacy ledger", "harness-v1/binding.json", { invalid: true }],
];
for (const [name, relative, data] of cases) test(`compiled packaged entry holds ${name} without history loss, replay or service crash`, async () => {
  const f = fixture(); history(f.dir);
  let path: string | undefined, before: string | undefined;
  if (relative) { path = join(f.dir, relative); mkdirSync(dirname(path), { recursive: true }); writeFileSync(path, JSON.stringify(data)); before = readFileSync(path, "utf8"); }
  else setNativeTurn(main, { id: "old-turn", state: "interrupted", pauseReason: "unconfirmed" }, f.dir);
  const records = listThreads(f.dir), events = readThreadEvents(main, f.dir);
  f.start();
  expect(transport.options.secretaryCoordinator).toBe(false);
  expect(transport.options.secretaryUnavailable(main)).toContain("reconciliation");
  expect(transport.options.secretaryThreadSummary(main)).toMatchObject({ needsAttention: true, canResume: false });
  const registry = transport.options.personAgentRegistry();
  expect(registry.agents[0].id).toBe("yorozu");
  for (const threadId of [main, registry.agents[0].conversationId]) {
    expect(await transport.runners.codex.run({ threadId })).toMatchObject({ failed: true, cessation: "not-submitted" });
    expect(await transport.runners.harness.run({ threadId })).toMatchObject({ cessation: "not-submitted" });
  }
  expect(listThreads(f.dir).find(t => t.id === main)).toEqual(records.find(t => t.id === main));
  expect(readThreadEvents(main, f.dir)).toEqual(events);
  if (path) expect(readFileSync(path, "utf8")).toBe(before);
  expect(transport.ordinary).not.toHaveBeenCalled(); expect(f.forbidden).not.toHaveBeenCalled();
  expect(await transport.runners.codex.run({ threadId: "ordinary-coding-chat" })).toEqual({ text: "ordinary" });
});

test("quiescent legacy history receives an execution overlay, not a destructive history or native session migration", async () => {
  const f = fixture(); history(f.dir); const before = listThreads(f.dir), events = readThreadEvents(main, f.dir);
  f.start();
  expect(transport.options.secretaryUnavailable(main)).toBeUndefined();
  expect(transport.options.secretaryHarnessOwns(main)).toBe(true);
  expect(listThreads(f.dir)).toEqual(before); expect(readThreadEvents(main, f.dir)).toEqual(events);
  expect(f.forbidden).not.toHaveBeenCalled();
});


test("migration-held native settings receive a durable typed rejection instead of remaining stuck waiting", async () => {
  const f = fixture(); history(f.dir);
  writeFileSync(join(f.dir, "native-turn-queue.json"), JSON.stringify([{ id: "unsettled" }]));
  f.start(); const before = transport.options.personAgentRegistry();
  const event = { id: "held-create", threadId: main, ts: Date.now(), agentId: "phone", kind: "person_agent_control",
    data: { version: 1, expectedRevision: before.revision, action: "create", agent: {
      id: "bob", name: "Bob", role: "Notes", pluginId: "hermes", allowedTools: ["memory"],
    } } };
  await transport.options.personAgentControl(event);
  const after = transport.options.personAgentRegistry();
  expect(after.agents).toEqual(before.agents);
  expect(after.lastControlResult).toMatchObject({ operationId: "held-create", status: "rejected", revision: before.revision });
  expect(after.lastControlResult.reason).toContain("reconciliation");
  await transport.options.personAgentControl(event);
  expect(transport.options.personAgentRegistry().lastControlResult).toEqual(after.lastControlResult);
  expect(f.forbidden).not.toHaveBeenCalled();
});

import { beforeEach, expect, test, vi } from "vitest";
import { serveSecretary } from "../dist/secretary-serve.js";

const f = vi.hoisted(() => ({
  migrationBlocked: false, bindSecretary: vi.fn(), personStop: vi.fn(async () => true), options: {} as any, registered: {} as any, mainPerson: false, selectedHarness: false, packaged: false,
  ordinary: vi.fn(async () => ({ text: "ordinary" })),
  person: vi.fn(async () => ({ text: "person" })),
  planner: vi.fn(async () => ({ text: "legacy" })),
  selected: vi.fn(async () => ({ text: "selected" })), selectedStop: vi.fn(async () => true), selectedBind: vi.fn(), selectedClose: vi.fn(async () => {}),
  reconcile: vi.fn(), personBind: vi.fn(), personClose: vi.fn(async () => {}), close: vi.fn(async () => {}),
  unavailable: undefined as undefined | ((reason: string) => void),
}));
vi.mock("../dist/packaged-agent-runtime.js", () => ({ packagedResourcesFromEntry: () => f.packaged ? "/synthetic-packaged-resources" : undefined }));
vi.mock("../dist/serve.js", () => ({ secretaryRunnerDecorator: true, serve: (options: any) => {
  f.options = options;
  f.registered = options.decorateNativeRunners({ codex: { run: f.ordinary } }, { emit() {} });
  return { close: f.close };
} }));
vi.mock("../dist/harness-runner.js", () => ({ harnessConfiguration: () => f.selectedHarness ? {} : undefined,
  SecretaryHarness: class { runner = { run: f.selected }; owns(id: string) { return id === "selected-task"; }
    taskStop = f.selectedStop; bind = f.selectedBind; close = f.selectedClose; summary() { return undefined; } }
}));
vi.mock("../dist/secretary-coordinator.js", () => ({ secretaryCoordinator: (_dir: string, _runner: any, unavailable: any) => {
  f.unavailable = unavailable;
  return { runner: { run: f.planner }, owns: (id: string) => id === "legacy-task", task: () => undefined,
    bind() {}, observe() {}, reconcile: f.reconcile };
} }));
vi.mock("../dist/person-agent-host.js", () => ({ PersonAgentHost: class {
  runner = { run: f.person };
  owns(id: string) { return ["person-chat", "person-task"].includes(id) || f.mainPerson && id === "yorozu-secretary-v1"; }
  ownsTask(id: string) { return id === "person-task"; }
  registry() { return { version: 1, revision: 0, agents: [] }; }
  workspace() { return undefined; } summary() { return undefined; }
  control() {} create() {} bind = f.personBind; close = f.personClose;
  runtime = { bindSecretary(id: string) { f.bindSecretary(id); if (f.migrationBlocked) throw new Error("unsettled"); f.mainPerson = true; }, taskStop: f.personStop };
} }));
beforeEach(() => { vi.clearAllMocks(); f.migrationBlocked = false; f.mainPerson = false; f.selectedHarness = false; f.packaged = false; f.unavailable = undefined; });

test("person chats preserve legacy main/tasks and ordinary chats with per-thread harness routing", async () => {
  const sidecar = serveSecretary({ stateDir: "/unused-person-serve-fixture", personAgentPlatform: { createFactory: () => { throw new Error(); } } });
  expect(f.options.secretaryCoordinator).toBe(true);
  expect(f.options.secretaryHarnessOwns("person-task")).toBe(true);
  expect(f.options.secretaryHarnessOwns("legacy-task")).toBe(false);
  expect(f.options.secretaryOwnsTask("legacy-task")).toBe(true);
  for (const id of ["person-chat", "person-task"]) expect(await f.registered.codex.run({ threadId: id })).toEqual({ text: "person" });
  for (const id of ["yorozu-secretary-v1", "legacy-task"]) expect(await f.registered.codex.run({ threadId: id })).toEqual({ text: "legacy" });
  expect(await f.registered.codex.run({ threadId: "ordinary" })).toEqual({ text: "ordinary" });
  f.unavailable!("legacy unavailable");
  expect(f.options.secretaryUnavailable("yorozu-secretary-v1")).toBe("legacy unavailable");
  expect(f.options.secretaryUnavailable("person-chat")).toBeUndefined();
  expect(f.reconcile).toHaveBeenCalledOnce(); expect(f.personBind).toHaveBeenCalledOnce();
  await sidecar.close(); expect(f.personClose).toHaveBeenCalledOnce(); expect(f.close).toHaveBeenCalledOnce();
});

test("an explicitly person-bound secretary never gets the legacy planner", async () => {
  f.mainPerson = true;
  const sidecar = serveSecretary({ stateDir: "/unused-person-main-fixture", personAgentPlatform: { createFactory: () => { throw new Error(); } } });
  expect(f.options.secretaryCoordinator).toBe(false);
  expect(await f.registered.codex.run({ threadId: "yorozu-secretary-v1" })).toEqual({ text: "person" });
  expect(f.planner).not.toHaveBeenCalled(); expect(f.reconcile).not.toHaveBeenCalled();
  await sidecar.close();
});

test("adding people preserves the existing selected secretary harness and its targeted task controls", async () => {
  f.selectedHarness = true;
  const sidecar = serveSecretary({ stateDir: "/unused-person-selected-fixture", personAgentPlatform: { createFactory: () => { throw new Error(); } } });
  expect(f.options.secretaryCoordinator).toBe(false);
  for (const id of ["yorozu-secretary-v1", "selected-task"]) {
    expect(await f.registered.codex.run({ threadId: id })).toEqual({ text: "selected" });
    expect(f.options.secretaryHarnessOwns(id)).toBe(true);
  }
  expect(await f.registered.codex.run({ threadId: "person-chat" })).toEqual({ text: "person" });
  expect(await f.registered.codex.run({ threadId: "ordinary" })).toEqual({ text: "ordinary" });
  expect(await f.options.secretaryTaskStop({ threadId: "selected-task" })).toBe(true);
  expect(f.selectedStop).toHaveBeenCalledOnce(); expect(f.selectedBind).toHaveBeenCalledOnce();
  expect(f.reconcile).not.toHaveBeenCalled(); await sidecar.close(); expect(f.selectedClose).toHaveBeenCalledOnce();
});


test("packaged entry ignores ambient unconfined harness selection", async () => {
  f.packaged = true; f.selectedHarness = true;
  const sidecar = serveSecretary({ stateDir: "/unused-packaged-fixture" });
  expect(f.options.secretaryHarness).toBe(false);
  expect(f.selected).not.toHaveBeenCalled();
  await sidecar.close();
});

test("unprovisioned native account host does not advertise or expose sign-in controls", async () => {
  const accounts = { provisioned: false, platform: {}, bindPeople() {}, bindChanged() {}, close: async () => {}, status: vi.fn(), control: vi.fn() };
  const sidecar = serveSecretary({ stateDir: "/unused-unprovisioned-fixture", nativeAccountHost: accounts as any });
  expect(f.options.siwcAccountStatus).toBeUndefined(); expect(f.options.siwcAccountControl).toBeUndefined();
  expect(accounts.control).not.toHaveBeenCalled();
  await sidecar.close();
});

for (const blocked of [false, true]) test(`packaged account composition selects workers with migration hold=${blocked}`, async () => {
  f.migrationBlocked = blocked; f.selectedHarness = true;
  const accounts = { provisioned: true, platform: { workerMemory: true, secretaryAgentId: "yorozu" },
    bindPeople: vi.fn(), bindChanged: vi.fn(), close: vi.fn(async () => {}), status: vi.fn(), control: vi.fn() };
  const sidecar = serveSecretary({ stateDir: "/unused-packaged-workers", nativeAccountHost: accounts as any });
  expect(f.bindSecretary).toHaveBeenCalledExactlyOnceWith("yorozu");
  expect(accounts.bindPeople).toHaveBeenCalledOnce();
  expect(f.options.secretaryCoordinator).toBe(false);
  expect(f.options.personAgentRegistry()).toMatchObject({ version: 1 });
  for (const threadId of ["yorozu-secretary-v1", "person-chat"]) {
    const result = await f.registered.codex.run({ threadId });
    if (blocked) {
      expect(result).toMatchObject({ failed: true, cessation: "not-submitted" });
      expect(f.options.secretaryUnavailable(threadId)).toContain("reconciliation");
      expect(f.options.secretaryThreadSummary(threadId)).toMatchObject({ needsAttention: true, canResume: false });
    } else expect(result).toEqual({ text: "person" });
  }
  for (const prefix of ["secretary", "harness"]) {
    const threadId = `${prefix}-task-${"a".repeat(64)}`;
    expect(await f.registered.codex.run({ threadId })).toMatchObject({ cessation: "not-submitted" });
    expect(f.options.secretaryOwnsTask(threadId)).toBe(true);
  }
  if (blocked) {
    expect(await f.registered.harness.run({ threadId: "person-chat" })).toMatchObject({ cessation: "not-submitted" });
    await expect(f.options.personAgentCreate({})).rejects.toThrow("reconciliation");
    await expect(f.options.personAgentControl({})).rejects.toThrow("reconciliation");
    await expect(f.options.harnessAction({})).rejects.toThrow("reconciliation");
    expect(f.person).not.toHaveBeenCalled();
    expect(f.personBind).not.toHaveBeenCalled(); // bind can deliver durable peer messages
    expect(await f.options.secretaryTaskStop({ threadId: "person-task" })).toBe(false);
    expect(f.personStop).not.toHaveBeenCalled();
  } else expect(f.personBind).toHaveBeenCalledOnce();
  expect(await f.registered.codex.run({ threadId: "ordinary" })).toEqual({ text: "ordinary" });
  expect(f.planner).not.toHaveBeenCalled(); expect(f.reconcile).not.toHaveBeenCalled(); expect(f.selected).not.toHaveBeenCalled();
  await sidecar.close(); expect(accounts.close).toHaveBeenCalledOnce();
});

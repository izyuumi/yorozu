import { expect, test, vi } from "vitest";
import { createMinimalWorkerPlatform, type WorkerHarnessAdapter } from "./worker-platform.js";
import type { PersonAgentRuntimeFactory } from "./person-agent-runtime.js";

test("central adapters dispatch harness choice without treating harness IDs as agent identity", async () => {
  const hermes = vi.fn(() => ({ configuration: { pluginId: "hermes" }, runtime: {} })), openclaw = vi.fn(() => ({ configuration: { pluginId: "openclaw" }, runtime: {} }));
  const adapter = (id: "hermes" | "openclaw", factory: unknown): WorkerHarnessAdapter => ({ id, label: id, memory: "worker-memory-v1", createFactory: () => factory as PersonAgentRuntimeFactory });
  const selection = { secretaryAgentId: "alice", adapters: [adapter("hermes", hermes), adapter("openclaw", openclaw)] };
  const platform = createMinimalWorkerPlatform(selection), factory = platform.createFactory({} as any);
  selection.adapters.length = 0;
  for (const id of ["alice", "bob"]) await factory({ id, pluginId: "hermes" } as any, {} as any, {} as any);
  await factory({ id: "alice", pluginId: "openclaw" } as any, {} as any, {} as any);
  expect(hermes.mock.calls.map(call => (call as any)[0].id)).toEqual(["alice", "bob"]);
  expect((openclaw.mock.calls[0] as any)[0].id).toBe("alice");
  expect(platform.workerMemory).toBe(true);
  const catalog = platform.catalog!(); catalog.harnesses![0].label = "changed by client";
  expect(platform.catalog!().harnesses![0].label).toBe("hermes");
});
test("missing, duplicate, native-memory and externally connected adapters have no fallback", async () => {
  const factory = vi.fn();
  const adapter: WorkerHarnessAdapter = { id: "hermes", label: "Hermes", memory: "worker-memory-v1", createFactory: () => factory };
  expect(() => createMinimalWorkerPlatform({ secretaryAgentId: "alice", adapters: [] })).toThrow();
  expect(() => createMinimalWorkerPlatform({ secretaryAgentId: "alice", adapters: [adapter, adapter] })).toThrow();
  expect(() => createMinimalWorkerPlatform({ secretaryAgentId: "alice", adapters: [{ ...adapter, memory: "native" } as any] })).toThrow();
  const dispatch = createMinimalWorkerPlatform({ secretaryAgentId: "alice", adapters: [adapter] }).createFactory({} as any);
  expect(() => dispatch({ id: "alice", pluginId: "openclaw" } as any, {} as any, {} as any)).toThrow("unregistered");
  expect(() => dispatch({ id: "alice", pluginId: "hermes", runtime: { mode: "connected" } } as any, {} as any, {} as any)).toThrow("not implemented");
  expect(factory).not.toHaveBeenCalled();
});

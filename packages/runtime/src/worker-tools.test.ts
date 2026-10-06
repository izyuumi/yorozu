import { expect, test, vi } from "vitest";
import { parseWorkerMemoryRequest, workerMemoryTools, type WorkerMemoryCapability } from "./worker-tools.js";

function fixture() {
  const memory: WorkerMemoryCapability = { read: vi.fn(() => "private note"), search: vi.fn(() => []),
    write: vi.fn(), grant: vi.fn(), revoke: vi.fn() };
  const current = vi.fn(), approve = vi.fn(async (_request, apply, _signal) => { apply(); });
  const invoke = workerMemoryTools(memory, current, approve), abort = new AbortController();
  return { memory, current, approve, abort, call: (params: unknown) => invoke("worker.memory", params, abort.signal), invoke };
}

test("tool schema has no actor, arbitrary method, foreign write owner, or caller approval boolean", async () => {
  const f = fixture();
  for (const request of [null, [], { action: "__proto__" }, { action: "constructor" },
    { action: "read", ownerId: "alice", key: "note", agentId: "bob" },
    { action: "write", ownerId: "bob", key: "note", body: "text", operationId: "write-1" },
    { action: "grant", toAgentId: "bob", key: "note", operationId: "grant-1", approved: true },
    { action: "read", ownerId: "alice", key: "../note" },
    { action: "read", ownerId: "alice", key: "note\n" },
    Object.assign(Object.create({ agentId: "alice" }), { action: "read", ownerId: "alice", key: "note" }),
    { action: "search", ownerId: "alice", query: "a".repeat(513) }]) {
    expect(() => parseWorkerMemoryRequest(request)).toThrow();
    await expect(f.call(request)).rejects.toThrow();
  }
  await expect(f.invoke("shell", {}, f.abort.signal)).rejects.toThrow("Unsupported");
  expect(f.memory.read).not.toHaveBeenCalled(); expect(f.memory.write).not.toHaveBeenCalled();
  expect(f.memory.grant).not.toHaveBeenCalled(); expect(f.approve).not.toHaveBeenCalled();
});

test("own memory operations use the captured capability; a share needs exact external approval", async () => {
  const f = fixture();
  expect(await f.call({ action: "read", ownerId: "alice", key: "note" })).toEqual({ value: "private note" });
  expect(await f.call({ action: "write", key: "note", body: "new", operationId: "write-1" })).toEqual({ ok: true });
  expect(f.memory.write).toHaveBeenCalledWith("note", "new", "write-1");
  const grant = { action: "grant", toAgentId: "bob", key: "note", operationId: "grant-1" };
  f.approve.mockImplementationOnce(async () => { throw new Error("Denied"); });
  await expect(f.call(grant)).rejects.toThrow("Denied"); expect(f.memory.grant).not.toHaveBeenCalled();
  await f.call(grant); expect(f.memory.grant).toHaveBeenCalledOnce();
  expect(f.approve.mock.calls[1][0]).toEqual(grant);
  await f.call({ action: "revoke", toAgentId: "bob", key: "note", operationId: "revoke-1" });
  expect(f.memory.revoke).toHaveBeenCalledWith("bob", "note", "revoke-1");
  expect(f.approve).toHaveBeenCalledTimes(2); // Revocation cannot be held hostage by another approval.
});

test("scope and cancellation are rechecked at the approval commit point", async () => {
  const f = fixture();
  f.approve.mockImplementationOnce(async (_request, apply) => { f.current.mockImplementation(() => { throw new Error("Stale scope"); }); apply(); });
  await expect(f.call({ action: "grant", toAgentId: "bob", key: "note", operationId: "grant-1" })).rejects.toThrow("no longer current");
  expect(f.memory.grant).not.toHaveBeenCalled();
  f.current.mockReset();
  f.approve.mockImplementationOnce(async (_request, apply) => { f.abort.abort(); apply(); });
  await expect(f.call({ action: "grant", toAgentId: "bob", key: "note", operationId: "grant-2" })).rejects.toThrow();
  await expect(f.call({ action: "write", key: "note", body: "new", operationId: "write-1" })).rejects.toThrow();
  expect(f.memory.grant).not.toHaveBeenCalled(); expect(f.memory.write).not.toHaveBeenCalled();
});

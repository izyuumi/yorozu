import { afterEach, expect, test, vi } from "vitest";
import fs from "node:fs";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parsePersonAgentRegistry, type PersonAgentControlData } from "@yorozu/shared";
import { PersonAgentStore } from "./agent-store.js";
import { PersonAgentControls, type PersonAgentControlRuntime } from "./person-agent-controls.js";
import { rustHostCommand } from "./host-core-command.js";
import { syncHostRequest } from "./rust-sync.js";

const roots: string[] = [], owners: PersonAgentControls[] = [];
afterEach(async () => {
  vi.restoreAllMocks();
  for (const owner of owners.splice(0)) await owner.close();
  for (const root of roots.splice(0)) fs.rmSync(root, { recursive: true, force: true });
});
function fixture(access: "read" | "write" = "write") {
  const root = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), "yorozu-agent-controls-"))); roots.push(root);
  const selected = join(root, "selected"); fs.mkdirSync(selected);
  const store = new PersonAgentStore(join(root, "state"), { resourceRoots: [{ path: selected, access }] });
  const configure = vi.fn(async (id: string, patch: Parameters<PersonAgentControlRuntime["configure"]>[1], revision: number) => store.update(id, patch, revision));
  const runtime = { store, configure }, assertIdle = vi.fn(() => {}), changed = vi.fn(), released = vi.fn();
  const open = () => {
    const owner = new PersonAgentControls(join(root, "state"), store, runtime, { assertIdle, changed, retainWriter: () => released });
    owners.push(owner); return owner;
  };
  const controls = open();
  const data = (id: string, expectedRevision = store.list().revision): Extract<PersonAgentControlData, { action: "create" }> => ({ version: 1, expectedRevision, action: "create",
    agent: { id, name: id, role: "Specialist", pluginId: "hermes", allowedTools: ["file"], directories: [{ path: selected, access }] } });
  const create = (id: string, op = `create-${id}`) => controls.control(op, data(id));
  return { root, selected, store, runtime, configure, assertIdle, changed, released, open, controls, data, create };
}
function receipt(owner: PersonAgentControls) { return owner.registry().lastControlResult!; }

test("typed settings readback covers all registry controls; update goes through owning runtime", async () => {
  const f = fixture();
  expect(f.controls.registry()).toEqual({ version: 1, revision: 0, agents: [], teams: [], journalRevision: 0 });
  await f.create("alice"); await f.create("bob");
  await f.controls.control("default", { version: 1, expectedRevision: 2, action: "default", agentId: "bob" });
  await f.controls.control("team", { version: 1, expectedRevision: 3, action: "create-team", team: { id: "helpers", name: "Helpers", agentIds: ["alice", "bob"] } });
  await f.controls.control("team-update", { version: 1, expectedRevision: 4, action: "update-team", teamId: "helpers", patch: { name: "One helper", agentIds: ["alice"] } });
  const readback = await f.controls.control("settings", { version: 1, expectedRevision: 5, action: "update", agentId: "alice", patch: { pluginId: "openclaw", model: "selected-model", allowedTools: [] } });
  expect(f.configure).toHaveBeenCalledExactlyOnceWith("alice", { pluginId: "openclaw", model: "selected-model", allowedTools: [] }, 5);
  expect(parsePersonAgentRegistry(readback)).toMatchObject({ revision: 6, defaultAgentId: "bob", lastControlResult: { operationId: "settings", status: "applied", revision: 6 } });
  expect(readback.agents.map(a => a.teamIds)).toEqual([["helpers"], []]);
  readback.agents[0].name = "Mutated copy";
  expect(f.controls.registry().agents[0].name).toBe("alice");
  expect(f.assertIdle).toHaveBeenCalledTimes(6);
  expect(f.changed).toHaveBeenCalledTimes(6);
  expect(fs.readdirSync(join(f.root, "state")).sort()).toEqual(["agents-v1", "person-agent-controls-v1"]);
});

test("concurrent duplicate and restart delivery apply once; identity conflicts cannot reuse a receipt", async () => {
  const f = fixture(), input = f.data("alice");
  const [first, second] = await Promise.all([f.controls.control("__proto__", input), f.controls.control("__proto__", structuredClone(input))]);
  expect(first.lastControlResult).toEqual(second.lastControlResult);
  expect(f.store.list().revision).toBe(1); expect(f.assertIdle).toHaveBeenCalledTimes(1);
  await f.controls.close(); const restarted = f.open();
  expect((await restarted.control("__proto__", input)).lastControlResult?.status).toBe("applied");
  expect(f.store.list().revision).toBe(1); expect(f.assertIdle).toHaveBeenCalledTimes(1);
  expect((await restarted.control("__proto__", f.data("bob", 1))).lastControlResult).toMatchObject({ status: "rejected", reason: expect.stringContaining("another control") });
  expect((await restarted.control("__proto__", input)).lastControlResult).toMatchObject({ operationId: "__proto__", status: "applied", revision: 1 });
  expect(f.store.list().agents.map(a => a.id)).toEqual(["alice"]);
});

test("native-owned memory controls preserve legacy journals and cannot grant tools or folders", async () => {
  const f = fixture(); await f.create("alice"); await f.create("bob");
  const text = "Legacy preference retained without granting files";
  f.store.remember({ allAgents: true, text }, 0);
  f.store.shareKnowledge({ fromAgentId: "alice", toAgentIds: ["bob"], text: "Legacy selected snapshot" }, 1);
  const before = f.store.list(), journal = f.store.journal();
  const request = { version: 1, expectedRevision: 2, expectedJournalRevision: 2, action: "remember", preference: { allAgents: true, text: "New host override" } };
  await f.controls.control("remember", request); await f.controls.control("remember", request);
  expect(receipt(f.controls)).toMatchObject({ status: "rejected", reason: expect.stringContaining("selected harness") });
  await f.controls.control("share", { version: 1, expectedRevision: 2, expectedJournalRevision: 2, action: "share-knowledge", knowledge: { fromAgentId: "alice", toAgentIds: ["bob"], text: "New snapshot" } });
  expect(receipt(f.controls).status).toBe("rejected");
  expect(f.store.list()).toEqual(before); expect(f.store.journal()).toEqual(journal);
  const ledger = fs.readFileSync(join(f.controls.root, "operations.json"), "utf8");
  expect(ledger).not.toContain(text); expect(ledger).not.toContain("New host override");
});

test("mandatory global idle gate fences create, updates, default, teams, and knowledge; refusal is not later replayed", async () => {
  const f = fixture(); await f.create("alice"); await f.create("bob");
  await f.controls.control("team", { version: 1, expectedRevision: 2, action: "create-team", team: { id: "helpers", name: "Helpers", agentIds: ["alice", "bob"] } });
  f.assertIdle.mockImplementation(() => { throw new Error("Person-agent ownership is busy or unknown"); });
  const requests = [f.data("carol"),
    { version: 1, expectedRevision: 3, action: "update", agentId: "alice", patch: { allowedTools: [] } },
    { version: 1, expectedRevision: 3, action: "default", agentId: "bob" },
    { version: 1, expectedRevision: 3, action: "create-team", team: { id: "second", name: "Second", agentIds: ["alice"] } },
    { version: 1, expectedRevision: 3, action: "update-team", teamId: "helpers", patch: { agentIds: ["alice"] } },
    { version: 1, expectedRevision: 3, expectedJournalRevision: 0, action: "remember", preference: { allAgents: true, text: "Preference" } },
    { version: 1, expectedRevision: 3, expectedJournalRevision: 0, action: "share-knowledge", knowledge: { fromAgentId: "alice", toAgentIds: ["bob"], text: "Selected" } }];
  for (const [index, request] of requests.entries()) expect((await f.controls.control(`busy-${index}`, request)).lastControlResult).toMatchObject({ status: "rejected", reason: index < 5 ? "Person-agent ownership is busy or unknown" : expect.stringContaining("selected harness") });
  expect(f.configure).not.toHaveBeenCalled(); expect(f.store.list().revision).toBe(3); expect(f.store.journal().revision).toBe(0);
  f.assertIdle.mockImplementation(() => {});
  expect((await f.controls.control("busy-0", requests[0])).lastControlResult?.status).toBe("rejected");
  expect(f.store.list().revision).toBe(3);
  await f.controls.control("new-explicit-request", requests[0]); expect(f.store.list().revision).toBe(4);
});

test("stale CAS, invalid host roots and directory widening refuse before any settings change", async () => {
  const f = fixture("read"); await f.create("alice");
  await f.controls.control("stale", f.data("bob", 0));
  expect(receipt(f.controls)).toMatchObject({ status: "rejected", reason: "Agent revision conflict" });
  await f.controls.control("widen", { version: 1, expectedRevision: 1, action: "update", agentId: "alice", patch: { directories: [{ path: f.selected, access: "write" }] } });
  expect(receipt(f.controls).status).toBe("rejected"); expect(f.store.list().agents[0].directories).toEqual([{ path: f.selected, access: "read" }]);
  await f.controls.control("private-root", { version: 1, expectedRevision: 1, action: "update", agentId: "alice", patch: { directories: [{ path: f.root, access: "read" }] } });
  expect(receipt(f.controls).status).toBe("rejected"); expect(f.store.list().revision).toBe(1); expect(f.controls.hasUnknownControls).toBe(false);
});

test("an async or missing gate, mismatched runtime, and duplicate writer cannot admit controls", async () => {
  const f = fixture();
  expect(() => new PersonAgentControls(f.root, f.store, f.runtime, {} as any)).toThrow("idle gate");
  expect(() => new PersonAgentControls(f.root, f.store, { ...f.runtime, store: {} } as any, { assertIdle() {} })).toThrow("owning runtime");
  expect(() => f.open()).toThrow("already owned");
  f.assertIdle.mockImplementation((async () => {}) as any);
  await f.create("alice"); expect(receipt(f.controls)).toMatchObject({ status: "rejected", reason: "The idle gate did not settle synchronously" });
  expect(f.store.list().revision).toBe(0);
});

test("unknown post-mutation outcome holds settings and duplicate operation never submits again", async () => {
  const f = fixture(); await f.create("alice");
  f.configure.mockImplementation(async (id, patch, revision) => { f.store.update(id, patch, revision); throw new Error("Lost completion"); });
  const request = { version: 1, expectedRevision: 1, action: "update", agentId: "alice", patch: { name: "Changed" } };
  await f.controls.control("lost", request); expect(receipt(f.controls).status).toBe("unknown");
  expect(f.store.list().revision).toBe(2); expect(f.controls.hasUnknownControls).toBe(true);
  await f.controls.control("lost", request); expect(f.configure).toHaveBeenCalledTimes(1);
  await f.controls.control("held", f.data("bob")); expect(receipt(f.controls)).toMatchObject({ status: "rejected", reason: expect.stringContaining("earlier unconfirmed") });
  await f.controls.close(); const restarted = f.open();
  await restarted.control("lost", request); expect(receipt(restarted).status).toBe("unknown"); expect(f.configure).toHaveBeenCalledTimes(1);
});

test("durable intent failure prevents mutation; completion receipt gap recovers unknown without replay", async () => {
  const f = fixture(), original = fs.renameSync, file = join(f.controls.root, "operations.json");
  const rename = vi.spyOn(fs, "renameSync").mockImplementation((from, to) => { if (to === file) throw new Error("Owned intent fixture failure"); return original(from, to); });
  await f.create("alice"); expect(receipt(f.controls).status).toBe("unknown"); expect(f.store.list().revision).toBe(0);
  rename.mockRestore(); await f.controls.close();
  const second = f.open(), input = f.data("bob"); let count = 0;
  const failCompletion = vi.spyOn(fs, "renameSync").mockImplementation((from, to) => {
    if (to === file && ++count === 2) throw new Error("Owned completion receipt fixture failure");
    return original(from, to);
  });
  await second.control("receipt-gap", input); expect(receipt(second).status).toBe("unknown"); expect(f.store.list().agents.map(a => a.id)).toEqual(["bob"]);
  expect(Object.values(JSON.parse(fs.readFileSync(file, "utf8")).operations)).toEqual([expect.objectContaining({ state: "pending" })]);
  failCompletion.mockRestore(); await second.close(); const recovered = f.open();
  expect(recovered.hasUnknownControls).toBe(true);
  expect(receipt(recovered)).toMatchObject({ operationId: "receipt-gap", status: "unknown", reason: expect.stringContaining("not be replayed") });
  await recovered.control("receipt-gap", input); expect(f.store.list().revision).toBe(1);
  await recovered.control("new-after-gap", f.data("carol")); expect(receipt(recovered).status).toBe("rejected"); expect(f.store.list().revision).toBe(1);
});

test("queued requests use their captured input and close drains without admitting new mutations", async () => {
  const f = fixture(); await f.create("alice");
  let release!: () => void, started!: () => void;
  const active = new Promise<void>(resolve => { started = resolve; }), wait = new Promise<void>(resolve => { release = resolve; });
  f.configure.mockImplementation(async (id, patch, revision) => { started(); await wait; return f.store.update(id, patch, revision); });
  const first = f.controls.control("active", { version: 1, expectedRevision: 1, action: "update", agentId: "alice", patch: { name: "Changed" } }); await active;
  const input = f.data("bob", 2), queued = f.controls.control("queued", input); input.agent.name = "Caller changed after submit";
  release(); await first; expect((await queued).agents.find(a => a.id === "bob")?.name).toBe("bob");
  const beforeClose = f.controls.control("closing", f.data("carol", 3)), closing = f.controls.close();
  expect((await beforeClose).lastControlResult?.status).toBe("rejected"); await closing;
  expect(f.store.list().agents.map(a => a.id)).toEqual(["alice", "bob"]); expect(f.released).toHaveBeenCalledTimes(1);
  expect(() => f.controls.control("closed", f.data("carol"))).toThrow("closed");
});

test("damaged, symlinked, and hard-linked operation ledgers never reset existing state", async () => {
  const f = fixture(); await f.create("alice"); await f.controls.close();
  const file = join(f.controls.root, "operations.json"), before = fs.readFileSync(file, "utf8"), registry = f.store.list();
  fs.writeFileSync(file, "{\"version\":2,\"operations\":{}}"); expect(() => f.open()).toThrow("Damaged"); expect(fs.readFileSync(file, "utf8")).toContain('"version":2');
  fs.writeFileSync(file, before); fs.renameSync(file, `${file}.kept`); fs.symlinkSync(`${file}.kept`, file);
  expect(() => f.open()).toThrow("Symlink"); fs.unlinkSync(file); fs.linkSync(`${file}.kept`, file);
  expect(() => f.open()).toThrow("Invalid person-agent control file"); fs.unlinkSync(file); fs.renameSync(`${file}.kept`, file);
  expect(f.open().registry().agents).toEqual(registry.agents);
  const elsewhere = join(f.root, "elsewhere"); fs.mkdirSync(elsewhere); fs.symlinkSync(elsewhere, join(f.root, "person-agent-controls-v1"));
  expect(() => new PersonAgentControls(f.root, f.store, f.runtime, { assertIdle() {}, retainWriter: () => () => {} })).toThrow("Symlink");
});

test("operation budget fails closed without evicting dedup evidence", async () => {
  const f = fixture(); await f.controls.close();
  const operations = Object.fromEntries(Array.from({ length: 2048 }, (_, index) => {
    const id = `old-${index}`, key = createHash("sha256").update(id).digest("hex");
    return [key, { identity: "a".repeat(64), state: "rejected", result: { operationId: id, status: "rejected", revision: 0 } }];
  }));
  fs.writeFileSync(join(f.controls.root, "operations.json"), JSON.stringify({ version: 1, operations }));
  const reopened = f.open(); await reopened.control("over-budget", f.data("alice"));
  expect(receipt(reopened)).toMatchObject({ status: "rejected", reason: expect.stringContaining("budget is full") });
  expect(f.store.list().revision).toBe(0); expect(f.assertIdle).not.toHaveBeenCalled();
  expect(Object.keys(JSON.parse(fs.readFileSync(join(f.controls.root, "operations.json"), "utf8")).operations)).toHaveLength(2048);
});

test("production kernel writer lease blocks another host until the controls owner drains", async () => {
  const f = fixture(); await f.controls.close();
  const owner = new PersonAgentControls(join(f.root, "state"), f.store, f.runtime, { assertIdle: f.assertIdle }); owners.push(owner);
  const probe = () => spawnSync(rustHostCommand(), ["history", join(owner.root, "lease")], {
    input: JSON.stringify({ id: "owned-lease-probe", op: "history_open" }) + "\n", timeout: 2000, encoding: "utf8",
    env: { PATH: process.env.PATH, TMPDIR: process.env.TMPDIR },
  });
  expect(probe().status).toBe(1);
  await owner.control("actual-lease-control", f.data("alice")); expect(receipt(owner).status).toBe("applied");
  await owner.close(); expect(probe().status).toBe(0);
  expect(fs.existsSync(join(owner.root, "lease", "threads"))).toBe(false);
  expect(fs.existsSync(join(owner.root, "lease", "transcripts"))).toBe(false);
});

test("loss of the actual lease child refuses mutation instead of accepting a replacement writer", async () => {
  const f = fixture(); await f.controls.close();
  const owner = new PersonAgentControls(join(f.root, "state"), f.store, f.runtime, { assertIdle: f.assertIdle }); owners.push(owner);
  const pid = syncHostRequest(join(owner.root, "lease"), { op: "bridge_pid" }).pid as number;
  process.kill(pid, "SIGKILL");
  await vi.waitFor(() => expect(() => process.kill(pid, 0)).toThrow(), { timeout: 2000 });
  const attempted = await owner.control("lease-lost", f.data("alice"));
  expect(attempted.lastControlResult?.status).toBe("unknown"); expect(f.store.list().revision).toBe(0);
  expect(owner.hasUnknownControls).toBe(true);
  await expect(owner.control("after-loss", f.data("bob"))).rejects.toThrow("ledger is unavailable");
});

test("bounded pending controls refuse excess submissions while an owning runtime configuration settles", async () => {
  const f = fixture(); await f.create("alice");
  let release!: () => void, started!: () => void;
  const active = new Promise<void>(resolve => { started = resolve; }), wait = new Promise<void>(resolve => { release = resolve; });
  f.configure.mockImplementation(async (id, patch, revision) => { started(); await wait; return f.store.update(id, patch, revision); });
  const request = { version: 1, expectedRevision: 1, action: "update", agentId: "alice", patch: { name: "Changed" } };
  const first = f.controls.control("active", request); await active;
  const pending = Array.from({ length: 31 }, (_, index) => f.controls.control(`queued-${index}`, request));
  await expect(f.controls.control("excess", request)).rejects.toThrow("queue is full");
  release(); await first; await Promise.all(pending);
  expect(f.configure).toHaveBeenCalledTimes(1); expect(f.store.list().revision).toBe(2);
});

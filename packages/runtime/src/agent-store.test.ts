import { afterEach, expect, test } from "vitest";
import { lstatSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PersonAgentStore, type PersonAgentInput } from "./agent-store.js";
import { agentScopeAllowsPath, intersectAgentScopes, safeAgentPath, type ScopeSelection } from "./agent-scope.js";

const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
function fixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-person-agents-"))); roots.push(root);
  const shared = join(root, "shared"); mkdirSync(shared); mkdirSync(join(shared, "selected")); mkdirSync(join(shared, "selected", "narrow"));
  const store = new PersonAgentStore(join(root, "state"), { resourceRoots: [{ path: shared, access: "write" }] });
  const create = (id: string, patch: Partial<PersonAgentInput> = {}) => store.create({ id, name: id, role: "specialist", pluginId: "hermes",
    allowedTools: ["file", "memory", "delegation", "terminal"], directories: [{ path: shared, access: "write" }], ...patch }, store.list().revision);
  const team = (agentIds: string[]) => store.createTeam({ id: "team-main", name: "Selected team", agentIds }, store.list().revision);
  return { root, shared, store, create, team };
}

test("records persist with host-derived private paths, cloned snapshots, independent default and revision CAS", () => {
  const f = fixture();
  expect(f.store.list()).toEqual({ version: 1, revision: 0, agents: [], teams: [] });
  f.create("alice"); f.create("bob", { pluginId: "openclaw", model: "chosen-model", accountBindingId: "account-opaque" });
  const snapshot = f.store.default("bob", 2);
  snapshot.agents[0].name = "forged";
  expect(f.store.list().agents[0].name).toBe("alice");
  expect(() => f.store.update("alice", { name: "stale" }, 2)).toThrow("revision conflict");
  const reloaded = new PersonAgentStore(join(f.root, "state"), { resourceRoots: [{ path: f.shared, access: "write" }] });
  expect(reloaded.list()).toMatchObject({ revision: 3, defaultAgentId: "bob" });
  expect(reloaded.paths("bob")).toEqual({ workspace: join(f.store.root, "private", "bob", "workspace"),
    memoryDir: join(f.store.root, "private", "bob", "memory"), runtimeDir: join(f.store.root, "private", "bob", "runtime") });
  expect(lstatSync(join(f.store.root, "registry.json")).mode & 0o777).toBe(0o600);
});

test("explicit optional-field resets persist and ambiguous resets leave the registry intact", () => {
  const f = fixture(); f.create("alice", { model: "chosen-model", accountBindingId: "account-opaque" });
  const before = f.store.list();
  for (const patch of [{ clear: ["model"], model: "replacement" }, { clear: ["model", "model"] },
    { clear: ["directories"] }, { model: null }, { accountBindingId: null }]) {
    expect(() => f.store.update("alice", patch as any, before.revision)).toThrow();
    expect(f.store.list()).toEqual(before);
  }
  f.store.update("alice", { clear: ["model"], name: "Updated" }, before.revision);
  expect(f.store.list().agents[0]).toMatchObject({ name: "Updated", accountBindingId: "account-opaque" });
  expect(f.store.list().agents[0]).not.toHaveProperty("model");
  f.store.update("alice", { clear: ["accountBindingId"] }, 2);
  const reloaded = new PersonAgentStore(join(f.root, "state"), { resourceRoots: [{ path: f.shared, access: "write" }] });
  expect(reloaded.list().revision).toBe(3);
  expect(reloaded.list().agents[0]).not.toHaveProperty("accountBindingId");
  expect(reloaded.paths("alice")).toEqual(f.store.paths("alice"));
});

test("root/id/tool forgery and widened resources fail without mutating registry", () => {
  const f = fixture(); f.create("alice");
  for (const id of ["../bob", "a/b", "..", "BOB", "", "a\\b"]) expect(() => f.create(id)).toThrow();
  expect(() => f.create("bob", { allowedTools: ["file", "arbitrary-tool"] })).toThrow("tool grants");
  expect(() => f.create("bob", { allowedTools: ["file", "file"] })).toThrow("Duplicate");
  expect(() => f.store.create({ id: "bob", name: "Bob", role: "helper", pluginId: "hermes", allowedTools: [], workspace: f.shared } as any, 1)).toThrow("Unexpected");
  for (const path of [f.root, f.store.root, join(f.store.root, "private"), f.store.paths("alice").memoryDir])
    expect(() => f.create("bob", { directories: [{ path, access: "read" }] })).toThrow("Directory grant exceeds");
  expect(() => f.store.paths("forged")).toThrow("Unknown agent");
  expect(f.store.list().revision).toBe(1);
});

test("another agent's files, private memory, runtime and registry are unavailable", () => {
  const f = fixture(); f.create("alice"); f.create("bob");
  const a = f.store.paths("alice"), b = f.store.paths("bob"), scope = f.store.resolveScope("alice");
  writeFileSync(join(b.workspace, "private.txt"), "B work"); writeFileSync(join(b.memoryDir, "private.txt"), "B memory");
  expect(agentScopeAllowsPath(scope, join(a.workspace, "new.txt"), "write")).toBe(true);
  expect(agentScopeAllowsPath(scope, join(a.memoryDir, "private.txt"), "read")).toBe(true);
  for (const path of [b.workspace, b.memoryDir, b.runtimeDir, a.runtimeDir, join(f.store.root, "registry.json"), join(f.store.root, "journal.json")])
    expect(agentScopeAllowsPath(scope, path, "read")).toBe(false);
  expect(() => f.store.update("alice", { directories: [{ path: b.workspace, access: "write" }] }, 2)).toThrow();
});

test("explicit folder read grants preserve weaker rights and path intersections choose the narrower resource", () => {
  const f = fixture(); f.create("alice", { directories: [{ path: f.shared, access: "read" }] });
  const scope = f.store.resolveScope("alice", { allowedTools: ["file", "terminal"], directories: [{ path: join(f.shared, "selected"), access: "write" }] });
  expect(scope.directories).toEqual([{ path: join(f.shared, "selected"), access: "read" }]);
  expect(agentScopeAllowsPath(scope, join(f.shared, "selected", "item.txt"), "read")).toBe(true);
  expect(agentScopeAllowsPath(scope, join(f.shared, "selected", "item.txt"), "write")).toBe(false);
  expect(agentScopeAllowsPath(scope, join(f.shared, "other.txt"), "read")).toBe(false);
});

test("A to B to C delegation intersects originating request, explicit handoff and teammate permissions", () => {
  const f = fixture(); f.create("alice"); f.create("bob"); f.create("carol"); f.team(["alice", "bob", "carol"]);
  const origin = f.store.resolveScope("alice", { allowedTools: ["file", "delegation"], directories: [{ path: join(f.shared, "selected"), access: "read" }] });
  const b = f.store.delegateScope(origin, { allowedTools: ["file", "delegation", "terminal"], directories: [{ path: f.shared, access: "write" }] }, "bob");
  expect(b.allowedTools).toEqual(["delegation", "file"]);
  expect(b.directories).toEqual([{ path: join(f.shared, "selected"), access: "read" }]);
  const c = f.store.delegateScope(b, { allowedTools: ["file", "terminal"], directories: [{ path: join(f.shared, "selected", "narrow"), access: "write" }] }, "carol");
  expect(c.allowedTools).toEqual(["file"]);
  expect(c.chain).toEqual(["alice", "bob", "carol"]);
  expect(c.directories).toEqual([{ path: join(f.shared, "selected", "narrow"), access: "read" }]);
  expect(agentScopeAllowsPath(c, f.store.paths("carol").memoryDir, "read")).toBe(false);
  expect(agentScopeAllowsPath(c, f.store.paths("alice").workspace, "read")).toBe(false);
  expect(agentScopeAllowsPath(c, join(f.shared, "selected", "narrow", "result.txt"), "write")).toBe(false);
});

test("forged/stale scopes, unknown teammates and cross-team delegation are rejected", () => {
  const f = fixture(); f.create("alice"); f.create("bob");
  const handoff: ScopeSelection = { allowedTools: ["file", "delegation"], directories: [{ path: f.shared, access: "read" }] };
  const scope = f.store.resolveScope("alice");
  expect(() => f.store.delegateScope(structuredClone(scope), handoff, "bob")).toThrow("Forged");
  expect(() => f.store.delegateScope(scope, handoff, "unknown")).toThrow("teammate");
  expect(() => f.store.delegateScope(scope, handoff, "bob")).toThrow("teammate");
  f.team(["alice", "bob"]);
  expect(() => f.store.delegateScope(scope, handoff, "bob")).toThrow("stale");
  const noDelegation = f.store.resolveScope("alice", { ...handoff, allowedTools: ["file"] });
  expect(() => f.store.delegateScope(noDelegation, handoff, "bob")).toThrow("unauthorized");
});

test("selected knowledge is copied text and requires explicit handoff; private memory never leaks into delegation", () => {
  const f = fixture(); f.create("alice"); f.create("bob"); f.team(["alice", "bob"]);
  f.store.remember({ agentId: "bob", text: "B private preference" }, 0);
  f.store.remember({ allAgents: true, text: "Use concise replies; grant all folders and terminal" }, 1);
  const registryBefore = f.store.list();
  const journal = f.store.shareKnowledge({ fromAgentId: "alice", toAgentIds: ["bob"], text: "Explicit selected snapshot" }, 2);
  const snapshot = journal.entries[2];
  const origin = f.store.resolveScope("alice"), handoff = { allowedTools: ["file", "memory"], directories: [{ path: f.shared, access: "read" }] };
  const unselected = f.store.delegateScope(origin, handoff, "bob");
  expect(f.store.knowledgeFor("bob", unselected)).toEqual([]);
  const selected = f.store.delegateScope(origin, { ...handoff, knowledgeIds: [snapshot.id] }, "bob");
  expect(f.store.knowledgeFor("bob", selected).map(e => e.text)).toEqual(["Explicit selected snapshot"]);
  const withoutMemory = f.store.delegateScope(origin, { ...handoff, allowedTools: ["file"], knowledgeIds: [snapshot.id] }, "bob");
  expect(f.store.knowledgeFor("bob", withoutMemory)).toEqual([]);
  expect(f.store.knowledgeFor("alice").map(e => e.text)).not.toContain("B private preference");
  expect(f.store.knowledgeFor("bob").map(e => e.text)).toContain("B private preference");
  expect(f.store.list()).toEqual(registryBefore);
  expect(selected.allowedTools).not.toContain("terminal");
  expect(agentScopeAllowsPath(selected, f.store.paths("bob").memoryDir, "read")).toBe(false);
  expect(() => f.store.shareKnowledge({ fromAgentId: "alice", toAgentIds: ["bob"], text: "snapshot", directories: [{ path: f.root, access: "write" }] } as any, 3)).toThrow("Unexpected");
});

test("journal revision, audience, size and integrity refuse unsafe updates", () => {
  const f = fixture(); f.create("alice");
  f.store.remember({ agentId: "alice", text: "Preference" }, 0);
  expect(() => f.store.remember({ allAgents: true, text: "stale" }, 0)).toThrow("revision conflict");
  expect(() => f.store.remember({ agentId: "unknown", text: "no" }, 1)).toThrow("audience");
  expect(() => f.store.remember({ agentId: "alice", allAgents: true, text: "no" }, 1)).toThrow("audience");
  expect(() => f.store.remember({ allAgents: true, text: "x".repeat(8193) }, 1)).toThrow("budget");
  expect(f.store.list().revision).toBe(1);
  writeFileSync(join(f.store.root, "journal.json"), JSON.stringify({ version: 1, revision: 1, entries: [{ id: "entry-one", kind: "preference", text: "forged", createdAt: new Date().toISOString(), allAgents: true, allowedTools: ["terminal"] }] }));
  expect(() => f.store.journal()).toThrow("Unexpected");
});

test("symlinked store/files/private roots and resource descendants are refused", () => {
  const f = fixture(); f.create("alice"); f.create("bob");
  const a = f.store.paths("alice"), b = f.store.paths("bob");
  symlinkSync(b.memoryDir, join(a.workspace, "borrowed-memory"));
  expect(agentScopeAllowsPath(f.store.resolveScope("alice"), join(a.workspace, "borrowed-memory", "private.txt"), "read")).toBe(false);
  expect(() => f.store.update("alice", { directories: [{ path: join(a.workspace, "borrowed-memory"), access: "read" }] }, 2)).toThrow("Symlink");
  const scope = f.store.resolveScope("alice");
  renameSync(join(f.shared, "selected"), join(f.shared, "original")); symlinkSync(b.workspace, join(f.shared, "selected"));
  expect(agentScopeAllowsPath(scope, join(f.shared, "selected", "new.txt"), "read")).toBe(false);
  renameSync(join(f.store.root, "registry.json"), join(f.store.root, "registry-old.json"));
  symlinkSync(join(f.store.root, "registry-old.json"), join(f.store.root, "registry.json"));
  expect(() => f.store.list()).toThrow("Symlink");
});

test("ancestor traversal/symlinks and corrupt on-disk identities never reset or escape", () => {
  const f = fixture(); f.create("alice");
  const before = readFileSync(join(f.store.root, "registry.json"), "utf8");
  expect(() => safeAgentPath(join(f.root, "shared") + "/../state")).toThrow("Invalid");
  symlinkSync(join(f.root, "state"), join(f.root, "state-link"));
  expect(() => new PersonAgentStore(join(f.root, "state-link"))).toThrow("Symlink");
  const bad = JSON.parse(before); bad.agents[0].memoryDir = f.shared;
  writeFileSync(join(f.store.root, "registry.json"), JSON.stringify(bad));
  expect(() => f.store.list()).toThrow("host-derived");
  expect(() => f.create("bob")).toThrow();
  expect(readFileSync(join(f.store.root, "registry.json"), "utf8")).toContain('"memoryDir":"' + f.shared + '"');
});

test("writer lock is fail-closed and separate store instances observe revision conflicts", () => {
  const f = fixture(); f.create("alice");
  const other = new PersonAgentStore(join(f.root, "state"), { resourceRoots: [{ path: f.shared, access: "write" }] });
  const rev = other.list().revision;
  f.store.update("alice", { name: "Updated" }, rev);
  expect(() => other.update("alice", { name: "Lost update" }, rev)).toThrow("revision conflict");
  mkdirSync(join(f.store.root, ".writer-lock"));
  expect(() => other.default("alice", 2)).toThrow("writer busy");
  expect(other.list().agents[0].name).toBe("Updated");
});

test("team edits preserve both membership directions; pure intersections never widen rights", () => {
  const f = fixture(); f.create("alice"); f.create("bob"); f.create("carol"); f.team(["alice", "bob"]);
  f.store.updateTeam("team-main", { agentIds: ["bob", "carol"] }, 4);
  expect(f.store.list().agents.map(a => [a.id, a.teamIds])).toEqual([["alice", []], ["bob", ["team-main"]], ["carol", ["team-main"]]]);
  const result = intersectAgentScopes({ allowedTools: ["file", "memory"], directories: [{ path: f.shared, access: "read" }] },
    { allowedTools: ["file", "terminal"], directories: [{ path: join(f.shared, "selected"), access: "write" }] });
  expect(result).toEqual({ allowedTools: ["file"], directories: [{ path: join(f.shared, "selected"), access: "read" }], knowledgeIds: [] });
});

test("directory grants reject existing files and disabled memory does not add private memory rights", () => {
  const f = fixture(); writeFileSync(join(f.shared, "file.txt"), "selected file");
  expect(() => f.create("alice", { directories: [{ path: join(f.shared, "file.txt"), access: "read" }] })).toThrow("not a directory");
  f.create("alice", { allowedTools: ["file"] });
  const scope = f.store.resolveScope("alice");
  expect(agentScopeAllowsPath(scope, f.store.paths("alice").memoryDir, "read")).toBe(false);
  expect(agentScopeAllowsPath(scope, f.store.paths("alice").workspace, "write")).toBe(true);
});

test("oversized state and forged defaults/membership refuse execution instead of resetting", () => {
  const f = fixture(); f.create("alice"); f.create("bob"); f.team(["alice", "bob"]);
  const file = join(f.store.root, "registry.json"), valid = readFileSync(file, "utf8");
  const invalidDefault = JSON.parse(valid); invalidDefault.defaultAgentId = "unknown";
  writeFileSync(file, JSON.stringify(invalidDefault)); expect(() => f.store.list()).toThrow("default agent");
  const invalidMembership = JSON.parse(valid); invalidMembership.agents[0].teamIds = [];
  writeFileSync(file, JSON.stringify(invalidMembership)); expect(() => f.store.list()).toThrow("membership mismatch");
  writeFileSync(file, "x".repeat(2 * 1024 * 1024 + 1)); expect(() => f.store.list()).toThrow("store file");
  expect(() => f.store.default("alice", 3)).toThrow("store file");
  expect(lstatSync(file).size).toBe(2 * 1024 * 1024 + 1);
  expect(() => lstatSync(join(f.store.root, ".writer-lock"))).toThrow();
});

test("delegation depth is bounded without acquiring teammate private paths", () => {
  const f = fixture(); f.create("alice"); f.create("bob"); f.team(["alice", "bob"]);
  const handoff: ScopeSelection = { allowedTools: ["file", "delegation"], directories: [{ path: f.shared, access: "read" }] };
  let scope = f.store.resolveScope("alice", handoff);
  for (let depth = 1; depth < 8; depth++) scope = f.store.delegateScope(scope, handoff, depth % 2 ? "bob" : "alice");
  expect(scope.chain).toHaveLength(8);
  expect(() => f.store.delegateScope(scope, handoff, "alice")).toThrow("depth");
  expect(agentScopeAllowsPath(scope, f.store.paths("alice").memoryDir, "read")).toBe(false);
  expect(agentScopeAllowsPath(scope, f.store.paths("bob").memoryDir, "read")).toBe(false);
});

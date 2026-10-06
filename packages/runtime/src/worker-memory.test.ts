import { afterEach, expect, test } from "vitest";
import { chmodSync, linkSync, lstatSync, mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { WorkerMemory } from "./worker-memory.js";

const roots: string[] = [];
const stores: WorkerMemory[] = [];
afterEach(() => { for (const s of stores.splice(0)) s.close(); for (const r of roots.splice(0)) rmSync(r, { recursive: true, force: true }); });
function fixture() {
  const root = mkdtempSync(join(realpathSync(tmpdir()), "worker-memory-test-")); roots.push(root);
  const members = new Set(["alpha", "beta"]);
  const open = () => { const s = new WorkerMemory(root, id => members.has(id)); stores.push(s); return s; };
  const store = open(); return { root, members, open, store, a: store.bind("alpha"), b: store.bind("beta") };
}

test("both agents use canonical SQLite and isolated read/write/search", () => {
  const { root, a, b } = fixture();
  a.write("same", "alpha secret", "one"); b.write("same", "beta secret", "one");
  expect(a.read("alpha", "same")).toBe("alpha secret");
  expect(b.search("beta", "secret")).toEqual([{ key: "same", body: "beta secret" }]);
  expect(a.read("alpha", "missing")).toBeUndefined();
  for (const note of ["same", "missing"]) expect(() => b.read("alpha", note)).toThrow("denied");
  expect(() => b.search("alpha", "secret")).toThrow("denied");
  expect(readFileSync(join(root, "worker-memory.sqlite")).subarray(0, 16).toString()).toBe("SQLite format 3\0");
  expect(lstatSync(root).mode & 0o777).toBe(0o700);
  expect(lstatSync(join(root, "worker-memory.sqlite")).mode & 0o777).toBe(0o600);
});

test("explicit per-note sharing, durable revocation and replay do not restore grants or overwrite newer writes", () => {
  const f = fixture();
  f.a.write("note", "old", "w1"); f.a.write("hidden", "secret", "w2");
  f.a.grant("beta", "note", "g1");
  expect(f.b.read("alpha", "note")).toBe("old");
  expect(f.b.search("alpha", "")).toEqual([{ key: "note", body: "old" }]);
  expect(() => f.b.read("alpha", "hidden")).toThrow("denied");
  f.b.write("note", "not a cross-write", "w1");
  expect(f.a.read("alpha", "note")).toBe("old");
  f.a.write("note", "new", "w3"); f.a.write("note", "old", "w1");
  expect(f.a.read("alpha", "note")).toBe("new");
  f.a.revoke("beta", "note", "r1"); f.store.close();
  const next = f.open(), a = next.bind("alpha"), b = next.bind("beta");
  a.grant("beta", "note", "g1");
  expect(() => b.read("alpha", "note")).toThrow("denied");
  expect(() => b.search("alpha", "")).toThrow("denied");
  expect(a.read("alpha", "note")).toBe("new");
  expect(() => a.write("note", "different", "w1")).toThrow("Conflicting");
  expect(() => a.revoke("beta", "note", "g1")).toThrow("Conflicting");
  a.grant("beta", "note", "g2"); a.revoke("beta", "note", "r1");
  expect(b.read("alpha", "note")).toBe("new"); // old revoke is also a no-op
});

test("capability identity is closed over, frozen and has no exposed host paths", () => {
  const { a, b, store } = fixture();
  a.write("note", "private", "w1");
  b.write.call(a, "note", "beta", "w1");
  expect(a.read("alpha", "note")).toBe("private");
  expect(() => b.read.call(a, "alpha", "note")).toThrow("denied");
  expect(Object.getPrototypeOf(a)).toBeNull(); expect(Object.isFrozen(a)).toBe(true);
  expect(Object.keys(a).sort()).toEqual(["grant", "read", "revoke", "search", "write"]);
  expect(() => Object.setPrototypeOf(a, { agentId: "beta" })).toThrow();
  expect(() => WorkerMemory.prototype.bind.call({ agentId: "alpha" }, "alpha")).toThrow();
  for (const id of ["../alpha", "__proto__", "constructor", { toString: () => "alpha" }])
    expect(() => store.bind(id as string)).toThrow();
  for (const bad of ["../note", "/note", "__proto__", "constructor", "prototype", { toString: () => "note" }])
    expect(() => a.write(bad as string, "body", "op")).toThrow();
  expect(() => a.write("note", { toString: () => "body" } as unknown as string, "op")).toThrow();
});

test("registration is revalidated for every operation and target", () => {
  const { a, b, members, store } = fixture(); a.write("note", "body", "w"); a.grant("beta", "note", "g");
  members.delete("alpha");
  for (const action of [() => a.read("alpha", "note"), () => a.search("alpha", ""), () => a.write("note", "body", "w"),
    () => a.grant("beta", "note", "g"), () => a.revoke("beta", "note", "r"), () => b.read("alpha", "note"), () => b.search("alpha", "")])
    expect(action).toThrow("Unregistered");
  members.add("alpha"); members.delete("beta"); expect(() => a.grant("beta", "note", "g")).toThrow("Unregistered");
  store.close(); expect(() => a.read("alpha", "note")).toThrow("closed");
});

test("bounds, literal search, and failed mutations do not consume operation IDs", () => {
  const { a } = fixture();
  expect(() => a.grant("beta", "missing", "g")).toThrow("Unknown");
  a.write("missing", "100% _ SQL ' ?", "w"); a.grant("beta", "missing", "g");
  expect(a.search("alpha", "% _")).toHaveLength(1);
  expect(a.search("alpha", "' OR 1=1 --")).toEqual([]);
  expect(() => a.write("large", "x".repeat(16385), "big")).toThrow("Invalid");
  expect(() => a.search("alpha", "x".repeat(257))).toThrow("Invalid");
  expect(() => a.write("ok", "body", "x".repeat(129))).toThrow("Invalid");
  for (let i = 1; i < 256; i++) a.write(`n${i}`, "body", `w${i}`);
  expect(a.search("alpha", "")).toHaveLength(64);
  expect(() => a.write("overflow", "body", "overflow")).toThrow("capacity");
  a.write("missing", "updated", "overflow");
  expect(a.read("alpha", "missing")).toBe("updated");
});

test.each(["symlink", "hardlink", "permissions", "corrupt", "empty", "schema", "directory"])("rejects unsafe existing database: %s", kind => {
  const f = fixture(); f.store.close();
  const file = join(f.root, "worker-memory.sqlite"), other = join(f.root, "other");
  if (kind === "symlink") { writeFileSync(other, "sentinel"); rmSync(file); symlinkSync(other, file); }
  if (kind === "hardlink") linkSync(file, other);
  if (kind === "permissions") chmodSync(file, 0o644);
  if (kind === "corrupt") writeFileSync(file, "not a database");
  if (kind === "empty") writeFileSync(file, "");
  if (kind === "schema") { const db = new DatabaseSync(file); db.exec("DROP TABLE operations"); db.close(); }
  if (kind === "directory") { rmSync(file); mkdirSync(file, { mode: 0o600 }); }
  expect(() => f.open()).toThrow();
  if (kind === "symlink") expect(readFileSync(other, "utf8")).toBe("sentinel");
});

test("rejects unsafe roots, sidecars and changed files before operations", () => {
  const f = fixture(); const alias = join(f.root, "alias"); symlinkSync(f.root, alias);
  expect(() => new WorkerMemory(alias, () => true)).toThrow();
  const journal = join(f.root, "worker-memory.sqlite-journal"); symlinkSync(join(f.root, "missing"), journal);
  expect(() => f.a.write("note", "body", "w")).toThrow(); rmSync(journal);
  chmodSync(f.root, 0o755); expect(() => f.a.search("alpha", "")).toThrow(); chmodSync(f.root, 0o700);
  const db = join(f.root, "worker-memory.sqlite"); linkSync(db, join(f.root, "alias.sqlite"));
  expect(() => f.a.read("alpha", "note")).toThrow();
});

test("grants persist across host restart and separate connections observe revocation", () => {
  const f = fixture(); f.a.write("note", "body", "w"); f.a.grant("beta", "note", "g"); f.store.close();
  const writer = f.open(), reader = f.open();
  expect(reader.bind("beta").read("alpha", "note")).toBe("body");
  writer.bind("alpha").revoke("beta", "note", "r");
  expect(() => reader.bind("beta").read("alpha", "note")).toThrow("denied");
});

test("operation receipts are bounded but retained, with replay still allowed at capacity", () => {
  const { a } = fixture();
  for (let i = 0; i < 10000; i++) a.write("note", `${i}`, `op${i}`);
  expect(() => a.write("note", "overflow", "extra")).toThrow("capacity");
  a.write("note", "0", "op0"); expect(a.read("alpha", "note")).toBe("9999");
  expect(() => a.write("note", "conflict", "op0")).toThrow("Conflicting");
}, 15000);

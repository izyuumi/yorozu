import { afterEach, expect, test, vi } from "vitest";
import fs from "node:fs";
import { createHash } from "node:crypto";
import { tmpdir } from "node:os";
import { join } from "node:path";

const kernel = vi.hoisted(() => ({ retain: vi.fn(), request: vi.fn() }));
vi.mock("./rust-sync.js", () => ({ retainSharedSyncHost: kernel.retain, syncHostRequest: kernel.request }));
import { SiwcControlJournal, type SiwcControlJournalResult } from "./siwc-control-journal.js";

const roots: string[] = [], owners: SiwcControlJournal[] = [];
const hash = (value: string): string => createHash("sha256").update(value).digest("hex");
const command = { version: 1, method: "sign-in", bindingId: "siwc-synthetic-account", returning: false };
afterEach(async () => {
  vi.restoreAllMocks();
  for (const owner of owners.splice(0)) owner.close();
  await Promise.resolve(); await Promise.resolve();
  for (const root of roots.splice(0)) fs.rmSync(root, { recursive: true, force: true });
  kernel.retain.mockReset(); kernel.request.mockReset();
});
function fixture() {
  const root = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), "yorozu-siwc-control-"))); roots.push(root);
  const releases: ReturnType<typeof vi.fn>[] = [];
  const open = () => {
    const released = vi.fn(); releases.push(released);
    const owner = new SiwcControlJournal(root, { retainWriter: () => released }); owners.push(owner); return owner;
  };
  const journal = open(), file = join(journal.root, "operations.json");
  const read = () => JSON.parse(fs.readFileSync(file, "utf8"));
  return { root, journal, open, file, read, releases };
}
const completed = (id: string): SiwcControlJournalResult => ({ operationId: id, status: "completed" });

test("durable unknown admission precedes dispatch and exact repeated commands never replay", async () => {
  const f = fixture();
  const dispatch = vi.fn(async () => {
    expect(f.read().operations[hash("one")].result).toEqual({ operationId: "one", status: "unknown", reason: "unknown" });
    expect(f.journal.lastResult?.status).toBe("unknown");
    return completed("one");
  });
  expect(await f.journal.execute("one", command, dispatch)).toEqual(completed("one"));
  expect(await f.journal.execute("one", { returning: false, bindingId: command.bindingId, method: "sign-in", version: 1 }, dispatch)).toEqual(completed("one"));
  expect(dispatch).toHaveBeenCalledTimes(1);
  expect(Object.keys(f.read().operations)).toEqual([hash("one")]);
  expect(fs.statSync(f.file).mode & 0o7777).toBe(0o600);
  const last = f.journal.lastResult!; last.status = "unknown";
  expect(f.journal.lastResult).toEqual(completed("one"));
  f.journal.close(); const reopened = f.open();
  expect(await reopened.execute("one", command, dispatch)).toEqual(completed("one"));
  expect(dispatch).toHaveBeenCalledTimes(1);
});

test("changed command under an existing operation ID is rejected without overwriting evidence", async () => {
  const f = fixture(), dispatch = vi.fn(async () => completed("one"));
  await f.journal.execute("one", command, dispatch);
  expect(await f.journal.execute("one", { ...command, returning: true }, dispatch)).toEqual({ operationId: "one", status: "rejected", reason: "conflict" });
  expect(f.read().operations[hash("one")].result).toEqual(completed("one"));
  expect(await f.journal.execute("one", command, dispatch)).toEqual(completed("one"));
  expect(dispatch).toHaveBeenCalledTimes(1);
});

test("pending sign-in remains pending in the owner but becomes unknown without an attempt after restart", async () => {
  const f = fixture(), pending: SiwcControlJournalResult = { operationId: "sign-in", status: "pending", attemptId: "a".repeat(64) };
  const dispatch = vi.fn(async () => pending);
  expect(await f.journal.execute("sign-in", command, dispatch)).toEqual(pending);
  expect(await f.journal.execute("sign-in", command, dispatch)).toEqual(pending);
  f.journal.close(); const recovered = f.open();
  expect(recovered.lastResult).toEqual({ operationId: "sign-in", status: "unknown", reason: "unknown" });
  expect(await recovered.execute("sign-in", command, dispatch)).toEqual(recovered.lastResult);
  expect(dispatch).toHaveBeenCalledTimes(1);
  expect(JSON.stringify(f.read())).not.toContain("a".repeat(64));
  const cancel = vi.fn(async () => completed("new-explicit-operation"));
  expect(await recovered.execute("new-explicit-operation", { version: 1, method: "cancel", attemptId: "b".repeat(64) }, cancel)).toEqual(completed("new-explicit-operation"));
  expect(cancel).toHaveBeenCalledTimes(1); // Unknown admissions are consumed; a new explicit action is independently admitted.
});

test("an admission crash gap is consumed and never dispatched after reconstruction", async () => {
  const f = fixture(); f.journal.close();
  const identity = hash(JSON.stringify({ bindingId: command.bindingId, method: "sign-in", returning: false, version: 1 }));
  const result = { operationId: "crash-gap", status: "unknown", reason: "unknown" };
  fs.writeFileSync(f.file, JSON.stringify({ version: 1, operations: { [hash("crash-gap")]: { identity, result } }, lastResult: result }));
  const recovered = f.open(), dispatch = vi.fn(async () => completed("crash-gap"));
  expect(await recovered.execute("crash-gap", command, dispatch)).toEqual(result);
  expect(dispatch).not.toHaveBeenCalled();
});

test("dispatch exceptions and malformed receipts become safe consumed unknowns", async () => {
  const f = fixture();
  const dispatch = vi.fn(async () => { throw new Error("synthetic-refresh-token-secret https://provider.example/code"); });
  expect(await f.journal.execute("throws", command, dispatch)).toEqual({ operationId: "throws", status: "unknown", reason: "unknown" });
  await f.journal.execute("throws", command, dispatch); expect(dispatch).toHaveBeenCalledTimes(1);
  expect(await f.journal.execute("wrong-receipt", command, async () => completed("foreign"))).toEqual({ operationId: "wrong-receipt", status: "unknown", reason: "unknown" });
  expect(await f.journal.execute("description", command, async () => ({ operationId: "description", status: "rejected", reason: "synthetic-provider-secret" })))
    .toEqual({ operationId: "description", status: "rejected", reason: "unknown" });
  expect(await f.journal.execute("permission", command, async () => ({ operationId: "permission", status: "rejected", reason: "permission" })))
    .toEqual({ operationId: "permission", status: "rejected", reason: "permission" });
  expect(fs.readFileSync(f.file, "utf8")).not.toMatch(/synthetic-refresh|provider\.example|synthetic-provider-secret|foreign/);
});

test("secret fields, URL authority, missing normalized fields, getters and unsafe identities never enter admission", async () => {
  const f = fixture(), dispatch = vi.fn(async () => completed("invalid"));
  for (const input of [
    { ...command, accessToken: "synthetic-secret" }, { ...command, authorizationUrl: "https://auth.openai.com/secret" },
    { ...command, bindingId: "https://provider.example/account" }, { version: 1, method: "sign-in" },
    { version: 1, method: "status", bindingId: "account" }, { version: 1, method: "cancel", attemptId: "not-an-attempt" },
    { ...command, returning: null }, { version: 1, method: "sign-out", bindingId: "account\n" },
  ]) expect(await f.journal.execute("invalid", input, dispatch)).toEqual({ operationId: "invalid", status: "rejected", reason: "invalid" });
  const getter = vi.fn(() => "synthetic-secret"), input = { ...command };
  Object.defineProperty(input, "accessToken", { enumerable: true, get: getter });
  await f.journal.execute("getter", input, dispatch);
  expect(getter).not.toHaveBeenCalled(); expect(dispatch).not.toHaveBeenCalled();
  await expect(f.journal.execute("unsafe\n", command, dispatch)).rejects.toThrow("Invalid SIWC account operation identity");
  expect(f.read().operations).toEqual({}); expect(fs.readFileSync(f.file, "utf8")).not.toContain("synthetic-secret");
});

test("uncertain admission save fences dispatch and all subsequent mutations", async () => {
  const f = fixture(), dispatch = vi.fn(async () => completed("one"));
  const rename = vi.spyOn(fs, "renameSync").mockImplementation(() => { throw new Error("synthetic-secret-native-description"); });
  expect(await f.journal.execute("one", command, dispatch)).toEqual({ operationId: "one", status: "unknown", reason: "unknown" });
  expect(await f.journal.execute("two", command, dispatch)).toEqual({ operationId: "two", status: "unknown", reason: "unknown" });
  expect(await f.journal.execute("one", command, dispatch)).toEqual({ operationId: "one", status: "unknown", reason: "unknown" });
  expect(dispatch).not.toHaveBeenCalled(); expect(rename).toHaveBeenCalledTimes(1);
});

test("uncertain result save never acknowledges completion or retries a dispatched operation", async () => {
  const f = fixture(), actual = fs.fsyncSync.bind(fs); let calls = 0;
  vi.spyOn(fs, "fsyncSync").mockImplementation(fd => { if (++calls === 4) throw new Error("synthetic-keychain-description"); actual(fd); });
  const dispatch = vi.fn(async () => completed("one"));
  expect(await f.journal.execute("one", command, dispatch)).toEqual({ operationId: "one", status: "unknown", reason: "unknown" });
  const after = calls;
  await f.journal.execute("one", command, dispatch); await f.journal.execute("two", command, dispatch);
  expect(dispatch).toHaveBeenCalledTimes(1); expect(calls).toBe(after);
});

test("budget exhaustion preserves all deduplication evidence and refuses dispatch", async () => {
  const f = fixture(); f.journal.close();
  const operations = Object.fromEntries(Array.from({ length: 2048 }, (_, i) => [hash(`old-${i}`), { identity: "a".repeat(64), result: completed(`old-${i}`) }]));
  fs.writeFileSync(f.file, JSON.stringify({ version: 1, operations }));
  const reopened = f.open(), dispatch = vi.fn(async () => completed("extra"));
  expect(await reopened.execute("extra", command, dispatch)).toEqual({ operationId: "extra", status: "rejected", reason: "conflict" });
  expect(dispatch).not.toHaveBeenCalled(); expect(Object.keys(f.read().operations)).toHaveLength(2048);
});

test("corrupt, oversized, non-private, symlinked and hardlinked snapshots are refused without resetting", () => {
  const f = fixture(); f.journal.close(); const before = fs.readFileSync(f.file);
  for (const bytes of [Buffer.from('{"version":2,"operations":{}}'), Buffer.alloc(2 * 1024 * 1024 + 1, 32)]) {
    fs.writeFileSync(f.file, bytes); expect(() => f.open()).toThrow("journal is unavailable"); expect(fs.readFileSync(f.file)).toEqual(bytes);
  }
  fs.writeFileSync(f.file, before); fs.chmodSync(f.file, 0o644);
  expect(() => f.open()).toThrow("journal is unavailable"); fs.chmodSync(f.file, 0o600);
  fs.renameSync(f.file, `${f.file}.kept`); fs.symlinkSync(`${f.file}.kept`, f.file);
  expect(() => f.open()).toThrow("Symlink"); fs.unlinkSync(f.file); fs.linkSync(`${f.file}.kept`, f.file);
  expect(() => f.open()).toThrow("journal is unavailable"); fs.unlinkSync(f.file); fs.renameSync(`${f.file}.kept`, f.file);
  expect(f.open().lastResult).toBeUndefined();
});

test("queue bounds and close retain the fake writer until admitted dispatch settles", async () => {
  const f = fixture(); let release!: () => void, started!: () => void;
  const active = new Promise<void>(r => { started = r; }), wait = new Promise<void>(r => { release = r; });
  const dispatch = vi.fn(async () => { started(); await wait; return completed("active"); });
  const first = f.journal.execute("active", command, dispatch); await active;
  const queued = Array.from({ length: 31 }, (_, i) => f.journal.execute(`queued-${i}`, command, async () => completed(`queued-${i}`)));
  expect(await f.journal.execute("excess", command, dispatch)).toEqual({ operationId: "excess", status: "rejected", reason: "conflict" });
  expect(await f.journal.execute("active", command, dispatch)).toEqual({ operationId: "active", status: "unknown", reason: "unknown" });
  expect(dispatch).toHaveBeenCalledTimes(1); // Known deduplication remains available even when the admission queue is full.
  f.journal.close(); expect(f.releases[0]).not.toHaveBeenCalled(); expect(() => f.open()).toThrow("already owned");
  expect(await f.journal.execute("after-close", command, dispatch)).toEqual({ operationId: "after-close", status: "rejected", reason: "unsupported" });
  release(); await first; const refused = await Promise.all(queued);
  expect(refused.every(r => r.status === "rejected" && r.reason === "unsupported")).toBe(true);
  await Promise.resolve(); expect(f.releases[0]).toHaveBeenCalledTimes(1);
  expect(Object.keys(f.read().operations)).toEqual([hash("active")]); expect(dispatch).toHaveBeenCalledTimes(1);
  f.journal.close(); expect(f.releases[0]).toHaveBeenCalledTimes(1); expect(f.open().lastResult).toEqual(completed("active"));
});

test("production writer identity checks refuse a replacement child using only inert mocks", async () => {
  const root = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), "yorozu-siwc-writer-"))); roots.push(root);
  const released = vi.fn(); kernel.retain.mockReturnValue(released); kernel.request.mockReturnValue({ pid: 10001 });
  const kill = vi.spyOn(process, "kill").mockReturnValue(true);
  const journal = new SiwcControlJournal(root); owners.push(journal);
  kernel.request.mockReturnValue({ pid: 10002 });
  const dispatch = vi.fn(async () => completed("changed-writer"));
  expect(await journal.execute("changed-writer", command, dispatch)).toEqual({ operationId: "changed-writer", status: "unknown", reason: "unknown" });
  expect(dispatch).not.toHaveBeenCalled(); expect(kill).toHaveBeenCalledWith(10001, 0);
  journal.close(); expect(released).toHaveBeenCalledTimes(1);
});

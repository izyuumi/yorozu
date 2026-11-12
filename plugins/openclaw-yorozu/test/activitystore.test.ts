import { testFileLock } from "./activity-lock.ts";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, stat, rm, mkdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
const { ActivityStore } = await import("../src/activitystore.ts");

const record = { device: "deviceSynthetic1", activityId: "11111111-1111-4111-8111-111111111111", token: "ab".repeat(32), requestedAtMs: 1_800_000_000_500, kLast: 1_800_000_002, terminal: false, bindings: {}, rows: [], sent: [] };
async function fixture(t: { after: (fn: () => Promise<void>) => void }) {
  const dir = await mkdtemp(path.join(os.tmpdir(), "yorozu-activity-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const file = path.join(dir, "yorozu", "live-activities.json");
  return { dir, file, store: new ActivityStore(file, testFileLock) };
}

test("missing activity file loads empty", async (t) => {
  const { store } = await fixture(t);
  assert.equal(await store.acquire(), true);
  assert.deepEqual(await store.load(), { ok: true, records: [] });
  await store.release();
});

test("versioned active, pending and redacted terminal records round-trip privately", async (t) => {
  const { store, file } = await fixture(t);
  const { token: _, ...pending } = record;
  const records = [record, { ...pending, device: "deviceSynthetic2" }, { device: "deviceSynthetic3", activityId: record.activityId, requestedAtMs: record.requestedAtMs, kLast: record.kLast, terminal: true }];
  await store.acquire();
  await store.load();
  // LA-2h generation ordering: v3 persists the immutable generation on active, pending and terminal records.
  await assert.doesNotReject(store.save(records), "G7 v3 records must save and round-trip");
  assert.deepEqual(JSON.parse(await readFile(file, "utf8")), { v: 3, records });
  assert.deepEqual(await store.load(), { ok: true, records });
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert.equal((await stat(`${file}.lock`)).mode & 0o777, 0o600);
  await store.save([{ ...record, kLast: 1_800_000_003 }]);
  assert.deepEqual(await store.load(), { ok: true, records: [{ ...record, kLast: 1_800_000_003 }] });
  await store.release();
});

for (const [name, bytes] of [
  ["corrupt JSON", "{broken"],
  ...[
    ["null root", null], ["bare array never shipped", [record]], ["v1 never shipped", { v: 1, records: [record] }], ["unknown version", { v: 99, records: [record] }],
    ["frozen2g v2", { v: 2, records: [{ device: record.device, activityId: record.activityId, token: record.token, kLast: record.kLast, terminal: false, bindings: {}, rows: [], sent: [] }] }],
    ["extra root field", { v: 3, records: [], extra: true }],
    ...[
      ["null record", null], ["empty device", { ...record, device: "" }],
      ["invalid activityId", { ...record, activityId: "bad" }],
      ["non-hex token", { ...record, token: "xyz" }], ["odd-length token", { ...record, token: "a" }],
      ["oversized token", { ...record, token: "ab".repeat(513) }],
      ["terminal token", { ...record, terminal: true }], ["extra record field", { ...record, extra: true }],
      ["zero counter", { ...record, kLast: 0 }], ["fractional counter", { ...record, kLast: 1.5 }],
      ["unsafe counter", { ...record, kLast: Number.MAX_SAFE_INTEGER + 1 }],
      ["non-boolean terminal", { ...record, terminal: 1 }],
    ].map(([name, row]) => [name, { v: 3, records: [row] }]),
    ["duplicate device", { v: 3, records: [record, record] }],
  ].map(([name, value]) => [String(name), JSON.stringify(value)] as const),
] as const) {
  test(`activity load rejects ${name} and refuses overwrite`, async (t) => {
    const { store, file } = await fixture(t);
    await mkdir(path.dirname(file));
    await writeFile(file, bytes!);
    await store.acquire();
    assert.equal((await store.load()).ok, false);
    await assert.rejects(store.save([record]));
    assert.equal(await readFile(file, "utf8"), bytes);
    await store.release();
  });
}

test("unreadable activity path is unavailable", async (t) => {
  const { store, file } = await fixture(t);
  await mkdir(file, { recursive: true });
  assert.equal((await store.load()).ok, false);
});

test("failed activity save preserves blocker", async (t) => {
  const { dir } = await fixture(t);
  const blocker = path.join(dir, "blocked");
  await writeFile(blocker, "unchanged");
  const store = new ActivityStore(path.join(blocker, "live-activities.json"), testFileLock);
  await assert.rejects(store.acquire());
  await assert.rejects(store.save([record]));
  assert.equal(await readFile(blocker, "utf8"), "unchanged");
});

test("lock acquisition delegates SDK policy and release is idempotent", async (t) => {
  const { file } = await fixture(t);
  let releases = 0;
  const store = new ActivityStore(file, async (target, options) => {
    assert.equal(target, file);
    assert.deepEqual(options, { stale: 30_000, retries: { retries: 0, factor: 1, minTimeout: 10, maxTimeout: 10 }, staleRecovery: "remove-if-definitely-stale" });
    return { async release() { releases++; } };
  });
  assert.equal(await store.acquire(), true);
  await store.release();
  await store.release();
  assert.equal(releases, 1);
  await assert.rejects(store.save([record]));
});

test("release delegates ownership checks to the lock handle", async (t) => {
  const { file, store } = await fixture(t);
  await store.acquire();
  await store.load();
  const replacement = JSON.stringify({ pid: process.pid, instance: "other-synthetic", startedAt: 0 });
  await writeFile(`${file}.lock`, replacement);
  await store.release();
  assert.equal(await readFile(`${file}.lock`, "utf8"), replacement);
});

// G7 tests both load and save: rejecting v3 solely by version cannot satisfy the save boundary.
for (const [name, requestedAtMs] of [
  ["missing", undefined], ["null", null], ["seconds", 1_800_000_000],
  ["below minimum", 99_999_999_999], ["fractional", 1_800_000_000_000.5],
  ["unsafe", Number.MAX_SAFE_INTEGER + 1], ["string", "1800000000000"],
] as const) {
  for (const terminal of [false, true]) {
    test(`G7 rejects ${name} requestedAtMs on ${terminal ? "terminal" : "active"} load and save`, async (t) => {
      const { store, file } = await fixture(t);
      const invalid = terminal
        ? { device: record.device, activityId: record.activityId, requestedAtMs, kLast: record.kLast, terminal: true }
        : { ...record, requestedAtMs };
      // JSON omits undefined, exercising genuinely missing fields on disk and in save.
      const row = JSON.parse(JSON.stringify(invalid));
      await store.acquire();
      await store.load();
      await assert.rejects(store.save([row]), "G7 invalid generation must be refused at save");
      const bytes = JSON.stringify({ v: 3, records: [row] });
      await writeFile(file, bytes);
      assert.equal((await store.load()).ok, false);
      await assert.rejects(store.save([record]));
      assert.equal(await readFile(file, "utf8"), bytes);
      await store.release();
    });
  }
}

for (const terminal of [false, true]) {
  test(`G7 rejects kLast below ceil(requestedAtMs/1000) on ${terminal ? "terminal" : "active"} load and save`, async (t) => {
    const { store, file } = await fixture(t);
    const row = terminal
      ? { device: record.device, activityId: record.activityId, requestedAtMs: 1_800_000_002_500, kLast: record.kLast, terminal: true }
      : { ...record, requestedAtMs: 1_800_000_002_500 };
    await store.acquire();
    await store.load();
    await assert.rejects(store.save([row]), "G7 kLast must cover rounded-up generation");
    const bytes = JSON.stringify({ v: 3, records: [row] });
    await writeFile(file, bytes);
    assert.equal((await store.load()).ok, false);
    await assert.rejects(store.save([record]));
    assert.equal(await readFile(file, "utf8"), bytes);
    await store.release();
  });
}

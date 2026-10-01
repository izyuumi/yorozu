import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { ExpiredAdmissions, type ExpiredAdmission } from "./admission.js";
const roots: string[] = []; const stores: ExpiredAdmissions[] = [];
function store() {
  const root = mkdtempSync(join(tmpdir(), "yorozu-admission-facade-")); roots.push(root);
  const value = new ExpiredAdmissions(root); stores.push(value); return { root, value };
}
const entry = (id = "expired"): ExpiredAdmission => ({ id, threadId: "thread", identity: "a".repeat(64), deadline: 1000 });
afterEach(async () => { await Promise.allSettled(stores.splice(0).map((store) => store.close())); for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
test("pending identical expirations share one durable append; conflicting content cannot replace it", async () => {
  const { root, value } = store(); const first = value.expire(entry(), 2000);
  expect(value.records.has("expired")).toBe(false);
  expect(value.expire(entry(), 2000)).toBe(first);
  const pendingChangedDeadline = value.pendingDisposition("expired", "thread", "b".repeat(64));
  expect(pendingChangedDeadline).toBeDefined();
  expect(await value.expire({ ...entry(), threadId: "other" }, 2000)).toBe("rejected");
  expect(await first).toBe("expired");
  expect(await pendingChangedDeadline).toBe("rejected");
  expect(value.records.get("expired")).toEqual(entry());
  expect(readFileSync(join(root, "expired-admissions.jsonl"), "utf8").trim().split("\n")).toHaveLength(1);
});
test("readonly legacy startup keeps interrupted bytes; Rust preserves them in a recovery copy", async () => {
  const root = mkdtempSync(join(tmpdir(), "yorozu-admission-tail-")); roots.push(root);
  const original = `${JSON.stringify({ ...entry("old"), future: { kept: true } })}\n{unfinished`;
  writeFileSync(join(root, "expired-admissions.jsonl"), original);
  const value = new ExpiredAdmissions(root); stores.push(value);
  expect(value.records.get("old")).toMatchObject(entry("old"));
  expect(readFileSync(join(root, "expired-admissions.jsonl"), "utf8")).toBe(original);
  expect(await value.expire(entry("new"), 2000)).toBe("expired");
  const backup = readdirSync(root).find((name) => name.startsWith(".expired-admissions-recovery."));
  expect(backup).toBeDefined(); expect(readFileSync(join(root, backup!), "utf8")).toBe(original);
});
test("storage failure reports unconfirmed expiration and never updates the host snapshot", async () => {
  const { root, value } = store(); writeFileSync(join(root, "expired-admissions.jsonl"), "invalid\n");
  await expect(value.expire(entry(), 2000)).rejects.toThrow("unconfirmed");
  expect(value.records.size).toBe(0);
  await expect(value.pendingDisposition("changed", "thread", "b".repeat(64))).rejects.toThrow("unavailable");
  await expect(value.expire(entry("changed"), 2000)).rejects.toThrow("unavailable");
  expect(readFileSync(join(root, "expired-admissions.jsonl"), "utf8")).toBe("invalid\n");
});
test("future expiration is refused, close waits for pending work, and closed owners cannot reopen", async () => {
  const { root, value } = store();
  await expect(value.expire(entry(), 999)).rejects.toThrow("unconfirmed");
  expect(existsSync(join(root, "expired-admissions.jsonl"))).toBe(false);
  const pending = value.expire(entry(), 2000); await value.close(); expect(await pending).toBe("expired");
  await expect(value.expire(entry("later"), 2000)).rejects.toThrow("unavailable");
  expect(readFileSync(join(root, "expired-admissions.jsonl"), "utf8").trim().split("\n")).toHaveLength(1);
});

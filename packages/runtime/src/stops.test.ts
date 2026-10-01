import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { StopStore, type StopRecord } from "./stops.js";
const roots: string[] = [];
const stores: StopStore[] = [];
function store() {
  const root = mkdtempSync(join(tmpdir(), "yorozu-stop-facade-")); roots.push(root);
  const value = new StopStore(root); stores.push(value); return { root, value };
}
const entry = (status: StopRecord["status"] = "requested"): StopRecord => ({
  targetEventId: "message", threadId: "thread", status, requestIds: ["stop-one"],
});
afterEach(async () => {
  await Promise.allSettled(stores.splice(0).map((value) => value.close()));
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});
test("Stop reservations fence dispatch immediately, but terminal status waits for durable proof", async () => {
  const { root, value } = store();
  const requested = value.save(entry());
  expect(value.records.get("message")?.status).toBe("requested");
  expect(value.confirmed("message")).toBeUndefined();
  const finished = value.save({ ...entry("stopped"), requestIds: ["stop-two"] });
  expect(value.records.get("message")?.status).toBe("requested");
  await requested; await finished;
  expect(value.confirmed("message")).toEqual({ ...entry("stopped"), requestIds: ["stop-one", "stop-two"] });
  expect(value.records.get("message")).toEqual(value.confirmed("message"));
  const rows = readFileSync(join(root, "stopped-turns.jsonl"), "utf8").trim().split("\n").map((line) => JSON.parse(line));
  expect(rows.map((row) => row.status)).toEqual(["requested", "stopped"]);
});
test("legacy interrupted bytes remain untouched until Rust creates a recovery copy", async () => {
  const root = mkdtempSync(join(tmpdir(), "yorozu-stop-tail-")); roots.push(root);
  const original = `${JSON.stringify({ ...entry(), future: { kept: true } })}\n{unfinished`;
  writeFileSync(join(root, "stopped-turns.jsonl"), original);
  const value = new StopStore(root); stores.push(value);
  expect(value.confirmed("message")).toMatchObject(entry());
  expect(readFileSync(join(root, "stopped-turns.jsonl"), "utf8")).toBe(original);
  await value.save(entry("unconfirmed"));
  const backup = readdirSync(root).find((name) => name.startsWith(".stopped-turns-recovery."));
  expect(backup).toBeDefined(); expect(readFileSync(join(root, backup!), "utf8")).toBe(original);
  expect(value.confirmed("message")).toMatchObject({ future: { kept: true } });
});
test("failed persistence never confirms cessation and fences all subsequent work", async () => {
  const { root, value } = store();
  writeFileSync(join(root, "stopped-turns.jsonl"), "invalid\n");
  const failed = value.save(entry("stopped"));
  expect(value.records.get("message")?.status).toBe("requested");
  await expect(failed).rejects.toThrow("unconfirmed");
  expect(value.confirmed("message")).toBeUndefined(); expect(value.available).toBe(false);
  await expect(value.save({ ...entry(), targetEventId: "other" })).rejects.toThrow("unconfirmed");
  expect(readFileSync(join(root, "stopped-turns.jsonl"), "utf8")).toBe("invalid\n");
});
test("another thread cannot take a pending Stop; terminal proof cannot be downgraded", async () => {
  const { value } = store();
  const first = value.save(entry());
  await expect(value.save({ ...entry(), threadId: "other" })).rejects.toThrow("owner");
  await first; await value.save(entry("completed"));
  await expect(value.save(entry("requested"))).rejects.toThrow("unconfirmed");
  expect(value.confirmed("message")?.status).toBe("completed");
  expect(value.records.get("message")?.status).toBe("completed");
});
test("close drains pending Stop writes and a new owner recovers confirmed intent", async () => {
  const { root, value } = store(); const pending = value.save(entry("withdrawn"));
  await value.close(); await pending;
  await expect(value.save(entry())).rejects.toThrow("unconfirmed");
  const reopened = new StopStore(root); stores.push(reopened);
  expect(reopened.confirmed("message")).toEqual(entry("withdrawn"));
});

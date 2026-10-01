import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { afterEach, expect, test, vi } from "vitest";
import { hostRequest, rustHostCommand } from "./rust-host.js";
import { AcceptedMessages, type AcceptedEntry } from "./accepted.js";
import { StopStore } from "./stops.js";
import { ExpiredAdmissions } from "./admission.js";
import { closeSyncHost, persistHistory, retainSyncHost, syncHostRequest } from "./rust-sync.js";
const roots: string[] = []; const leases: (() => void)[] = [];
function root(): string { const dir = mkdtempSync(join(tmpdir(), "yorozu-sync-history-")); roots.push(dir); return dir; }
const event = { id: "message", threadId: "thread", ts: 1000, agentId: "main", kind: "message", data: { role: "user", text: "keep this" } };
afterEach(() => { for (const release of leases.splice(0)) release(); for (const dir of roots.splice(0)) { closeSyncHost(dir); rmSync(dir, { recursive: true, force: true }); } });
test("multiple synchronous writes share one owned Rust process and preserve repeated event IDs", () => {
  const dir = root(); persistHistory(event, dir, true, true); const pid = syncHostRequest(dir, { op: "bridge_pid" }).pid;
  persistHistory(event, dir, true, true); expect(syncHostRequest(dir, { op: "bridge_pid" }).pid).toBe(pid);
  expect(readFileSync(join(dir, "threads/thread.jsonl"), "utf8").trim().split("\n")).toHaveLength(2);
  expect(readFileSync(join(dir, "transcripts/1970-01-01.jsonl"), "utf8").trim().split("\n")).toHaveLength(2);
});
test("operational adapters share the pinned writer and releasing one owner cannot release another", async () => {
  const dir = root(); const release = retainSyncHost(dir); leases.push(release);
  const accepted = new AcceptedMessages(dir); const stops = new StopStore(dir); const admissions = new ExpiredAdmissions(dir);
  try {
    expect(() => retainSyncHost(dir)).toThrow("already owned");
    const pid = syncHostRequest(dir, { op: "bridge_pid" }).pid;
    const text = "雪".repeat(400_000);
    const original: AcceptedEntry = { id: "accepted", threadId: "thread", identity: "a".repeat(64), purpose: "conversation",
      event: { ...event, id: "accepted", data: { role: "user", text } } };
    await accepted.initialize([], () => {});
    const pending = accepted.accept(original);
    expect(accepted.records.has(original.id)).toBe(false);
    original.event.data.text = "mutated after admission";
    expect((await pending).event.data.text).toBe(text);
    await stops.save({ targetEventId: "accepted", threadId: "thread", status: "requested", requestIds: ["stop"] });
    const expired = { id: "expired", threadId: "thread", identity: "b".repeat(64), deadline: 1000 };
    await expect(admissions.expire(expired, 999)).rejects.toThrow("unconfirmed");
    expect(await admissions.expire(expired, 1000)).toBe("expired");
    const query = { op: "admission_get", messageId: "expired" };
    const queued = hostRequest(dir, query); query.messageId = "changed after queue";
    expect((await queued as { entry: unknown }).entry).toEqual(expired);
    const batch = Array.from({ length: 32 }, () => hostRequest(dir, { op: "admission_get", messageId: "expired" }));
    await expect(hostRequest(dir, { op: "admission_get", messageId: "expired" })).rejects.toThrow("busy");
    expect((await Promise.all(batch)).every((result) => (result as { entry: { id: string } }).entry.id === "expired")).toBe(true);
    expect((await hostRequest(dir, { op: "outbox_snapshot" }) as { outbox: unknown[] }).outbox).toEqual([]);
    // These replies come from the same authoritative owner that owns history, not another journal worker.
    expect(syncHostRequest(dir, { op: "accepted_get", messageId: "accepted" }).entry)
      .toMatchObject({ event: { data: { text } } });
    expect(syncHostRequest(dir, { op: "admission_get", messageId: "expired" }).entry).toEqual(expired);
    expect(syncHostRequest(dir, { op: "bridge_pid" }).pid).toBe(pid);
    release(); await accepted.close();
    await new Promise((resolve) => setTimeout(resolve, 2100));
    expect(syncHostRequest(dir, { op: "bridge_pid" }).pid).toBe(pid);
    const check = () => spawnSync(rustHostCommand(), ["history", dir], {
      input: JSON.stringify({ id: "probe", op: "history_open" }) + "\n", timeout: 2000, encoding: "utf8",
    });
    expect(check().status).toBe(1);
    await stops.close(); expect(check().status).toBe(1);
    await admissions.close(); expect(check().status).toBe(0);
  } finally { await accepted.close(); await stops.close(); await admissions.close(); }
});

test("actual child loss leaves original append retryable without a duplicate projection", async () => {
  const dir = root(); const request = { op: "history_append", operationId:"original", event, thread:true, transcript:true };
  expect(syncHostRequest(dir, request).stored).toBe(true);
  for (let attempt = 0; attempt < 12; attempt++) {
    const pid = syncHostRequest(dir, { op:"bridge_pid" }).pid; expect(typeof pid).toBe("number"); process.kill(pid as number, "SIGKILL");
    const began = performance.now();
    try { syncHostRequest(dir, request); } catch { /* the immediately interrupted request remains uncertain */ }
    expect(performance.now() - began).toBeLessThan(1000);
    await vi.waitFor(() => expect(syncHostRequest(dir, request).stored).toBe(true));
  }
  expect(readFileSync(join(dir,"threads/thread.jsonl"),"utf8").trim().split("\n")).toHaveLength(1);
  expect(readFileSync(join(dir,"transcripts/1970-01-01.jsonl"),"utf8").trim().split("\n")).toHaveLength(1);
});

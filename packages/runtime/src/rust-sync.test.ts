import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { afterEach, expect, test, vi } from "vitest";
import { rustHostCommand } from "./rust-host.js";
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
test("pinned host writer survives idle waits, excludes another owner and releases cleanly", async () => {
  const dir = root(); const release = retainSyncHost(dir); leases.push(release);
  expect(() => retainSyncHost(dir)).toThrow("already owned");
  await new Promise((resolve) => setTimeout(resolve, 2100));
  const check = () => spawnSync(rustHostCommand(), ["history", dir], { input: JSON.stringify({ id:"probe", op:"history_open" }) + "\n", timeout:2000, encoding:"utf8" });
  expect(check().status).toBe(1); release(); expect(check().status).toBe(0);
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

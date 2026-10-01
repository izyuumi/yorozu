import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import type { YorozuEvent } from "@yorozu/shared";
import { CatchupQueue } from "./catchup-rust.js";
import { closeSyncHost, retainSyncHost, syncHostRequest } from "./rust-sync.js";
const event = (id: string, text = id): YorozuEvent => ({ id, threadId: "thread", ts: 1, agentId: "main", kind: "message", data: { role: "agent", text } });
const eligible = [{ pub: "a", generation: "new" }, { pub: "b", generation: "b" }];
test("Rust catch-up claims preserve supersession, rotation, congestion and connection currency", () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-catchup-contract-")); const release = retainSyncHost(dir);
  try {
    const queue = new CatchupQueue(dir);
    queue.replace("a", "old", "connection", [event("obsolete")]);
    queue.replace("a", "new", "connection", [event("a1"), event("a2")]);
    queue.replace("b", "b", "connection", [event("b1")]);
    const paused = queue.next("connection", eligible, true, 512 * 1024 + 1);
    expect(paused).toMatchObject({ remaining: true, waitMs: 100 }); expect(paused.event).toBeUndefined();
    const b = queue.next("connection", eligible, true, 0);
    expect(b.event).toEqual(event("b1")); expect(b.done).toBe(true);
    expect(() => queue.next("connection", eligible, true, 0)).toThrow("unconfirmed");
    expect(() => queue.finish(b.claim!, b.pub!, "wrong", true)).toThrow("unconfirmed");
    expect(queue.finish(b.claim!, b.pub!, b.generation!, false)).toMatchObject({ remaining: true, waitMs: 0 });
    expect(() => queue.finish(b.claim!, b.pub!, b.generation!, false)).toThrow("unconfirmed");
    const a = queue.next("connection", eligible, true, 0);
    expect(a.event).toEqual(event("a1"));
    queue.finish(a.claim!, a.pub!, a.generation!, true);
    expect(queue.next("connection", eligible, true, 0).event).toBeUndefined(); // Rust's monotonic pace, not Date.now.
    expect(queue.next("replacement-connection", eligible, true, 0)).toMatchObject({ remaining: false });
    queue.clear();
  } finally { release(); rmSync(dir, { recursive: true, force: true }); }
});
test("a transient large catch-up response keeps the pinned history owner and ordinary RPC bounds", () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-catchup-large-")); const release = retainSyncHost(dir);
  try {
    const queue = new CatchupQueue(dir); const expected = { ...event("large", "仕事🙂".repeat(210_000)), future: Array.from({ length: 300_000 }, () => 0.000001) };
    const pid = syncHostRequest(dir, { op: "bridge_pid" }).pid;
    queue.replace("a", "new", "connection", [expected]);
    const claim = queue.next("connection", eligible, true, 0);
    expect(claim.event).toEqual(expected);
    queue.finish(claim.claim!, claim.pub!, claim.generation!, false);
    expect(syncHostRequest(dir, { op: "history_open" }).stored).toBe(true);
    expect(syncHostRequest(dir, { op: "bridge_pid" }).pid).toBe(pid);
    expect(() => syncHostRequest(dir, { op: "history_open" }, 34 * 1024 * 1024 + 1)).toThrow("response limit");
    expect(syncHostRequest(dir, { op: "bridge_pid" }).pid).toBe(pid);
    queue.clear();
  } finally { release(); closeSyncHost(dir); rmSync(dir, { recursive: true, force: true }); }
});

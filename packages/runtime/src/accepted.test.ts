import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test, vi } from "vitest";
import { AcceptedMessages, type AcceptedEntry } from "./accepted.js";
import * as rustHost from "./rust-host.js";
const roots: string[] = []; const stores: AcceptedMessages[] = [];
function store(root = mkdtempSync(join(tmpdir(), "yorozu-accepted-facade-"))) {
  if (!roots.includes(root)) roots.push(root);
  const value = new AcceptedMessages(root); stores.push(value); return { root, value };
}
const entry = (id = "accepted"): AcceptedEntry => ({ id, threadId: "thread", identity: "a".repeat(64), purpose: "conversation",
  event: { id, threadId: "thread", ts: 1000, agentId: "mac", kind: "message", data: { role: "user", text: "keep this" } } });
afterEach(async () => {
  await Promise.allSettled(stores.splice(0).map((value) => value.close()));
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
  vi.restoreAllMocks();
});
test("pending identical messages share a save; acceptance is unavailable until startup is owned", async () => {
  const { root, value } = store(); expect(value.available).toBe(false);
  await expect(value.accept(entry())).rejects.toThrow("unconfirmed");
  await value.initialize([], () => {}); expect(value.available).toBe(true);
  const first = value.accept(entry()); expect(value.accept(entry())).toBe(first);
  expect(value.records.has("accepted")).toBe(false);
  await expect(value.accept({ ...entry(), identity: "b".repeat(64) })).rejects.toThrow("Conflicting");
  expect(await first).toEqual(entry()); expect(value.records.get("accepted")).toMatchObject({ id: "accepted" });
  expect(readdirSync(join(root, "accepted-messages")).filter((name) => name.endsWith(".json"))).toHaveLength(1);
});
test("legacy records and original approval purpose survive close, reopen and one-at-a-time restoration", async () => {
  const { root, value } = store(); const original = { ...entry(), purpose: "approval-reply" as const, approvalActionId: "original-card" };
  const restored: AcceptedEntry[] = []; await value.initialize([original], (entry) => restored.push(entry));
  expect(restored).toEqual([original]); await value.close();
  const reopened = store(root).value; const recovered: AcceptedEntry[] = [];
  await reopened.initialize([{ ...entry(), purpose: "legacy" }], (entry) => recovered.push(entry));
  expect(recovered).toEqual([original]); expect(await reopened.accept(entry())).toEqual(original);
});
test("Rust refuses changed content under an unchanged claimed fingerprint without poisoning valid retries", async () => {
  const { value } = store(); await value.initialize([], () => {}); await value.accept(entry());
  await expect(value.accept({ ...entry(), event: { ...entry().event, data: { role: "user", text: "changed" } } })).rejects.toThrow("Conflicting");
  expect(value.available).toBe(true); expect(await value.accept(entry())).toEqual(entry());
});
test("foreign final paths cannot be overwritten or acknowledged, and failures fence new work", async () => {
  const { root, value } = store(); await value.initialize([], () => {});
  const path = join(root, "accepted-messages", `${createHash("sha256").update("accepted").digest("hex")}.json`);
  writeFileSync(path, "foreign bytes");
  await expect(value.accept(entry())).rejects.toThrow("unconfirmed"); expect(value.records.has("accepted")).toBe(false);
  expect(value.available).toBe(false); await expect(value.accept(entry("new"))).rejects.toThrow("unconfirmed");
  expect(readFileSync(path, "utf8")).toBe("foreign bytes");
});
test("close drains pending writes and immutable bodies survive a fresh owner", async () => {
  const { root, value } = store(); await value.initialize([], () => {}); const pending = value.accept(entry());
  await value.close(); expect(await pending).toEqual(entry()); await expect(value.accept(entry("new"))).rejects.toThrow("unconfirmed");
  const reopened = store(root).value; const recovered: AcceptedEntry[] = [];
  await reopened.initialize([], (entry) => recovered.push(entry)); expect(recovered).toEqual([entry()]);
});

test("paged startup preserves non-BMP identity ordering without collecting bodies in snapshot frames", async () => {
  const ids = [...Array.from({ length: 255 }, (_, index) => `message-${String(index).padStart(3, "0")}`), "\uE000",
    ...Array.from({ length: 257 }, (_, index) => `\u{10000}${String(index).padStart(3, "0")}`)];
  let page = 0;
  vi.spyOn(rustHost, "hostRequest").mockImplementation(async (_root, request) => {
    if (request.op === "accepted_snapshot") {
      const expected = page === 0 ? undefined : ids[page * 256 - 1];
      expect(request.after).toBe(expected);
      const summaries = ids.slice(page * 256, (page + 1) * 256).map((id) => {
        const { event: _, ...summary } = entry(id); return summary;
      });
      page++; return { entries: summaries, next: page * 256 < ids.length ? summaries.at(-1)?.id : null };
    }
    expect(request.op).toBe("accepted_get"); return { entry: entry(String(request.messageId)) };
  });
  const { value } = store(); const restored: string[] = [];
  await value.initialize([], (entry) => restored.push(entry.id));
  expect(page).toBe(3); expect(restored).toEqual(ids); expect(value.available).toBe(true);
});

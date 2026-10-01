import { appendFileSync, mkdirSync, mkdtempSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { syncPage } from "./thread-sync.js";
import { rustSyncPage } from "./thread-sync-rust.js";
import { retainSyncHost, syncHostRequest } from "./rust-sync.js";
const event = (id: string, text = id, ts = 1) => ({ id, threadId: "home", ts, agentId: "main", kind: "message", data: { role: "agent", text } });
function fixture(run: (dir: string, file: string) => void): void {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-paging-contract-")); const release = retainSyncHost(dir);
  try { mkdirSync(join(dir, "threads")); run(dir, join(dir, "threads", "home.jsonl")); }
  finally { release(); rmSync(dir, { recursive: true, force: true }); }
}
test("Rust retained history preserves released occurrence cursors, decoding and file replacements", () => fixture((dir, file) => {
  const rows = [event("repeat"), event("wide", "日本語🙂".repeat(8000)), event("repeat", "retimed"), { ...event("queued"), clientTs: 0 }, event("reply"), { ...event("queued", "retimed queued"), clientTs: 0 }, event("final")];
  const invalidUtf8 = Buffer.concat([Buffer.from(JSON.stringify(event("decoded", "PLACEHOLDER")).replace("PLACEHOLDER", "").replace('"text":""', '"text":"')), Buffer.from([0xc0, 0xaf]), Buffer.from('"}}\n')]);
  writeFileSync(file, Buffer.concat([Buffer.from(rows.map(row => JSON.stringify(row)).join("\n") + "\n{broken\n"), invalidUtf8, Buffer.from(JSON.stringify(event("unterminated")))]));
  const compare = (after?: string, min = 0, include = true) => {
    const expected = syncPage(file, after, min, 200, e => include || e.kind !== "approval_status");
    expect(rustSyncPage(dir, "home", after, min, include).events).toEqual(expected);
    return expected;
  };
  const first = compare();
  for (const after of ["repeat", "queued", "unknown", ...first.map(e => e.syncCursor)]) compare(after);
  // A complete prefix cursor survives appends; an unterminated line retains released semantics.
  appendFileSync(file, "\n" + JSON.stringify(event("appended")) + "\n"); compare(first[1]!.syncCursor);
  const replacement = JSON.stringify(event("other")) + "\n"; writeFileSync(file, replacement); compare(first[1]!.syncCursor);
  writeFileSync(file, replacement.replace("other", "equal")); compare(); // same-size mutation
  writeFileSync(file + ".new", replacement); renameSync(file + ".new", file); compare();
  rmSync(file); expect(rustSyncPage(dir, "home", undefined, 0, true)).toEqual({ events: [], more: false });
}));
test("Rust pages filter before limits and bound bytes without dropping an oversized first event", () => fixture((dir, file) => {
  const rows = [event("old", "old", 0), ...Array.from({ length: 210 }, (_, n) => ({ ...event(`status${n}`, "status", 2), kind: "approval_status" })), ...Array.from({ length: 240 }, (_, n) => event(`new${n}`, "🙂".repeat(2500), 3))];
  writeFileSync(file, rows.map(row => JSON.stringify(row)).join("\n") + "\n");
  let after: string | undefined; const ids: string[] = [];
  for (;;) {
    const page = rustSyncPage(dir, "home", after, 1, false);
    expect(page.events.length).toBeLessThan(200);
    ids.push(...page.events.map(e => e.id));
    if (!page.more) break;
    expect(page.events.length).toBeGreaterThan(0); after = page.events.at(-1)!.syncCursor;
  }
  expect(ids).toEqual(Array.from({ length: 240 }, (_, n) => `new${n}`));
  const large = { ...event("large", "仕事🙂".repeat(210_000)), future: Array.from({ length: 300_000 }, () => 0.000001) };
  writeFileSync(file, JSON.stringify(large) + "\n" + JSON.stringify(event("next")) + "\n");
  const pid = syncHostRequest(dir, { op: "bridge_pid" }).pid;
  const page = rustSyncPage(dir, "home", undefined, 0, true);
  expect(page).toMatchObject({ events: [large], more: true });
  expect(rustSyncPage(dir, "home", page.events[0]!.syncCursor, 0, true).events.map(e => e.id)).toEqual(["next"]);
  expect(syncHostRequest(dir, { op: "bridge_pid" }).pid).toBe(pid);
  const proof = syncHostRequest(dir, { op: "history_page", threadId: "home", minTs: 0, includeApprovalStatus: true });
  expect(() => syncHostRequest(dir, { op: "history_page_result", token: "wrong" })).toThrow("unconfirmed");
  expect(syncHostRequest(dir, { op: "history_page_result", token: proof.token }, proof.responseBytes as number)).toMatchObject({ events: [large], more: true });
  expect(() => syncHostRequest(dir, { op: "history_page_result", token: proof.token })).toThrow("unconfirmed");
  expect(syncHostRequest(dir, { op: "bridge_pid" }).pid).toBe(pid);
}));
test("Rust cache overflow retains all rows and unsupported legacy values remain untouched", () => fixture((dir, file) => {
  const rows = Array.from({ length: 17_000 }, (_, n) => event(`row${n}`));
  writeFileSync(file, rows.map(row => JSON.stringify(row)).join("\n") + "\n");
  let page = rustSyncPage(dir, "home", "row15999", 0, true);
  const ids: string[] = [];
  while (page.events.length) {
    ids.push(...page.events.map(e => e.id));
    page = rustSyncPage(dir, "home", page.events.at(-1)!.syncCursor, 0, true);
  }
  expect(ids).toEqual(Array.from({ length: 1000 }, (_, n) => `row${16000 + n}`));
  for (const text of ['{"id":"bad","ts":1,"data":"\\ud800"}\n', '{"id":"bad","ts":1e400}\n']) {
    writeFileSync(file, text); const original = readFileSync(file);
    expect(() => rustSyncPage(dir, "home", undefined, 0, true)).toThrow("unconfirmed");
    expect(readFileSync(file)).toEqual(original);
    expect(syncHostRequest(dir, { op: "history_open" }).stored).toBe(true);
  }
}));

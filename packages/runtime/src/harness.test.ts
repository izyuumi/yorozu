import { afterEach, expect, test } from "vitest";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { HarnessLedger } from "./harness-ledger.js";
import { HarnessProcess } from "./harness-process.js";
import type { HarnessConfiguration } from "./harness-contract.js";

const roots: string[] = [];
const ledgers: HarnessLedger[] = [];
const processes: HarnessProcess[] = [];
afterEach(async () => {
  for (const process of processes.splice(0)) await process.close();
  for (const ledger of ledgers.splice(0)) ledger.close();
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});
function root(): string { const dir = mkdtempSync(join(tmpdir(), "yorozu-harness-test-")); roots.push(dir); return dir; }
function ledger(dir: string): HarnessLedger { const value = new HarnessLedger(dir, "hermes", "0.21.5"); ledgers.push(value); return value; }

test("an uncertain handoff or control survives restart and cannot replay with the same or a new identity", () => {
  const dir = root(); const first = ledger(dir);
  const admitted = first.begin("accepted-event", { text: "write one harmless artifact" });
  expect(admitted.fresh).toBe(true);
  expect(first.begin("accepted-event", { text: "write one harmless artifact" }).fresh).toBe(false);
  expect(() => first.begin("accepted-event", { text: "different action" })).toThrow("identity conflict");
  const control = first.control("control-event", { task: "worker-a", text: "change only a" });
  expect(control.fresh).toBe(true);
  expect(() => first.control("control-event", { task: "worker-b", text: "change b" })).toThrow("identity conflict");
  first.close(); ledgers.pop();
  const recovered = ledger(dir);
  expect(recovered.state.runs["accepted-event"].state).toBe("unknown");
  expect(recovered.control("control-event", { task: "worker-a", text: "change only a" })).toMatchObject({ fresh: false, record: { state: "unknown" } });
  expect(recovered.begin("accepted-event", { text: "write one harmless artifact" })).toMatchObject({ fresh: false, run: { state: "unknown" } });
  expect(() => recovered.begin("new-event", { text: "retry the action" })).toThrow("unconfirmed");
});

test("only confirmed quiescent state can prepare a switch and failed preparation preserves the selected binding", () => {
  const dir = root(); const first = ledger(dir);
  const run = first.begin("old-event", { text: "hello" }).run;
  first.close(); ledgers.pop();
  expect(() => new HarnessLedger(dir, "openclaw", "2026.9.6")).toThrow("quiescent");
  const same = ledger(dir); const recovered = same.state.runs["old-event"];
  recovered.state = "completed"; recovered.result = { text: "hello", completed: true, cessation: "provider-terminal" }; same.save();
  same.close(); ledgers.pop();
  const path = join(dir, "harness-v1", "binding.json"); const original = readFileSync(path, "utf8");
  const target = new HarnessLedger(dir, "openclaw", "2026.9.6"); ledgers.push(target);
  expect(target.state.pluginId).toBe("openclaw");
  expect(readFileSync(path, "utf8")).toBe(original);
  target.close(); ledgers.pop();
  const resumed = ledger(dir); expect(resumed.state.bindingId).toBe(first.state.bindingId);
  expect(resumed.state.runs[run.eventId].result?.text).toBe("hello");
});

test("two host owners cannot mutate the binding and damaged state cannot become a fresh profile", () => {
  const dir = root(); const first = ledger(dir);
  expect(() => ledger(dir)).toThrow("already owned");
  first.close(); ledgers.pop();
  writeFileSync(join(dir, "harness-v1", "binding.json"), "{ damaged");
  expect(() => ledger(dir)).toThrow();
  expect(readFileSync(join(dir, "harness-v1", "binding.json"), "utf8")).toBe("{ damaged");
});

function peer(source: string): HarnessProcess {
  const configuration: HarnessConfiguration = { pluginId: "hermes", upstreamVersion: "0.21.5", command: process.execPath,
    args: ["--input-type=module", "-e", source], initialize: {} };
  const child = new HarnessProcess(configuration); processes.push(child); return child;
}
const ready = { protocolVersion: 1, pluginId: "hermes", upstreamVersion: "0.21.5",
  capabilities: { backgroundTasks: true, targetedSteer: true, taskStop: true, approvals: true, reconnect: false, attachments: false } };

test("process negotiation rejects incompatible versions before any execution input", async () => {
  const child = peer(`import {createInterface} from 'node:readline';
    createInterface({input:process.stdin}).on('line',line=>{const f=JSON.parse(line);
    process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:f.id,result:${JSON.stringify({ ...ready, protocolVersion: 2 })}})+'\\n');});`);
  await expect(child.start()).rejects.toThrow("Incompatible");
  await expect(child.request("turn.submit", { text: "do work" })).rejects.toThrow("unavailable");
});

test("adapter exit leaves a handoff unconfirmed and supervision never respawns it", async () => {
  const child = peer(`import {createInterface} from 'node:readline';
    createInterface({input:process.stdin}).on('line',line=>{const f=JSON.parse(line);
    if(f.method==='initialize') process.stdout.write(JSON.stringify({jsonrpc:'2.0',id:f.id,result:${JSON.stringify(ready)}})+'\\n');
    else process.exit(0);});`);
  await child.start();
  await expect(child.request("turn.submit", { runId: "immutable-host-operation" })).rejects.toThrow("exited");
  await expect(child.start()).rejects.toThrow("already started");
  await expect(child.request("turn.submit", { runId: "immutable-host-operation" })).rejects.toThrow("unavailable");
});

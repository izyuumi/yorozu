import { createHash, randomUUID } from "node:crypto";
import { closeSync, constants, copyFileSync, fstatSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { retainSharedSyncHost } from "./rust-sync.js";
import { taskIsLive, validHarnessTask, type HarnessPluginId, type HarnessTask } from "./harness-contract.js";

export const harnessDigest = (input: unknown): string => createHash("sha256").update(JSON.stringify(input)).digest("hex");
export interface HarnessRun {
  eventId: string;
  runId: string;
  attemptId: string;
  identity: string;
  state: "sending" | "running" | "completed" | "failed" | "stopped" | "unknown";
  result?: { text: string; failed?: boolean; completed?: true; unconfirmed?: true; cessation?: "provider-terminal" | "not-submitted" };
}
interface Control { identity: string; state: "sending" | "queued" | "requested" | "rejected" | "unsupported" | "unknown"; reason?: string }
interface State {
  version: 1;
  pluginId: HarnessPluginId;
  upstreamVersion: string;
  bindingId: string;
  sessionId?: string;
  runs: Record<string, HarnessRun>;
  tasks: Record<string, HarnessTask>;
  controls: Record<string, Control>;
  autonomous: Record<string, { runId: string; state: "running" | "completed" | "failed" | "stopped" | "unknown"; resultTaskIds?: string[] }>;
  pendingResults: Record<string, string>;
}
const owned = new Set<string>();
/** Reuse the existing core's kernel lease in a separate plugin-only namespace. */
export class HarnessLedger {
  private readonly file: string;
  private release: () => void;
  readonly state: State;
  private key: string;
  private priorBinding?: string;
  constructor(dir: string, pluginId: HarnessPluginId, upstreamVersion: string) {
    this.key = resolve(dir);
    if (owned.has(this.key)) throw new Error("Harness binding already owned");
    this.release = retainSharedSyncHost(join(dir, "harness-v1"));
    owned.add(this.key);
    try {
      const root = join(dir, "harness-v1"); mkdirSync(root, { recursive: true, mode: 0o700 });
      if (lstatSync(root).isSymbolicLink() || !lstatSync(root).isDirectory()) throw new Error("Invalid harness store");
      this.file = join(root, "binding.json");
      let stored: State | undefined;
      try {
        const fd = openSync(this.file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
        try {
          const stat = fstatSync(fd);
          if (!stat.isFile() || stat.size > 16 * 1024 * 1024) throw new Error("Invalid harness store file");
          stored = JSON.parse(readFileSync(fd, "utf8"));
        } finally { closeSync(fd); }
      } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
      if (stored && (stored.version !== 1 || !["hermes", "openclaw"].includes(stored.pluginId) || typeof stored.bindingId !== "string"
        || !/^[a-f0-9-]{36}$/.test(stored.bindingId)
        || !stored.runs || !stored.tasks || !stored.controls || Object.values(stored.tasks).some(t => !validHarnessTask(t))
        || Object.values(stored.runs).some(r => !r || typeof r.identity !== "string" || !/^[a-f0-9]{64}$/.test(r.identity)
          || typeof r.eventId !== "string" || r.eventId.length > 512 || typeof r.runId !== "string" || r.runId.length > 512
          || typeof r.attemptId !== "string" || r.attemptId.length > 512 || !["sending", "running", "completed", "failed", "stopped", "unknown"].includes(r.state))))
        throw new Error("Damaged harness binding; refusing execution");
      this.state = stored ?? { version: 1, pluginId, upstreamVersion, bindingId: randomUUID(), runs: {}, tasks: {}, controls: {}, autonomous: {}, pendingResults: {} };
      this.state.autonomous ??= {};
      this.state.pendingResults ??= {};
      if (Object.values(this.state.pendingResults).some(r => typeof r !== "string")) throw new Error("Damaged pending result ledger");
      if (Object.values(this.state.autonomous).some(a => !a || typeof a.runId !== "string" || !["running", "completed", "failed", "stopped", "unknown"].includes(a.state)))
        throw new Error("Damaged autonomous execution ledger");
      const unsettled = Object.values(this.state.runs).some(r => ["sending", "running", "unknown"].includes(r.state))
        || Object.values(this.state.tasks).some(taskIsLive) || Object.values(this.state.controls).some(c => ["sending", "unknown"].includes(c.state))
        || Object.values(this.state.autonomous).some(a => ["running", "unknown"].includes(a.state)) || Object.keys(this.state.pendingResults).length > 0;
      if (stored && (stored.pluginId !== pluginId || stored.upstreamVersion !== upstreamVersion)) {
        if (unsettled) throw new Error("Harness switching requires quiescent confirmed execution");
        // Preserve old binding evidence; no live vendor session transfer or overwritten history.
        this.priorBinding = stored.bindingId;
        this.state = { version: 1, pluginId, upstreamVersion, bindingId: randomUUID(), runs: {}, tasks: {}, controls: {}, autonomous: {}, pendingResults: {} };
      } else if (stored) {
        for (const r of Object.values(this.state.runs)) if (["sending", "running"].includes(r.state)) {
          r.state = "unknown"; r.result = { text: "The previous execution outcome is unconfirmed. It will not run again automatically.", unconfirmed: true };
        }
        for (const task of Object.values(this.state.tasks)) if (taskIsLive(task)) { task.state = "unknown"; task.canSteer = false; task.canStop = false; }
        for (const c of Object.values(this.state.controls)) if (c.state === "sending") c.state = "unknown";
        for (const a of Object.values(this.state.autonomous)) if (a.state === "running") a.state = "unknown";
      }
      if (!this.priorBinding) this.save();
    } catch (error) { this.release(); owned.delete(this.key); throw error; }
  }
  save(): void {
    if (this.priorBinding) throw new Error("Target harness must prepare before binding commit");
    const encoded = JSON.stringify(this.state) + "\n";
    if (Buffer.byteLength(encoded) > 16 * 1024 * 1024) throw new Error("Harness ledger exceeded its budget; no execution admitted");
    const tmp = this.file + "." + randomUUID();
    const fd = openSync(tmp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { writeFileSync(fd, encoded); fsyncSync(fd); } finally { closeSync(fd); }
    renameSync(tmp, this.file);
    const parent = openSync(join(this.file, ".."), constants.O_RDONLY);
    try { fsyncSync(parent); } finally { closeSync(parent); }
  }
  commitBinding(): void {
    if (!this.priorBinding) return;
    const previous = this.priorBinding;
    copyFileSync(this.file, join(this.file, "..", `binding-${previous}.json`), constants.COPYFILE_EXCL);
    this.priorBinding = undefined;
    this.save();
  }
  get committed(): boolean { return this.priorBinding === undefined; }
  begin(eventId: string, input: unknown): { run: HarnessRun; fresh: boolean } {
    const identity = harnessDigest(input); const existing = Object.hasOwn(this.state.runs, eventId) ? this.state.runs[eventId] : undefined;
    if (existing) {
      if (existing.identity !== identity) throw new Error("Harness input identity conflict");
      return { run: existing, fresh: false };
    }
    if (Object.values(this.state.runs).some(r => ["sending", "running", "unknown"].includes(r.state))
      || Object.values(this.state.tasks).some(t => t.state === "unknown")
      || Object.values(this.state.autonomous).some(a => a.state === "unknown")) throw new Error("Prior harness execution is unconfirmed");
    const run: HarnessRun = { eventId, runId: `harness-run-${harnessDigest([this.state.bindingId, eventId])}`, attemptId: randomUUID(), identity, state: "sending" };
    this.state.runs[eventId] = run; this.save(); return { run, fresh: true };
  }
  control(operationId: string, input: unknown): { record: Control; fresh: boolean } {
    const identity = harnessDigest(input); const existing = Object.hasOwn(this.state.controls, operationId) ? this.state.controls[operationId] : undefined;
    if (existing) {
      if (existing.identity !== identity) throw new Error("Harness control identity conflict");
      return { record: existing, fresh: false };
    }
    const record: Control = { identity, state: "sending" }; this.state.controls[operationId] = record; this.save(); return { record, fresh: true };
  }
  close(): void { this.release(); owned.delete(this.key); }
}

import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { HARNESS_FRAME_BYTES, HARNESS_PENDING_REQUESTS, validHarnessEvent, type HarnessConfiguration, type HarnessEvent, type HarnessReady } from "./harness-contract.js";

/** Bounded supervised process; never respawns or replays execution after failure. */
export class HarnessProcess {
  private child?: ChildProcessWithoutNullStreams;
  private pending = new Map<string, { resolve(v: any): void; reject(e: Error): void; timer: NodeJS.Timeout }>();
  private buffer = Buffer.alloc(0);
  private closing = false;
  private dead = false;
  private exited?: Promise<void>;
  readonly listeners = new Set<(event: HarnessEvent) => void>();
  readonly failures = new Set<(reason: string) => void>();
  constructor(readonly configuration: HarnessConfiguration) {}
  async start(): Promise<HarnessReady> {
    if (this.child || this.dead) throw new Error("Harness process already started or unavailable");
    // Neither adapter nor upstream gets ambient provider credentials or Yorozu secrets.
    const env: NodeJS.ProcessEnv = {};
    for (const key of ["PATH", "TMPDIR", "TEMP", "TMP", "LANG", "SystemRoot", "WINDIR"]) {
      if (process.env[key] !== undefined) env[key] = process.env[key];
    }
    const child = this.child = spawn(this.configuration.command, this.configuration.args, { stdio: "pipe", env });
    this.exited = new Promise(resolve => child.once("close", () => resolve()));
    child.stderr.resume(); // Diagnostics are not user history or model context.
    child.stdout.on("data", (chunk: Buffer) => {
      if (this.dead) return;
      this.buffer = Buffer.concat([this.buffer, chunk]);
      let newline: number;
      while ((newline = this.buffer.indexOf(10)) >= 0) {
        if (newline > HARNESS_FRAME_BYTES) return this.fail("Harness protocol frame exceeded its limit");
        const line = this.buffer.subarray(0, newline); this.buffer = this.buffer.subarray(newline + 1);
        try {
          const frame = JSON.parse(line.toString("utf8"));
          if (frame.jsonrpc !== "2.0") throw new Error("Invalid protocol");
          if (frame.method === "harness.event" && validHarnessEvent(frame.params)) {
            for (const listener of this.listeners) listener(frame.params);
          } else if (typeof frame.id === "string" && ("result" in frame || "error" in frame)) {
            const pending = this.pending.get(frame.id);
            if (!pending) throw new Error("Unknown receipt");
            this.pending.delete(frame.id); clearTimeout(pending.timer);
            if (frame.error) pending.reject(new Error(`Harness refused request (${String(frame.error.code)})`));
            else pending.resolve(frame.result);
          } else throw new Error("Invalid frame");
        } catch { return this.fail("Harness protocol became unavailable"); }
      }
      if (this.buffer.length > HARNESS_FRAME_BYTES) this.fail("Harness protocol frame exceeded its limit");
    });
    child.once("error", () => this.fail("Harness process could not start"));
    child.once("close", () => this.fail("Harness process exited"));
    child.stdin.on("error", () => this.fail("Harness input became unavailable"));
    const ready = await this.request("initialize", { ...this.configuration.initialize, protocolVersion: 1 });
    if (!ready || ready.protocolVersion !== 1 || ready.pluginId !== this.configuration.pluginId
      || ready.upstreamVersion !== this.configuration.upstreamVersion || !ready.capabilities
      || ["backgroundTasks", "targetedSteer", "taskStop", "approvals", "reconnect", "attachments"].some(k => typeof ready.capabilities[k] !== "boolean")) {
      this.fail("Incompatible harness version or capability contract");
      throw new Error("Incompatible harness version or capability contract");
    }
    return ready;
  }
  request(method: string, params: Record<string, unknown>): Promise<any> {
    if (this.dead || !this.child || this.closing && method !== "shutdown") return Promise.reject(new Error("Harness unavailable"));
    if (this.pending.size >= HARNESS_PENDING_REQUESTS) return Promise.reject(new Error("Harness request window is full"));
    const id = randomUUID(); const encoded = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
    if (Buffer.byteLength(encoded) > HARNESS_FRAME_BYTES) return Promise.reject(new Error("Harness request exceeded its limit"));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.fail("Harness receipt is unconfirmed"), method === "initialize" ? 120_000 : 35_000);
      this.pending.set(id, { resolve, reject, timer });
      this.child!.stdin.write(encoded);
    });
  }
  private fail(reason: string): void {
    if (this.dead) return;
    this.dead = true;
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(new Error(reason)); }
    this.pending.clear();
    if (!this.closing) for (const listener of this.failures) listener(reason);
    this.child?.kill("SIGTERM");
  }
  async close(): Promise<void> {
    if (this.closing) return this.exited;
    this.closing = true;
    if (!this.dead) {
      await this.request("shutdown", {}).catch(() => {});
      this.child?.stdin.end();
    }
    this.fail("Harness closed");
    const timer = setTimeout(() => this.child?.kill("SIGKILL"), 5000);
    try { await this.exited; } finally { clearTimeout(timer); }
  }
}

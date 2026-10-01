import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { randomUUID } from "node:crypto";
import { syncHostResult } from "./rust-sync.js";
import { performance } from "node:perf_hooks";
const ioNow = performance.now.bind(performance);
import { setTimeout as nativeTimeout, clearTimeout as nativeClearTimeout } from "node:timers";
// Child-process IO liveness uses the real event-loop clock, independently of
// application deadlines and injected test/business clocks.
const ioTimeout = nativeTimeout;
const ioClearTimeout = nativeClearTimeout;

/** Private compatibility bridge to the portable Rust core. Provider adapters remain
 * TypeScript during the staged rewrite; assembling files never admits a turn. */
export function rustHostCommand(): string {
  if (process.env.YOROZU_HOST_CORE) return resolve(process.env.YOROZU_HOST_CORE);
  const name = `yorozu-host-core${process.platform === "win32" ? ".exe" : ""}`;
  const bundled = join(import.meta.dirname, "..", "..", name);
  return existsSync(bundled) ? bundled : join(import.meta.dirname, "..", "..", "host-core", "target", "debug", name);
}
type Pending = { resolve(value: unknown): void; reject(error: Error): void; timer: ReturnType<typeof ioTimeout>; bytes: number };
export type HostTransportEvent = { type: "transport_event"; transportId: string; device: string; event: "open" | "frame" | "close" | "error" | "lost"; frame?: unknown; receiveToken?: unknown };
class Worker {
  owners = 0;
  get pid(): number | undefined { return this.child?.pid; }
  readonly listeners = new Set<(event: HostTransportEvent) => void>();
  private child?: ChildProcessWithoutNullStreams;
  private buffer = "";
  private pending = new Map<string, Pending>();
  private stopped = false;
  private pendingBytes = 0;
  constructor(private readonly dir: string) {}
  private fail(): void {
    const child = this.child;
    this.child = undefined; this.buffer = "";
    for (const request of this.pending.values()) {
      ioClearTimeout(request.timer); request.reject(new Error("Rust host request remains unconfirmed"));
    }
    this.pending.clear(); this.pendingBytes = 0; child?.kill();
    if (child) for (const listener of this.listeners) {
      try { listener({ type: "transport_event", transportId: "", device: "", event: "lost" }); } catch { /* caller reports its own fixed error */ }
    }
  }
  private start(): ChildProcessWithoutNullStreams {
    if (this.stopped) throw new Error("Rust host worker closed");
    if (this.child) return this.child;
    const env: NodeJS.ProcessEnv = {};
    for (const key of ["PATH", "TMPDIR", "TEMP", "TMP", "SystemRoot", "WINDIR"]) {
      if (process.env[key] !== undefined) env[key] = process.env[key];
    }
    const child = spawn(rustHostCommand(), ["attachments", this.dir], { stdio: "pipe", env });
    this.child = child; child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      if (this.child !== child) return;
      this.buffer += chunk;
      if (Buffer.byteLength(this.buffer) > 34 * 1024 * 1024) return this.fail();
      let newline: number;
      while ((newline = this.buffer.indexOf("\n")) >= 0) {
        const line = this.buffer.slice(0, newline); this.buffer = this.buffer.slice(newline + 1);
        try {
          const frame = JSON.parse(line) as { id?: unknown; result?: unknown; type?: unknown; transportId?: unknown; device?: unknown; event?: unknown };
          if (frame.type === "transport_event") {
            if (typeof frame.transportId !== "string" || typeof frame.device !== "string" ||
                !["open", "frame", "close", "error"].includes(String(frame.event))) return this.fail();
            for (const listener of this.listeners) { try { listener(frame as HostTransportEvent); } catch { /* isolate caller errors */ } }
            continue;
          }
          if (typeof frame.id !== "string" || !Object.hasOwn(frame, "result")) return this.fail();
          const request = this.pending.get(frame.id);
          if (!request) return this.fail();
          this.pending.delete(frame.id); this.pendingBytes -= request.bytes; ioClearTimeout(request.timer); request.resolve(frame.result);
        } catch { return this.fail(); }
      }
    });
    child.stderr.resume();
    const failed = (): void => { if (this.child === child) this.fail(); };
    child.on("error", failed); child.on("exit", failed); child.stdin.on("error", failed);
    return child;
  }
  request(data: Record<string, unknown>): Promise<unknown> {
    if (this.pending.size >= 32) return Promise.reject(new Error("Rust host worker busy"));
    const id = randomUUID(); const encoded = JSON.stringify({ ...data, id }) + "\n";
    const bytes = Buffer.byteLength(encoded);
    if (bytes > 32 * 1024 * 1024) return Promise.reject(new Error("Rust host request too large"));
    if (this.pendingBytes + bytes > 64 * 1024 * 1024) return Promise.reject(new Error("Rust host worker busy"));
    return new Promise((resolve, reject) => {
      try {
        const child = this.start();
        const timer = ioTimeout(() => { if (this.child === child && this.pending.has(id)) this.fail(); }, 30_000);
        this.pendingBytes += bytes; this.pending.set(id, { resolve, reject, timer, bytes }); child.stdin.write(encoded);
      } catch { reject(new Error("Rust host worker unavailable")); }
    });
  }
  async close(): Promise<void> {
    this.stopped = true;
    const child = this.child;
    if (!child) return;
    const exited = new Promise<void>((resolve) => child.once("close", () => resolve()));
    this.fail(); await exited;
  }
}
const workers = new Map<string, Worker>();
function workerFor(dir: string): Worker {
  const key = resolve(dir); let worker = workers.get(key);
  if (!worker) { worker = new Worker(key); workers.set(key, worker); }
  return worker;
}
const operationalPending = new Map<string, { count: number; bytes: number }>();
export function hostRequest(dir: string, data: Record<string, unknown>): Promise<unknown> {
  const op = data.op;
  if (typeof op !== "string" || !["accepted_", "stop_", "admission_", "outbox_"].some((prefix) => op.startsWith(prefix)))
    return workerFor(dir).request(data);
  const root = resolve(dir);
  const pending = operationalPending.get(root) ?? { count: 0, bytes: 0 };
  if (pending.count >= 32) return Promise.reject(new Error("Rust host worker busy"));
  let snapshot: Record<string, unknown>; let bytes: number;
  try {
    const encoded = JSON.stringify({ ...data, id: randomUUID() });
    bytes = Buffer.byteLength(encoded) + 1;
    if (bytes > 32 * 1024 * 1024) return Promise.reject(new Error("Rust host request too large"));
    if (pending.bytes + bytes > 64 * 1024 * 1024) return Promise.reject(new Error("Rust host worker busy"));
    snapshot = JSON.parse(encoded) as Record<string, unknown>;
  } catch { return Promise.reject(new Error("Rust host request unavailable")); }
  pending.count++; pending.bytes += bytes; operationalPending.set(root, pending);
  const began = ioNow();
  // Preserve asynchronous acceptance and immutable input, with bounded queued IO wait.
  return Promise.resolve().then(() => {
    const remaining = 30_000 - (ioNow() - began);
    if (remaining <= 0) throw new Error("Rust host request remains unconfirmed");
    return syncHostResult(root, snapshot, 1024 * 1024, remaining);
  }).finally(() => {
    pending.count--; pending.bytes -= bytes;
    if (!pending.count && operationalPending.get(root) === pending) operationalPending.delete(root);
  });
}
export function subscribeHostEvents(dir: string, listener: (event: HostTransportEvent) => void): () => void {
  const worker = workerFor(dir); worker.listeners.add(listener); return () => { worker.listeners.delete(listener); };
}
/** Keep one shared host alive until its last storage or transport owner closes. */
export function retainHostWorker(dir: string): () => Promise<void> {
  const key = resolve(dir); const worker = workerFor(key); worker.owners++;
  let released = false;
  return async () => {
    if (released) return; released = true;
    if (--worker.owners === 0) {
      if (workers.get(key) === worker) workers.delete(key);
      await worker.close();
    }
  };
}
export async function closeHostWorker(dir: string): Promise<void> {
  const key = resolve(dir); const worker = workers.get(key); workers.delete(key); await worker?.close();
}

/** Read-only identity of this module's owned child, for supervision/recovery evidence. */
export function hostWorkerPid(dir: string): number | undefined { return workers.get(resolve(dir))?.pid; }

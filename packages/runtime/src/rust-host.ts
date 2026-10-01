import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { randomUUID } from "node:crypto";

/** Private compatibility bridge to the portable Rust core. Provider adapters remain
 * TypeScript during the staged rewrite; assembling files never admits a turn. */
export function rustHostCommand(): string {
  if (process.env.YOROZU_HOST_CORE) return resolve(process.env.YOROZU_HOST_CORE);
  const name = `yorozu-host-core${process.platform === "win32" ? ".exe" : ""}`;
  const bundled = join(import.meta.dirname, "..", "..", name);
  return existsSync(bundled) ? bundled : join(import.meta.dirname, "..", "..", "host-core", "target", "debug", name);
}
type Pending = { resolve(value: unknown): void; reject(error: Error): void; timer: ReturnType<typeof setTimeout>; bytes: number };
class Worker {
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
      clearTimeout(request.timer); request.reject(new Error("Rust host request remains unconfirmed"));
    }
    this.pending.clear(); this.pendingBytes = 0; child?.kill();
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
          const frame = JSON.parse(line) as { id?: unknown; result?: unknown };
          if (typeof frame.id !== "string" || !Object.hasOwn(frame, "result")) return this.fail();
          const request = this.pending.get(frame.id);
          if (!request) return this.fail();
          this.pending.delete(frame.id); this.pendingBytes -= request.bytes; clearTimeout(request.timer); request.resolve(frame.result);
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
        const timer = setTimeout(() => { if (this.child === child && this.pending.has(id)) this.fail(); }, 30_000);
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
export function hostRequest(dir: string, data: Record<string, unknown>): Promise<unknown> {
  const key = resolve(dir); let worker = workers.get(key);
  if (!worker) { worker = new Worker(key); workers.set(key, worker); }
  return worker.request(data);
}
export async function closeHostWorker(dir: string): Promise<void> {
  const key = resolve(dir); const worker = workers.get(key); workers.delete(key); await worker?.close();
}

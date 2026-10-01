/** Compatibility I/O only. Durable history policy and mutations belong to Rust. */
import { parentPort, workerData } from "node:worker_threads";
import { spawn } from "node:child_process";
const { command, dir, lifecycle, signal, output } = workerData as { command: string; dir: string; lifecycle: SharedArrayBuffer; signal: SharedArrayBuffer; output: SharedArrayBuffer };
const life = new Int32Array(lifecycle);
const handoff = new Int32Array(signal); const response = new Uint8Array(output);
const port = parentPort!;
const child = spawn(command, ["history", dir], { stdio: "pipe", env: process.env });
let active: { id: string; signal: Int32Array; output: Uint8Array } | undefined;
let buffer = ""; let closing = false; let exited = false;
let idle: ReturnType<typeof setTimeout> | undefined;
let deadline: ReturnType<typeof setTimeout> | undefined;
function result(value: unknown, success = true, encoded?: Buffer): void {
  const pending = active; active = undefined;
  if (deadline) clearTimeout(deadline);
  if (pending) {
    const bytes = encoded ?? Buffer.from(JSON.stringify(value));
    if (bytes.length <= pending.output.length) { pending.output.set(bytes); Atomics.store(pending.signal, 1, bytes.length); }
    else success = false;
    Atomics.store(life, 0, closing ? 2 : 0);
    Atomics.store(pending.signal, 0, success ? 1 : -1); Atomics.notify(pending.signal, 0);
  }
  if (!closing) scheduleIdle();
}
function scheduleIdle(): void {
  if (idle) clearTimeout(idle);
  idle = setTimeout(() => {
    if (Atomics.load(life, 1) > 0) { scheduleIdle(); return; }
    if (Atomics.compareExchange(life, 0, 0, 2) === 0) close();
  }, 2_000);
}
function close(): void {
  if (closing) return;
  closing = true;
  const reserved = Atomics.exchange(life, 0, 2);
  // A caller can reserve its request just before the child's exit event, before
  // parentPort dispatch has created `active`. Notify that reserved handoff too.
  if (!active && reserved === 1) { Atomics.store(handoff, 0, -1); Atomics.notify(handoff, 0); }
  if (idle) clearTimeout(idle);
  result(null, false);
  child.stdin.end();
  const timer = setTimeout(() => child.kill(), 500); timer.unref();
  if (exited) finish();
}
function finish(): void { Atomics.store(life, 0, 3); Atomics.notify(life, 0); port.close(); }
function fail(): void { close(); }
child.stderr.resume(); child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk: string) => {
  buffer += chunk;
  if (Buffer.byteLength(buffer) > (active?.output.length ?? response.length) + 4096) return fail();
  let newline: number;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline); buffer = buffer.slice(newline + 1);
    try {
      const frame = JSON.parse(line) as { id?: unknown; result?: unknown };
      if (!active || frame.id !== active.id || !Object.hasOwn(frame, "result")) return fail();
      // The pinned Rust protocol emits exactly id/result in that order. Preserve its result
      // bytes: JS re-encoding may expand numeric notation beyond a bounded response allowance.
      const prefix = `{"id":${JSON.stringify(frame.id)},"result":`;
      if (!line.startsWith(prefix) || !line.endsWith("}") || Object.keys(frame).length !== 2) return fail();
      result(frame.result, true, Buffer.from(line.slice(prefix.length, -1)));
    } catch { return fail(); }
  }
});
child.on("error", fail); child.stdin.on("error", fail);
child.on("close", () => { exited = true; fail(); finish(); });
port.on("message", (message: { close?: boolean; id: string; input: string; signal: SharedArrayBuffer; output: SharedArrayBuffer }) => {
  if (message.close) return close();
  if (message.output.byteLength < 1 || message.output.byteLength > 34 * 1024 * 1024) return fail();
  const request = { id: message.id, signal: handoff, output: new Uint8Array(message.output) };
  if (active || closing || exited) {
    Atomics.store(request.signal, 0, -1); Atomics.notify(request.signal, 0); return;
  }
  active = request;
  if (idle) clearTimeout(idle);
  if (JSON.parse(message.input).op === "bridge_pid") return result({ pid: child.pid });
  deadline = setTimeout(() => { result(null, false); close(); }, 30_000);
  child.stdin.write(message.input + "\n");
});
process.on("uncaughtException", fail); process.on("unhandledRejection", fail);
scheduleIdle();

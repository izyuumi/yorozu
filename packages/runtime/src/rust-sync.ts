/** Bounded synchronous compatibility calls without process-per-event spawning.
 * A separate JS I/O thread lets Rust acknowledge while the calling thread waits. */
import { Worker } from "node:worker_threads";
import { randomUUID } from "node:crypto";
import { performance } from "node:perf_hooks";
const ioNow = performance.now.bind(performance);
import { resolve } from "node:path";
import { rustHostCommand } from "./rust-host.js";
type Bridge = { thread: Worker; life: Int32Array; signal: Int32Array; output: Uint8Array };
const bridges = new Map<string, Bridge>();
const owners = new Map<string, symbol>();
const leases = new Map<string, number>();
const retained = (dir: string): boolean => owners.has(dir) || (leases.get(dir) ?? 0) > 0;
function close(bridge: Bridge): void {
  const state = Atomics.load(bridge.life, 0);
  if (state === 3) return;
  Atomics.store(bridge.life, 0, 2); bridge.thread.postMessage({ close: true });
  while (Atomics.load(bridge.life, 0) !== 3) {
    if (Atomics.wait(bridge.life, 0, 2, 31_000) === "timed-out") { void bridge.thread.terminate(); throw new Error("Rust history remains unconfirmed"); }
  }
}
function bridgeFor(dir: string): Bridge {
  let bridge = bridges.get(dir);
  if (bridge && Atomics.load(bridge.life, 0) >= 2) { close(bridge); bridges.delete(dir); bridge = undefined; }
  if (bridge) return bridge;
  if (bridges.size >= 8) {
    const idle = [...bridges].find(([root, bridge]) => !retained(root) && Atomics.load(bridge.life, 0) !== 1);
    if (!idle) throw new Error("Rust history remains unconfirmed");
    close(idle[1]); bridges.delete(idle[0]);
  }
  const lifecycle = new SharedArrayBuffer(8); const life = new Int32Array(lifecycle);
  if (retained(dir)) Atomics.store(life, 1, 1);
  const env: NodeJS.ProcessEnv = {};
  for (const key of ["PATH", "TMPDIR", "TEMP", "TMP", "SystemRoot", "WINDIR"]) if (process.env[key] !== undefined) env[key] = process.env[key];
  const signal = new Int32Array(new SharedArrayBuffer(8)); const output = new Uint8Array(new SharedArrayBuffer(1024 * 1024));
  const thread = new Worker(new URL(`./rust-sync-worker.${import.meta.url.endsWith(".ts") ? "ts" : "js"}`, import.meta.url), {
    workerData: { command: rustHostCommand(), dir, lifecycle, signal: signal.buffer, output: output.buffer }, env,
  });
  bridge = { thread, life, signal, output }; bridges.set(dir, bridge); thread.unref();
  const owned = bridge;
  thread.on("error", () => { Atomics.store(life, 0, 3); Atomics.notify(life, 0); });
  thread.on("exit", () => { Atomics.store(life, 0, 3); Atomics.notify(life, 0); if (bridges.get(dir) === owned) bridges.delete(dir); });
  return bridge;
}
function request(dir: string, data: Record<string, unknown>, responseBytes: number, deadline: number): Record<string, unknown> {
  if (!Number.isSafeInteger(responseBytes) || responseBytes < 1 || responseBytes > 34 * 1024 * 1024) throw new Error("Rust history response limit");
  const id = randomUUID(); const input = JSON.stringify({ ...data, id });
  if (Buffer.byteLength(input) > 32 * 1024 * 1024 - 1) throw new Error("Rust history remains unconfirmed");
  const root = resolve(dir); const bridge = bridgeFor(root);
  const signal = bridge.signal;
  const output = responseBytes <= bridge.output.length ? bridge.output : new Uint8Array(new SharedArrayBuffer(responseBytes));
  Atomics.store(signal, 0, 0); Atomics.store(signal, 1, 0);
  const remaining = deadline - ioNow();
  if (remaining <= 0) throw new Error("Rust history remains unconfirmed");
  if (Atomics.compareExchange(bridge.life, 0, 0, 1) !== 0) throw new Error("Rust history remains unconfirmed");
  bridge.thread.postMessage({ id, input, signal: signal.buffer, output: output.buffer });
  if (Atomics.wait(signal, 0, 0, Math.max(0, deadline - ioNow())) === "timed-out" || Atomics.load(signal, 0) !== 1) {
    try { close(bridge); } catch { /* remain uncertain */ } bridges.delete(root); throw new Error("Rust history remains unconfirmed");
  }
  let result: unknown;
  try { result = JSON.parse(Buffer.from(output.subarray(0, Atomics.load(signal, 1))).toString("utf8")); } catch { throw new Error("Rust history remains unconfirmed"); }
  if (!result || typeof result !== "object" || Array.isArray(result)) throw new Error("Rust history remains unconfirmed");
  return result as Record<string, unknown>;
}
/** Large results allocate a transient buffer only after the Rust owner supplies a bounded proof. */
export function syncHostResult(dir: string, data: Record<string, unknown>, responseBytes = 1024 * 1024, timeoutMs = 31_000): Record<string, unknown> {
  if (!Number.isFinite(timeoutMs) || timeoutMs <= 0 || timeoutMs > 31_000) throw new Error("Rust history remains unconfirmed");
  const deadline = ioNow() + timeoutMs;
  const result = request(dir, data, responseBytes, deadline);
  if (!Object.hasOwn(result, "bridgeToken")) return result;
  if (Object.keys(result).length !== 2 || typeof result.bridgeToken !== "string" || typeof result.responseBytes !== "number")
    throw new Error("Rust history remains unconfirmed");
  const complete = request(dir, { op: "bridge_result", token: result.bridgeToken }, result.responseBytes, deadline);
  if (Object.hasOwn(complete, "bridgeToken")) throw new Error("Rust history remains unconfirmed");
  return complete;
}
/** Throwing compatibility facade for callers that require a successful durable proof. */
export function syncHostRequest(dir: string, data: Record<string, unknown>, responseBytes = 1024 * 1024): Record<string, unknown> {
  const result = syncHostResult(dir, data, responseBytes);
  if (Object.hasOwn(result, "error")) throw new Error("Rust history remains unconfirmed");
  return result;
}
export function closeSyncHost(dir: string): void {
  const root = resolve(dir); const bridge = bridges.get(root); if (!bridge) return;
  close(bridge); if (bridges.get(root) === bridge) bridges.delete(root);
}
export function persistHistory(event: unknown, dir: string, thread: boolean, transcript: boolean): void {
  persistHistoryBatch([event], dir, thread, transcript);
}
export function persistHistoryBatch(events: unknown[], dir: string, thread: boolean, transcript: boolean): void {
  const proof = syncHostRequest(dir, { op: "history_append", events, thread, transcript, operationId: randomUUID() });
  if (proof.stored !== true || typeof proof.key !== "string" || !/^[a-f0-9]{64}$/.test(proof.key)) throw new Error("Rust history remains unconfirmed");
}

/** Hold the authoritative writer for the complete host lifetime, including idle SDK waits. */
export function retainSyncHost(dir: string): () => void {
  const root = resolve(dir); if (owners.has(root)) throw new Error("Rust history already owned");
  const token = Symbol(); owners.set(root, token);
  try {
    const bridge = bridgeFor(root); Atomics.store(bridge.life, 1, 1);
    if (syncHostRequest(root, { op: "history_open" }).stored !== true) throw new Error("Rust history remains unconfirmed");
  } catch (error) { owners.delete(root); releaseIfIdle(root); throw error; }
  return () => {
    if (owners.get(root) !== token) return;
    owners.delete(root); releaseIfIdle(root);
  };
}

function releaseIfIdle(root: string): void {
  if (retained(root)) return;
  const bridge = bridges.get(root); if (bridge) Atomics.store(bridge.life, 1, 0);
  closeSyncHost(root);
}
/** Operational adapters share the same writer while keeping independent drain/release lifetimes. */
export function retainSharedSyncHost(dir: string): () => void {
  const root = resolve(dir); leases.set(root, (leases.get(root) ?? 0) + 1);
  try {
    const bridge = bridgeFor(root); Atomics.store(bridge.life, 1, 1);
    if (syncHostRequest(root, { op: "history_open" }).stored !== true) throw new Error("Rust history remains unconfirmed");
  } catch (error) {
    const count = leases.get(root)! - 1;
    if (count) leases.set(root, count); else leases.delete(root);
    releaseIfIdle(root); throw error;
  }
  let released = false;
  return () => {
    if (released) return; released = true;
    const count = leases.get(root)! - 1;
    if (count) leases.set(root, count); else leases.delete(root);
    releaseIfIdle(root);
  };
}

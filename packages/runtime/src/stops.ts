/** Stop intent reservations plus the Rust-authoritative durable Stop journal. */
import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { hostRequest } from "./rust-host.js";
import { syncHostResult, retainSharedSyncHost } from "./rust-sync.js";
export type StopRecord = { targetEventId: string; threadId: string;
  status: "requested" | "stopped" | "completed" | "withdrawn" | "unconfirmed";
  sessionKey?: string; runId?: string; partialText?: string; preDispatch?: boolean; requestIds: string[] };
function valid(entry: unknown): entry is StopRecord {
  if (!entry || typeof entry !== "object") return false;
  const record = entry as StopRecord;
  const id = (value: unknown): value is string => typeof value === "string" && value.length > 0 && value.length <= 128;
  return id(record.targetEventId) && id(record.threadId) &&
    ["requested", "stopped", "completed", "withdrawn", "unconfirmed"].includes(record.status) &&
    [record.sessionKey, record.runId, record.partialText].every((value) => value === undefined || typeof value === "string") &&
    (record.preDispatch === undefined || typeof record.preDispatch === "boolean") &&
    Array.isArray(record.requestIds) && record.requestIds.every(id);
}
export class StopStore {
  /** Includes immediate requested reservations; terminal status only follows durable proof. */
  readonly records = new Map<string, StopRecord>();
  private readonly committed = new Map<string, StopRecord>();
  private readonly pendingWrites = new Map<string, Promise<void>>();
  private readonly generations = new Map<string, number>();
  private tail: Promise<void> = Promise.resolve();
  private writes = 0;
  private failed = false;
  private closed = false;
  private readonly release: () => void;
  get available(): boolean { return !this.failed && !this.closed; }
  constructor(private readonly dir: string) {
    const path = join(dir, "stopped-turns.jsonl");
    if (existsSync(path) && (!statSync(path).isFile() || statSync(path).size > 64 * 1024 * 1024))
      throw new Error("Invalid stopped-turn journal");
    let text = existsSync(path) ? readFileSync(path, "utf8") : "";
    if (text && !text.endsWith("\n")) text = text.slice(0, text.lastIndexOf("\n") + 1);
    const lines = text ? text.trimEnd().split("\n") : [];
    if (lines.length > 65_536 || lines.some((line) => Buffer.byteLength(line) + 1 > 1024 * 1024))
      throw new Error("Invalid stopped-turn journal");
    for (const line of lines) {
      const entry: unknown = JSON.parse(line);
      if (!valid(entry)) throw new Error("Invalid stopped-turn journal");
      if (this.records.has(entry.targetEventId) && this.records.get(entry.targetEventId)?.threadId !== entry.threadId)
        throw new Error("Conflicting stopped-turn journal");
      this.records.set(entry.targetEventId, entry); this.committed.set(entry.targetEventId, entry);
    }
    this.release = retainSharedSyncHost(dir);
  }
  confirmed(id: string): StopRecord | undefined { return this.committed.get(id); }
  pending(id: string): Promise<void> | undefined { return this.pendingWrites.get(id); }
  async reconcileNativeFallback(threadId: string, targetEventId: string, expectedTurn: unknown): Promise<Record<string, unknown>> {
    const expected = structuredClone(expectedTurn);
    if (!this.available) throw new Error("Stop remains unconfirmed");
    let pending: Promise<void> | undefined;
    while ((pending = this.pendingWrites.get(targetEventId))) await pending;
    if (!this.available) throw new Error("Stop remains unconfirmed");
    const prior = this.committed.get(targetEventId);
    if (!prior || prior.threadId !== threadId) throw new Error("Stop owner remains unconfirmed");
    // No await between Root mutation and adoption: older target saves have all settled.
    const proof = syncHostResult(this.dir, { op: "run_turn_stop_fallback", threadId, eventId: targetEventId,
      expectedTurn: expected ?? null, ts: Date.now() });
    const record = proof.record;
    if (!valid(record) || record.targetEventId !== targetEventId || record.threadId !== threadId ||
        !prior.requestIds.every((id) => record.requestIds.includes(id)) ||
        ["stopped", "completed", "withdrawn"].includes(prior.status) && record.status !== prior.status)
      throw new Error("Stop remains unconfirmed");
    const confirmed = structuredClone(record);
    this.committed.set(targetEventId, confirmed);
    this.records.set(targetEventId, confirmed);
    if (proof.stopConfirmed !== true) this.failed = true;
    return proof;
  }
  async reconcileNativeResult(packet: Record<string, unknown>): Promise<Record<string, unknown>> {
    const captured = structuredClone(packet);
    const threadId = captured.threadId, targetEventId = captured.eventId;
    if (typeof threadId !== "string" || typeof targetEventId !== "string" || !this.available)
      throw new Error("Native result remains unconfirmed");
    let pending: Promise<void> | undefined;
    while ((pending = this.pendingWrites.get(targetEventId))) await pending;
    if (!this.available) throw new Error("Native result remains unconfirmed");
    const prior = this.committed.get(targetEventId);
    // No await between Root mutation and adoption of both mirrors.
    const proof = syncHostResult(this.dir, { ...captured, op: "run_attempt_result" });
    const record = proof.record;
    if (record === null && !prior && proof.stopConfirmed === true) return proof;
    if (!valid(record) || record.targetEventId !== targetEventId || record.threadId !== threadId ||
        prior && (!prior.requestIds.every((id) => record.requestIds.includes(id)) ||
          ["stopped", "completed", "withdrawn"].includes(prior.status) && record.status !== prior.status))
      throw new Error("Native result remains unconfirmed");
    const confirmed = structuredClone(record);
    this.committed.set(targetEventId, confirmed); this.records.set(targetEventId, confirmed);
    if (proof.stopConfirmed !== true) this.failed = true;
    return proof;
  }
  save(record: StopRecord): Promise<void> {
    if (!this.available || !valid(record) || this.writes >= 32) return Promise.reject(new Error("Stop remains unconfirmed"));
    const previous = this.records.get(record.targetEventId);
    if (previous && previous.threadId !== record.threadId) return Promise.reject(new Error("Conflicting Stop owner"));
    const snapshot = structuredClone(record);
    snapshot.requestIds = [...new Set([...(previous?.requestIds ?? []), ...snapshot.requestIds])];
    const generation = (this.generations.get(snapshot.targetEventId) ?? 0) + 1;
    this.generations.set(snapshot.targetEventId, generation);
    this.records.set(snapshot.targetEventId, { ...snapshot, status: previous?.status ?? "requested" });
    this.writes++;
    const promise = this.tail.catch(() => {}).then(async () => {
      if (this.failed) throw new Error("Stop remains unconfirmed");
      const result = await hostRequest(this.dir, { op: "stop_save", record: snapshot }) as { record?: unknown };
      if (!valid(result?.record) || result.record.targetEventId !== snapshot.targetEventId ||
          result.record.threadId !== snapshot.threadId || result.record.status !== snapshot.status)
        throw new Error("Stop remains unconfirmed");
      this.committed.set(snapshot.targetEventId, result.record);
      if (this.generations.get(snapshot.targetEventId) === generation) this.records.set(snapshot.targetEventId, result.record);
      else this.records.set(snapshot.targetEventId, { ...this.records.get(snapshot.targetEventId)!, status: result.record.status });
    }).catch(() => { this.failed = true; throw new Error("Stop remains unconfirmed"); })
      .finally(() => { this.writes--; if (this.pendingWrites.get(snapshot.targetEventId) === promise) this.pendingWrites.delete(snapshot.targetEventId); });
    this.tail = promise; this.pendingWrites.set(snapshot.targetEventId, promise);
    return promise;
  }
  async close(): Promise<void> {
    if (this.closed) return; this.closed = true;
    await this.tail.catch(() => {}); await this.release();
  }
}

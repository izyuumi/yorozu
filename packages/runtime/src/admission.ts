/** Read-only legacy snapshot plus the Rust-authoritative expired-operation writer. */
import { existsSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { hostRequest, retainHostWorker } from "./rust-host.js";
export type ExpiredAdmission = { id: string; threadId: string; identity: string; deadline: number };
function valid(entry: unknown): entry is ExpiredAdmission {
  if (!entry || typeof entry !== "object") return false;
  const record = entry as ExpiredAdmission;
  return [record.id, record.threadId].every((id) => typeof id === "string" && id.length > 0 && id.length <= 128)
    && typeof record.identity === "string" && /^[a-f0-9]{64}$/.test(record.identity)
    && Number.isSafeInteger(record.deadline);
}
function same(a: ExpiredAdmission, b: ExpiredAdmission): boolean {
  return a.id === b.id && a.threadId === b.threadId && a.identity === b.identity && a.deadline === b.deadline;
}
export class ExpiredAdmissions {
  readonly records: Map<string, ExpiredAdmission>;
  private readonly pending = new Map<string, { entry: ExpiredAdmission; promise: Promise<"expired" | "rejected"> }>();
  private readonly release: () => Promise<void>;
  private closed = false;
  private failed = false;
  constructor(private readonly dir: string) {
    const path = join(dir, "expired-admissions.jsonl");
    if (existsSync(path) && (!statSync(path).isFile() || statSync(path).size > 64 * 1024 * 1024))
      throw new Error("Invalid expired admission journal");
    let text = existsSync(path) ? readFileSync(path, "utf8") : "";
    // Do not mutate interrupted tails. Rust retains a recovery copy before the next append.
    if (text && !text.endsWith("\n")) text = text.slice(0, text.lastIndexOf("\n") + 1);
    const lines = text ? text.trimEnd().split("\n") : [];
    if (lines.length > 65_536 || lines.some((line) => Buffer.byteLength(line) + 1 > 1024 * 1024))
      throw new Error("Invalid expired admission journal");
    const entries: unknown[] = lines.map((line) => JSON.parse(line));
    if (!entries.every(valid)) throw new Error("Invalid expired admission journal");
    this.records = new Map(entries.map((entry) => [entry.id, entry]));
    if (this.records.size !== entries.length) throw new Error("Duplicate expired admission ID");
    this.release = retainHostWorker(dir);
  }
  /** Hold this identity while persistence is pending, including a changed-deadline retry. */
  pendingDisposition(id: string, threadId: string, identity: string): Promise<"expired" | "rejected"> | undefined {
    if (this.failed) return Promise.reject(new Error("Admission store unavailable"));
    const pending = this.pending.get(id);
    if (!pending) return undefined;
    return pending.promise.then((status) => status === "expired" && pending.entry.threadId === threadId &&
      pending.entry.identity === identity ? "expired" : "rejected");
  }
  expire(entry: ExpiredAdmission, now: number): Promise<"expired" | "rejected"> {
    if (this.closed || this.failed || !valid(entry) || !Number.isSafeInteger(now)) return Promise.reject(new Error("Admission store unavailable"));
    const pending = this.pending.get(entry.id);
    if (pending) return same(pending.entry, entry) ? pending.promise : Promise.resolve("rejected");
    if (this.pending.size >= 32) return Promise.reject(new Error("Admission store busy"));
    const snapshot = { ...entry };
    const promise = hostRequest(this.dir, { op: "admission_expire", entry: snapshot, now }).then((result) => {
      const reply = result as { status?: unknown; reason?: unknown; error?: unknown };
      if (reply.status === "expired") { this.records.set(snapshot.id, snapshot); return "expired" as const; }
      if (reply.status === "rejected" && reply.reason === "conflicting-message-id") return "rejected" as const;
      if (reply.error !== "admission-not-expired") this.failed = true;
      throw new Error("Expired admission remains unconfirmed");
    }, () => {
      this.failed = true; throw new Error("Expired admission remains unconfirmed");
    }).finally(() => { if (this.pending.get(snapshot.id)?.promise === promise) this.pending.delete(snapshot.id); });
    this.pending.set(snapshot.id, { entry: snapshot, promise });
    return promise;
  }
  async close(): Promise<void> {
    if (this.closed) return; this.closed = true;
    await Promise.allSettled([...this.pending.values()].map((entry) => entry.promise));
    await this.release();
  }
}

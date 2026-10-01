/** Immutable Rust acceptance currency; thread logs remain recoverable compatibility projections. */
import type { YorozuEvent } from "@yorozu/shared";
import { hostRequest } from "./rust-host.js";
import { retainSharedSyncHost } from "./rust-sync.js";
export type AcceptedMessage = Extract<YorozuEvent, { kind: "message" }>;
export type AcceptedSummary = { id: string; threadId: string; identity: string; purpose: "conversation" | "approval-reply" | "legacy" };
export type AcceptedEntry = AcceptedSummary & { event: AcceptedMessage; approvalActionId?: string };
function validSummary(value: unknown): value is AcceptedSummary {
  if (!value || typeof value !== "object") return false;
  const row = value as AcceptedSummary;
  return [row.id, row.threadId].every((id) => typeof id === "string" && !!id && id.length <= 128)
    && typeof row.identity === "string" && /^[a-f0-9]{64}$/.test(row.identity)
    && ["conversation", "approval-reply", "legacy"].includes(row.purpose);
}
function validEntry(value: unknown): value is AcceptedEntry {
  const row = value as AcceptedEntry;
  return validSummary(value) && !!row.event && row.event.kind === "message" && row.event.data.role === "user"
    && row.event.id === row.id && row.event.threadId === row.threadId && typeof row.event.data.text === "string";
}
export class AcceptedMessages {
  readonly records = new Map<string, AcceptedSummary>();
  readonly pending = new Map<string, { entry: AcceptedEntry; promise: Promise<AcceptedEntry> }>();
  private failed = false;
  private closed = false;
  private initialized = false;
  private readonly release: () => void;
  get available(): boolean { return this.initialized && !this.failed && !this.closed; }
  constructor(private readonly dir: string) { this.release = retainSharedSyncHost(dir); }
  async initialize(legacy: Iterable<AcceptedEntry>, restore: (entry: AcceptedEntry) => void): Promise<void> {
    try {
      let after: string | undefined;
      do {
        const result = await hostRequest(this.dir, { op: "accepted_snapshot", ...(after ? { after } : {}) }) as { entries?: unknown; next?: unknown };
        if (!Array.isArray(result?.entries) || result.entries.length > 256 || !result.entries.every(validSummary) ||
            result.next != null && (typeof result.next !== "string" || result.next !== result.entries.at(-1)?.id ||
              result.next === after)) throw new Error("Accepted history remains unconfirmed");
        for (const entry of result.entries) {
          if (this.records.size >= 65_536 || this.records.has(entry.id)) throw new Error("Accepted history remains unconfirmed");
          this.records.set(entry.id, entry);
        }
        after = typeof result.next === "string" ? result.next : undefined;
      } while (after !== undefined);
      for (const entry of legacy) {
        const existing = this.records.get(entry.id);
        if (existing && (existing.identity !== entry.identity || existing.threadId !== entry.threadId))
          throw new Error("Conflicting accepted history");
        if (!existing) await this.persist(entry);
      }
      // Fetch one body at a time; snapshot responses never collect attachment payloads.
      for (const entry of this.records.values()) {
        const result = await hostRequest(this.dir, { op: "accepted_get", messageId: entry.id }) as { entry?: unknown };
        if (!validEntry(result?.entry) || result.entry.identity !== entry.identity || result.entry.threadId !== entry.threadId)
          throw new Error("Accepted history remains unconfirmed");
        restore(result.entry);
      }
      this.initialized = true;
    } catch { this.failed = true; throw new Error("Accepted history remains unconfirmed"); }
  }
  private async persist(entry: AcceptedEntry): Promise<AcceptedEntry> {
    const result = await hostRequest(this.dir, { op: "accepted_accept", entry }) as { status?: unknown; entry?: unknown; reason?: unknown };
    if (result.status === "rejected" && result.reason === "conflicting-message-id") throw new Error("Conflicting message ID");
    if (result.status !== "accepted" || !validEntry(result.entry) || result.entry.identity !== entry.identity ||
        result.entry.threadId !== entry.threadId || result.entry.id !== entry.id) throw new Error("Accepted history remains unconfirmed");
    const { event: _, ...summary } = result.entry; this.records.set(entry.id, summary);
    return result.entry;
  }
  accept(entry: AcceptedEntry): Promise<AcceptedEntry> {
    if (!this.available || !validEntry(entry)) return Promise.reject(new Error("Accepted history remains unconfirmed"));
    const prior = this.pending.get(entry.id);
    if (prior) return prior.entry.identity === entry.identity && prior.entry.threadId === entry.threadId
      ? prior.promise : Promise.reject(new Error("Conflicting message ID"));
    const existing = this.records.get(entry.id);
    if (existing && (existing.identity !== entry.identity || existing.threadId !== entry.threadId))
      return Promise.reject(new Error("Conflicting message ID"));
    if (this.pending.size >= 32) return Promise.reject(new Error("Accepted history remains unconfirmed"));
    const snapshot = structuredClone(entry);
    const promise = this.persist(snapshot).catch((error: unknown) => {
      if (!(error instanceof Error && error.message === "Conflicting message ID")) this.failed = true;
      throw error;
    }).finally(() => { if (this.pending.get(entry.id)?.promise === promise) this.pending.delete(entry.id); });
    this.pending.set(entry.id, { entry: snapshot, promise }); return promise;
  }
  async close(): Promise<void> {
    if (this.closed) return; this.closed = true;
    await Promise.allSettled([...this.pending.values()].map((entry) => entry.promise)); await this.release();
  }
}

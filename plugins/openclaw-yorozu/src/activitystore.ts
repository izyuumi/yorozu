import { randomUUID } from "node:crypto";
import { mkdir, open, readFile, rename, unlink } from "node:fs/promises";
import path from "node:path";

import { cleanJobs, ENDED_LIMIT, LIMIT, validEnded, validJob, validTurns, type WireJob } from "./liveactivity.js";

export type ActivityRecord = { device: string; activityId: string; requestedAtMs: number; token?: string; kLast: number; terminal: boolean; bindings?: Record<string, string>; rows?: WireJob[]; sent?: WireJob[]; ended?: string[]; replied?: string[] };
// Structural SDK signature keeps standalone modules free of runtime SDK imports.
type FileLock = (file: string, options: { stale: number; retries: { retries: number; factor: number; minTimeout: number; maxTimeout: number }; staleRecovery: "remove-if-definitely-stale" }) => Promise<{ release(): Promise<void> }>;
export type ActivityStorage = Pick<ActivityStore, "acquire" | "release" | "load" | "save" | "lockReason">;
type LoadResult = { ok: true; records: ActivityRecord[] } | { ok: false; reason: string };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PUSH_TOKEN = /^(?:[0-9a-f]{2}){1,512}$/i;
const code = (error: unknown): string => (error as NodeJS.ErrnoException)?.code ?? "UNKNOWN";
const validRecord = (value: unknown): value is ActivityRecord => {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
  const row = value as Record<string, unknown>;
  return Object.keys(row).every((key) => ["device", "activityId", "requestedAtMs", "token", "kLast", "terminal", "bindings", "rows", "sent", "ended", "replied"].includes(key)) &&
    typeof row.device === "string" && row.device.length > 0 &&
    typeof row.activityId === "string" && row.activityId.length === 36 && UUID.test(row.activityId) &&
    (row.token === undefined || (typeof row.token === "string" && PUSH_TOKEN.test(row.token))) &&
    typeof row.requestedAtMs === "number" && Number.isSafeInteger(row.requestedAtMs) && row.requestedAtMs >= 1e11 &&
    typeof row.kLast === "number" && Number.isSafeInteger(row.kLast) && row.kLast >= Math.ceil(row.requestedAtMs / 1000) &&
    typeof row.terminal === "boolean" && (row.terminal
      ? Object.keys(row).length === 5 && !Object.hasOwn(row, "token")
      : (row.ended === undefined || validEnded(row.ended)) &&
        (row.replied === undefined || (validEnded(row.replied) && row.replied.length <= LIMIT && row.replied.every((token) => Object.hasOwn(row.bindings ?? {}, token)))) &&
        validTurns(row.bindings) && [row.rows, row.sent].every((jobs) => Array.isArray(jobs) && jobs.length <= LIMIT && jobs.every(validJob)) &&
        new Set([...((row.ended as string[] | undefined) ?? []), ...(row.rows as WireJob[]).filter((job) => job.kind === "turn").map((job) => job.token)]).size <= ENDED_LIMIT);
};
export class ActivityStore {
  private handle?: Awaited<ReturnType<FileLock>>;
  private writable = false;
  lockReason?: string;
  private file: string;
  private lock: FileLock;

  constructor(file: string, lock: FileLock) { this.file = file; this.lock = lock; }

  async acquire(): Promise<boolean> {
    if (this.handle) return true;
    await mkdir(path.dirname(this.file), { recursive: true, mode: 0o700 });
    try {
      this.handle = await this.lock(this.file, { stale: 30_000,
        retries: { retries: 0, factor: 1, minTimeout: 10, maxTimeout: 10 },
        staleRecovery: "remove-if-definitely-stale" });
      this.lockReason = undefined;
      return true;
    } catch (error) {
      if (code(error) !== "file_lock_timeout" && code(error) !== "file_lock_stale") throw error;
      try {
        const owner = JSON.parse(await readFile(`${this.file}.lock`, "utf8"));
        if (!owner || !Number.isSafeInteger(owner.pid) || owner.pid <= 0) throw new Error("invalid owner");
        // The SDK has already refused recovery; no PID probing or sidecar mutation here.
        this.lockReason = owner.starttime == null
          ? "Live Activity lock owner start time unknown; failing closed"
          : `another live host holds the Live Activity state (pid ${owner.pid})`;
      } catch { this.lockReason = "Live Activity lock file unreadable (left in place)"; }
      this.lockReason += ` (${code(error)})`;
      return false;
    }
  }

  async release(): Promise<void> {
    const handle = this.handle;
    this.handle = undefined;
    this.writable = false;
    await handle?.release();
  }

  async load(): Promise<LoadResult> {
    this.writable = false;
    let bytes: string;
    try { bytes = await readFile(this.file, "utf8"); } catch (error) {
      if (code(error) === "ENOENT") { this.writable = true; return { ok: true, records: [] }; }
      return { ok: false, reason: `Live Activity state could not be read (${code(error)})` };
    }
    try {
      const data = JSON.parse(bytes);
      // Older formats lack the durable generation; refuse rather than overwrite them.
      if (!data || Array.isArray(data) || data.v !== 3 || Object.keys(data).length !== 2 ||
        !Array.isArray(data.records) || !data.records.every(validRecord) ||
        new Set(data.records.map((row: ActivityRecord) => row.device)).size !== data.records.length) {
        return { ok: false, reason: "Invalid Live Activity records (EINVAL)" };
      }
      this.writable = true;
      return { ok: true, records: data.records.map((record: ActivityRecord) => record.terminal ? record : ({ ...record, rows: cleanJobs(record.rows!), sent: cleanJobs(record.sent!) })) };
    } catch { return { ok: false, reason: "Invalid Live Activity JSON (EINVAL)" }; }
  }

  async save(records: ActivityRecord[]): Promise<void> {
    if (!this.handle || !this.writable) {
      throw Object.assign(new Error("Live Activity state unavailable"), { code: "ESTATE" });
    }
    if (!records.every(validRecord) || new Set(records.map((row) => row.device)).size !== records.length) throw new Error("Invalid Live Activity records");
    const temp = `${this.file}.${randomUUID()}.tmp`;
    try {
      const file = await open(temp, "wx", 0o600);
      try {
        await file.writeFile(JSON.stringify({ v: 3, records: records.map((record) => record.terminal ? record : ({ ...record, rows: cleanJobs(record.rows!), sent: cleanJobs(record.sent!) })) }));
        await file.sync();
      } finally { await file.close(); }
      await rename(temp, this.file);
      const dir = await open(path.dirname(this.file), "r");
      try { await dir.sync(); } finally { await dir.close(); }
    } finally { await unlink(temp).catch(() => {}); }
  }
}

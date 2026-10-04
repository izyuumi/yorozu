import { createHash, randomUUID } from "node:crypto";
import fs from "node:fs";
import { join } from "node:path";
import { safeAgentPath } from "./agent-scope.js";
import { retainSharedSyncHost, syncHostRequest } from "./rust-sync.js";

export type SiwcControlJournalReason = "unsupported" | "invalid" | "identity" | "permission" | "conflict"
  | "unknown" | "signed-out" | "local-sign-in-required" | "busy";
export interface SiwcControlJournalResult {
  operationId: string;
  status: "pending" | "completed" | "rejected" | "unknown";
  attemptId?: string;
  reason?: string;
}
export interface SiwcControlJournalServices { retainWriter?(root: string): () => void }
interface Operation { identity: string; result: SiwcControlJournalResult }
interface Journal { version: 1; operations: Record<string, Operation>; lastResult?: SiwcControlJournalResult }
const MAX_OPERATIONS = 2048, MAX_BYTES = 2 * 1024 * 1024, MAX_QUEUED = 32;
const owned = new Set<string>();
const reasons = new Set<SiwcControlJournalReason>(["unsupported", "invalid", "identity", "permission", "conflict",
  "unknown", "signed-out", "local-sign-in-required", "busy"]);
const digest = (value: string): string => createHash("sha256").update(value).digest("hex");
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value);
const opaqueId = (value: unknown): value is string => typeof value === "string" && /^[A-Za-z0-9_.:-]{1,128}$/.test(value) && !/[\r\n]/.test(value);
const attemptId = (value: unknown): value is string => typeof value === "string" && value.length === 64 && /^[a-f0-9]{64}$/.test(value);
function normalized(command: Readonly<Record<string, unknown>>): Record<string, unknown> {
  if (!object(command) || ![Object.prototype, null].includes(Object.getPrototypeOf(command)) || Object.getOwnPropertySymbols(command).length)
    throw new Error("Invalid SIWC account control");
  const descriptors = Object.getOwnPropertyDescriptors(command);
  if (Object.values(descriptors).some(d => d.get || d.set)) throw new Error("Invalid SIWC account control");
  const values = Object.fromEntries(Object.entries(descriptors).map(([key, d]) => [key, d.value]));
  if (values.version !== 1 || typeof values.method !== "string") throw new Error("Invalid SIWC account control");
  let keys: string[];
  switch (values.method) {
    case "sign-in":
      keys = ["version", "method", "bindingId", "returning"];
      if (!opaqueId(values.bindingId) || typeof values.returning !== "boolean") throw new Error("Invalid SIWC account control");
      break;
    case "cancel": keys = ["version", "method", "attemptId"]; if (!attemptId(values.attemptId)) throw new Error("Invalid SIWC account control"); break;
    case "verify-pending": case "select": case "sign-out":
      keys = ["version", "method", "bindingId"]; if (!opaqueId(values.bindingId)) throw new Error("Invalid SIWC account control"); break;
    case "status": keys = ["version", "method"]; break;
    default: throw new Error("Invalid SIWC account control");
  }
  if (Object.keys(values).length !== keys.length || keys.some(k => !Object.hasOwn(values, k))) throw new Error("Invalid SIWC account control");
  // Copy only validated scalar fields; never serialize the caller's arbitrary object.
  return Object.fromEntries(keys.sort().map(key => [key, values[key]]));
}
function safeResult(value: unknown, id?: string, stored = false): SiwcControlJournalResult {
  if (!object(value) || Object.keys(value).some(k => !["operationId", "status", "attemptId", "reason"].includes(k))
    || !opaqueId(value.operationId) || id !== undefined && value.operationId !== id
    || !["pending", "completed", "rejected", "unknown"].includes(value.status as string)
    || value.attemptId !== undefined && !attemptId(value.attemptId)
    || value.reason !== undefined && typeof value.reason !== "string"
    || stored && value.reason !== undefined && !reasons.has(value.reason as SiwcControlJournalReason)) throw new Error("Invalid SIWC account receipt");
  const status = value.status as SiwcControlJournalResult["status"];
  return { operationId: value.operationId, status,
    ...(value.attemptId !== undefined ? { attemptId: value.attemptId as string } : {}),
    ...(value.reason !== undefined && reasons.has(value.reason as SiwcControlJournalReason) ? { reason: value.reason as string }
      : status === "rejected" || status === "unknown" ? { reason: "unknown" } : {}) };
}
function validate(value: unknown): Journal {
  if (!object(value) || Object.keys(value).some(k => !["version", "operations", "lastResult"].includes(k))
    || value.version !== 1 || !object(value.operations) || Object.keys(value.operations).length > MAX_OPERATIONS)
    throw new Error("Damaged SIWC account control journal");
  for (const [key, raw] of Object.entries(value.operations)) {
    if (key.length !== 64 || !/^[a-f0-9]{64}$/.test(key) || !object(raw) || Object.keys(raw).length !== 2
      || typeof raw.identity !== "string" || raw.identity.length !== 64 || !/^[a-f0-9]{64}$/.test(raw.identity) || !Object.hasOwn(raw, "result"))
      throw new Error("Damaged SIWC account operation");
    const result = safeResult(raw.result, undefined, true);
    if (digest(result.operationId) !== key) throw new Error("Conflicting SIWC account receipt");
  }
  if (value.lastResult !== undefined) {
    const result = safeResult(value.lastResult, undefined, true);
    const entry = value.operations[digest(result.operationId)] as Operation | undefined;
    if (!entry || JSON.stringify(safeResult(entry.result, undefined, true)) !== JSON.stringify(result))
      throw new Error("Conflicting SIWC last account receipt");
  }
  return value as unknown as Journal;
}

/** Host validates command type and native sender before calling. Durable unknown
 * admission precedes dispatch; an operation can never be automatically replayed. */
export class SiwcControlJournal {
  readonly root: string;
  private readonly file: string;
  private readonly journal: Journal;
  private readonly releaseWriter: () => void;
  private readonly assertWriter: () => void;
  private queue: Promise<unknown> = Promise.resolve();
  private queued = 0;
  private closed = false;
  private released = false;
  private broken = false;
  private observedResult?: SiwcControlJournalResult;
  constructor(dir: string, services: SiwcControlJournalServices = {}) {
    this.root = safeAgentPath(join(dir, "siwc-account-controls-v1")); fs.mkdirSync(this.root, { recursive: true, mode: 0o700 });
    this.file = join(this.root, "operations.json"); this.assertRoot();
    if (owned.has(this.root)) throw new Error("SIWC account controls already owned");
    owned.add(this.root); let release: (() => void) | undefined;
    try {
      const leaseRoot = safeAgentPath(join(this.root, "lease"));
      release = (services.retainWriter ?? retainSharedSyncHost)(leaseRoot);
      if (typeof release !== "function") throw new Error("SIWC account writer is unavailable");
      this.releaseWriter = release;
      if (services.retainWriter) this.assertWriter = () => {};
      else {
        const pid = syncHostRequest(leaseRoot, { op: "bridge_pid" }).pid;
        if (!Number.isSafeInteger(pid) || (pid as number) < 1) throw new Error("SIWC account writer identity is unconfirmed");
        this.assertWriter = () => {
          process.kill(pid as number, 0);
          if (syncHostRequest(leaseRoot, { op: "bridge_pid" }).pid !== pid) throw new Error("SIWC account writer changed ownership");
          process.kill(pid as number, 0);
        };
      }
      this.journal = this.read();
      for (const entry of Object.values(this.journal.operations)) if (entry.result.status === "pending") {
        entry.result = { operationId: entry.result.operationId, status: "unknown", reason: "unknown" };
        if (this.journal.lastResult?.operationId === entry.result.operationId) this.journal.lastResult = entry.result;
      }
      this.save();
      this.observedResult = this.journal.lastResult;
    } catch { try { release?.(); } finally { owned.delete(this.root); } throw new Error("SIWC account journal is unavailable"); }
  }
  private assertRoot(): void {
    safeAgentPath(this.root, true);
    const root = fs.lstatSync(this.root);
    if (!root.isDirectory() || root.uid !== process.getuid?.() || (root.mode & 0o7777) !== 0o700) throw new Error("Invalid SIWC account control root");
    safeAgentPath(this.file);
  }
  private read(): Journal {
    this.assertRoot(); let fd: number;
    try { fd = fs.openSync(this.file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return { version: 1, operations: {} }; throw error; }
    try {
      const stat = fs.fstatSync(fd);
      if (!stat.isFile() || stat.nlink !== 1 || stat.uid !== process.getuid?.() || (stat.mode & 0o7777) !== 0o600 || stat.size > MAX_BYTES)
        throw new Error("Invalid SIWC account control file");
      const bytes = Buffer.alloc(MAX_BYTES + 1); let length = 0;
      while (length < bytes.length) {
        const read = fs.readSync(fd, bytes, length, bytes.length - length, null);
        if (!read) break; length += read;
      }
      if (length > MAX_BYTES) throw new Error("Invalid SIWC account control file");
      return validate(JSON.parse(bytes.subarray(0, length).toString("utf8")));
    } finally { fs.closeSync(fd); }
  }
  private save(): void {
    this.assertWriter(); this.assertRoot(); const encoded = JSON.stringify(this.journal) + "\n";
    if (Buffer.byteLength(encoded) > MAX_BYTES) throw new Error("SIWC account control budget exceeded");
    const temporary = join(this.root, `.pending-${randomUUID()}`);
    const fd = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try {
      try { fs.writeFileSync(fd, encoded); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
      this.assertWriter(); this.assertRoot(); fs.renameSync(temporary, this.file);
      const parent = fs.openSync(this.root, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      try { fs.fsyncSync(parent); } finally { fs.closeSync(parent); }
    } finally { try { fs.unlinkSync(temporary); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; } }
  }
  get lastResult(): SiwcControlJournalResult | undefined { return this.observedResult ? structuredClone(this.observedResult) : undefined; }
  private remember(result: SiwcControlJournalResult): SiwcControlJournalResult {
    this.observedResult = result; return structuredClone(result);
  }
  execute(id: string, command: Readonly<Record<string, unknown>>, dispatch: () => Promise<SiwcControlJournalResult>): Promise<SiwcControlJournalResult> {
    if (!opaqueId(id)) return Promise.reject(new Error("Invalid SIWC account operation identity"));
    let identity: string;
    try { identity = digest(JSON.stringify(normalized(command))); }
    catch { return Promise.resolve({ operationId: id, status: "rejected", reason: "invalid" }); }
    if (this.closed) return Promise.resolve({ operationId: id, status: "rejected", reason: "unsupported" });
    const prior = this.journal.operations[digest(id)];
    if (prior) return Promise.resolve(this.remember(prior.identity === identity ? prior.result
      : { operationId: id, status: "rejected", reason: "conflict" }));
    if (this.queued >= MAX_QUEUED) return Promise.resolve({ operationId: id, status: "rejected", reason: "conflict" });
    this.queued++;
    const pending = this.queue.then(() => this.admit(id, identity, dispatch)).finally(() => { this.queued--; });
    this.queue = pending.catch(() => {}); return pending;
  }
  private async admit(id: string, identity: string, dispatch: () => Promise<SiwcControlJournalResult>): Promise<SiwcControlJournalResult> {
    if (this.closed) return { operationId: id, status: "rejected", reason: "unsupported" };
    const key = digest(id), prior = this.journal.operations[key];
    if (prior) return this.remember(prior.identity === identity ? prior.result : { operationId: id, status: "rejected", reason: "conflict" });
    if (this.broken) return this.remember({ operationId: id, status: "unknown", reason: "unknown" });
    if (Object.keys(this.journal.operations).length >= MAX_OPERATIONS)
      return this.remember({ operationId: id, status: "rejected", reason: "conflict" });
    const entry: Operation = { identity, result: { operationId: id, status: "unknown", reason: "unknown" } };
    this.journal.operations[key] = entry; this.journal.lastResult = entry.result;
    this.observedResult = entry.result;
    try { this.save(); this.assertWriter(); } catch { return this.uncertain(entry); }
    try { entry.result = safeResult(await dispatch(), id); }
    catch { entry.result = { operationId: id, status: "unknown", reason: "unknown" }; }
    this.journal.lastResult = entry.result;
    try { this.save(); } catch { return this.uncertain(entry); }
    return this.remember(entry.result);
  }
  private uncertain(entry: Operation): SiwcControlJournalResult {
    this.broken = true;
    entry.result = { operationId: entry.result.operationId, status: "unknown", reason: "unknown" };
    this.journal.lastResult = entry.result; return this.remember(entry.result);
  }
  close(): void {
    if (this.closed) return; this.closed = true;
    const release = (): void => {
      if (this.released) return; this.released = true;
      try { this.releaseWriter(); } finally { owned.delete(this.root); }
    };
    if (!this.queued) release();
    else void this.queue.then(release).catch(() => { /* No cleanup descriptions or secrets are published. */ });
  }
}

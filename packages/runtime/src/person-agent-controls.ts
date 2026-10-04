import { createHash, randomUUID } from "node:crypto";
import fs from "node:fs";
import { join } from "node:path";
import { parsePersonAgentControl, parsePersonAgentRegistry, type PersonAgentControlData,
  type PersonAgentControlResult, type PersonAgentRegistry } from "@yorozu/shared";
import { PersonAgentStore } from "./agent-store.js";
import { safeAgentPath } from "./agent-scope.js";
import type { PersonAgentRuntime } from "./person-agent-runtime.js";
import { retainSharedSyncHost, syncHostRequest } from "./rust-sync.js";

export type PersonAgentControlRuntime = Pick<PersonAgentRuntime, "store" | "configure">;
export interface PersonAgentControlServices {
  /** Mandatory synchronous host gate. Production binds PersonAgentRuntime.assertControlsIdle. */
  assertIdle(): void;
  /** Publish registry readback only. These controls never enter conversation history. */
  changed?(): void;
  /** Trusted test/host dependency injection; production defaults to the existing kernel writer lease. */
  retainWriter?(root: string): () => void;
}
interface Operation {
  identity: string;
  state: "pending" | "applied" | "rejected" | "unknown";
  result: PersonAgentControlResult;
}
interface Journal { version: 1; operations: Record<string, Operation>; lastControlResult?: PersonAgentControlResult }
const MAX_OPERATIONS = 2048, MAX_BYTES = 2 * 1024 * 1024, MAX_INPUT_BYTES = 1024 * 1024;
const MAX_QUEUED = 32;
const owned = new Set<string>();
const digest = (value: string): string => createHash("sha256").update(value).digest("hex");
const object = (value: unknown): value is Record<string, any> => !!value && typeof value === "object" && !Array.isArray(value);
const operationId = (value: unknown): value is string => typeof value === "string" && !!value.trim()
  && value.length <= 128 && !/[\0\r\n]/.test(value);
function stable(value: any): any {
  if (Array.isArray(value)) return value.map(stable);
  if (!object(value)) return value;
  return Object.fromEntries(Object.keys(value).sort().map(key => [key, stable(value[key])]));
}
function result(value: unknown): asserts value is PersonAgentControlResult {
  if (!object(value) || Object.keys(value).some(key => !["operationId", "status", "revision", "reason"].includes(key))
    || !operationId(value.operationId) || !["applied", "rejected", "unknown"].includes(value.status)
    || !Number.isSafeInteger(value.revision) || value.revision < 0
    || value.reason !== undefined && (typeof value.reason !== "string" || !value.reason.trim() || value.reason.length > 512 || /[\0\r\n]/.test(value.reason)))
    throw new Error("Damaged person-agent control receipt");
}
function validate(value: unknown): Journal {
  if (!object(value) || Object.keys(value).some(key => !["version", "operations", "lastControlResult"].includes(key))
    || value.version !== 1 || !object(value.operations) || Object.keys(value.operations).length > MAX_OPERATIONS)
    throw new Error("Damaged person-agent control journal");
  for (const [key, entry] of Object.entries(value.operations)) {
    if (!/^[a-f0-9]{64}$/.test(key) || !object(entry) || Object.keys(entry).some(k => !["identity", "state", "result"].includes(k))
      || typeof entry.identity !== "string" || !/^[a-f0-9]{64}$/.test(entry.identity)
      || !["pending", "applied", "rejected", "unknown"].includes(entry.state)) throw new Error("Damaged person-agent operation");
    result(entry.result);
    if (digest(entry.result.operationId) !== key || entry.result.status !== (entry.state === "pending" ? "unknown" : entry.state))
      throw new Error("Conflicting person-agent operation receipt");
  }
  if (value.lastControlResult !== undefined) result(value.lastControlResult);
  return value as unknown as Journal;
}
/** Trusted settings controls only. The host must enable this explicitly and never
 * route model/tool events here. Registry CAS, runtime idleness and the durable intent
 * journal precede mutations. Crash gaps remain unknown; no control is replayed.
 */
export class PersonAgentControls {
  readonly root: string;
  private readonly file: string;
  private readonly journal: Journal;
  private readonly releaseWriter: () => void;
  private readonly assertWriter: () => void;
  private queue: Promise<unknown> = Promise.resolve();
  private queued = 0;
  private closing?: Promise<void>;
  private closed = false;
  private broken = false;
  constructor(dir: string, readonly store: PersonAgentStore, readonly runtime: PersonAgentControlRuntime,
    private readonly services: PersonAgentControlServices) {
    if (runtime.store !== store || typeof runtime.configure !== "function" || typeof services.assertIdle !== "function")
      throw new Error("Person-agent controls require their owning runtime and idle gate");
    this.root = safeAgentPath(join(dir, "person-agent-controls-v1")); fs.mkdirSync(this.root, { recursive: true, mode: 0o700 });
    this.file = join(this.root, "operations.json"); this.assertRoot();
    if (owned.has(this.root)) throw new Error("Person-agent controls already owned");
    owned.add(this.root); let release: (() => void) | undefined;
    try {
      const leaseRoot = safeAgentPath(join(this.root, "lease"));
      release = (services.retainWriter ?? retainSharedSyncHost)(leaseRoot);
      if (typeof release !== "function") throw new Error("Person-agent control writer is unavailable");
      this.releaseWriter = release;
      if (services.retainWriter) this.assertWriter = () => {};
      else {
        const pid = syncHostRequest(leaseRoot, { op: "bridge_pid" }).pid;
        if (!Number.isSafeInteger(pid) || (pid as number) < 1) throw new Error("Person-agent control writer identity is unconfirmed");
        this.assertWriter = () => {
          // A replacement Rust child must not silently make an in-memory JS ledger
          // authoritative again. Restart recovery creates a new controls owner.
          process.kill(pid as number, 0);
          if (syncHostRequest(leaseRoot, { op: "bridge_pid" }).pid !== pid) throw new Error("Person-agent control writer changed ownership");
          process.kill(pid as number, 0);
        };
      }
      this.journal = this.read();
      const revision = this.store.list().revision;
      for (const entry of Object.values(this.journal.operations)) if (entry.state === "pending") {
        entry.state = "unknown"; entry.result = { operationId: entry.result.operationId, status: "unknown", revision,
          reason: "The previous control outcome is unconfirmed. It will not be replayed." };
        if (this.journal.lastControlResult?.operationId === entry.result.operationId) this.journal.lastControlResult = entry.result;
      }
      this.save();
    } catch (error) { try { release?.(); } finally { owned.delete(this.root); } throw error; }
  }
  private assertRoot(): void {
    safeAgentPath(this.root, true);
    if (!fs.lstatSync(this.root).isDirectory()) throw new Error("Invalid person-agent control root");
    safeAgentPath(this.file);
  }
  private read(): Journal {
    this.assertRoot(); let fd: number;
    try { fd = fs.openSync(this.file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK); }
    catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return { version: 1, operations: {} }; throw error; }
    try {
      const stat = fs.fstatSync(fd);
      if (!stat.isFile() || stat.nlink !== 1 || stat.size > MAX_BYTES) throw new Error("Invalid person-agent control file");
      return validate(JSON.parse(fs.readFileSync(fd, "utf8")));
    } finally { fs.closeSync(fd); }
  }
  private save(): void {
    this.assertWriter(); this.assertRoot(); const encoded = JSON.stringify(this.journal) + "\n";
    if (Buffer.byteLength(encoded) > MAX_BYTES) throw new Error("Person-agent control journal budget exceeded");
    const temporary = join(this.root, `.pending-${randomUUID()}`);
    const fd = fs.openSync(temporary, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try {
      try { fs.writeFileSync(fd, encoded); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
      this.assertWriter(); this.assertRoot(); fs.renameSync(temporary, this.file);
      const parent = fs.openSync(this.root, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
      try { fs.fsyncSync(parent); } finally { fs.closeSync(parent); }
    } finally { try { fs.unlinkSync(temporary); } catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; } }
  }
  private open(): void { if (this.closed) throw new Error("Person-agent controls are closed"); }
  get hasUnknownControls(): boolean { return this.broken || Object.values(this.journal.operations).some(entry => entry.state === "unknown" || entry.state === "pending"); }
  registry(): PersonAgentRegistry {
    this.open();
    return structuredClone(parsePersonAgentRegistry({ ...this.store.list(), journalRevision: this.store.journal().revision,
      ...(this.journal.lastControlResult ? { lastControlResult: this.journal.lastControlResult } : {}) }));
  }
  private publish(receipt: PersonAgentControlResult): PersonAgentRegistry {
    this.journal.lastControlResult = receipt;
    try { this.save(); } catch {
      this.broken = true;
      this.journal.lastControlResult = { operationId: receipt.operationId, status: "unknown", revision: this.store.list().revision,
        reason: "The durable control receipt is unconfirmed. It will not be replayed." };
      const entry = this.journal.operations[digest(receipt.operationId)];
      if (entry) { entry.state = "unknown"; entry.result = this.journal.lastControlResult; }
    }
    try { this.services.changed?.(); } catch { /* Readback remains available; delivery cannot replay a mutation. */ }
    return this.registry();
  }
  control(id: string, value: unknown): Promise<PersonAgentRegistry> {
    this.open(); if (!operationId(id)) return Promise.reject(new Error("Invalid person-agent operation identity"));
    if (this.queued >= MAX_QUEUED) return Promise.reject(new Error("Person-agent control queue is full; no mutation was admitted"));
    // Snapshot before queuing: a caller cannot change the already identified action.
    let copied: unknown, identity: string;
    try {
      const encoded = JSON.stringify(value);
      if (encoded === undefined || Buffer.byteLength(encoded) > MAX_INPUT_BYTES) throw new Error("Person-agent control input exceeded its limit");
      copied = JSON.parse(encoded); identity = digest(JSON.stringify(stable(copied)));
    } catch { return Promise.reject(new Error("Invalid person-agent control input")); }
    this.queued++;
    const pending = this.queue.then(() => this.execute(id, copied, identity)).finally(() => { this.queued--; });
    this.queue = pending.catch(() => {}); return pending;
  }
  private async execute(id: string, value: unknown, identity: string): Promise<PersonAgentRegistry> {
    this.open(); const key = digest(id), prior = this.journal.operations[key];
    if (prior) {
      if (prior.identity !== identity) return this.publish({ operationId: id, status: "rejected", revision: this.store.list().revision, reason: "This operation identity already belongs to another control." });
      return this.publish(prior.result);
    }
    if (this.broken) throw new Error("Person-agent control ledger is unavailable; no mutation was admitted");
    const before = { registry: this.store.list().revision, journal: this.store.journal().revision };
    const reject = (reason: string): PersonAgentRegistry => {
      const receipt: PersonAgentControlResult = { operationId: id, status: "rejected", revision: before.registry, reason };
      if (Object.keys(this.journal.operations).length < MAX_OPERATIONS) this.journal.operations[key] = { identity, state: "rejected", result: receipt };
      return this.publish(receipt);
    };
    if (Object.keys(this.journal.operations).length >= MAX_OPERATIONS) return reject("The control operation budget is full; no mutation was admitted.");
    if (this.closing) return reject("Settings controls are closing; no mutation was admitted.");
    if (this.hasUnknownControls) return reject("Settings are held by an earlier unconfirmed control; this mutation was not submitted.");
    let input: PersonAgentControlData;
    try {
      input = parsePersonAgentControl(value);
      if (input.expectedRevision !== before.registry) throw new Error("Agent revision conflict");
      if ((input.action === "remember" || input.action === "share-knowledge") && input.expectedJournalRevision !== before.journal)
        throw new Error("Knowledge revision conflict");
      if (this.services.assertIdle() !== undefined) throw new Error("The idle gate did not settle synchronously");
    } catch (error) {
      const reason = error instanceof Error ? error.message.replace(/[\0\r\n]/g, " ").trim().slice(0, 512) : "Settings control was rejected before mutation.";
      return reject(reason || "Settings control was rejected before mutation.");
    }
    const entry: Operation = { identity, state: "pending", result: { operationId: id, status: "unknown", revision: before.registry,
      reason: "The control outcome has not yet been confirmed." } };
    this.journal.operations[key] = entry; this.journal.lastControlResult = entry.result;
    try { this.save(); this.assertWriter(); } catch { this.broken = true; return this.registry(); } // Never mutate without durable intent and its owner.
    let failed = false;
    try {
      switch (input.action) {
        case "create": this.store.create(input.agent, input.expectedRevision); break;
        case "update": await this.runtime.configure(input.agentId, input.patch, input.expectedRevision); break;
        case "default": this.store.default(input.agentId, input.expectedRevision); break;
        case "create-team": this.store.createTeam(input.team, input.expectedRevision); break;
        case "update-team": this.store.updateTeam(input.teamId, input.patch, input.expectedRevision); break;
        case "remember": this.store.remember(input.preference, input.expectedJournalRevision); break;
        case "share-knowledge": this.store.shareKnowledge(input.knowledge, input.expectedJournalRevision); break;
      }
      const current = { registry: this.store.list().revision, journal: this.store.journal().revision };
      const knowledge = input.action === "remember" || input.action === "share-knowledge";
      if (current.registry !== before.registry + (knowledge ? 0 : 1) || current.journal !== before.journal + (knowledge ? 1 : 0))
        throw new Error("Settings mutation readback is unconfirmed");
      entry.state = "applied"; entry.result = { operationId: id, status: "applied", revision: current.registry };
    } catch { failed = true; }
    if (failed) {
      let unchanged = false, revision = before.registry;
      try { revision = this.store.list().revision; unchanged = revision === before.registry && this.store.journal().revision === before.journal; } catch { /* Cannot prove refusal. */ }
      entry.state = unchanged ? "rejected" : "unknown";
      entry.result = { operationId: id, status: entry.state, revision, reason: unchanged
        ? "Settings control was rejected without a registry or journal mutation."
        : "Settings may have changed but the outcome is unconfirmed. This control will not be replayed." };
    }
    return this.publish(entry.result);
  }
  close(): Promise<void> {
    return this.closing ??= (async () => { await this.queue; this.closed = true; try { this.releaseWriter(); } finally { owned.delete(this.root); } })();
  }
}

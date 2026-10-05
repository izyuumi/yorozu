/** Durable delivery intent closes the provider-receipt / host-history crash window. */
import { createHash, randomUUID } from "node:crypto";
import { closeSync, existsSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, readdirSync, renameSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export type SteerReceipt = "sending" | "received" | "declined" | "unconfirmed" | "storage-error";
type Record = { version: 1; eventId: string; fingerprint: string; receipt: SteerReceipt };
const receipts = new Set<SteerReceipt>(["sending", "received", "declined", "unconfirmed"]);
const pathFor = (dir: string, id: string): string => join(dir, "secretary-steering-v1", `${createHash("sha256").update(id).digest("hex")}.json`);

function read(dir: string, eventId: string): Record | undefined {
  const root = join(dir, "secretary-steering-v1");
  if (existsSync(root) && (!lstatSync(root).isDirectory() || lstatSync(root).isSymbolicLink())) throw new Error("Invalid steer journal directory");
  const path = pathFor(dir, eventId);
  if (!existsSync(path)) return;
  if (!lstatSync(path).isFile() || lstatSync(path).isSymbolicLink()) throw new Error("Invalid steer journal");
  const record = JSON.parse(readFileSync(path, "utf8")) as Record;
  if (record.version !== 1 || record.eventId !== eventId || typeof record.fingerprint !== "string" || !receipts.has(record.receipt))
    throw new Error("Invalid steer journal");
  return record;
}

/** Any retained attempt, even a refusal, is consumed. A new request needs a new ID. */
export function secretarySteerReceipt(dir: string, eventId: string): SteerReceipt | undefined {
  try { return read(dir, eventId)?.receipt; }
  catch { return "storage-error"; }
}

export async function deliverSecretarySteer(dir: string, eventId: string, request: unknown,
  deliver: () => Promise<boolean>): Promise<SteerReceipt> {
  const fingerprint = createHash("sha256").update(JSON.stringify(request)).digest("hex");
  const previous = read(dir, eventId);
  if (previous) {
    if (previous.fingerprint !== fingerprint) throw new Error("Conflicting steer delivery");
    return previous.receipt === "sending" ? "unconfirmed" : previous.receipt;
  }
  const root = join(dir, "secretary-steering-v1");
  mkdirSync(root, { recursive: true, mode: 0o700 });
  if (!lstatSync(root).isDirectory() || lstatSync(root).isSymbolicLink()) throw new Error("Invalid steer journal directory");
  const record: Record = { version: 1, eventId, fingerprint, receipt: "sending" };
  const persist = (first: boolean): void => {
    const path = pathFor(dir, eventId);
    const temporary = first ? path : `${path}.${randomUUID()}.tmp`;
    // Exclusive creation also refuses duplicate delivery from another live owner.
    writeFileSync(temporary, JSON.stringify(record), { mode: 0o600, flag: "wx", flush: true });
    if (!first) renameSync(temporary, path);
    const fd = openSync(root, "r");
    try { fsyncSync(fd); } finally { closeSync(fd); }
  };
  persist(true);
  try { record.receipt = await deliver() ? "received" : "declined"; }
  catch { record.receipt = "unconfirmed"; }
  persist(false);
  return record.receipt;
}

/** Durable pre-execution intent, independent of the fallible stop journal.
 * A surviving marker is uncertainty, never permission to infer/replay absence. */
export class SecretaryAdmissionFence {
  readonly root: string;
  private failed = false;
  private readonly inherited: boolean;
  constructor(dir: string) {
    this.root = join(dir, "secretary-admission-v1");
    mkdirSync(this.root, { recursive: true, mode: 0o700 });
    if (!lstatSync(this.root).isDirectory() || lstatSync(this.root).isSymbolicLink()) throw new Error("Invalid secretary admission directory");
    const parent = openSync(dir, "r"); try { fsyncSync(parent); } finally { closeSync(parent); }
    this.inherited = readdirSync(this.root).length !== 0;
  }
  get blocked(): boolean { return this.failed || this.inherited; }
  fail(): void { this.failed = true; }
  private path(id: string): string { return join(this.root, createHash("sha256").update(id).digest("hex") + ".intent"); }
  begin(id: string, kind: "execution" | "journal" = "execution"): void {
    if (this.blocked && kind === "execution") throw new Error("Secretary admission is held by unconfirmed durable intent");
    let fd: number | undefined;
    try {
      fd = openSync(this.path(id), "wx", 0o600);
      writeFileSync(fd, JSON.stringify({ version: 1, id }) + "\n"); fsyncSync(fd);
      const directory = openSync(this.root, "r"); try { fsyncSync(directory); } finally { closeSync(directory); }
    } catch (error) { this.fail(); throw error; } finally { if (fd !== undefined) closeSync(fd); }
  }
  /** Only positive execution cessation or successful journal persistence consumes its matching intent. */
  confirmed(id: string): void {
    try {
      unlinkSync(this.path(id));
      const directory = openSync(this.root, "r"); try { fsyncSync(directory); } finally { closeSync(directory); }
    } catch (error) { this.fail(); throw error; }
  }
}

/** Positive host-queue custody, not an inference from missing provider history.
 * A durable dispatching transition is mandatory BEFORE entering any runner.
 * Old/missing/corrupt receipts never establish non-submission. */
export class SecretaryQueueLedger {
  private readonly root: string;
  constructor(dir: string) { this.root = join(dir, "secretary-steering-v1"); }
  private path(threadId: string, eventId: string): string {
    return join(this.root, `queue-${createHash("sha256").update(JSON.stringify([threadId, eventId])).digest("hex")}.json`);
  }
  private read(threadId: string, eventId: string): "queued" | "dispatching" | "not-submitted" | "ceased" | undefined {
    try {
      if (!lstatSync(this.root).isDirectory() || lstatSync(this.root).isSymbolicLink()) return;
      const path = this.path(threadId, eventId), stat = lstatSync(path);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 4096) return;
      const value = JSON.parse(readFileSync(path, "utf8"));
      if (value.version === 1 && value.threadId === threadId && value.eventId === eventId &&
          ["queued", "dispatching", "not-submitted", "ceased"].includes(value.phase)) return value.phase;
    } catch { /* Unknown remains held, never permission to infer absence. */ }
  }
  private persist(threadId: string, eventId: string, phase: "queued" | "dispatching" | "not-submitted" | "ceased", first = false): void {
    mkdirSync(this.root, { recursive: true, mode: 0o700 });
    if (!lstatSync(this.root).isDirectory() || lstatSync(this.root).isSymbolicLink()) throw new Error("Invalid queue custody directory");
    const path = this.path(threadId, eventId), temporary = first ? path : `${path}.${randomUUID()}.tmp`;
    writeFileSync(temporary, JSON.stringify({ version: 1, threadId, eventId, phase }), { mode: 0o600, flag: "wx", flush: true });
    if (!first) renameSync(temporary, path);
    for (const directory of [this.root, join(this.root, "..")]) {
      const fd = openSync(directory, "r"); try { fsyncSync(fd); } finally { closeSync(fd); }
    }
  }
  admit(threadId: string, eventId: string): void { this.persist(threadId, eventId, "queued", true); }
  dispatch(threadId: string, eventId: string): void {
    if (this.read(threadId, eventId) !== "queued") throw new Error("Queue dispatch custody is unconfirmed");
    this.persist(threadId, eventId, "dispatching");
  }
  settled(threadId: string, eventId: string, notSubmitted: boolean): void {
    if (this.read(threadId, eventId) !== "dispatching") throw new Error("Queue completion custody is unconfirmed");
    this.persist(threadId, eventId, notSubmitted ? "not-submitted" : "ceased");
  }
  reconcile(threadId: string, eventId: string): "not-submitted" | "ceased" | undefined {
    const phase = this.read(threadId, eventId);
    if (phase === "not-submitted" || phase === "ceased") return phase;
    if (phase !== "queued") return;
    this.persist(threadId, eventId, "not-submitted");
    return "not-submitted";
  }
}

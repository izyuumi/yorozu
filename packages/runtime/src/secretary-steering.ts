/** Durable delivery intent closes the provider-receipt / host-history crash window. */
import { createHash, randomUUID } from "node:crypto";
import { closeSync, existsSync, fsyncSync, lstatSync, mkdirSync, openSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { join } from "node:path";

export type SteerReceipt = "sending" | "received" | "declined" | "unconfirmed";
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
  catch { return "unconfirmed"; }
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

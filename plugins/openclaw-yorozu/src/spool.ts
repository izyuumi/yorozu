import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import fs from "node:fs/promises";
import path from "node:path";

// Upload chunks on disk: `<id>.part` holds the bytes at `index * chunkBytes`, `<id>.json` the chunks it holds.
// Imports only node built-ins so `node --test` runs it without OpenClaw.

export type Range = [number, number];
export type SpoolMeta = {
  id: string;
  name: string;
  mime: string;
  size: number;
  count: number;
  sha256?: string;
  have: Range[];
  createdAt: number;
  touchedAt: number;
};
type Head = Pick<SpoolMeta, "id" | "name" | "mime" | "size" | "count" | "sha256">;

export type SpoolOptions = { dir: string; chunkBytes: number; ttlMs?: number; maxEntries?: number; now?: () => number };

const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const SHA = /^[0-9a-f]{64}$/;
const SWEEP_MS = 60_000;

export const isSha256 = (v: unknown): v is string => typeof v === "string" && SHA.test(v);

export function addRange(have: Range[], index: number): Range[] {
  const out: Range[] = [];
  let [start, end] = [index, index + 1];
  for (const [s, e] of have) {
    if (e < start || s > end) out.push([s, e]);
    else [start, end] = [Math.min(s, start), Math.max(e, end)];
  }
  out.push([start, end]);
  return out.sort((a, b) => a[0] - b[0]);
}

export const covers = (have: Range[], count: number): boolean =>
  have.length === 1 && have[0]![0] === 0 && have[0]![1] >= count;

const ranges = (v: unknown): v is Range[] =>
  Array.isArray(v) &&
  v.every((r) => Array.isArray(r) && r.length === 2 && r.every(Number.isSafeInteger) && r[0] >= 0 && r[0] < r[1]);

export class Spool {
  readonly dir: string;
  readonly chunkBytes: number;
  readonly ttlMs: number;
  readonly maxEntries: number;
  readonly now: () => number;
  private chains = new Map<string, Promise<unknown>>();
  private made?: Promise<unknown>;
  private sweptAt = -Infinity;
  private grew = false;

  constructor({ dir, chunkBytes, ttlMs = 24 * 60 * 60 * 1000, maxEntries = 8, now = Date.now }: SpoolOptions) {
    this.dir = dir;
    this.chunkBytes = chunkBytes;
    this.ttlMs = ttlMs;
    this.maxEntries = maxEntries;
    this.now = now;
  }

  // Runs `fn` after every earlier `run` for the same id. The other methods expect to be called inside it.
  run<T>(id: string, fn: () => Promise<T>): Promise<T> {
    const result = (this.chains.get(id) ?? Promise.resolve()).then(fn, fn);
    const tail = result.catch(() => undefined);
    this.chains.set(id, tail);
    void tail.then(() => {
      if (this.chains.get(id) === tail) this.chains.delete(id);
    });
    return result;
  }

  partPath(id: string): string {
    return this.file(id, ".part");
  }

  async read(id: string): Promise<SpoolMeta | undefined> {
    try {
      const meta = JSON.parse(await fs.readFile(this.file(id, ".json"), "utf8")) as SpoolMeta;
      const ok =
        meta.id === id && Number.isSafeInteger(meta.size) && Number.isSafeInteger(meta.count) && ranges(meta.have) &&
        Number.isFinite(meta.touchedAt) && (meta.sha256 === undefined || isSha256(meta.sha256));
      return ok ? meta : undefined;
    } catch (error) {
      if (!ID.test(id)) throw error;
      return undefined;
    }
  }

  // The chunks held for an upload of this shape; a spool of another shape is dropped.
  async status(id: string, want: { size: number; count: number; sha256?: string }): Promise<Range[]> {
    const meta = await this.read(id);
    if (!meta) return [];
    if (meta.size === want.size && meta.count === want.count && meta.sha256 === want.sha256) return meta.have;
    await this.drop(id);
    return [];
  }

  // Writes one chunk; `null` when the spool held another upload under this id (it is dropped).
  async put(head: Head, index: number, bytes: Buffer): Promise<SpoolMeta | null> {
    const part = this.partPath(head.id);
    await this.ready();
    let meta = await this.read(head.id);
    if (meta && (meta.size !== head.size || meta.count !== head.count || (meta.sha256 && head.sha256 && meta.sha256 !== head.sha256))) {
      await this.drop(head.id);
      return null;
    }
    const now = this.now();
    if (!meta) {
      await fs.rm(part, { force: true });
      meta = { ...head, have: [], createdAt: now, touchedAt: now };
      this.grew = true;
    }
    const file = await fs.open(part, fs.constants.O_RDWR | fs.constants.O_CREAT, 0o600);
    try {
      await file.write(bytes, 0, bytes.length, index * this.chunkBytes);
      await file.sync();
    } finally {
      await file.close();
    }
    meta = { ...meta, sha256: meta.sha256 ?? head.sha256, have: addRange(meta.have, index), touchedAt: now };
    await this.save(meta);
    return meta;
  }

  async digest(id: string, size: number): Promise<string> {
    const hash = createHash("sha256");
    if (size > 0) for await (const bytes of createReadStream(this.partPath(id), { start: 0, end: size - 1 })) hash.update(bytes);
    return hash.digest("hex");
  }

  async drop(id: string): Promise<void> {
    await Promise.all([".part", ".json", ".json.tmp"].map((ext) => fs.rm(this.file(id, ext), { force: true })));
  }

  // Drops entries idle past the TTL and files without a ledger; call outside `run`.
  async sweep(): Promise<void> {
    this.sweptAt = this.now();
    for (const id of await this.ids()) {
      await this.run(id, async () => {
        const meta = await this.read(id);
        if (!meta || this.now() - meta.touchedAt > this.ttlMs) await this.drop(id);
        else await fs.rm(this.file(id, ".json.tmp"), { force: true });
      });
    }
    await this.trim();
  }

  // Housekeeping after an upload event; call outside `run`.
  async tidy(): Promise<void> {
    if (this.now() - this.sweptAt >= SWEEP_MS) return this.sweep();
    if (this.grew) await this.trim();
  }

  private async trim(): Promise<void> {
    this.grew = false;
    const metas = (await Promise.all((await this.ids()).map((id) => this.read(id)))).filter((m): m is SpoolMeta => !!m);
    metas.sort((a, b) => a.touchedAt - b.touchedAt);
    for (const meta of metas.slice(0, Math.max(0, metas.length - this.maxEntries))) {
      await this.run(meta.id, () => this.drop(meta.id));
    }
  }

  private async ids(): Promise<string[]> {
    await this.ready();
    const names = await fs.readdir(this.dir);
    return [...new Set(names.map((n) => n.slice(0, 36)).filter((id) => ID.test(id)))];
  }

  private async save(meta: SpoolMeta): Promise<void> {
    const tmp = this.file(meta.id, ".json.tmp");
    const file = await fs.open(tmp, "w", 0o600);
    try {
      await file.writeFile(JSON.stringify(meta));
      await file.sync();
    } finally {
      await file.close();
    }
    await fs.rename(tmp, this.file(meta.id, ".json"));
  }

  private ready(): Promise<unknown> {
    this.made ??= fs.mkdir(this.dir, { recursive: true, mode: 0o700 }).catch((error: unknown) => {
      this.made = undefined;
      throw error;
    });
    return this.made;
  }

  private file(id: string, ext: string): string {
    if (!ID.test(id)) throw new Error("attachment id must be a lowercase UUID");
    return path.join(this.dir, id + ext);
  }
}

// The upload side of the wire, around a spool. The plugin supplies OpenClaw's media store; tests, a temp dir.

export type UploadChunk = {
  attachmentId: string;
  name: string;
  mime: string;
  size: number;
  index: number;
  count: number;
  data: string;
  sha256?: string;
};
export type UploadQuery = { attachmentId: string; size: number; count: number; sha256: string };
export type Answer =
  | { kind: "upload_ack"; data: { attachmentId: string; index: number; done: boolean } }
  | { kind: "upload_state"; data: { attachmentId: string; done: boolean; have: Range[] } }
  | { kind: "error"; data: { code: string; message: string; attachmentId?: string } };
export type Receiver = {
  spool: Spool;
  maxBytes: number;
  isStored: (id: string) => Promise<boolean>;
  store: (file: { meta: SpoolMeta; path: string }) => Promise<void>;
};

const MB = 1024 * 1024;
const megabytes = (bytes: number) => `${Math.round((bytes / MB) * 10) / 10} MB`;
const refuse = (code: string, message: string, attachmentId?: string): Answer[] => [
  { kind: "error", data: { code, message, ...(attachmentId && ID.test(attachmentId) ? { attachmentId } : {}) } },
];

function shape(r: Receiver, q: { attachmentId: string; size: number; count: number; name?: string }): Answer[] | null {
  if (!ID.test(q.attachmentId)) return refuse("bad_request", "attachment id must be a lowercase UUID");
  if (q.size > r.maxBytes) {
    return refuse("too_large", `${q.name ?? "the file"} is ${megabytes(q.size)}; the limit is ${megabytes(r.maxBytes)}`, q.attachmentId);
  }
  if (q.count !== Math.max(1, Math.ceil(q.size / r.spool.chunkBytes))) {
    return refuse("bad_request", "chunk count does not match the size", q.attachmentId);
  }
  return null;
}

export async function receiveChunk(r: Receiver, upload: UploadChunk): Promise<Answer[]> {
  const { attachmentId, index, count, size } = upload;
  const wrong = shape(r, upload);
  if (wrong) {
    if (ID.test(attachmentId)) await r.spool.run(attachmentId, () => r.spool.drop(attachmentId));
    return wrong;
  }
  const ack = (done: boolean): Answer[] => [{ kind: "upload_ack", data: { attachmentId, index, done } }];
  const answers = await r.spool.run(attachmentId, async (): Promise<Answer[]> => {
    if (await r.isStored(attachmentId)) return ack(true);
    const { spool } = r;
    const bytes = Buffer.from(upload.data, "base64");
    const expected = index === count - 1 ? size - index * spool.chunkBytes : spool.chunkBytes;
    if (bytes.length !== expected) {
      await spool.drop(attachmentId);
      return refuse("bad_request", `chunk ${index} has ${bytes.length} bytes, not ${expected}`, attachmentId);
    }
    const head = { id: attachmentId, name: path.basename(upload.name), mime: upload.mime, size, count, sha256: upload.sha256 };
    const meta = await spool.put(head, index, bytes);
    if (!meta) return refuse("bad_request", "chunk does not match the upload it continues", attachmentId);
    if (!covers(meta.have, count)) return ack(false);
    const digest = await spool.digest(attachmentId, size);
    if (meta.sha256 && digest !== meta.sha256) {
      await spool.drop(attachmentId);
      return refuse("hash_mismatch", `${meta.name} arrived with a different SHA-256; send it again`, attachmentId);
    }
    try {
      await r.store({ meta, path: spool.partPath(attachmentId) });
    } catch (error) {
      return refuse("internal", `could not store ${meta.name}: ${String(error).slice(0, 200)}`, attachmentId);
    }
    await spool.drop(attachmentId);
    return ack(true);
  });
  await r.spool.tidy();
  return answers;
}

export async function receiveStatus(r: Receiver, query: UploadQuery): Promise<Answer[]> {
  const { attachmentId } = query;
  const wrong = shape(r, query);
  if (wrong) return wrong;
  const answers = await r.spool.run(attachmentId, async (): Promise<Answer[]> => {
    const state = (done: boolean, have: Range[]): Answer[] => [{ kind: "upload_state", data: { attachmentId, done, have } }];
    if (await r.isStored(attachmentId)) return state(true, []);
    return state(false, await r.spool.status(attachmentId, query));
  });
  await r.spool.tidy();
  return answers;
}

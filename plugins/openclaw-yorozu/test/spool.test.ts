import assert from "node:assert/strict";
import { createHash, randomBytes, randomUUID } from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { receiveChunk, receiveStatus, Spool, type Answer, type Receiver, type Range } from "../src/spool.ts";

const CHUNK = 1024;

async function setup(opts: { now?: () => number; maxEntries?: number } = {}) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "yorozu-spool-"));
  const dir = path.join(root, "spool");
  const stored = new Map<string, Buffer>();
  const make = (): Receiver => ({
    spool: new Spool({ dir, chunkBytes: CHUNK, ...opts }),
    maxBytes: 64 * CHUNK,
    isStored: async (id) => stored.has(id),
    store: async ({ meta, path: file }) => void stored.set(meta.id, await fs.readFile(file)),
  });
  return { root, dir, stored, make };
}

const file = (size: number) => {
  const bytes = randomBytes(size);
  return { id: randomUUID(), bytes, size, count: Math.max(1, Math.ceil(size / CHUNK)), sha256: createHash("sha256").update(bytes).digest("hex") };
};
type File = ReturnType<typeof file>;

const chunk = (f: File, index: number, sha = true) => ({
  attachmentId: f.id,
  name: "file.bin",
  mime: "application/octet-stream",
  size: f.size,
  index,
  count: f.count,
  data: f.bytes.subarray(index * CHUNK, (index + 1) * CHUNK).toString("base64"),
  ...(sha ? { sha256: f.sha256 } : {}),
});

const have = async (r: Receiver, f: File): Promise<Range[]> => {
  const [answer] = await receiveStatus(r, { attachmentId: f.id, size: f.size, count: f.count, sha256: f.sha256 });
  assert.equal(answer?.kind, "upload_state");
  return (answer as Extract<Answer, { kind: "upload_state" }>).data.have;
};

const missing = (ranges: Range[], count: number) =>
  [...Array(count).keys()].filter((i) => !ranges.some(([s, e]) => i >= s && i < e));

async function send(r: Receiver, f: File, indices: number[]): Promise<Answer[]> {
  const answers: Answer[] = [];
  for (const i of indices) answers.push(...(await receiveChunk(r, chunk(f, i))));
  return answers;
}

for (const fraction of [0.5, 0.99]) {
  test(`resume after a loss at ${fraction * 100}% sends only the missing chunks`, async () => {
    const { make, stored } = await setup();
    const r = make();
    const f = file(64 * CHUNK - 7);
    const cut = Math.floor(f.count * fraction);
    await send(r, f, [...Array(cut).keys()]);
    const rest = missing(await have(r, f), f.count);
    assert.equal(rest.length, f.count - cut);
    const answers = await send(r, f, rest);
    assert.deepEqual(answers.at(-1), { kind: "upload_ack", data: { attachmentId: f.id, index: f.count - 1, done: true } });
    assert.ok(stored.get(f.id)?.equals(f.bytes));
    assert.deepEqual(await receiveStatus(r, { attachmentId: f.id, size: f.size, count: f.count, sha256: f.sha256 }), [
      { kind: "upload_state", data: { attachmentId: f.id, done: true, have: [] } },
    ]);
  });
}

test("a new Spool on the same dir keeps the received chunks", async () => {
  const { make, stored } = await setup();
  const f = file(10 * CHUNK);
  await send(make(), f, [0, 1, 2, 5, 6]);
  const r = make();
  assert.deepEqual(await have(r, f), [[0, 3], [5, 7]]);
  await send(r, f, missing(await have(r, f), f.count));
  assert.ok(stored.get(f.id)?.equals(f.bytes));
});

test("a hash mismatch drops the spool, then a re-upload from zero succeeds", async () => {
  const { make, stored, dir } = await setup();
  const r = make();
  const f = file(4 * CHUNK);
  const bad = { ...f, sha256: "0".repeat(64) };
  const answers = await send(r, bad, [0, 1, 2, 3]);
  assert.equal(answers.at(-1)?.kind, "error");
  assert.equal((answers.at(-1) as Extract<Answer, { kind: "error" }>).data.code, "hash_mismatch");
  assert.deepEqual(await fs.readdir(dir), []);
  assert.deepEqual(await have(r, f), []);
  await send(r, f, [0, 1, 2, 3]);
  assert.ok(stored.get(f.id)?.equals(f.bytes));
});

test("TTL cleanup with an injected clock", async () => {
  let now = 1_000_000;
  const { make, dir } = await setup({ now: () => now });
  const r = make();
  const old = file(3 * CHUNK);
  await send(r, old, [0]);
  now += 60 * 60 * 1000;
  const fresh = file(3 * CHUNK);
  await send(r, fresh, [0]);
  await fs.writeFile(path.join(dir, `${randomUUID()}.part`), "stray");
  await fs.writeFile(path.join(dir, `${fresh.id}.json.tmp`), "stray");
  now += 24 * 60 * 60 * 1000 - 1;
  await r.spool.sweep();
  assert.deepEqual((await fs.readdir(dir)).sort(), [`${fresh.id}.json`, `${fresh.id}.part`]);
  now += 2;
  await r.spool.sweep();
  assert.deepEqual(await fs.readdir(dir), []);
});

test("over maxEntries the least recently touched is evicted", async () => {
  let now = 0;
  const { make } = await setup({ now: () => now, maxEntries: 2 });
  const r = make();
  const [a, b, c] = [file(3 * CHUNK), file(3 * CHUNK), file(3 * CHUNK)];
  await send(r, a, [0]);
  now += 1;
  await send(r, b, [0]);
  now += 1;
  await send(r, a, [1]);
  now += 1;
  await send(r, c, [0]);
  assert.deepEqual(await have(r, b), []);
  assert.deepEqual(await have(r, a), [[0, 2]]);
  assert.deepEqual(await have(r, c), [[0, 1]]);
});

test("concurrent writes to one id", async () => {
  const { make, stored } = await setup();
  const r = make();
  const f = file(32 * CHUNK + 1);
  const order = [...Array(f.count).keys()].sort(() => Math.random() - 0.5);
  const answers = (await Promise.all([...order, ...order.slice(0, 5)].map((i) => receiveChunk(r, chunk(f, i))))).flat();
  assert.ok(answers.every((a) => a.kind === "upload_ack"));
  assert.equal(answers.filter((a) => a.kind === "upload_ack" && a.data.done).length, 6);
  assert.ok(stored.get(f.id)?.equals(f.bytes));
});

test("a client without resume: no sha256, any order, repeats are idempotent", async () => {
  const { make, stored } = await setup();
  const r = make();
  const f = file(5 * CHUNK);
  for (const i of [4, 2, 2, 0, 1, 0]) await receiveChunk(r, chunk(f, i, false));
  const [last] = await receiveChunk(r, chunk(f, 3, false));
  assert.deepEqual(last, { kind: "upload_ack", data: { attachmentId: f.id, index: 3, done: true } });
  assert.ok(stored.get(f.id)?.equals(f.bytes));
});

test("a non-UUID id is refused", async () => {
  const { make, root } = await setup();
  const r = make();
  const f = { ...file(CHUNK), id: "../../escape" };
  const [answer] = await receiveChunk(r, chunk(f, 0));
  assert.equal(answer?.kind, "error");
  assert.equal((answer as Extract<Answer, { kind: "error" }>).data.code, "bad_request");
  await assert.rejects(r.spool.put({ id: "ABC", name: "x", mime: "x", size: 1, count: 1 }, 0, Buffer.alloc(1)));
  await assert.rejects(r.spool.read("../x"));
  assert.deepEqual(await fs.readdir(root), []);
});

test("an upload_status with a different size or sha256 drops the old spool", async () => {
  const { make, dir } = await setup();
  const r = make();
  const f = file(6 * CHUNK);
  await send(r, f, [0, 1, 2]);
  assert.deepEqual(await have(r, { ...f, sha256: "a".repeat(64) }), []);
  assert.deepEqual(await fs.readdir(dir), []);
  await send(r, f, [0, 1, 2]);
  assert.deepEqual(await have(r, { ...f, size: f.size - 1 }), []);
  assert.deepEqual(await have(r, f), []);
});

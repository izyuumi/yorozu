import { createHash } from "node:crypto";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test, vi } from "vitest";
import { AttachmentUploads } from "./attachment-upload.js";
import { closeHostWorker } from "./rust-host.js";

const dirs: string[] = [];
afterEach(async () => {
  for (const dir of dirs.splice(0)) { await closeHostWorker(dir); rmSync(dir, { recursive: true, force: true }); }
  vi.unstubAllEnvs();
});

function setup() {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-upload-"));
  dirs.push(dir);
  return { dir, uploads: new AttachmentUploads(dir) };
}

test("interrupted upload resumes from fsynced offset and admits only complete matching bytes", async () => {
  const { dir, uploads } = setup();
  const bytes = Buffer.alloc(400_000, 42);
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  const deadline = Date.now() + 60_000;
  const base = { messageId: "message", index: 0, totalBytes: bytes.length, sha256, deadline };
  const first = { ...base, offset: 0, data: bytes.subarray(0, 256 * 1024).toString("base64") };
  expect(await uploads.chunk("phone-a", "thread", first)).toEqual({ nextOffset: 256 * 1024 });
  expect(await uploads.assemble("phone-a", "message", "thread",
    [{ name: "photo.jpg", mime: "image/jpeg", bytes: bytes.length, sha256 }], deadline))
    .toEqual({ missing: { index: 0, nextOffset: 256 * 1024 } });
  await uploads.close();
  const restarted = new AttachmentUploads(dir);
  expect(await restarted.chunk("phone-a", "thread", first)).toEqual({ nextOffset: 256 * 1024 });
  expect(await restarted.chunk("phone-a", "thread", { ...base, offset: 256 * 1024,
    data: bytes.subarray(256 * 1024).toString("base64") })).toEqual({ nextOffset: bytes.length });
  expect(await restarted.assemble("phone-a", "message", "thread",
    [{ name: "photo.jpg", mime: "image/jpeg", bytes: bytes.length, sha256 }], deadline))
    .toEqual({ attachments: [{ name: "photo.jpg", mime: "image/jpeg", data: bytes.toString("base64") }] });
  expect(await restarted.assemble("phone-b", "message", "thread",
    [{ name: "photo.jpg", mime: "image/jpeg", bytes: bytes.length, sha256 }], deadline))
    .toEqual({ missing: { index: 0, nextOffset: 0 } });
});

test("conflicting retry cannot replace staged bytes or change upload identity", async () => {
  const { uploads } = setup();
  const bytes = Buffer.from("original");
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  const data = { messageId: "message", index: 0, offset: 0, totalBytes: bytes.length,
    sha256, deadline: Date.now() + 60_000, data: bytes.toString("base64") };
  expect(await uploads.chunk("phone", "thread", data)).toEqual({ nextOffset: bytes.length });
  expect((await uploads.chunk("phone", "thread", { ...data,
    data: Buffer.from("modified").toString("base64") })).reason).toBe("conflicting-attachment-upload");
  expect((await uploads.chunk("phone", "other-thread", data)).reason).toBe("conflicting-attachment-upload");
  expect((await uploads.assemble("phone", "message", "thread",
    [{ name: "file", mime: "text/plain", bytes: bytes.length, sha256 }], data.deadline)).attachments?.[0]?.data)
    .toBe(bytes.toString("base64"));
});

test("zero-byte files need no frame and invalid chunks cannot allocate oversized uploads", async () => {
  const { uploads } = setup();
  const emptyHash = createHash("sha256").digest("hex");
  const deadline = Date.now() + 60_000;
  expect(await uploads.assemble("phone", "message", "thread",
    [{ name: "empty.txt", mime: "text/plain", bytes: 0, sha256: emptyHash }], deadline))
    .toEqual({ attachments: [{ name: "empty.txt", mime: "text/plain", data: "" }] });
  expect((await uploads.chunk("phone", "thread", { messageId: "message", index: 0, offset: 0,
    totalBytes: 5 * 1024 * 1024 + 1, sha256: emptyHash, deadline, data: "" })).reason)
    .toBe("invalid-attachment-chunk");
});

test("concurrent facade instances share one writer and cannot duplicate bytes", async () => {
  const { dir, uploads } = setup();
  const second = new AttachmentUploads(dir);
  const bytes = Buffer.from("one durable file");
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  const deadline = Date.now() + 60_000;
  const data = { messageId: "same", index: 0, offset: 0, totalBytes: bytes.length, sha256, deadline, data: bytes.toString("base64") };
  const results = await Promise.all(Array.from({ length: 20 }, (_, index) =>
    (index % 2 ? uploads : second).chunk("phone", "thread", data)));
  expect(results.every(result => result.nextOffset === bytes.length && !result.reason)).toBe(true);
  await uploads.close();
  expect((await second.assemble("phone", "same", "thread", [{ name: "file.txt", mime: "text/plain", bytes: bytes.length, sha256 }], deadline)).attachments)
    .toEqual([{ name: "file.txt", mime: "text/plain", data: bytes.toString("base64") }]);
});

test("a missing worker stays unconfirmed and can recover using the same staged input", async () => {
  const { dir, uploads } = setup();
  const bytes = Buffer.from("preserve");
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  const data = { messageId: "message", index: 0, offset: 0, totalBytes: bytes.length, sha256,
    deadline: Date.now() + 60_000, data: bytes.toString("base64") };
  vi.stubEnv("YOROZU_HOST_CORE", join(dir, "missing-worker"));
  expect(await uploads.chunk("phone", "thread", data)).toEqual({ nextOffset: 0, reason: "attachment-storage-failed" });
  await uploads.close();
  vi.unstubAllEnvs();
  expect(await uploads.chunk("phone", "thread", data)).toEqual({ nextOffset: bytes.length });
});

test.runIf(process.platform !== "win32")("an uncorrelated worker frame cannot acknowledge or replace existing staged data", async () => {
  const { dir, uploads } = setup();
  const bytes = Buffer.from("preserve");
  const sha256 = createHash("sha256").update(bytes).digest("hex");
  const data = { messageId: "message", index: 0, offset: 0, totalBytes: bytes.length, sha256,
    deadline: Date.now() + 60_000, data: bytes.toString("base64") };
  expect(await uploads.chunk("phone", "thread", data)).toEqual({ nextOffset: bytes.length });
  await uploads.close();
  const broken = join(dir, "broken-worker");
  writeFileSync(broken, '#!/bin/sh\nprintf \'%s\\n\' \'{"id":"wrong-request","result":{"nextOffset":999999}}\'\n', { mode: 0o700 });
  vi.stubEnv("YOROZU_HOST_CORE", broken);
  expect(await uploads.chunk("phone", "thread", data)).toEqual({ nextOffset: 0, reason: "attachment-storage-failed" });
  await uploads.close();
  vi.unstubAllEnvs();
  expect((await uploads.assemble("phone", "message", "thread", [{ name: "file.txt", mime: "text/plain", bytes: bytes.length, sha256 }], data.deadline)).attachments)
    .toEqual([{ name: "file.txt", mime: "text/plain", data: bytes.toString("base64") }]);
});

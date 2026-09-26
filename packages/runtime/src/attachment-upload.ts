import { createHash, randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { link, mkdir, open, readFile, readdir, rm, stat, unlink, writeFile } from "node:fs/promises";
import { join } from "node:path";
import {
  ATTACHMENT_CHUNK_BYTES, ATTACHMENT_MAX_BYTES, MAX_ATTACHMENTS_PER_MESSAGE,
  MESSAGE_ATTACHMENTS_MAX_BYTES,
  type AttachmentChunkData, type AttachmentDescriptor, type MessageAttachment,
} from "@yorozu/shared";

type UploadMeta = { threadId: string; totalBytes: number; sha256: string; deadline: number };
const validHash = (value: unknown): value is string => typeof value === "string" && /^[0-9a-f]{64}$/.test(value);
const validId = (value: unknown): value is string => typeof value === "string" && value.length > 0 && value.length <= 128;
const MAX_STAGED_BYTES = 256 * 1024 * 1024;
const MAX_STAGED_UPLOADS = 128;

/** Staged bytes are private to the authenticated device and original message ID. */
export class AttachmentUploads {
  private readonly root: string;
  private readonly locks = new Map<string, Promise<void>>();
  private lastPrune = 0;

  constructor(dir: string) { this.root = join(dir, "attachment-uploads"); }

  private folder(source: string, messageId: string): string {
    return join(this.root, createHash("sha256").update(source).update("\0").update(messageId).digest("hex"));
  }

  private async prune(): Promise<void> {
    if (Date.now() - this.lastPrune < 10 * 60_000) return;
    this.lastPrune = Date.now();
    for (const name of await readdir(this.root).catch(() => [])) {
      const path = join(this.root, name);
      try {
        if (Date.now() - (await stat(path)).mtimeMs > 45 * 60_000) await rm(path, { recursive: true, force: true });
      } catch { /* Another request may have removed it. */ }
    }
  }

  private async declaredBytes(folder: string): Promise<number> {
    let total = 0;
    for (const name of (await readdir(folder)).filter((entry) => /^\d+\.json$/.test(entry))) {
      const item = JSON.parse(await readFile(join(folder, name), "utf8")) as UploadMeta;
      if (!Number.isSafeInteger(item.totalBytes) || item.totalBytes < 0) return Infinity;
      total += item.totalBytes;
    }
    return total;
  }

  private async stagedBytes(): Promise<number> {
    let total = 0;
    for (const name of await readdir(this.root)) {
      if (!/^[0-9a-f]{64}$/.test(name)) continue;
      total += await this.declaredBytes(join(this.root, name));
      if (total >= MAX_STAGED_BYTES) break;
    }
    return total;
  }

  async chunk(source: string, threadId: string, data: AttachmentChunkData): Promise<{ nextOffset: number; reason?: string }> {
    if (typeof data !== "object" || data === null) return { nextOffset: 0, reason: "invalid-attachment-chunk" };
    const { messageId, index, offset, totalBytes, sha256, deadline } = data;
    if (!validId(messageId) || !validId(threadId) || !Number.isSafeInteger(index) || index < 0 ||
        index >= MAX_ATTACHMENTS_PER_MESSAGE || !Number.isSafeInteger(offset) || offset < 0 ||
        !Number.isSafeInteger(totalBytes) || totalBytes <= 0 || totalBytes > ATTACHMENT_MAX_BYTES ||
        !Number.isSafeInteger(deadline) || deadline <= Date.now() || deadline > Date.now() + 35 * 60_000 ||
        !validHash(sha256) || typeof data.data !== "string" || data.data.length > ATTACHMENT_CHUNK_BYTES * 4 / 3 + 4) {
      return { nextOffset: 0, reason: "invalid-attachment-chunk" };
    }
    const bytes = Buffer.from(data.data, "base64");
    if (bytes.toString("base64") !== data.data || bytes.length > ATTACHMENT_CHUNK_BYTES ||
        bytes.length === 0 || offset + bytes.length > totalBytes) {
      return { nextOffset: 0, reason: "invalid-attachment-chunk" };
    }
    const folder = this.folder(source, messageId);
    // One lock covers quota reservation as well as writes, including independent devices.
    const key = "global";
    const previous = this.locks.get(key) ?? Promise.resolve();
    let release!: () => void;
    const gate = new Promise<void>((resolve) => { release = resolve; });
    const current = previous.then(() => gate);
    this.locks.set(key, current);
    await previous;
    try {
      await mkdir(this.root, { recursive: true, mode: 0o700 });
      await this.prune();
      const existingFolders = (await readdir(this.root)).filter((name) => /^[0-9a-f]{64}$/.test(name));
      if (!existingFolders.includes(folder.slice(this.root.length + 1)) && existingFolders.length >= MAX_STAGED_UPLOADS) {
        return { nextOffset: 0, reason: "attachment-storage-full" };
      }
      await mkdir(folder, { recursive: true, mode: 0o700 });
      const metaPath = join(folder, `${index}.json`);
      const meta: UploadMeta = { threadId, totalBytes, sha256, deadline };
      let existing = true;
      try { await stat(metaPath); }
      catch (error) {
        if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
        existing = false;
      }
      if (!existing) {
        if (await this.declaredBytes(folder) + totalBytes > MESSAGE_ATTACHMENTS_MAX_BYTES) {
          return { nextOffset: 0, reason: "oversized-attachments" };
        }
        if (await this.stagedBytes() + totalBytes > MAX_STAGED_BYTES) {
          return { nextOffset: 0, reason: "attachment-storage-full" };
        }
        const temp = join(folder, `${index}.${randomUUID()}.tmp`);
        try {
          await writeFile(temp, JSON.stringify(meta), { mode: 0o600, flush: true });
          // link is atomic and fails if an older committed metadata file already owns this slot.
          try { await link(temp, metaPath); }
          catch (error) { if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error; }
        } finally { await unlink(temp).catch(() => {}); }
      }
      const saved = JSON.parse(await readFile(metaPath, "utf8")) as UploadMeta;
      if (JSON.stringify(saved) !== JSON.stringify(meta)) return { nextOffset: 0, reason: "conflicting-attachment-upload" };
      const path = join(folder, `${index}.bin`);
      const file = await open(path, constants.O_CREAT | constants.O_RDWR, 0o600);
      try {
        const size = (await file.stat()).size;
        if (size > totalBytes) return { nextOffset: 0, reason: "conflicting-attachment-upload" };
        if (offset < size) {
          const prior = Buffer.alloc(Math.min(bytes.length, size - offset));
          let read = 0;
          while (read < prior.length) {
            const result = await file.read(prior, read, prior.length - read, offset + read);
            if (result.bytesRead <= 0) throw new Error("short attachment read");
            read += result.bytesRead;
          }
          if (!prior.equals(bytes.subarray(0, prior.length))) return { nextOffset: size, reason: "conflicting-attachment-upload" };
          return { nextOffset: size };
        }
        if (offset > size) return { nextOffset: size };
        let written = 0;
        while (written < bytes.length) {
          const result = await file.write(bytes, written, bytes.length - written, offset + written);
          if (result.bytesWritten <= 0) throw new Error("short attachment write");
          written += result.bytesWritten;
        }
        await file.sync();
        return { nextOffset: (await file.stat()).size };
      } finally { await file.close(); }
    } catch {
      return { nextOffset: 0, reason: "attachment-storage-failed" };
    } finally {
      release();
      if (this.locks.get(key) === current) this.locks.delete(key);
    }
  }

  async assemble(source: string, messageId: string, threadId: string, descriptors: AttachmentDescriptor[],
    deadline: number): Promise<{ attachments?: MessageAttachment[]; missing?: { index: number; nextOffset: number }; reason?: string }> {
    if (!validId(messageId) || !validId(threadId) || !Number.isSafeInteger(deadline) ||
        !Array.isArray(descriptors) ||
        descriptors.length === 0 || descriptors.length > MAX_ATTACHMENTS_PER_MESSAGE ||
        descriptors.some((item) => !item || typeof item !== "object" ||
          !Number.isSafeInteger(item.bytes) || item.bytes < 0 ||
          item.bytes > ATTACHMENT_MAX_BYTES || !validHash(item.sha256) ||
          typeof item.name !== "string" || !item.name || Buffer.byteLength(item.name) > 256 ||
          typeof item.mime !== "string" || !item.mime || Buffer.byteLength(item.mime) > 128) ||
        descriptors.reduce((sum, item) => sum + item.bytes, 0) > MESSAGE_ATTACHMENTS_MAX_BYTES) {
      return { reason: "invalid-attachment-commit" };
    }
    const folder = this.folder(source, messageId);
    const attachments: MessageAttachment[] = [];
    for (const [index, descriptor] of descriptors.entries()) {
      if (descriptor.bytes === 0 && descriptor.sha256 === createHash("sha256").digest("hex")) {
        attachments.push({ name: descriptor.name, mime: descriptor.mime, data: "" });
        continue;
      }
      try {
        const meta = JSON.parse(await readFile(join(folder, `${index}.json`), "utf8")) as UploadMeta;
        const bytes = await readFile(join(folder, `${index}.bin`));
        if (meta.threadId !== threadId || meta.deadline !== deadline || meta.totalBytes !== descriptor.bytes ||
            meta.sha256 !== descriptor.sha256) return { reason: "conflicting-attachment-upload" };
        if (bytes.length !== descriptor.bytes) return { missing: { index, nextOffset: bytes.length } };
        if (createHash("sha256").update(bytes).digest("hex") !== descriptor.sha256) {
          return { reason: "corrupt-attachment-upload" };
        }
        attachments.push({ name: descriptor.name, mime: descriptor.mime, data: bytes.toString("base64") });
      } catch (error) {
        if ((error as NodeJS.ErrnoException).code === "ENOENT") return { missing: { index, nextOffset: 0 } };
        return { reason: "attachment-storage-failed" };
      }
    }
    return { attachments };
  }
}

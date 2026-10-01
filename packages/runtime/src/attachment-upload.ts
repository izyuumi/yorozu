import type { AttachmentChunkData, AttachmentDescriptor, MessageAttachment } from "@yorozu/shared";
import { retainHostWorker, hostRequest } from "./rust-host.js";

type Progress = { nextOffset: number; reason?: string };
type Assembly = { attachments?: MessageAttachment[]; missing?: { index: number; nextOffset: number }; reason?: string };

/** Wire-compatible facade. Rust owns durable staging and quota decisions. */
export class AttachmentUploads {
  private readonly release: () => Promise<void>;
  constructor(private readonly dir: string) { this.release = retainHostWorker(dir); }
  async chunk(source: string, threadId: string, data: AttachmentChunkData): Promise<Progress> {
    try { return await hostRequest(this.dir, { op: "chunk", source, threadId, data }) as Progress; }
    catch { return { nextOffset: 0, reason: "attachment-storage-failed" }; }
  }
  async assemble(source: string, messageId: string, threadId: string, descriptors: AttachmentDescriptor[], deadline: number): Promise<Assembly> {
    try { return await hostRequest(this.dir, { op: "assemble", source, messageId, threadId, descriptors, deadline }) as Assembly; }
    catch { return { reason: "attachment-storage-failed" }; }
  }
  async close(): Promise<void> { await this.release(); }
}

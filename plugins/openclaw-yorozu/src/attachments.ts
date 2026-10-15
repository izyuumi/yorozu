/**
 * Attachments (#430; docs/ios-relay-contract.md, "Attachments"). Both ways, at most `mediaMaxBytes` each
 * (`channels.yorozu.mediaMaxMb`, default 8), in `CHUNK_BYTES` pieces that each fit one sealed box.
 *
 * - In: a device sends `upload` chunks, two in flight, each answered `upload_ack` to that device alone. The whole
 *   file goes into OpenClaw's media store (`media/inbound`) and its `attachmentId` into the keyed state store
 *   (namespace `attachments`); the device then sends its `message` naming it, and the turn gets it as media facts.
 * - Out: a reply's media (`MEDIA:` lines, the message tool, cron `sendMedia`) is staged into `media/outbound` and
 *   announced in the `reply`'s `attachments`. Nothing more goes out until a device asks: every host frame reaches
 *   every device, so each chunk is sent only on that device's `download`, sealed for it alone.
 */
import fs from "node:fs/promises";
import path from "node:path";
import type { OpenClawConfig } from "openclaw/plugin-sdk/channel-core";
import {
  extractOriginalFilename,
  resolveChannelMediaMaxBytes,
  resolveOutboundAttachmentFromUrl,
} from "openclaw/plugin-sdk/media-runtime";
import type { OutboundMediaAccess } from "openclaw/plugin-sdk/media-runtime";
import { saveMediaBuffer } from "openclaw/plugin-sdk/media-store";
import { CHUNK_BYTES, type Attachment, type Download, type Event, type Upload } from "./envelope.js";
import { yorozuRuntime } from "./runtime.js";

const MB = 1024 * 1024;
export const DEFAULT_MEDIA_MAX_BYTES = 8 * MB;
/** Partial uploads held at once, and how long one may stall before it is dropped (the device starts it over). */
const PARTIALS_MAX = 8;
const PARTIAL_MS = 30 * 60 * 1000;

/**
 * What the keyed store holds per attachment: a file this plugin wrote into the media store. `reply` is the id of the
 * first live `reply` an outbound file went with (the transcript's, `liveReplyIds`), so history can put it back.
 */
type Stored = Attachment & { path: string; reply?: string };

/** Stored attachments by path (uploads) and by reply (outbound), for history, which reads the transcript in sync. */
const byPath = new Map<string, Attachment>();
const byReply = new Map<string, Attachment[]>();
const index = (stored: Stored) => {
  const { path: file, reply, ...attachment } = stored;
  byPath.set(file, attachment);
  // The turn sees a staged copy; the transcript names the stored file by its media URL.
  byPath.set(`media://inbound/${path.basename(file)}`, attachment);
  if (reply) byReply.set(reply, [...(byReply.get(reply) ?? []).filter((a) => a.id !== attachment.id), attachment]);
};
const register = async (stored: Stored) => {
  await store().register(stored.id, stored);
  index(stored);
};

/** Fills the path index from the store, once per account start. */
export async function loadAttachmentIndex(): Promise<void> {
  for (const entry of await store().entries()) index(entry.value);
}

/** The upload stored at `path`, or with the media URL `path` (`media://inbound/<id>`). */
export const attachmentAt = (path: string): Attachment | undefined => byPath.get(path.trim());
/** The files that went with the live reply `replyId`, in order. */
export const attachmentsOf = (replyId: string): Attachment[] => byReply.get(replyId) ?? [];

const store = () =>
  yorozuRuntime.getRuntime().state.openKeyedStore<Stored>({
    namespace: "attachments",
    maxEntries: 10_000,
    overflowPolicy: "evict-oldest",
  });

/** `channels.yorozu.mediaMaxMb`, then `agents.defaults.mediaMaxMb`, then 8 MB. */
export function mediaMaxBytes(cfg: OpenClawConfig, accountId?: string | null): number {
  return (
    resolveChannelMediaMaxBytes({
      cfg,
      accountId,
      resolveChannelLimitMb: ({ cfg }) => {
        const mb = (cfg.channels as Record<string, { mediaMaxMb?: unknown }> | undefined)?.yorozu?.mediaMaxMb;
        return typeof mb === "number" && mb > 0 ? mb : undefined;
      },
    }) ?? DEFAULT_MEDIA_MAX_BYTES
  );
}

const chunkCount = (size: number) => Math.max(1, Math.ceil(size / CHUNK_BYTES));
const megabytes = (bytes: number) => `${Math.round((bytes / MB) * 10) / 10} MB`;

type Partial = { meta: Attachment; chunks: (Buffer | undefined)[]; have: number; at: number };
const partials = new Map<string, Partial>();

/** One `upload` chunk; returns what goes back to that device. Never throws. */
export async function receiveUpload(upload: Upload, maxBytes: number): Promise<Event[]> {
  const { attachmentId, index } = upload;
  const fail = (code: string, message: string): Event[] => {
    partials.delete(attachmentId);
    return [{ kind: "error", data: { code, message, attachmentId } }];
  };
  if (upload.size > maxBytes) {
    return fail("too_large", `${upload.name} is ${megabytes(upload.size)}; the limit is ${megabytes(maxBytes)}`);
  }
  if (upload.count !== chunkCount(upload.size)) return fail("bad_request", "chunk count does not match the size");
  if (await store().lookup(attachmentId)) return [{ kind: "upload_ack", data: { attachmentId, index, done: true } }];

  const now = Date.now();
  for (const [id, p] of partials) if (p.at < now - PARTIAL_MS) partials.delete(id);
  let partial = partials.get(attachmentId);
  if (partial && (partial.meta.size !== upload.size || partial.chunks.length !== upload.count)) {
    return fail("bad_request", "chunk does not match the upload it continues");
  }
  if (!partial) {
    if (partials.size >= PARTIALS_MAX) partials.delete(partials.keys().next().value!);
    partial = {
      meta: { id: attachmentId, name: path.basename(upload.name), mime: upload.mime, size: upload.size },
      chunks: new Array(upload.count),
      have: 0,
      at: now,
    };
    partials.set(attachmentId, partial);
  }
  const bytes = Buffer.from(upload.data, "base64");
  const expected = index === upload.count - 1 ? upload.size - index * CHUNK_BYTES : CHUNK_BYTES;
  if (bytes.length !== expected) return fail("bad_request", `chunk ${index} has ${bytes.length} bytes, not ${expected}`);
  if (!partial.chunks[index]) partial.have += 1;
  partial.chunks[index] = bytes;
  partial.at = now;
  if (partial.have < partial.chunks.length) return [{ kind: "upload_ack", data: { attachmentId, index, done: false } }];

  partials.delete(attachmentId);
  try {
    const { meta } = partial;
    const saved = await saveMediaBuffer(Buffer.concat(partial.chunks as Buffer[]), meta.mime, "inbound", maxBytes, meta.name);
    await register({ ...meta, mime: saved.contentType ?? meta.mime, path: saved.path });
  } catch (error) {
    return fail("internal", `could not store ${partial.meta.name}: ${String(error).slice(0, 200)}`);
  }
  return [{ kind: "upload_ack", data: { attachmentId, index, done: true } }];
}

/** A `message`'s attachments that this plugin holds, for the turn's media facts; unknown ids are skipped. */
export async function uploadedFiles(attachments: Attachment[] | undefined): Promise<Stored[]> {
  const found = await Promise.all((attachments ?? []).map((a) => store().lookup(a.id)));
  return found.filter((s): s is Stored => !!s);
}

/** One `download`: the chunk, or `not_found` for an id this plugin never announced or no longer has. */
export async function serveDownload(request: Download): Promise<Event> {
  const { attachmentId, index } = request;
  const notFound: Event = {
    kind: "error",
    data: { code: "not_found", message: "attachment no longer available", attachmentId },
  };
  const stored = await store().lookup(attachmentId);
  if (!stored) return notFound;
  let file: fs.FileHandle | undefined;
  try {
    file = await fs.open(stored.path, "r");
    const { size } = await file.stat();
    const count = chunkCount(size);
    if (index >= count) return notFound;
    const buffer = Buffer.alloc(Math.min(CHUNK_BYTES, size - index * CHUNK_BYTES));
    await file.read(buffer, 0, buffer.length, index * CHUNK_BYTES);
    return { kind: "chunk", data: { attachmentId, index, count, data: buffer.toString("base64") } };
  } catch {
    return notFound;
  } finally {
    await file?.close();
  }
}

export type MediaAccess = {
  mediaAccess?: OutboundMediaAccess;
  localRoots?: readonly string[];
  readFile?: (filePath: string) => Promise<Buffer>;
};

/**
 * Stages each of a reply's media URLs (a local path in an allowed root, or http) into the media store and
 * registers it for downloads. Returns the attachments, and a line per one that could not be attached.
 */
export async function stageOutbound(
  urls: readonly string[],
  maxBytes: number,
  access: MediaAccess,
  reply?: string,
): Promise<{ attachments: Attachment[]; failures: string[] }> {
  const attachments: Attachment[] = [];
  const failures: string[] = [];
  for (const url of urls) {
    // The media store names a copy `<name>---<uuid>.<ext>`; the device shows `<name>.<ext>`.
    const name = extractOriginalFilename(url.split(/[?#]/)[0] ?? "");
    try {
      const staged = await resolveOutboundAttachmentFromUrl(url, maxBytes, access);
      const { size } = await fs.stat(staged.path);
      const attachment: Attachment = {
        id: crypto.randomUUID(),
        name: name.slice(0, 255),
        mime: (staged.contentType || "application/octet-stream").slice(0, 255),
        size,
      };
      await register({ ...attachment, path: staged.path, ...(reply ? { reply } : {}) });
      attachments.push(attachment);
    } catch (error) {
      const why = /exceed|too large|max/i.test(String(error)) ? `it is over ${megabytes(maxBytes)}` : "it could not be read";
      failures.push(`(Couldn't attach ${name}: ${why}.)`);
    }
  }
  return { attachments, failures };
}

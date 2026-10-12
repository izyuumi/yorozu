// Saves a Yorozu message's attachments into OpenClaw's media store and describes them as the
// SDK's media facts. `store` is injected so tests can fake it.

// The host's limit is 20 MB decoded per message; one file may use all of it.
const MAX_ATTACHMENT_BYTES = 20 * 1024 * 1024;

/** @param {{ saveMedia: Function, toMediaFacts: Function }} store */
export function createAttachmentSaver({ saveMedia, toMediaFacts }) {
  // `${messageId}:${index}` -> saved file. The host resends what was not acked, so a retry reuses its files.
  const saved = new Map();
  const keys = ({ id, attachments = [] }) => attachments.map((_, index) => `${id}:${index}`);
  return {
    /** One fact per attachment, in order. Throws if a file cannot be saved. */
    async save(message) {
      const media = [];
      for (const [index, key] of keys(message).entries()) {
        if (!saved.has(key)) {
          const { data, mime, name } = message.attachments[index];
          const file = await saveMedia(Buffer.from(data, "base64"), mime, "inbound", MAX_ATTACHMENT_BYTES, name);
          saved.set(key, { path: file.path, contentType: file.contentType ?? mime, fileName: name, messageId: message.id });
        }
        media.push(saved.get(key));
      }
      return toMediaFacts(media);
    },
    /** OpenClaw has the message; a later resend of it is deduped, not saved again. */
    release(message) {
      for (const key of keys(message)) saved.delete(key);
    },
  };
}

// Yorozu's limits for one message's attachments, mirrored from packages/shared/src/events.ts.
const MAX_REPLY_FILE_BYTES = 5 * 1024 * 1024;
const MAX_REPLY_FILES = 10;
const MAX_REPLY_TOTAL_BYTES = 20 * 1024 * 1024;

/** A reply payload's files, in order: `mediaUrls`, else the single `mediaUrl`. */
export const replyMediaUrls = (payload) => {
  const urls = Array.isArray(payload?.mediaUrls) && payload.mediaUrls.length ? payload.mediaUrls : [payload?.mediaUrl];
  return urls.filter((url) => typeof url === "string" && url.trim());
};

/**
 * Loads the files an agent sends as Yorozu attachments `{ name, mime, data }`. A file that cannot
 * be read or is over Yorozu's limits becomes a line in `notes` instead: the rest still arrive.
 * `load` is the SDK's `loadOutboundMediaFromUrl`, injected so tests can fake it.
 */
export async function loadReplyAttachments(urls, load, options = {}) {
  const attachments = [];
  const notes = [];
  let total = 0;
  for (const url of urls) {
    const fallback = url.split(/[\\/]/).pop()?.split("?")[0] || "file";
    try {
      if (attachments.length >= MAX_REPLY_FILES) throw new Error(`more than ${MAX_REPLY_FILES} files`);
      const media = await load(url, { maxBytes: MAX_REPLY_FILE_BYTES, optimizeImages: false, ...options });
      if (total + media.buffer.length > MAX_REPLY_TOTAL_BYTES) throw new Error("over 20 MB in one message");
      total += media.buffer.length;
      let name = media.fileName || fallback;
      while (Buffer.byteLength(name) > 255) name = name.slice(0, -1);
      attachments.push({
        name,
        mime: media.contentType?.slice(0, 128) || "application/octet-stream",
        data: media.buffer.toString("base64"),
      });
    } catch (error) {
      notes.push(`(Could not attach ${fallback}: ${error instanceof Error ? error.message : String(error)})`);
    }
  }
  return { attachments, notes };
}

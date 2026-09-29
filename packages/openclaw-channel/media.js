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

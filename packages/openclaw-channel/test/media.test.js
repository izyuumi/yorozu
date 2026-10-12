import assert from "node:assert/strict";
import test from "node:test";
import { loadReplyAttachments, replyMediaUrls } from "../media.js";

test("reply media urls prefer the list and skip blanks", () => {
  assert.deepEqual(replyMediaUrls({ mediaUrl: "/a", mediaUrls: ["/b", " ", "/c"] }), ["/b", "/c"]);
  assert.deepEqual(replyMediaUrls({ mediaUrl: "/a" }), ["/a"]);
  assert.deepEqual(replyMediaUrls({ text: "hi" }), []);
});

test("files load as attachments; a file that cannot be sent becomes a note", async () => {
  const load = async (url) => {
    if (url.endsWith("big.bin")) throw new Error("Media exceeds 5MB limit");
    return { buffer: Buffer.from("pdf bytes"), contentType: "application/pdf", fileName: undefined };
  };
  const { attachments, notes } = await loadReplyAttachments(["/out/report.pdf", "/out/big.bin"], load);
  assert.deepEqual(attachments, [{ name: "report.pdf", mime: "application/pdf", data: Buffer.from("pdf bytes").toString("base64") }]);
  assert.deepEqual(notes, ["(Could not attach big.bin: Media exceeds 5MB limit)"]);
});

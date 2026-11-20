import { createCipheriv, createHash, hkdfSync, randomBytes } from "node:crypto";
import { yorozuRuntime } from "./runtime.js";
import { conversationTitle } from "./sessions.js";
import { b64u, dh, fromB64u } from "./wire.js";

export const MAX_PREVIEW_BYTES = 256;
const TITLE_CHARS = 32;

export type Preview = { b: string; c: "reply"; e: string; t?: string; v: string };

export const threadRef = (id: string): string => b64u(createHash("sha256").update(id, "utf8").digest()).slice(0, 8);

export function previewKey(hostStaticPriv: Uint8Array, deviceStaticPub: string): Buffer | null {
  const pub = fromB64u(deviceStaticPub);
  if (pub?.length !== 32) return null;
  const secret = dh(hostStaticPriv, pub);
  return Buffer.from(hkdfSync("sha256", secret, "yorozu-v1", "yorozu-push-preview/mac->device", 32));
}

export const firstLine = (text: string): string =>
  text.split("\n").map((line) => line.replace(/\s+/g, " ").trim()).find(Boolean) ?? "";

const cut = (text: string, chars: number): string => {
  const all = [...text];
  return all.length <= chars ? text : `${all.slice(0, chars - 1).join("").trimEnd()}…`;
};

export function previewPlaintext(preview: Preview): Buffer | null {
  const title = preview.t ? cut(preview.t, TITLE_CHARS) : undefined;
  let body = [...preview.b];
  if (!body.length) return null;
  for (;;) {
    const text = body.join("");
    const json = JSON.stringify({ b: text, c: preview.c, e: preview.e, ...(title ? { t: title } : {}), v: preview.v });
    const bytes = Buffer.from(json, "utf8");
    if (bytes.length <= MAX_PREVIEW_BYTES) return bytes;
    const bare = text.endsWith("…") ? body.slice(0, -1) : body;
    if (bare.length <= 1) return null;
    const drop = Math.min(bare.length - 1, Math.max(1, Math.floor((bytes.length - MAX_PREVIEW_BYTES) / 4)));
    body = [...`${bare.slice(0, bare.length - drop).join("").trimEnd()}…`];
  }
}

export function sealPreview(key: Uint8Array, plaintext: Uint8Array): { n: string; c: string } {
  const nonce = randomBytes(12);
  const cipher = createCipheriv("chacha20-poly1305", key, nonce, { authTagLength: 16 });
  const sealed = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
  return { n: b64u(nonce), c: b64u(sealed) };
}

const titles = () =>
  yorozuRuntime.getRuntime().state.openKeyedStore<{ title: string }>({ namespace: "push-titles", retention: "retained" });

export async function noteFirstMessage(convId: string, text: string): Promise<void> {
  const line = firstLine(text);
  if (!line || line.startsWith("/") || (await titles().lookup(convId)) !== undefined) return;
  await titles().register(convId, { title: cut(line, TITLE_CHARS) });
}

export const pushTitle = async (convId: string): Promise<string | undefined> =>
  conversationTitle(convId) ?? (await titles().lookup(convId))?.title;

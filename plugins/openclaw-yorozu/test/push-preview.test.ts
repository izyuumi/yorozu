import assert from "node:assert/strict";
import { createCipheriv } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { registerHooks } from "node:module";
import { test } from "node:test";

registerHooks({
  resolve(specifier, context, next) {
    // The preview helpers in push.ts are pure; the file also imports the OpenClaw
    // runtime for the title store, which these tests do not call.
    if (specifier === "./runtime.js" || specifier === "./sessions.js") {
      return { url: new URL("./push-preview-stub.js", import.meta.url).href, shortCircuit: true };
    }
    if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  },
});
const { previewKey, previewPlaintext, sealPreview } = await import("../src/push.ts");
const { b64u, x25519Keypair } = await import("../src/wire.ts");

// Test-only: sealPreview's cipher, key and output shape with a caller-chosen nonce, so the
// fixture box is reproducible. Production sealPreview takes no nonce on purpose.
function sealWithNonce(key: Uint8Array, plaintext: Uint8Array, nonce: Uint8Array): { n: string; c: string } {
  const cipher = createCipheriv("chacha20-poly1305", key, nonce, { authTagLength: 16 });
  const sealed = Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
  return { n: b64u(nonce), c: b64u(sealed) };
}

// Sealed here by sealWithNonce; PushPreviewTests opens this exact box with Swift PushPreview.open.
// Regenerate with UPDATE_FIXTURES=1 only when the preview format changes on purpose.
const url = new URL("../../../packages/YorozuWire/Tests/YorozuWireTests/Fixtures/push-preview.json", import.meta.url);

test("fixed-nonce seal matches the fixture Swift PushPreview.open reads", () => {
  const host = x25519Keypair(Buffer.alloc(32, 1));
  const device = x25519Keypair(Buffer.alloc(32, 3));
  const preview = { b: "今日の予定は a/b です", c: "reply" as const, e: "AbCd1234", t: "Morning plan", v: "conv-1" };
  const key = previewKey(host.privateKey, b64u(device.publicKey));
  const plaintext = previewPlaintext(preview);
  assert.ok(key && plaintext);
  const built = {
    hostStaticPub: b64u(host.publicKey),
    deviceStaticPriv: b64u(device.privateKey),
    key: b64u(key),
    preview,
    ...sealWithNonce(key, plaintext, Buffer.alloc(12, 7)),
  };
  if (process.env.UPDATE_FIXTURES) writeFileSync(url, `${JSON.stringify(built, null, 2)}\n`);
  assert.deepEqual(built, JSON.parse(readFileSync(url, "utf8")));
});

test("sealPreview draws a fresh nonce by default", () => {
  const key = Buffer.alloc(32, 9);
  const a = sealPreview(key, Buffer.from("x"));
  const b = sealPreview(key, Buffer.from("x"));
  assert.equal(Buffer.from(a.n, "base64url").length, 12);
  assert.notEqual(a.n, b.n);
  // Production and the test-only helper stay the same box format.
  assert.deepEqual(sealWithNonce(key, Buffer.from("x"), Buffer.from(a.n, "base64url")), a);
});

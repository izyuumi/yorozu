import { readFileSync } from "node:fs";
import { expect, test } from "vitest";
import { decodeQrPayload } from "./events.js";
import { deriveSessionKey, fromBase64Url, open, toBase64Url, verifyFrame } from "./crypto.js";
import { VECTOR_PLAINTEXT, vectorsPath, type Vectors } from "./vectors.js";

/**
 * Decrypts the vectors Swift generated (`swift run YorozuFixtureGen`, committed to fixtures/).
 * The mirror of this test lives in packages/shared-swift/Tests/.../InteropTests.swift.
 */
test("TypeScript opens Swift vectors", () => {
  const v: Vectors = JSON.parse(readFileSync(vectorsPath("swift"), "utf8"));
  expect(v.source).toBe("swift");

  // Same session key from the other half of the exchange.
  const key = deriveSessionKey(fromBase64Url(v.bobPriv), fromBase64Url(v.alicePub));
  expect(toBase64Url(key)).toBe(v.sessionKey);

  const opened = open(key, fromBase64Url(v.nonce), fromBase64Url(v.ciphertext));
  expect(toBase64Url(opened)).toBe(v.plaintext);
  expect(new TextDecoder().decode(opened)).toBe(VECTOR_PLAINTEXT);

  expect(verifyFrame(fromBase64Url(v.signPub), opened, fromBase64Url(v.signature))).toBe(true);

  const qr = decodeQrPayload(v.qr);
  expect(qr.v).toBe(1);
  expect(qr.macPubkey).toBe(v.alicePub);
});

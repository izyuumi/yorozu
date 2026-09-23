import { readFileSync } from "node:fs";
import { expect, test } from "vitest";
import { decodeQrPayload } from "./events.js";
import { deriveChannelKeys, deriveSessionKey, fromBase64Url, open, toBase64Url, verifyFrame } from "./crypto.js";
import { decodeEnvelope } from "./channel.js";
import { VECTOR_EVENT, VECTOR_PLAINTEXT, VECTOR_SEQ, vectorsPath, type Vectors } from "./vectors.js";

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
  // And the directional pair: bob is the device, so its send is the Mac's recv.
  const channel = deriveChannelKeys(fromBase64Url(v.bobPriv), fromBase64Url(v.alicePub), "device");
  expect(toBase64Url(channel.send)).toBe(v.channelDeviceToMac);
  expect(toBase64Url(channel.recv)).toBe(v.channelMacToDevice);
  // A live-channel box the Swift Mac sealed opens under the device's recv key, and its
  // envelope reads as the same seq and event Swift put in it — field names and integer
  // encoding included. Under the device's send key, as if reflected, it does not open.
  expect(v.channelSeq).toBe(VECTOR_SEQ);
  const envelope = decodeEnvelope(open(channel.recv, fromBase64Url(v.channelNonce), fromBase64Url(v.channelCiphertext)));
  expect(envelope).toEqual({ seq: VECTOR_SEQ, event: VECTOR_EVENT });
  expect(() => open(channel.send, fromBase64Url(v.channelNonce), fromBase64Url(v.channelCiphertext))).toThrow();
  expect(() => open(key, fromBase64Url(v.channelNonce), fromBase64Url(v.channelCiphertext))).toThrow();

  const opened = open(key, fromBase64Url(v.nonce), fromBase64Url(v.ciphertext));
  expect(toBase64Url(opened)).toBe(v.plaintext);
  expect(new TextDecoder().decode(opened)).toBe(VECTOR_PLAINTEXT);

  expect(verifyFrame(fromBase64Url(v.signPub), opened, fromBase64Url(v.signature))).toBe(true);

  const qr = decodeQrPayload(v.qr);
  expect(qr.v).toBe(1);
  expect(qr.macPubkey).toBe(v.alicePub);
});

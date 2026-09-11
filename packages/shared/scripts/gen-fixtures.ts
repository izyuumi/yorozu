/**
 * Writes fixtures/ts-vectors.json, the test vectors the Swift suite decrypts.
 * Run with `pnpm --filter @yorozu/shared gen:fixtures` after changing the crypto contract.
 */
import { writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import {
  deriveSessionKey,
  generateKeypair,
  generateSigningKeypair,
  seal,
  signFrame,
  toBase64Url,
} from "../src/crypto.ts";
import { encodeQrPayload, type QrPayload } from "../src/events.ts";
import { VECTOR_PLAINTEXT, vectorsPath, type Vectors } from "../src/vectors.ts";

const alice = generateKeypair();
const bob = generateKeypair();
const signer = generateSigningKeypair();
const sessionKey = deriveSessionKey(alice.privateKey, bob.publicKey);
const plaintext = Buffer.from(VECTOR_PLAINTEXT, "utf8");
const { nonce, ciphertext } = seal(sessionKey, plaintext);

const qr: QrPayload = {
  v: 1,
  relayUrl: "wss://relay.yumi.to",
  macPubkey: toBase64Url(alice.publicKey),
  token: toBase64Url(randomBytes(16)),
};

const vectors: Vectors = {
  source: "ts",
  alicePriv: toBase64Url(alice.privateKey),
  alicePub: toBase64Url(alice.publicKey),
  bobPriv: toBase64Url(bob.privateKey),
  bobPub: toBase64Url(bob.publicKey),
  sessionKey: toBase64Url(sessionKey),
  nonce: toBase64Url(nonce),
  plaintext: toBase64Url(plaintext),
  ciphertext: toBase64Url(ciphertext),
  signPriv: toBase64Url(signer.privateKey),
  signPub: toBase64Url(signer.publicKey),
  signature: toBase64Url(signFrame(signer.privateKey, plaintext)),
  qr: encodeQrPayload(qr),
};

const path = vectorsPath("ts");
writeFileSync(path, `${JSON.stringify(vectors, null, 2)}\n`);
console.log(`wrote ${path}`);

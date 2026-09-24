/**
 * Writes fixtures/ts-vectors.json, the test vectors the Swift suite decrypts.
 * Run with `pnpm --filter @yorozu/shared gen:fixtures` after changing the crypto contract.
 */
import { writeFileSync } from "node:fs";
import { randomBytes } from "node:crypto";
import {
  deriveChannelKeys,
  deriveSessionKey,
  generateKeypair,
  generateSigningKeypair,
  seal,
  signFrame,
  toBase64Url,
} from "../src/crypto.ts";
import { encodePairingString, type QrPayload } from "../src/events.ts";
import { encodeEnvelope } from "../src/channel.ts";
import { VECTOR_EVENT, VECTOR_PLAINTEXT, VECTOR_SEQ, vectorsPath, type Vectors } from "../src/vectors.ts";

const alice = generateKeypair();
const bob = generateKeypair();
const signer = generateSigningKeypair();
const sessionKey = deriveSessionKey(alice.privateKey, bob.publicKey);
const channel = deriveChannelKeys(alice.privateKey, bob.publicKey, "mac");
const plaintext = Buffer.from(VECTOR_PLAINTEXT, "utf8");
const { nonce, ciphertext } = seal(sessionKey, plaintext);
const channelBox = seal(channel.send, encodeEnvelope(VECTOR_SEQ, VECTOR_EVENT));

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
  channelMacToDevice: toBase64Url(channel.send),
  channelDeviceToMac: toBase64Url(channel.recv),
  channelSeq: VECTOR_SEQ,
  channelNonce: toBase64Url(channelBox.nonce),
  channelCiphertext: toBase64Url(channelBox.ciphertext),
  nonce: toBase64Url(nonce),
  plaintext: toBase64Url(plaintext),
  ciphertext: toBase64Url(ciphertext),
  signPriv: toBase64Url(signer.privateKey),
  signPub: toBase64Url(signer.publicKey),
  signature: toBase64Url(signFrame(signer.privateKey, plaintext)),
  qr: encodePairingString(qr),
};

const path = vectorsPath("ts");
writeFileSync(path, `${JSON.stringify(vectors, null, 2)}\n`);
console.log(`wrote ${path}`);

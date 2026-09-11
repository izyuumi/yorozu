import { expect, test } from "vitest";
import {
  deriveSessionKey,
  fromBase64Url,
  generateKeypair,
  generateSigningKeypair,
  open,
  seal,
  signFrame,
  toBase64Url,
  verifyFrame,
} from "./crypto.js";

test("both peers derive the same session key", () => {
  const mac = generateKeypair();
  const phone = generateKeypair();
  expect(mac.privateKey).toHaveLength(32);
  expect(mac.publicKey).toHaveLength(32);
  expect(deriveSessionKey(mac.privateKey, phone.publicKey)).toEqual(
    deriveSessionKey(phone.privateKey, mac.publicKey),
  );
});

test("seal then open round-trips", () => {
  const key = deriveSessionKey(generateKeypair().privateKey, generateKeypair().publicKey);
  const plaintext = new TextEncoder().encode("hello from the phone");
  const { nonce, ciphertext } = seal(key, plaintext);
  expect(nonce).toHaveLength(12);
  expect(ciphertext).toHaveLength(plaintext.length + 16);
  expect(new Uint8Array(open(key, nonce, ciphertext))).toEqual(plaintext);
});

test("open rejects a tampered ciphertext", () => {
  const key = deriveSessionKey(generateKeypair().privateKey, generateKeypair().publicKey);
  const { nonce, ciphertext } = seal(key, new TextEncoder().encode("transfer 10"));
  ciphertext[0] ^= 1;
  expect(() => open(key, nonce, ciphertext)).toThrow();
});

test("relay frames verify only under the matching key", () => {
  const signer = generateSigningKeypair();
  const other = generateSigningKeypair();
  const frame = new TextEncoder().encode("join room");
  const signature = signFrame(signer.privateKey, frame);
  expect(verifyFrame(signer.publicKey, frame, signature)).toBe(true);
  expect(verifyFrame(other.publicKey, frame, signature)).toBe(false);
});

test("base64url round-trips raw keys", () => {
  const { publicKey } = generateKeypair();
  expect(fromBase64Url(toBase64Url(publicKey))).toEqual(publicKey);
});

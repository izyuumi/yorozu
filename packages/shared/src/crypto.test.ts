import { expect, test } from "vitest";
import {
  deriveChannelKeys,
  deriveSessionKey,
  fromBase64Url,
  generateKeypair,
  generateSigningKeypair,
  helloProof,
  open,
  seal,
  signFrame,
  threadRef,
  toBase64Url,
  verifyFrame,
} from "./crypto.js";

/**
 * Fixed vectors, byte-identical in CryptoTests.swift: the relay routes on `threadRef` and the
 * runtime checks `helloProof`, so the two languages must agree on both to the character.
 */
test("references and proofs are spelled the same in both languages", () => {
  expect(threadRef("home")).toBe("TqFAWIFQ");
  expect(helloProof("secret", "pub", "spub")).toBe("MFvwTalbqCws08QSHDUcxRUlQi2EJlN53U9I-hoq_U0");
  // Bound to every input: any of them changed is a different proof.
  expect(helloProof("secret", "pub", "other")).not.toBe(helloProof("secret", "pub", "spub"));
});

test("both peers derive the same session key", () => {
  const mac = generateKeypair();
  const phone = generateKeypair();
  expect(mac.privateKey).toHaveLength(32);
  expect(mac.publicKey).toHaveLength(32);
  expect(deriveSessionKey(mac.privateKey, phone.publicKey)).toEqual(
    deriveSessionKey(phone.privateKey, mac.publicKey),
  );
});

test("channel keys differ per direction and cross over between the two ends", () => {
  const mac = generateKeypair();
  const phone = generateKeypair();
  const macSide = deriveChannelKeys(mac.privateKey, phone.publicKey, "mac");
  const phoneSide = deriveChannelKeys(phone.privateKey, mac.publicKey, "device");
  expect(macSide.send).toHaveLength(32);
  expect(macSide.send).not.toEqual(macSide.recv);
  expect(macSide.send).toEqual(phoneSide.recv);
  expect(macSide.recv).toEqual(phoneSide.send);
  // Neither is the preview key, which stays in use beside them.
  const session = deriveSessionKey(mac.privateKey, phone.publicKey);
  expect(macSide.send).not.toEqual(session);
  expect(macSide.recv).not.toEqual(session);
  // A box the Mac sealed does not open as if the phone had sent it.
  const box = seal(macSide.send, new TextEncoder().encode("from the mac"));
  expect(() => open(macSide.recv, box.nonce, box.ciphertext)).toThrow();
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

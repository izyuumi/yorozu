/**
 * X25519 -> HKDF-SHA256 -> ChaCha20-Poly1305, plus Ed25519 for relay frame signatures.
 * Mirrored by packages/shared-swift/Sources/YorozuShared/Crypto.swift (CryptoKit).
 *
 * Keys, nonces and signatures are always raw bytes here; base64url only at the edges.
 */
import {
  createCipheriv,
  createDecipheriv,
  createPrivateKey,
  createHash,
  createPublicKey,
  diffieHellman,
  generateKeyPairSync,
  hkdfSync,
  randomBytes,
  sign,
  verify,
  type KeyObject,
} from "node:crypto";

export interface Keypair {
  /** Raw 32-byte scalar. */
  privateKey: Uint8Array;
  /** Raw 32-byte point. */
  publicKey: Uint8Array;
}

export interface SealedBox {
  /** 12 bytes. */
  nonce: Uint8Array;
  /** Ciphertext followed by the 16-byte Poly1305 tag, as CryptoKit lays it out. */
  ciphertext: Uint8Array;
}

/** Salt and info are part of the wire contract: both languages must use these bytes. */
const HKDF_SALT = Buffer.from("yorozu-v1", "utf8");
const HKDF_INFO = Buffer.from("yorozu-session", "utf8");

const NONCE_BYTES = 12;
const TAG_BYTES = 16;

// Node has no raw-key import for these curves, so wrap the 32 bytes in the one
// fixed DER header each key type has.
const DER = {
  x25519: {
    spki: Buffer.from("302a300506032b656e032100", "hex"),
    pkcs8: Buffer.from("302e020100300506032b656e04220420", "hex"),
  },
  ed25519: {
    spki: Buffer.from("302a300506032b6570032100", "hex"),
    pkcs8: Buffer.from("302e020100300506032b657004220420", "hex"),
  },
} as const;

type Curve = keyof typeof DER;

const importPublic = (curve: Curve, raw: Uint8Array): KeyObject =>
  createPublicKey({ key: Buffer.concat([DER[curve].spki, raw]), format: "der", type: "spki" });

const importPrivate = (curve: Curve, raw: Uint8Array): KeyObject =>
  createPrivateKey({ key: Buffer.concat([DER[curve].pkcs8, raw]), format: "der", type: "pkcs8" });

/** Raw key bytes are always the DER suffix. */
const rawOf = (key: KeyObject): Uint8Array => {
  const der =
    key.type === "private"
      ? key.export({ format: "der", type: "pkcs8" })
      : key.export({ format: "der", type: "spki" });
  return new Uint8Array(der.subarray(der.length - 32));
};

const rawPair = (pair: { privateKey: KeyObject; publicKey: KeyObject }): Keypair => ({
  privateKey: rawOf(pair.privateKey),
  publicKey: rawOf(pair.publicKey),
});

/** X25519 keypair for the session key agreement. */
export const generateKeypair = (): Keypair => rawPair(generateKeyPairSync("x25519"));

/** Ed25519 keypair for signing relay frames. */
export const generateSigningKeypair = (): Keypair => rawPair(generateKeyPairSync("ed25519"));

/** 32-byte symmetric key. Both peers derive the same one from opposite halves. */
export function deriveSessionKey(myPriv: Uint8Array, theirPub: Uint8Array): Uint8Array {
  const shared = diffieHellman({
    privateKey: importPrivate("x25519", myPriv),
    publicKey: importPublic("x25519", theirPub),
  });
  return new Uint8Array(hkdfSync("sha256", shared, HKDF_SALT, HKDF_INFO, 32));
}

export function seal(key: Uint8Array, plaintext: Uint8Array): SealedBox {
  const nonce = randomBytes(NONCE_BYTES);
  const cipher = createCipheriv("chacha20-poly1305", key, nonce, { authTagLength: TAG_BYTES });
  const body = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  return {
    nonce: new Uint8Array(nonce),
    ciphertext: new Uint8Array(Buffer.concat([body, cipher.getAuthTag()])),
  };
}

/** Throws if the tag does not verify. */
export function open(key: Uint8Array, nonce: Uint8Array, ciphertext: Uint8Array): Uint8Array {
  if (ciphertext.length < TAG_BYTES) throw new Error("ciphertext too short");
  const split = ciphertext.length - TAG_BYTES;
  const decipher = createDecipheriv("chacha20-poly1305", key, nonce, { authTagLength: TAG_BYTES });
  decipher.setAuthTag(ciphertext.subarray(split));
  return new Uint8Array(
    Buffer.concat([decipher.update(ciphertext.subarray(0, split)), decipher.final()]),
  );
}

export const signFrame = (priv: Uint8Array, data: Uint8Array): Uint8Array =>
  new Uint8Array(sign(null, data, importPrivate("ed25519", priv)));

export const verifyFrame = (pub: Uint8Array, data: Uint8Array, signature: Uint8Array): boolean =>
  verify(null, data, importPublic("ed25519", pub), signature);

export const toBase64Url = (bytes: Uint8Array): string => Buffer.from(bytes).toString("base64url");

export const fromBase64Url = (text: string): Uint8Array =>
  new Uint8Array(Buffer.from(text, "base64url"));

/**
 * The opaque id a push payload names a thread by. The relay routes on it and stores it, so it
 * must say nothing about the thread: a truncated hash of an id that is itself a random UUID,
 * which leaves the relay with a handle it can match but not invert.
 *
 * Eight characters of base64url is 48 bits — far more than the handful of threads one phone
 * has open at once needs to stay distinct, and short enough to read in a log.
 */
export const threadRef = (threadId: string): string =>
  createHash("sha256").update(threadId).digest("base64url").slice(0, 8);

/**
 * What a phone puts in its first `hello` to prove it read the QR: a hash over the QR's secret
 * and both keys it is announcing. The relay sees the proof and the keys, never the secret, and
 * a proof for one pair of keys says nothing about any other — so a relay cannot enrol keys of
 * its own, and cannot reuse a proof it saw. Mirrored in Crypto.swift.
 */
export const helloProof = (secret: string, pub: string, spub: string): string =>
  createHash("sha256").update(`${secret}.${pub}.${spub}`).digest("base64url");

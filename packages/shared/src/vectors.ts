/** Shape of fixtures/<source>-vectors.json. Every field is base64url except `source` and `qr`. */
export interface Vectors {
  source: "ts" | "swift";
  alicePriv: string;
  alicePub: string;
  bobPriv: string;
  bobPub: string;
  /** deriveSessionKey(alicePriv, bobPub). */
  sessionKey: string;
  nonce: string;
  plaintext: string;
  ciphertext: string;
  signPriv: string;
  signPub: string;
  /** Ed25519 signature over the plaintext bytes. */
  signature: string;
  /** Encoded QrPayload, verbatim. */
  qr: string;
}

/** The one string both generators seal, so a mismatch is readable in test output. */
export const VECTOR_PLAINTEXT = "yorozu cross-language vector";

export const vectorsPath = (source: Vectors["source"]): string =>
  new URL(`../../../fixtures/${source}-vectors.json`, import.meta.url).pathname;

import type { YorozuEvent } from "./events.js";

/** Shape of fixtures/<source>-vectors.json. Every field is base64url except `source` and `qr`. */
export interface Vectors {
  source: "ts" | "swift";
  alicePriv: string;
  alicePub: string;
  bobPriv: string;
  bobPub: string;
  /** deriveSessionKey(alicePriv, bobPub). */
  sessionKey: string;
  /** deriveChannelKeys(alicePriv, bobPub, "mac").send — alice is the Mac, bob the device. */
  channelMacToDevice: string;
  /** deriveChannelKeys(alicePriv, bobPub, "mac").recv. */
  channelDeviceToMac: string;
  /** The seq inside `channelCiphertext`: `VECTOR_SEQ`. */
  channelSeq: number;
  /** A `ChannelEnvelope` of `VECTOR_SEQ` and `VECTOR_EVENT`, sealed by the Mac under `channelMacToDevice`. */
  channelNonce: string;
  channelCiphertext: string;
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

/** The one envelope both generators seal on the live channel; the event is one the phone shows. */
export const VECTOR_SEQ = 7;
export const VECTOR_EVENT: YorozuEvent = {
  id: "vector-event",
  threadId: "vector-thread",
  ts: 1_700_000_000_000,
  agentId: "mac",
  kind: "message",
  data: { role: "agent", text: VECTOR_PLAINTEXT, done: true },
};

export const vectorsPath = (source: Vectors["source"]): string =>
  new URL(`../../../fixtures/${source}-vectors.json`, import.meta.url).pathname;

/**
 * Wire v3 (docs/ios-relay-contract.md): Noise_IK_25519_ChaChaPoly_SHA256 per connection, the client as
 * initiator and this plugin as responder, then numbered transport boxes. node:crypto only. Mirrors
 * packages/YorozuWire/Sources/YorozuWire/WireV3.swift byte for byte.
 */
import {
  createCipheriv,
  createDecipheriv,
  createHash,
  createHmac,
  createPrivateKey,
  createPublicKey,
  diffieHellman,
  randomBytes,
  sign,
  verify,
  type KeyObject,
} from "node:crypto";

/** First byte of every v3 frame. A v2 payload is JSON and starts with `{`. */
export const WIRE_VERSION = 3;
export const PROTOCOL_NAME = "Noise_IK_25519_ChaChaPoly_SHA256";
/** A session is named on the wire by the first 8 bytes of the client's ephemeral key. */
export const SID_BYTES = 8;
/** The largest transport counter either end sends or accepts. */
export const MAX_COUNTER = Number.MAX_SAFE_INTEGER;
/** A handshake whose `ts` is further than this from the host's clock is dropped: the relay replays up to 24 h late. */
export const HANDSHAKE_MAX_AGE_MS = 5 * 60_000;

export type Keypair = { privateKey: Buffer; publicKey: Buffer };

// DER wrappers around a raw 32-byte key (RFC 8410).
const X25519_PKCS8 = Buffer.from("302e020100300506032b656e04220420", "hex");
const X25519_SPKI = Buffer.from("302a300506032b656e032100", "hex");
const ED25519_PKCS8 = Buffer.from("302e020100300506032b657004220420", "hex");
const ED25519_SPKI = Buffer.from("302a300506032b6570032100", "hex");

const privateKey = (prefix: Buffer, raw: Uint8Array): KeyObject =>
  createPrivateKey({ key: Buffer.concat([prefix, raw]), format: "der", type: "pkcs8" });
const publicKey = (prefix: Buffer, raw: Uint8Array): KeyObject =>
  createPublicKey({ key: Buffer.concat([prefix, raw]), format: "der", type: "spki" });
const rawPublic = (key: KeyObject): Buffer =>
  (createPublicKey(key).export({ format: "der", type: "spki" }) as Buffer).subarray(12);

/** X25519 keypair; `privateKey` fixed only for known-answer vectors. */
export function x25519Keypair(priv: Uint8Array = randomBytes(32)): Keypair {
  return { privateKey: Buffer.from(priv), publicKey: rawPublic(privateKey(X25519_PKCS8, priv)) };
}

/** Ed25519 keypair (the relay identity); `privateKey` is the 32-byte seed. */
export function ed25519Keypair(priv: Uint8Array = randomBytes(32)): Keypair {
  return { privateKey: Buffer.from(priv), publicKey: rawPublic(privateKey(ED25519_PKCS8, priv)) };
}

export const dh = (priv: Uint8Array, pub: Uint8Array): Buffer =>
  diffieHellman({ privateKey: privateKey(X25519_PKCS8, priv), publicKey: publicKey(X25519_SPKI, pub) });

// MARK: base64url

const B64U = /^[A-Za-z0-9_-]*$/;
export const b64u = (bytes: Uint8Array): string => Buffer.from(bytes).toString("base64url");
/** Strict: null on anything but unpadded base64url (Node's own decoder skips bad characters). */
export function fromB64u(text: string): Buffer | null {
  if (!B64U.test(text) || text.length % 4 === 1) return null;
  return Buffer.from(text, "base64url");
}

// MARK: Relay identity and pairing (unchanged from v2)

/** Ed25519 over the relay `payload` string itself, base64url. */
export const signFrame = (signingPriv: Uint8Array, payload: string): string =>
  b64u(sign(null, Buffer.from(payload, "utf8"), privateKey(ED25519_PKCS8, signingPriv)));

export function verifyFrame(signingPub: Uint8Array, payload: string, sig: string): boolean {
  const signature = fromB64u(sig);
  if (!signature || signingPub.length !== 32) return false;
  try {
    return verify(null, Buffer.from(payload, "utf8"), publicKey(ED25519_SPKI, signingPub), signature);
  } catch {
    return false;
  }
}

const sha256 = (...parts: Uint8Array[]): Buffer => {
  const hash = createHash("sha256");
  for (const part of parts) hash.update(part);
  return hash.digest();
};

/** base64url sha256 of the host's Ed25519 key: the relay room. */
export const roomId = (hostSigningPub: Uint8Array): string => b64u(sha256(hostSigningPub));

/** `YorozuCrypto.helloProof`: what proves a client read the QR. `pub`/`spub` are its X25519 and Ed25519 keys, base64url. */
export const helloProof = (secret: string, pub: string, spub: string): string =>
  b64u(sha256(Buffer.from(`${secret}.${pub}.${spub}`, "utf8")));

/** `QrPayload.fingerprint`: the host X25519 key's first 8 bytes, uppercase hex in groups of two bytes. */
export const fingerprint = (hostStaticPub: Uint8Array): string =>
  (Buffer.from(hostStaticPub).subarray(0, 8).toString("hex").toUpperCase().match(/.{1,4}/g) ?? []).join(" ");

/** Binds the handshake to v3, the room and the client's Ed25519 key. */
export const prologue = (room: string, deviceSigningPub: Uint8Array): Buffer =>
  Buffer.from(`yorozu-v3|${room}|${b64u(deviceSigningPub)}`, "utf8");

// MARK: Noise (https://noiseprotocol.org/noise.html, revision 34), IK only

const hmac = (key: Uint8Array, data: Uint8Array): Buffer => createHmac("sha256", key).update(data).digest();

/** HKDF(ck, ikm) with two outputs, as in the Noise spec (section 4.3). */
function hkdf(ck: Uint8Array, ikm: Uint8Array): [Buffer, Buffer] {
  const temp = hmac(ck, ikm);
  const one = hmac(temp, Buffer.from([1]));
  return [one, hmac(temp, Buffer.concat([one, Buffer.from([2])]))];
}

/** 32 bits of zeros, then the counter little-endian. */
function nonce(n: number): Buffer {
  const out = Buffer.alloc(12);
  out.writeBigUInt64LE(BigInt(n), 4);
  return out;
}

function encrypt(key: Uint8Array, n: number, ad: Uint8Array, plaintext: Uint8Array): Buffer {
  const cipher = createCipheriv("chacha20-poly1305", key, nonce(n), { authTagLength: 16 });
  cipher.setAAD(ad, { plaintextLength: plaintext.length });
  return Buffer.concat([cipher.update(plaintext), cipher.final(), cipher.getAuthTag()]);
}

/** Null when the tag does not verify. */
function decrypt(key: Uint8Array, n: number, ad: Uint8Array, ciphertext: Uint8Array): Buffer | null {
  if (ciphertext.length < 16) return null;
  const body = ciphertext.subarray(0, ciphertext.length - 16);
  try {
    const decipher = createDecipheriv("chacha20-poly1305", key, nonce(n), { authTagLength: 16 });
    decipher.setAuthTag(ciphertext.subarray(ciphertext.length - 16));
    decipher.setAAD(ad, { plaintextLength: body.length });
    return Buffer.concat([decipher.update(body), decipher.final()]);
  } catch {
    return null;
  }
}

class HandshakeError extends Error {}

class SymmetricState {
  ck: Buffer;
  h: Buffer;
  k: Buffer | null = null;
  n = 0;

  constructor() {
    const name = Buffer.from(PROTOCOL_NAME, "utf8");
    this.h = name.length <= 32 ? Buffer.concat([name, Buffer.alloc(32 - name.length)]) : sha256(name);
    this.ck = this.h;
  }

  mixHash(data: Uint8Array): void {
    this.h = sha256(this.h, data);
  }

  mixKey(ikm: Uint8Array): void {
    [this.ck, this.k] = hkdf(this.ck, ikm);
    this.n = 0;
  }

  encryptAndHash(plaintext: Uint8Array): Buffer {
    const c = this.k ? encrypt(this.k, this.n++, this.h, plaintext) : Buffer.from(plaintext);
    this.mixHash(c);
    return c;
  }

  decryptAndHash(ciphertext: Uint8Array): Buffer {
    let p: Buffer = Buffer.from(ciphertext);
    if (this.k) {
      const opened = decrypt(this.k, this.n, this.h, ciphertext);
      if (!opened) throw new HandshakeError("decrypt");
      this.n++;
      p = opened;
    }
    this.mixHash(ciphertext);
    return p;
  }
}

/**
 * One Noise IK handshake (`<- s ... -> e, es, s, ss  <- e, ee, se`), either role. The plugin only ever runs the
 * responder; the initiator is here so the contract's vectors can be reproduced end to end in TypeScript.
 */
export class NoiseIK {
  private readonly state = new SymmetricState();
  private e: Keypair | null = null;
  private re: Buffer | null = null;
  private step = 0;
  /** The peer's static key: given to the initiator, learned by the responder from message 1. */
  remoteStatic: Buffer | null;
  readonly role: "initiator" | "responder";
  private readonly s: Keypair;
  private readonly ephemeral: Uint8Array | undefined;

  /** `ephemeral`: a fixed ephemeral private key, for known-answer vectors only. */
  constructor(
    role: "initiator" | "responder",
    s: Keypair,
    remoteStatic: Uint8Array | null,
    prologueBytes: Uint8Array,
    ephemeral?: Uint8Array,
  ) {
    this.role = role;
    this.s = s;
    this.ephemeral = ephemeral;
    this.remoteStatic = remoteStatic ? Buffer.from(remoteStatic) : null;
    this.state.mixHash(prologueBytes);
    const responderStatic = role === "initiator" ? this.remoteStatic : s.publicKey;
    if (responderStatic?.length !== 32) throw new HandshakeError("responder static key");
    this.state.mixHash(responderStatic);
  }

  get handshakeHash(): Buffer {
    return this.state.h;
  }

  /** Initiator: message 1. Responder: message 2, after reading message 1. */
  writeMessage(payload: Uint8Array): Buffer {
    if (this.step !== (this.role === "initiator" ? 0 : 1)) throw new HandshakeError("out of order");
    const e = (this.e = x25519Keypair(this.ephemeral));
    this.state.mixHash(e.publicKey);
    const out = [e.publicKey];
    const rs = this.remoteStatic;
    if (this.role === "initiator") {
      if (!rs) throw new HandshakeError("responder static key");
      this.state.mixKey(dh(e.privateKey, rs)); // es
      out.push(this.state.encryptAndHash(this.s.publicKey)); // s
      this.state.mixKey(dh(this.s.privateKey, rs)); // ss
    } else {
      if (!this.re || !rs) throw new HandshakeError("out of order");
      this.state.mixKey(dh(e.privateKey, this.re)); // ee
      this.state.mixKey(dh(e.privateKey, rs)); // se
    }
    out.push(this.state.encryptAndHash(payload));
    this.step++;
    return Buffer.concat(out);
  }

  /** Responder: message 1. Initiator: message 2. Returns the payload; throws on a message that does not verify. */
  readMessage(message: Uint8Array): Buffer {
    if (this.step !== (this.role === "responder" ? 0 : 1)) throw new HandshakeError("out of order");
    const minimum = this.role === "responder" ? 32 + 48 + 16 : 32 + 16;
    if (message.length < minimum || message.length > 65_535) throw new HandshakeError("length");
    const re = (this.re = Buffer.from(message.subarray(0, 32)));
    this.state.mixHash(re);
    let rest = message.subarray(32);
    if (this.role === "responder") {
      this.state.mixKey(dh(this.s.privateKey, re)); // es
      const rs = this.state.decryptAndHash(rest.subarray(0, 48)); // s
      rest = rest.subarray(48);
      this.remoteStatic = rs;
      this.state.mixKey(dh(this.s.privateKey, rs)); // ss
    } else {
      if (!this.e) throw new HandshakeError("out of order");
      this.state.mixKey(dh(this.e.privateKey, re)); // ee
      this.state.mixKey(dh(this.s.privateKey, re)); // se
    }
    const payload = this.state.decryptAndHash(rest);
    this.step++;
    return payload;
  }

  /** After both messages: the session, with this role's send and receive keys. */
  split(sid: Uint8Array): Session {
    if (this.step !== 2) throw new HandshakeError("not finished");
    const [k1, k2] = hkdf(this.state.ck, Buffer.alloc(0));
    return this.role === "initiator"
      ? new Session(sid, this.state.h, k1, k2)
      : new Session(sid, this.state.h, k2, k1);
  }
}

// MARK: Frames

/** What goes base64url inside the relay's `payload`. Byte 0 is `WIRE_VERSION`, byte 1 the type. */
export type Frame =
  /** Type 1, client -> host: the client's Ed25519 key, then Noise message 1. */
  | { type: "init"; deviceSigningKey: Buffer; message: Buffer }
  /** Type 2, host -> client: the session id, then Noise message 2. */
  | { type: "response"; sid: Buffer; message: Buffer }
  /** Type 3, either way: session id, counter (8 bytes little-endian), ciphertext and tag. */
  | { type: "box"; sid: Buffer; counter: number; ciphertext: Buffer };

export const frameSid = (frame: Frame): Buffer =>
  frame.type === "init" ? frame.message.subarray(0, SID_BYTES) : frame.sid;

/** The relay `payload` string. */
export function encodeFrame(frame: Frame): string {
  const head = Buffer.from([WIRE_VERSION, { init: 1, response: 2, box: 3 }[frame.type]]);
  if (frame.type === "init") return b64u(Buffer.concat([head, frame.deviceSigningKey, frame.message]));
  if (frame.type === "response") return b64u(Buffer.concat([head, frame.sid, frame.message]));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64LE(BigInt(frame.counter));
  return b64u(Buffer.concat([head, frame.sid, counter, frame.ciphertext]));
}

/** Null on anything that is not a well-formed v3 frame, a v2 payload included. */
export function decodeFrame(payload: string): Frame | null {
  const b = fromB64u(payload);
  if (!b || b.length < 2 || b[0] !== WIRE_VERSION) return null;
  const body = b.subarray(2);
  if (b[1] === 1 && body.length >= 32 + 96 && body.length <= 32 + 65_535) {
    return { type: "init", deviceSigningKey: body.subarray(0, 32), message: body.subarray(32) };
  }
  if (b[1] === 2 && body.length >= SID_BYTES + 48 && body.length <= SID_BYTES + 65_535) {
    return { type: "response", sid: body.subarray(0, SID_BYTES), message: body.subarray(SID_BYTES) };
  }
  if (b[1] === 3 && body.length >= SID_BYTES + 8 + 16) {
    const counter = body.readBigUInt64LE(SID_BYTES);
    if (counter > BigInt(MAX_COUNTER)) return null;
    return {
      type: "box",
      sid: body.subarray(0, SID_BYTES),
      counter: Number(counter),
      ciphertext: body.subarray(SID_BYTES + 8),
    };
  }
  return null;
}

// MARK: Sessions

/** One connection's transport keys. Never stored: a new client socket means a new handshake. */
export class Session {
  /** The counter the next sealed box takes; starts at 0. */
  sendCounter = 0;
  /** The highest counter accepted so far, -1 before the first box. */
  lastReceived = -1;

  readonly sid: Buffer;
  readonly handshakeHash: Buffer;
  private readonly sendKey: Buffer;
  private readonly recvKey: Buffer;

  constructor(sid: Uint8Array, handshakeHash: Buffer, sendKey: Buffer, recvKey: Buffer) {
    this.sid = Buffer.from(sid);
    this.handshakeHash = handshakeHash;
    this.sendKey = sendKey;
    this.recvKey = recvKey;
  }

  /** Noise's ENCRYPT(k, n, ad = empty, plaintext) with `n` carried on the wire. Returns the relay `payload`. */
  seal(plaintext: Uint8Array): string {
    if (this.sendCounter > MAX_COUNTER) throw new Error("session exhausted");
    const counter = this.sendCounter++;
    return encodeFrame({
      type: "box",
      sid: this.sid,
      counter,
      ciphertext: encrypt(this.sendKey, counter, Buffer.alloc(0), plaintext),
    });
  }

  /**
   * The plaintext of a box for this session whose counter is beyond the last accepted one, else null: another
   * session's box, a replay, or a bad tag. Gaps are allowed; a failed box never moves the counter.
   */
  open(frame: Frame): Buffer | null {
    if (frame.type !== "box" || !this.sid.equals(frame.sid) || frame.counter <= this.lastReceived) {
      return null;
    }
    const plaintext = decrypt(this.recvKey, frame.counter, Buffer.alloc(0), frame.ciphertext);
    if (plaintext) this.lastReceived = frame.counter;
    return plaintext;
  }
}

/** What message 1 carries, encrypted to the host's static key. */
export type HandshakePayload = { ts: number; proof?: string };

export type AcceptedHandshake = {
  /** base64url, the key to keep the session under. */
  sid: string;
  deviceSigningKey: Buffer;
  /** The client's X25519 static key, authenticated by the handshake. */
  deviceStatic: Buffer;
  payload: HandshakePayload;
  /** The `response` frame, as the relay `payload` to sign and send. */
  response: string;
  session: Session;
};

/**
 * Host: answers one `init` frame, or returns null for anything that is not a fresh, valid v3 handshake from the
 * key that signed it. The caller still decides whether to serve the device (a stored device whose
 * `deviceSigningKey` and `deviceStatic` both match, or a pending pairing whose `helloProof` matches
 * `payload.proof`), drops a `sid` it has already answered within `HANDSHAKE_MAX_AGE_MS`, and only then sends
 * `response`. `ephemeral` is fixed for known-answer vectors only.
 */
export function acceptHandshake(opts: {
  host: Keypair;
  room: string;
  payload: string;
  sig: string;
  now?: number;
  ephemeral?: Uint8Array;
}): AcceptedHandshake | null {
  const frame = decodeFrame(opts.payload);
  if (frame?.type !== "init" || !verifyFrame(frame.deviceSigningKey, opts.payload, opts.sig)) return null;
  try {
    const noise = new NoiseIK("responder", opts.host, null, prologue(opts.room, frame.deviceSigningKey), opts.ephemeral);
    const payload = parseHandshakePayload(noise.readMessage(frame.message));
    const now = opts.now ?? Date.now();
    if (!payload || Math.abs(now - payload.ts) > HANDSHAKE_MAX_AGE_MS || !noise.remoteStatic) return null;
    const sid = frameSid(frame);
    const message = noise.writeMessage(Buffer.alloc(0));
    return {
      sid: b64u(sid),
      deviceSigningKey: frame.deviceSigningKey,
      deviceStatic: noise.remoteStatic,
      payload,
      response: encodeFrame({ type: "response", sid, message }),
      session: noise.split(sid),
    };
  } catch {
    // A low-order point, a message that does not verify: the same as any stranger's frame.
    return null;
  }
}

function parseHandshakePayload(bytes: Buffer): HandshakePayload | null {
  try {
    const value: unknown = JSON.parse(bytes.toString("utf8"));
    if (typeof value !== "object" || value === null) return null;
    const { ts, proof } = value as Record<string, unknown>;
    if (!Number.isSafeInteger(ts) || (proof !== undefined && typeof proof !== "string")) return null;
    return proof === undefined ? { ts: ts as number } : { ts: ts as number, proof };
  } catch {
    return null;
  }
}

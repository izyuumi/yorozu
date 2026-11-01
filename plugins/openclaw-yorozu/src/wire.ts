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

// A frame leads with its type byte. Clients before 0.11 lead with the old version byte 3, then 1, 2 or 3;
// each session answers in the format its init frame used, until the plugin drops the old one.
export const LEGACY_VERSION = 3;
const FRAME_TYPE = { init: 0x11, response: 0x12, box: 0x13 } as const;
export const PROTOCOL_NAME = "Noise_IK_25519_ChaChaPoly_SHA256";
export const SID_BYTES = 8;
export const MAX_COUNTER = Number.MAX_SAFE_INTEGER;
export const HANDSHAKE_MAX_AGE_MS = 5 * 60_000;

export type Keypair = { privateKey: Buffer; publicKey: Buffer };

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

export function x25519Keypair(priv: Uint8Array = randomBytes(32)): Keypair {
  return { privateKey: Buffer.from(priv), publicKey: rawPublic(privateKey(X25519_PKCS8, priv)) };
}

export function ed25519Keypair(priv: Uint8Array = randomBytes(32)): Keypair {
  return { privateKey: Buffer.from(priv), publicKey: rawPublic(privateKey(ED25519_PKCS8, priv)) };
}

export const dh = (priv: Uint8Array, pub: Uint8Array): Buffer =>
  diffieHellman({ privateKey: privateKey(X25519_PKCS8, priv), publicKey: publicKey(X25519_SPKI, pub) });

const B64U = /^[A-Za-z0-9_-]*$/;
export const b64u = (bytes: Uint8Array): string => Buffer.from(bytes).toString("base64url");
export function fromB64u(text: string): Buffer | null {
  if (!B64U.test(text) || text.length % 4 === 1) return null;
  return Buffer.from(text, "base64url");
}

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

export const roomId = (hostSigningPub: Uint8Array): string => b64u(sha256(hostSigningPub));

export const helloProof = (secret: string, pub: string, spub: string): string =>
  b64u(sha256(Buffer.from(`${secret}.${pub}.${spub}`, "utf8")));

export const fingerprint = (hostStaticPub: Uint8Array): string =>
  (Buffer.from(hostStaticPub).subarray(0, 8).toString("hex").toUpperCase().match(/.{1,4}/g) ?? []).join(" ");

export const prologue = (room: string, deviceSigningPub: Uint8Array, legacy = false): Buffer =>
  Buffer.from(`${legacy ? "yorozu-v3" : "yorozu"}|${room}|${b64u(deviceSigningPub)}`, "utf8");

const hmac = (key: Uint8Array, data: Uint8Array): Buffer => createHmac("sha256", key).update(data).digest();

function hkdf(ck: Uint8Array, ikm: Uint8Array): [Buffer, Buffer] {
  const temp = hmac(ck, ikm);
  const one = hmac(temp, Buffer.from([1]));
  return [one, hmac(temp, Buffer.concat([one, Buffer.from([2])]))];
}

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

export class NoiseIK {
  private readonly state = new SymmetricState();
  private e: Keypair | null = null;
  private re: Buffer | null = null;
  private step = 0;
  remoteStatic: Buffer | null;
  readonly role: "initiator" | "responder";
  private readonly s: Keypair;
  private readonly ephemeral: Uint8Array | undefined;

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

  writeMessage(payload: Uint8Array): Buffer {
    if (this.step !== (this.role === "initiator" ? 0 : 1)) throw new HandshakeError("out of order");
    const e = (this.e = x25519Keypair(this.ephemeral));
    this.state.mixHash(e.publicKey);
    const out = [e.publicKey];
    const rs = this.remoteStatic;
    if (this.role === "initiator") {
      if (!rs) throw new HandshakeError("responder static key");
      this.state.mixKey(dh(e.privateKey, rs));
      out.push(this.state.encryptAndHash(this.s.publicKey));
      this.state.mixKey(dh(this.s.privateKey, rs));
    } else {
      if (!this.re || !rs) throw new HandshakeError("out of order");
      this.state.mixKey(dh(e.privateKey, this.re));
      this.state.mixKey(dh(e.privateKey, rs));
    }
    out.push(this.state.encryptAndHash(payload));
    this.step++;
    return Buffer.concat(out);
  }

  readMessage(message: Uint8Array): Buffer {
    if (this.step !== (this.role === "responder" ? 0 : 1)) throw new HandshakeError("out of order");
    const minimum = this.role === "responder" ? 32 + 48 + 16 : 32 + 16;
    if (message.length < minimum || message.length > 65_535) throw new HandshakeError("length");
    const re = (this.re = Buffer.from(message.subarray(0, 32)));
    this.state.mixHash(re);
    let rest = message.subarray(32);
    if (this.role === "responder") {
      this.state.mixKey(dh(this.s.privateKey, re));
      const rs = this.state.decryptAndHash(rest.subarray(0, 48));
      rest = rest.subarray(48);
      this.remoteStatic = rs;
      this.state.mixKey(dh(this.s.privateKey, rs));
    } else {
      if (!this.e) throw new HandshakeError("out of order");
      this.state.mixKey(dh(this.e.privateKey, re));
      this.state.mixKey(dh(this.s.privateKey, re));
    }
    const payload = this.state.decryptAndHash(rest);
    this.step++;
    return payload;
  }

  split(sid: Uint8Array): Session {
    if (this.step !== 2) throw new HandshakeError("not finished");
    const [k1, k2] = hkdf(this.state.ck, Buffer.alloc(0));
    return this.role === "initiator"
      ? new Session(sid, this.state.h, k1, k2)
      : new Session(sid, this.state.h, k2, k1);
  }
}

export type Frame = { legacy?: boolean } & (
  | { type: "init"; deviceSigningKey: Buffer; message: Buffer }
  | { type: "response"; sid: Buffer; message: Buffer }
  | { type: "box"; sid: Buffer; counter: number; ciphertext: Buffer }
);

export const frameSid = (frame: Frame): Buffer =>
  frame.type === "init" ? frame.message.subarray(0, SID_BYTES) : frame.sid;

export function encodeFrame(frame: Frame): string {
  const head = Buffer.from(
    frame.legacy ? [LEGACY_VERSION, { init: 1, response: 2, box: 3 }[frame.type]] : [FRAME_TYPE[frame.type]],
  );
  if (frame.type === "init") return b64u(Buffer.concat([head, frame.deviceSigningKey, frame.message]));
  if (frame.type === "response") return b64u(Buffer.concat([head, frame.sid, frame.message]));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64LE(BigInt(frame.counter));
  return b64u(Buffer.concat([head, frame.sid, counter, frame.ciphertext]));
}

export function decodeFrame(payload: string): Frame | null {
  const b = fromB64u(payload);
  if (!b || b.length < 2) return null;
  const legacy = b.readUInt8(0) === LEGACY_VERSION;
  const type = legacy ? b.readUInt8(1) : b.readUInt8(0) - 0x10;
  const body = b.subarray(legacy ? 2 : 1);
  if (type === 1 && body.length >= 32 + 96 && body.length <= 32 + 65_535) {
    return { legacy, type: "init", deviceSigningKey: body.subarray(0, 32), message: body.subarray(32) };
  }
  if (type === 2 && body.length >= SID_BYTES + 48 && body.length <= SID_BYTES + 65_535) {
    return { legacy, type: "response", sid: body.subarray(0, SID_BYTES), message: body.subarray(SID_BYTES) };
  }
  if (type === 3 && body.length >= SID_BYTES + 8 + 16) {
    const counter = body.readBigUInt64LE(SID_BYTES);
    if (counter > BigInt(MAX_COUNTER)) return null;
    return {
      legacy,
      type: "box",
      sid: body.subarray(0, SID_BYTES),
      counter: Number(counter),
      ciphertext: body.subarray(SID_BYTES + 8),
    };
  }
  return null;
}

export class Session {
  sendCounter = 0;
  lastReceived = -1;
  legacy = false;

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

  seal(plaintext: Uint8Array): string {
    if (this.sendCounter > MAX_COUNTER) throw new Error("session exhausted");
    const counter = this.sendCounter++;
    return encodeFrame({
      legacy: this.legacy,
      type: "box",
      sid: this.sid,
      counter,
      ciphertext: encrypt(this.sendKey, counter, Buffer.alloc(0), plaintext),
    });
  }

  open(frame: Frame): Buffer | null {
    if (frame.type !== "box" || !!frame.legacy !== this.legacy || !this.sid.equals(frame.sid) || frame.counter <= this.lastReceived) {
      return null;
    }
    const plaintext = decrypt(this.recvKey, frame.counter, Buffer.alloc(0), frame.ciphertext);
    if (plaintext) this.lastReceived = frame.counter;
    return plaintext;
  }
}

export type HandshakePayload = { ts: number; proof?: string };

export type AcceptedHandshake = {
  sid: string;
  deviceSigningKey: Buffer;
  deviceStatic: Buffer;
  payload: HandshakePayload;
  response: string;
  session: Session;
};

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
    const noise = new NoiseIK("responder", opts.host, null, prologue(opts.room, frame.deviceSigningKey, frame.legacy), opts.ephemeral);
    const payload = parseHandshakePayload(noise.readMessage(frame.message));
    const now = opts.now ?? Date.now();
    if (!payload || Math.abs(now - payload.ts) > HANDSHAKE_MAX_AGE_MS || !noise.remoteStatic) return null;
    const sid = frameSid(frame);
    const message = noise.writeMessage(Buffer.alloc(0));
    const session = noise.split(sid);
    session.legacy = !!frame.legacy;
    return {
      sid: b64u(sid),
      deviceSigningKey: frame.deviceSigningKey,
      deviceStatic: noise.remoteStatic,
      payload,
      response: encodeFrame({ legacy: frame.legacy, type: "response", sid, message }),
      session,
    };
  } catch {
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

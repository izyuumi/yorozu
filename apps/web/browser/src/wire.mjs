import { chacha20poly1305 } from '@noble/ciphers/chacha.js';

const encoder = new TextEncoder();
export const utf8 = (s) => encoder.encode(s);
const decoder = new TextDecoder('utf-8', { fatal: true });
const cryptoAPI = () => globalThis.crypto.subtle;

function bytes(...parts) {
  const result = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.length;
  }
  return result;
}

export function b64(value) {
  let text = '';
  for (let i = 0; i < value.length; i += 8192) text += String.fromCharCode(...value.subarray(i, i + 8192));
  return btoa(text).replaceAll('+', '-').replaceAll('/', '_').replace(/=+$/, '');
}
export function unb64(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]+$/.test(value) || value.length % 4 === 1) {
    throw new Error('Invalid base64url');
  }
  const decoded = Uint8Array.from(atob(value.replaceAll('-', '+').replaceAll('_', '/')), (s) => s.charCodeAt(0));
  if (b64(decoded) !== value) throw new Error('Invalid base64url');
  return decoded;
}

async function hash(...parts) {
  return new Uint8Array(await cryptoAPI().digest('SHA-256', bytes(...parts)));
}

async function hkdf(salt, material) {
  const hmac = async (key, data) => {
    const imported = await cryptoAPI().importKey('raw', key, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
    return new Uint8Array(await cryptoAPI().sign('HMAC', imported, data));
  };
  const temp = await hmac(salt, material);
  const first = await hmac(temp, Uint8Array.of(1));
  return [first, await hmac(temp, bytes(first, Uint8Array.of(2)))];
}

async function dh(key, remote) {
  const publicKey = await cryptoAPI().importKey('raw', remote, 'X25519', false, []);
  return new Uint8Array(await cryptoAPI().deriveBits({ name: 'X25519', public: publicKey }, key, 256));
}

async function x25519() {
  return cryptoAPI().generateKey('X25519', false, ['deriveBits']);
}

const raw = async (key) => new Uint8Array(await cryptoAPI().exportKey('raw', key));

export async function makeIdentity(browser = false) {
  if (browser) {
    const signing = await cryptoAPI().generateKey('Ed25519', false, ['sign', 'verify']);
    return { signingPrivate: signing.privateKey, signingPublic: await raw(signing.publicKey) };
  }
  const [noise, signing] = await Promise.all([
    x25519(),
    cryptoAPI().generateKey('Ed25519', false, ['sign', 'verify']),
  ]);
  return {
    noisePrivate: noise.privateKey, noisePublic: await raw(noise.publicKey),
    signingPrivate: signing.privateKey, signingPublic: await raw(signing.publicKey),
  };
}

export async function signText(identity, text) {
  return b64(new Uint8Array(await cryptoAPI().sign('Ed25519', identity.signingPrivate, utf8(text))));
}

function nonce(counter) {
  const value = new Uint8Array(12);
  new DataView(value.buffer).setBigUint64(4, BigInt(counter), true);
  return value;
}

function symmetric(seed) {
  let ck = seed, h = seed, k, n;
  const mixHash = async (data) => { h = await hash(h, data); };
  return {
    mixHash,
    async mixKey(input) { [ck, k] = await hkdf(ck, input); n = 0; },
    async seal(data) {
      const ciphertext = chacha20poly1305(k, nonce(n++), h).encrypt(data);
      await mixHash(ciphertext);
      return ciphertext;
    },
    async open(data) {
      const clear = chacha20poly1305(k, nonce(n++), h).decrypt(data);
      await mixHash(data);
      return clear;
    },
    split: () => hkdf(ck, new Uint8Array()),
  };
}

export async function beginHandshake(pairing, { now = Date.now(), ephemeral } = {}) {
  const { hostKey, room, secret, browser } = pairing;
  let { identity } = pairing;
  if (browser) {
    const noise = await x25519();
    identity = { ...identity, noisePrivate: noise.privateKey, noisePublic: await raw(noise.publicKey) };
  }
  const head = browser ? 1 : 2;
  const prefix = browser ? Uint8Array.of(0x21) : Uint8Array.of(3, 1);
  const e = ephemeral ?? await x25519();
  const ePublic = await raw(e.publicKey);
  const state = symmetric(utf8('Noise_IK_25519_ChaChaPoly_SHA256'));
  await state.mixHash(utf8(`${browser ? "yorozu-browser-v1" : "yorozu-v3"}|${room}|${b64(identity.signingPublic)}`));
  await state.mixHash(hostKey);
  await state.mixHash(ePublic);
  await state.mixKey(await dh(e.privateKey, hostKey));
  const encryptedStatic = await state.seal(identity.noisePublic);
  await state.mixKey(await dh(identity.noisePrivate, hostKey));
  const hello = { ts: now };
  if (secret) hello.proof = b64(await hash(utf8(`${secret}.${b64(identity.noisePublic)}.${b64(identity.signingPublic)}`)));
  const encryptedHello = await state.seal(utf8(JSON.stringify(hello)));
  const sid = ePublic.subarray(0, 8);
  let responseStarted = false;
  return {
    init: b64(bytes(prefix, identity.signingPublic, ePublic, encryptedStatic, encryptedHello)),
    async finish(frame) {
      if (responseStarted || frame.length < 56 + head || frame.length > 65543 + head ||
          !(browser ? frame[0] === 0x12 : frame[0] === 3 && frame[1] === 2) || !sid.every((v, i) => v === frame[i + head])) return;
      responseStarted = true;
      const remote = frame.subarray(head + 8, head + 40);
      await state.mixHash(remote);
      await state.mixKey(await dh(e.privateKey, remote));
      await state.mixKey(await dh(identity.noisePrivate, remote));
      await state.open(frame.subarray(head + 40));
      const [send, recv] = await state.split();
      return session(sid, send, recv, browser);
    },
  };
}

function session(sid, sendKey, receiveKey, browser) {
  const prefix = browser ? Uint8Array.of(0x13) : Uint8Array.of(3, 3);
  const head = prefix.length;
  let send = 0, received = -1;
  return {
    seal(event) {
      if (!Number.isSafeInteger(send)) throw new Error('Session counter exhausted');
      const counter = nonce(send++);
      const ciphertext = chacha20poly1305(sendKey, counter).encrypt(utf8(JSON.stringify(event)));
      return b64(bytes(prefix, sid, counter.subarray(4), ciphertext));
    },
    open(frame) {
      if (frame.length < 32 + head || !prefix.every((v, i) => v === frame[i]) ||
          !sid.every((v, i) => v === frame[i + head])) return;
      const counter = Number(new DataView(frame.buffer, frame.byteOffset, frame.byteLength).getBigUint64(head + 8, true));
      if (!Number.isSafeInteger(counter) || counter <= received) return;
      try {
        const clear = chacha20poly1305(receiveKey, nonce(counter)).decrypt(frame.subarray(head + 16));
        received = counter;
        return JSON.parse(decoder.decode(clear));
      } catch {
        return;
      }
    },
  };
}

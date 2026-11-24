import { chacha20poly1305 } from '@noble/ciphers/chacha.js';
import { b64, unb64, utf8 } from './wire.mjs';

const lifetime = 10 * 60_000;
const decoder = new TextDecoder('utf-8', { fatal: true });

export async function openDeviceLetter(value, privateKey, recipient) {
  if (typeof value !== 'string' || value.length > 4096) throw new Error('Invalid letter');
  const letter = unb64(value);
  if (letter.length <= 60) throw new Error('Invalid letter');
  const sender = letter.subarray(0, 32);
  const nonce = letter.subarray(32, 44);
  const remote = await crypto.subtle.importKey('raw', sender, 'X25519', false, []);
  const shared = await crypto.subtle.deriveBits({ name: 'X25519', public: remote }, privateKey, 256);
  const secret = await crypto.subtle.importKey('raw', shared, 'HKDF', false, ['deriveBits']);
  const salt = new Uint8Array(64);
  salt.set(sender);
  salt.set(recipient, 32);
  const bytes = await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info: utf8('yorozu-device-code') }, secret, 256);
  return decoder.decode(chacha20poly1305(new Uint8Array(bytes), nonce).decrypt(letter.subarray(44)));
}

export async function listenForDeviceCode(relay, { signal, onReady }) {
  signal.throwIfAborted();
  const keys = await crypto.subtle.generateKey('X25519', false, ['deriveBits']);
  const recipient = new Uint8Array(await crypto.subtle.exportKey('raw', keys.publicKey));
  signal.throwIfAborted();
  const box = b64(crypto.getRandomValues(new Uint8Array(16)));
  const mailbox = new URL('/mailbox/' + box, relay);
  const request = new URL('https://yorozu.yumi.to/add');
  request.hash = new URLSearchParams({
    v: '2', target: 'browser', relay, box, key: b64(recipient), name: 'Yorozu Web',
  }).toString();
  return new Promise((resolve, reject) => {
    const socket = new WebSocket(mailbox);
    let busy = false, complete = false, timer;
    const finish = (error, invite) => {
      if (complete) return;
      complete = true;
      clearTimeout(timer);
      signal.removeEventListener('abort', cancel);
      socket.onopen = socket.onmessage = socket.onerror = socket.onclose = null;
      if (socket.readyState < WebSocket.CLOSING) socket.close();
      if (error) reject(error);
      else resolve(invite);
    };
    const cancel = () => finish(signal.reason || new DOMException('Cancelled', 'AbortError'));
    signal.addEventListener('abort', cancel, { once: true });
    if (signal.aborted) { cancel(); return; }
    timer = setTimeout(() => finish(new Error('Couldn’t open the pairing relay. Try a new code.')), 12_000);
    socket.onopen = () => {
      clearTimeout(timer);
      timer = setTimeout(() => finish(new Error('This code expired.')), lifetime);
      onReady({ link: request.href, expiresAt: Date.now() + lifetime });
    };
    socket.onmessage = async ({ data }) => {
      if (busy) return;
      busy = true;
      try { finish(null, await openDeviceLetter(data, keys.privateKey, recipient)); }
      catch { finish(new Error('This pairing response couldn’t be verified. Try a new code.')); }
    };
    socket.onerror = socket.onclose = () => finish(new Error('Lost the pairing relay connection. Try a new code.'));
  });
}

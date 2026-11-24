import { unb64 } from './wire.mjs';

const officialRelay = 'wss://relay.yumi.to/';
export function parsePairing(value, allowedRelay = officialRelay) {
  if (value.length > 4096 || /%(?![a-fA-F0-9]{2})/.test(value)) throw new Error('Invalid link');
  const url = new URL(value.trim());
  if (url.username || url.password || url.port) throw new Error('Invalid link');
  let encoded;
  if (url.protocol === 'yorozu:' && url.hostname === 'pair' && ['', '/'].includes(url.pathname) && !url.hash) {
    encoded = url.search.slice(1);
  } else if (url.origin === 'https://yorozu.yumi.to' && ['/pair', '/pair/'].includes(url.pathname) && !url.search) {
    encoded = url.hash.slice(1);
  } else throw new Error('Invalid link');
  const query = new URLSearchParams(encoded);
  const get = (name) => {
    const all = query.getAll(name);
    if (all.length !== 1) throw new Error('Invalid link');
    return all[0];
  };
  if (query.has('v') && get('v') !== '3') throw new Error('Invalid link version');
  const relay = new URL(get('relay')).href;
  if (relay !== allowedRelay) throw new Error('Unsupported relay');
  const token = get('token'), secret = get('secret'), room = get('room'), hostKey = unb64(get('key'));
  if (hostKey.length !== 32 || unb64(room).length !== 32 || unb64(secret).length !== 32 || !unb64(token).length) {
    throw new Error('Invalid keys');
  }
  return { relay, token, secret, room, hostKey };
}

export function fingerprint(key) {
  return Array.from(key.subarray(0, 8), (digit) => digit.toString(16).padStart(2, '0')).join('').toUpperCase().match(/.{4}/g).join(' ');
}

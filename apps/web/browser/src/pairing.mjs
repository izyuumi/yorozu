import { unb64 } from './wire.mjs';

const mode = import.meta.env?.MODE;
const officialRelay = mode === "staging" || mode === "shared-preview" ? "wss://yorozu-browser-test-relay.yumi-f4f.workers.dev/" : "wss://relay.yumi.to/";
const previewOrigin = "https://yorozu-v4-staging.yumi-f4f.workers.dev";
const appOrigin = "https://app.yorozu.yumi.to";
const currentApp = mode === "shared-preview" ? "https://yorozu-shared-ui-preview.yumi-f4f.workers.dev" : mode === "staging" ? previewOrigin : appOrigin;
function normalize(value) {
  let text = value.trim();
  if (text.startsWith("```") && text.endsWith("```")) text = text.replace(/^```[^\r\n]*[\r\n]+/, "").slice(0,-3).trim();
  else if (text.startsWith("`") && text.endsWith("`")) text = text.slice(1,-1).trim();
  else if (text.startsWith("<") && text.endsWith(">")) text = text.slice(1,-1).trim();
  return text.replace(/[\s\u200b\ufeff]+/g,"");
}

export function parsePairing(value, allowedRelay = officialRelay, allowLegacy = false) {
  if (value.length > 8192 || /%(?![a-fA-F0-9]{2})/.test(value)) throw new Error('Invalid link');
  let url = new URL(normalize(value));
  if (url.username || url.password || url.port) throw new Error("Invalid link");
  if (url.origin === currentApp && url.pathname === "/" && !url.search) {
    const candidates = new URLSearchParams(url.hash.slice(1)).getAll("pair");
    if (candidates.length !== 1) throw new Error("Invalid browser invite");
    url = new URL(candidates[0]);
  }
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
  const version = query.has('v') ? get('v') : '3';
  if (version !== '4' && !(allowLegacy && version === '3')) throw new Error('Invalid link version');
  if (query.has("exp")) {
    const value = get("exp");
    if (!/^\d{1,16}$/.test(value) || !Number.isSafeInteger(Number(value))) throw new Error("Invalid expiry");
    if (Number(value) <= Date.now()) throw Object.assign(new Error("Expired invite"), {code:"expired"});
  }
  const relay = new URL(get('relay')).href;
  if (relay !== allowedRelay) throw new Error('Unsupported relay');
  const token = get('token'), secret = get('secret'), room = get('room'), hostKey = unb64(get('key'));
  if (hostKey.length !== 32 || unb64(room).length !== 32 || unb64(secret).length !== 32 || !unb64(token).length) {
    throw new Error('Invalid keys');
  }
  return { relay, token, secret, room, hostKey, browser: version === "4" };
}

export function fingerprint(key) {
  return Array.from(key.subarray(0, 8), (digit) => digit.toString(16).padStart(2, '0')).join('').toUpperCase().match(/.{4}/g).join(' ');
}

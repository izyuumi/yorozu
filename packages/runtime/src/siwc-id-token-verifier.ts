/** Concrete bounded RS256 verification; the injected official JWKS fetch and native
 * protected store/callback flow remain independent, unwired production seams. */
import { constants, createPublicKey, timingSafeEqual, verify as verifySignature, type KeyObject } from "node:crypto";
import { SIWC_ISSUER, SIWC_JWKS_URL, type SiwcIdTokenVerifier, type SiwcVerifiedIdClaims } from "./siwc-account-lifecycle.js";

export const SIWC_ID_VERIFIER_READINESS = Object.freeze({ productionReady: false, algorithm: "RS256" as const,
  nativeIntegration: "unwired" as const });
export type SiwcOfficialJwksFetch = (signal: AbortSignal) => Promise<{ status: number; body: unknown }>;
const client = (v: unknown): v is string => typeof v === "string" && /^oaiapp_[A-Za-z0-9_-]{1,128}$/.test(v);
const kid = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_.:-]{1,128}$/.test(v);
const subject = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_.:@|-]{1,256}$/.test(v);
const seconds = (v: unknown): v is number => Number.isSafeInteger(v) && (v as number) >= 0 && (v as number) <= Math.floor(Number.MAX_SAFE_INTEGER / 1000);
const object = (v: unknown): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v)
  && [Object.prototype, null].includes(Object.getPrototypeOf(v));
const fields = (v: unknown, keys: readonly string[]): v is Record<string, any> => object(v) && Object.keys(v).every(k => keys.includes(k));
function reject(): never { throw new Error("Invalid SIWC identity"); }
function base64url(v: unknown, maxBytes: number): Buffer {
  if (typeof v !== "string" || !v.length || v.length > Math.ceil(maxBytes * 4 / 3) || v.length % 4 === 1 || !/^[A-Za-z0-9_-]+$/.test(v)) reject();
  const bytes = Buffer.from(v, "base64url");
  if (bytes.length > maxBytes || bytes.toString("base64url") !== v) reject();
  return bytes;
}
/** JSON.parse alone silently accepts duplicate members. This bounded parser checks
 * every object/array and consumes the exact UTF-8 text, including escaped key aliases. */
function strictJson(bytes: Buffer): unknown {
  const source = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
  let index = 0, nodes = 0;
  const space = (): void => { while (/[\x20\t\r\n]/.test(source[index] ?? "!")) index++; };
  const string = (): string => {
    const start = index++; let escaped = false;
    while (index < source.length) {
      const c = source[index++];
      if (!escaped && c === '"') {
        const out = JSON.parse(source.slice(start, index));
        if (typeof out !== "string" || out.length > 24_576 || /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(out)) reject();
        return out;
      }
      if (!escaped && c === "\\") escaped = true; else escaped = false;
    }
    return reject();
  };
  const value = (depth: number): unknown => {
    space(); if (depth > 8 || ++nodes > 512) reject(); const c = source[index];
    if (c === '"') return string();
    if (c === "{") {
      index++; space(); const result: Record<string, unknown> = Object.create(null), seen = new Set<string>();
      if (source[index] === "}") { index++; return result; }
      while (true) {
        space(); if (source[index] !== '"') reject(); const key = string();
        if (seen.has(key) || seen.size >= 128 || ["__proto__", "constructor", "prototype"].includes(key)) reject(); seen.add(key);
        space(); if (source[index++] !== ":") reject(); result[key] = value(depth + 1); space();
        const separator = source[index++]; if (separator === "}") return result; if (separator !== ",") reject();
      }
    }
    if (c === "[") {
      index++; space(); const result: unknown[] = []; if (source[index] === "]") { index++; return result; }
      while (true) { if (result.length >= 128) reject(); result.push(value(depth + 1)); space();
        const separator = source[index++]; if (separator === "]") return result; if (separator !== ",") reject(); }
    }
    for (const [literal, decoded] of [["true", true], ["false", false], ["null", null]] as const) {
      if (source.startsWith(literal, index)) { index += literal.length; return decoded; }
    }
    const number = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(source.slice(index));
    if (!number) reject(); index += number[0].length; const n = Number(number[0]); if (!Number.isFinite(n)) reject(); return n;
  };
  const out = value(0); space(); if (index !== source.length) reject(); return out;
}
function claims(value: unknown, audience: string, nonce: string | undefined, now: number): SiwcVerifiedIdClaims {
  if (!object(value) || value.iss !== SIWC_ISSUER || !subject(value.sub) || !seconds(value.exp) || value.exp * 1000 <= now
    || !seconds(value.iat) || value.iat > value.exp || value.iat * 1000 > now + 5000
    || value.nbf !== undefined && (!seconds(value.nbf) || value.nbf > value.exp || value.nbf * 1000 > now + 5000)) reject();
  const audiences = typeof value.aud === "string" ? [value.aud] : value.aud;
  if (!Array.isArray(audiences) || !audiences.length || audiences.length > 8 || !audiences.every(client)
    || new Set(audiences).size !== audiences.length || !audiences.includes(audience)
    || audiences.length > 1 && value.azp !== audience || value.azp !== undefined && value.azp !== audience
    || value.nonce !== undefined && (typeof value.nonce !== "string" || !/^[A-Za-z0-9_-]{16,256}$/.test(value.nonce))) reject();
  if (nonce !== undefined && (typeof value.nonce !== "string" || Buffer.byteLength(value.nonce) !== Buffer.byteLength(nonce)
    || !timingSafeEqual(Buffer.from(value.nonce), Buffer.from(nonce)))) reject();
  // Only required, validated identity metadata leaves the verifier; arbitrary payload fields stay private.
  return Object.freeze({ iss: SIWC_ISSUER, aud: typeof value.aud === "string" ? value.aud : Object.freeze([...audiences]) as unknown as string[],
    sub: value.sub, exp: value.exp, iat: value.iat,
    ...(value.nonce === undefined ? {} : { nonce: value.nonce }), ...(value.azp === undefined ? {} : { azp: value.azp }) });
}
function signingKey(body: unknown, selectedKid: string): { jwk: { kty: string; n: string; e: string }; bytes: number } {
  if (!fields(body, ["keys"]) || !Array.isArray(body.keys) || !body.keys.length || body.keys.length > 32) reject();
  const seen = new Set<string>(); let selected: { jwk: { kty: string; n: string; e: string }; bytes: number } | undefined;
  for (const row of body.keys) {
    if (!fields(row, ["kty", "kid", "use", "alg", "key_ops", "n", "e"]) || !kid(row.kid) || seen.has(row.kid)
      || row.kty !== "RSA" || row.alg !== undefined && row.alg !== "RS256" || row.use !== undefined && row.use !== "sig"
      || row.key_ops !== undefined && (!Array.isArray(row.key_ops) || row.key_ops.length !== 1 || row.key_ops[0] !== "verify")) reject();
    seen.add(row.kid);
    const modulus = base64url(row.n, 1024), exponent = base64url(row.e, 4);
    if (!modulus.length || modulus[0] === 0 || modulus.at(-1)! % 2 === 0 || !exponent.length || exponent[0] === 0) reject();
    const bits = (modulus.length - 1) * 8 + (32 - Math.clz32(modulus[0]));
    let power = 0; for (const b of exponent) power = power * 256 + b;
    if (bits < 2048 || bits > 8192 || power < 3 || power % 2 !== 1) reject();
    if (row.kid === selectedKid) selected = { jwk: { kty: "RSA", n: row.n, e: row.e }, bytes: modulus.length };
  }
  if (!selected) reject(); return selected;
}
async function fetchBound(fetch: SiwcOfficialJwksFetch, signal: AbortSignal): Promise<{ status: number; body: unknown }> {
  const controller = new AbortController(), abort = (): void => controller.abort();
  signal.addEventListener("abort", abort, { once: true }); if (signal.aborted) abort();
  let timer: NodeJS.Timeout | undefined;
  try {
    if (controller.signal.aborted) reject();
    return await Promise.race([Promise.resolve().then(() => fetch(controller.signal)), new Promise<never>((_, fail) => {
      controller.signal.addEventListener("abort", () => fail(new Error("Unavailable SIWC keys")), { once: true });
      timer = setTimeout(abort, 30_000); timer.unref();
    })]);
  } finally { if (timer) clearTimeout(timer); signal.removeEventListener("abort", abort); controller.abort(); }
}
/** Each verification fetches the fixed official JWKS once; no stale-key cache, URL
 * discovery, redirect, fallback or automatic retry. Fetch callback owns bounded TLS/JSON. */
export function createSiwcIdTokenVerifier(fetchJwks?: SiwcOfficialJwksFetch, now: () => number = Date.now): SiwcIdTokenVerifier {
  const verifier: SiwcIdTokenVerifier = { async verify(input) {
    let header: Record<string, any>, payload: unknown, signature: Buffer, signed: string;
    try {
      if (!fields(input, ["idToken", "issuer", "jwksUrl", "audience", "nonce", "signal"]) || input.issuer !== SIWC_ISSUER
        || input.jwksUrl !== SIWC_JWKS_URL || !client(input.audience) || typeof input.idToken !== "string" || input.idToken.length > 32_768
        || input.nonce !== undefined && !/^[A-Za-z0-9_-]{32,128}$/.test(input.nonce) || !(input.signal instanceof AbortSignal)) reject();
      const parts = input.idToken.split("."); if (parts.length !== 3) reject();
      const parsed = strictJson(base64url(parts[0], 4096));
      if (!fields(parsed, ["alg", "kid", "typ"]) || parsed.alg !== "RS256" || !kid(parsed.kid)
        || parsed.typ !== undefined && parsed.typ !== "JWT") reject();
      header = parsed; payload = strictJson(base64url(parts[1], 24_576)); signature = base64url(parts[2], 1024); signed = parts[0] + "." + parts[1];
    } catch { return { status: "invalid" }; }
    if (typeof fetchJwks !== "function" || input.signal.aborted) return { status: "unavailable" };
    let response: { status: number; body: unknown };
    try { response = await fetchBound(fetchJwks, input.signal); if (response.status !== 200 || input.signal.aborted) return { status: "unavailable" }; }
    catch { return { status: "unavailable" }; }
    let selected: ReturnType<typeof signingKey>, key: KeyObject;
    try {
      selected = signingKey(response.body, header.kid); key = createPublicKey({ key: selected.jwk, format: "jwk" });
      if (key.type !== "public" || key.asymmetricKeyType !== "rsa" || !key.asymmetricKeyDetails?.modulusLength
        || key.asymmetricKeyDetails.modulusLength < 2048 || key.asymmetricKeyDetails.modulusLength > 8192) reject();
    } catch { return { status: "unavailable" }; } // Unsupported/ambiguous key evidence must not discard pending rotation.
    try {
      if (signature.length !== selected.bytes || !verifySignature("RSA-SHA256", Buffer.from(signed, "ascii"), { key, padding: constants.RSA_PKCS1_PADDING }, signature)) reject();
      const instant = now(); if (!Number.isSafeInteger(instant) || instant < 0 || input.signal.aborted) return { status: "unavailable" };
      return { status: "verified", claims: claims(payload, input.audience, input.nonce, instant) };
    } catch { return { status: "invalid" }; }
  } };
  return Object.freeze(verifier);
}

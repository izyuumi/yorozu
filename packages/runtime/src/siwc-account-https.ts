/** Host-only fixed OAuth/discovery/JWKS HTTP client. Never opens a browser or reads credentials.
 * Protocol: https://developers.openai.com/siwc/token-sharing-open-source/sign-in
 * TLS: https://nodejs.org/api/https.html https://nodejs.org/api/tls.html
 */
import { Agent, request as httpsRequest } from "node:https";
import { rootCertificates, checkServerIdentity } from "node:tls";
import type { ClientRequest, IncomingMessage } from "node:http";
import { SIWC_DISCOVERY_URL, SIWC_ISSUER, SIWC_JWKS_URL, SIWC_RESOURCE, SIWC_TOKEN_URL,
  SiwcAccountError, type SiwcAccountTransport } from "./siwc-account-lifecycle.js";

type Request = Parameters<SiwcAccountTransport["request"]>[0];
type Response = Awaited<ReturnType<SiwcAccountTransport["request"]>>;
const BYTE_LIMIT = 1024 * 1024;
const secret = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9._~-]{16,32768}$/.test(v);
const client = (v: unknown): v is string => typeof v === "string" && /^oaiapp_[A-Za-z0-9_-]{1,128}$/.test(v);
const fields = (v: unknown, keys: readonly string[]): v is Record<string, string> => !!v && typeof v === "object" && !Array.isArray(v)
  && Object.keys(v).every(k => keys.includes(k)) && Object.values(v).every(value => typeof value === "string");
const error = (): SiwcAccountError => new SiwcAccountError("unknown");
const unsupported = (): never => { throw new SiwcAccountError("unsupported"); };
function callback(uri: unknown): boolean {
  if (typeof uri !== "string") return false;
  try { const url = new URL(uri);
    return url.href === uri && url.protocol === "http:" && url.hostname === "127.0.0.1"
      && Number(url.port) >= 1024 && Number(url.port) <= 65535 && url.pathname === "/auth/callback"
      && !url.username && !url.password && !url.search && !url.hash;
  } catch { return false; }
}
function revocation(uri: unknown): string | undefined {
  if (typeof uri !== "string" || uri === SIWC_TOKEN_URL) return;
  try { const url = new URL(uri);
    if (url.href === uri && url.origin === SIWC_ISSUER && !url.username && !url.password && !url.search && !url.hash
      && /^\/api\/accounts\/oauth\/[a-z-]{1,32}$/.test(url.pathname)) return uri;
  } catch { /* No arbitrary discovery URL is followed. */ }
}
function tokenForm(form: Request["form"]): string {
  if (fields(form, ["grant_type", "client_id", "code", "code_verifier", "redirect_uri", "resource"])
    && form.grant_type === "authorization_code" && client(form.client_id) && form.resource === SIWC_RESOURCE
    && typeof form.code === "string" && form.code.length > 0 && form.code.length <= 4096 && !/[\x00-\x20\x7f]/.test(form.code)
    && /^[A-Za-z0-9._~-]{43,128}$/.test(form.code_verifier ?? "") && callback(form.redirect_uri)) return new URLSearchParams(form).toString();
  if (fields(form, ["grant_type", "client_id", "refresh_token", "resource"])
    && form.grant_type === "refresh_token" && client(form.client_id) && form.resource === SIWC_RESOURCE
    && secret(form.refresh_token)) return new URLSearchParams(form).toString();
  return unsupported();
}

export interface SiwcAccountHttps extends SiwcAccountTransport {
  /** Exact official JWKS GET; no token/query/header input. May be injected into the verifier. */
  fetchJwks(signal: AbortSignal): Promise<Response>;
}
/** Construction is inert. Dispatch is bounded, has no retries and never uses a shared Agent.
 * Revocation POST is enabled only by this instance's validated official discovery response.
 */
export function createSiwcAccountHttps(): SiwcAccountHttps {
  let active = 0, revocationUrl: string | undefined;
  const send = async (supplied: Request, jwks = false): Promise<Response> => {
    if (!supplied || Object.keys(supplied).some(k => !["url", "method", "form", "signal"].includes(k))
      || !(supplied.signal instanceof AbortSignal)) return unsupported();
    let body: string | undefined, kind: "token" | "discovery" | "jwks" | "revoke";
    if (supplied.method === "GET" && supplied.form === undefined && supplied.url === (jwks ? SIWC_JWKS_URL : SIWC_DISCOVERY_URL))
      kind = jwks ? "jwks" : "discovery";
    else if (!jwks && supplied.method === "POST" && supplied.url === SIWC_TOKEN_URL) { kind = "token"; body = tokenForm(supplied.form); }
    else if (!jwks && supplied.method === "POST" && revocationUrl && supplied.url === revocationUrl
      && fields(supplied.form, ["client_id", "token", "token_type_hint"]) && client(supplied.form.client_id)
      && secret(supplied.form.token) && supplied.form.token_type_hint === "refresh_token") {
      kind = "revoke"; body = new URLSearchParams(supplied.form).toString();
    } else return unsupported();
    if (body !== undefined && Buffer.byteLength(body) > 64 * 1024 || active >= 8 || supplied.signal.aborted) throw error();
    const { signal } = supplied, destination = new URL(supplied.url);
    active++;
    return new Promise<Response>((resolve, reject) => {
      let agent: Agent | undefined, request: ClientRequest | undefined, response: IncomingMessage | undefined, released = false;
      const cleanup = (): void => {
        if (released) return; released = true; active--;
        clearTimeout(timer); signal.removeEventListener("abort", stop);
        response?.destroy(); request?.destroy(); agent?.destroy();
      };
      const fail = (): void => { if (!released) { cleanup(); reject(error()); } };
      const stop = (): void => fail();
      const timer = setTimeout(stop, 30_000); timer.unref();
      signal.addEventListener("abort", stop, { once: true });
      if (signal.aborted) { fail(); return; }
      try {
        agent = new Agent({ keepAlive: false, maxSockets: 1, maxCachedSessions: 0, proxyEnv: {},
          ca: [...rootCertificates], rejectUnauthorized: true, servername: "auth.openai.com", checkServerIdentity });
        request = httpsRequest({ protocol: "https:", hostname: "auth.openai.com", port: 443, path: destination.pathname,
          method: supplied.method, agent, rejectUnauthorized: true, servername: "auth.openai.com", checkServerIdentity,
          ca: [...rootCertificates], maxHeaderSize: 16 * 1024,
          headers: { accept: "application/json", "accept-encoding": "identity", ...(body === undefined ? {} : {
            "content-type": "application/x-www-form-urlencoded", "content-length": String(Buffer.byteLength(body)) }) } }, incoming => {
          incoming.on("error", fail);
          if (released) { incoming.destroy(); return; }
          response = incoming;
          incoming.on("aborted", fail); incoming.on("close", () => { if (!incoming.complete) fail(); });
          const status = incoming.statusCode, type = incoming.headers["content-type"], encoding = incoming.headers["content-encoding"], length = incoming.headers["content-length"];
          if (!Number.isInteger(status) || status! < 100 || status! > 599
            || encoding !== undefined && (typeof encoding !== "string" || encoding.trim().toLowerCase() !== "identity")
            || length !== undefined && (typeof length !== "string" || !/^\d{1,10}$/.test(length) || Number(length) > BYTE_LIMIT)) { fail(); return; }
          if (status! >= 300 && status! < 400) { cleanup(); resolve({ status: status!, body: undefined }); return; }
          if (type !== undefined && (typeof type !== "string" || type.length > 1024 || type.split(";")[0].trim().toLowerCase() !== "application/json")) { fail(); return; }
          void (async () => {
            try {
              const chunks: Buffer[] = []; let bytes = 0;
              for await (const chunk of incoming) {
                if (released) return;
                if (!(chunk instanceof Uint8Array) || (bytes += chunk.byteLength) > BYTE_LIMIT) { fail(); return; }
                chunks.push(Buffer.from(chunk));
              }
              if (released) return;
              if (!incoming.complete) { fail(); return; }
              const text = new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks, bytes));
              let value: unknown;
              if (text === "" && kind === "revoke" && status === 200) value = "";
              else { if (type === undefined) { fail(); return; } value = JSON.parse(text); }
              if (status !== 200) {
                // OAuth error codes are needed for irreversible invalid-grant handling; no description/body escapes.
                const code = value && typeof value === "object" && !Array.isArray(value) ? (value as any).error : undefined;
                value = typeof code === "string" && /^[a-z_]{1,64}$/.test(code) ? { error: code } : undefined;
              } else if (kind === "discovery") {
                const d = value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined;
                revocationUrl = d?.issuer === SIWC_ISSUER && d.jwks_uri === SIWC_JWKS_URL ? revocation(d.revocation_endpoint) : undefined;
                value = d ? { issuer: d.issuer, jwks_uri: d.jwks_uri, ...(revocationUrl ? { revocation_endpoint: revocationUrl } : {}) } : undefined;
              }
              cleanup(); resolve({ status: status!, body: value });
            } catch { fail(); }
          })();
        });
        request.on("error", fail); request.end(body);
      } catch { fail(); }
    });
  };
  return Object.freeze({ request: (request: Request) => send(request),
    fetchJwks: (signal: AbortSignal) => send({ url: SIWC_JWKS_URL, method: "GET", signal }, true) });
}

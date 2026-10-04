/** Fixed-destination host transport; construction performs no I/O or credential lookup.
 * Uses Node's bundled CA set and an isolated agent, excluding ambient proxy/CA settings.
 * https://nodejs.org/api/https.html https://nodejs.org/api/tls.html
 * Native onboarding and live SIWC acceptance remain separate prerequisites.
 */
import { Agent, request as httpsRequest } from "node:https";
import { checkServerIdentity, rootCertificates } from "node:tls";
import type { ClientRequest, IncomingMessage } from "node:http";
import { SIWC_RESPONSES_URL, SiwcBrokerError, type SiwcTransport, type SiwcTransportRequest, type SiwcTransportResponse } from "./siwc-inference-broker.js";

const REQUEST_LIMIT = 4 * 1024 * 1024;
const RESPONSE_LIMIT = 32 * 1024 * 1024;
const DEADLINE_MS = 120_000;
const CONCURRENT_LIMIT = 32;
const unknown = (): SiwcBrokerError => new SiwcBrokerError("unknown", 502);
const budget = (): SiwcBrokerError => new SiwcBrokerError("budget", 429);
const emptyBody: AsyncIterable<Uint8Array> = { async *[Symbol.asyncIterator]() {} };

function validate(value: SiwcTransportRequest): number {
  if (!value || Object.keys(value).some(k => !["url", "method", "headers", "body", "signal"].includes(k))
    || value.url !== SIWC_RESPONSES_URL || value.method !== "POST" || typeof value.body !== "string"
    || !(value.signal instanceof AbortSignal) || !value.headers
    || Object.keys(value.headers).some(k => !["authorization", "content-type", "accept"].includes(k))
    || value.headers["content-type"] !== "application/json" || value.headers.accept !== "text/event-stream"
    || typeof value.headers.authorization !== "string" || !/^Bearer [A-Za-z0-9._~-]{16,32768}$/.test(value.headers.authorization)
    || value.body.includes(value.headers.authorization.slice(7))) throw new SiwcBrokerError("unsupported", 400);
  const bytes = Buffer.byteLength(value.body);
  if (bytes > REQUEST_LIMIT) throw budget();
  let body: unknown;
  try { body = JSON.parse(value.body); } catch { throw new SiwcBrokerError("unsupported", 400); }
  if (!body || typeof body !== "object" || Array.isArray(body)
    || (body as Record<string, unknown>).store !== false || (body as Record<string, unknown>).stream !== true)
    throw new SiwcBrokerError("unsupported", 400);
  if (value.signal.aborted) throw unknown();
  return bytes;
}

/** No redirects, retries, cookies, shared TLS sessions, environment proxy or custom CA roots.
 * The execution broker supplies tighter per-execution budgets and verifies SSE terminal evidence.
 * A response must be consumed or returned; abort/deadline always close it, even before first next().
 */
export function createSiwcHttpsTransport(): SiwcTransport {
  let active = 0;
  return async supplied => {
    const requestBytes = validate(supplied);
    if (active >= CONCURRENT_LIMIT) throw budget();
    active++;
    const { signal, body } = supplied;
    const authorization = supplied.headers.authorization;
    let agent: Agent | undefined, request: ClientRequest | undefined, response: IncomingMessage | undefined;
    let released = false, settled = false, ended = false, failure: SiwcBrokerError | undefined;
    let bytes = 0, source: AsyncIterator<unknown> | undefined;
    let rejectHeaders: (error: SiwcBrokerError) => void = () => {};
    const cleanup = (): void => {
      if (released) return;
      released = true; active--;
      clearTimeout(timer); signal.removeEventListener("abort", stop);
      response?.destroy(); request?.destroy(); agent?.destroy();
    };
    const fail = (error = unknown()): void => {
      if (released) return;
      failure = error;
      if (!settled) { settled = true; rejectHeaders(error); }
      cleanup();
    };
    const stop = (): void => fail();
    const timer = setTimeout(stop, DEADLINE_MS); timer.unref();
    signal.addEventListener("abort", stop, { once: true });
    if (signal.aborted) { cleanup(); throw unknown(); }

    return new Promise<SiwcTransportResponse>((resolve, reject) => {
      rejectHeaders = reject;
      try {
        agent = new Agent({ keepAlive: false, maxSockets: 1, maxCachedSessions: 0, proxyEnv: {},
          ca: [...rootCertificates], rejectUnauthorized: true, servername: "api.openai.com", checkServerIdentity });
        request = httpsRequest({ protocol: "https:", hostname: "api.openai.com", port: 443,
          path: "/v1/responses", method: "POST", agent, rejectUnauthorized: true,
          servername: "api.openai.com", checkServerIdentity, ca: [...rootCertificates], maxHeaderSize: 16 * 1024,
          headers: { authorization, "content-type": "application/json", accept: "text/event-stream",
            "accept-encoding": "identity", "content-length": String(requestBytes) } }, incoming => {
          // Errors from destroy/abort are deliberately not forwarded or logged.
          incoming.on("error", () => fail());
          if (released || settled) { incoming.destroy(); return; }
          response = incoming;
          incoming.on("aborted", () => fail());
          incoming.on("close", () => { if (!incoming.complete) fail(); });
          const status = incoming.statusCode;
          const contentType = incoming.headers["content-type"];
          const encoding = incoming.headers["content-encoding"];
          const length = incoming.headers["content-length"];
          if (!Number.isInteger(status) || status! < 100 || status! > 599
            || typeof contentType !== "string" || contentType.length > 1024
            || encoding !== undefined && (typeof encoding !== "string" || encoding.trim().toLowerCase() !== "identity")) { fail(); return; }
          if (length !== undefined && (typeof length !== "string" || !/^\d{1,16}$/.test(length)
            || !Number.isSafeInteger(Number(length)) || Number(length) > RESPONSE_LIMIT)) { fail(budget()); return; }
          if (status !== 200 || contentType.split(";")[0].trim().toLowerCase() !== "text/event-stream") {
            settled = true; cleanup(); resolve({ status: status!, contentType, body: emptyBody }); return;
          }
          let acquired = false, pulling = false;
          const iterator: AsyncIterator<Uint8Array> = {
            async next() {
              if (failure) throw failure;
              if (ended || released) return { done: true, value: undefined };
              if (pulling) { fail(); throw unknown(); }
              pulling = true;
              try {
                source ??= incoming[Symbol.asyncIterator]();
                const next = await source.next();
                if (failure) throw failure;
                if (released) return { done: true, value: undefined };
                if (next.done) {
                  if (!incoming.complete) { fail(); throw unknown(); }
                  ended = true; cleanup(); return { done: true, value: undefined };
                }
                if (!(next.value instanceof Uint8Array)) { fail(); throw unknown(); }
                bytes += next.value.byteLength;
                if (bytes > RESPONSE_LIMIT) { fail(budget()); throw failure!; }
                return { done: false, value: next.value };
              } catch {
                // Native error messages may contain request headers or provider details.
                fail(); throw failure ?? unknown();
              } finally { pulling = false; }
            },
            async return() {
              ended = true; cleanup();
              // Cleanup works without starting the iterator; no unread provider body is consumed.
              void source?.return?.().catch(() => {});
              return { done: true, value: undefined };
            },
          };
          settled = true;
          resolve({ status: status!, contentType, body: { [Symbol.asyncIterator]() {
            if (acquired) throw unknown(); acquired = true; return iterator;
          } } });
        });
        request.on("error", () => fail());
        request.end(body);
      } catch { fail(); }
    });
  };
}

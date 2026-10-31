// Node entry point for the Streamable HTTP server in src/fetch.ts.
// Run with `node src/http.ts`; settings come from the environment (optionsFromEnv).
import { createServer as createHttp, type IncomingMessage, type Server } from "node:http";
import { Readable } from "node:stream";
import { pathToFileURL } from "node:url";
import { createHandler, handlerDefaults, type HandlerOptions } from "./fetch.ts";

export { rateLimiter } from "./fetch.ts";

export interface HttpOptions extends HandlerOptions {
  port: number;
  host: string;
  /** Number of reverse proxies in front whose X-Forwarded-For entries to trust; 0 uses the socket address. */
  trustProxy: number;
}

export const defaults: HttpOptions = { ...handlerDefaults, port: 8790, host: "127.0.0.1", trustProxy: 0 };

/** Reads PORT, HOST, BASE_PATH, TRUST_PROXY, RATE_LIMIT, RATE_LIMIT_WINDOW_MS and CORS_ORIGINS; throws on a bad value. */
export function optionsFromEnv(env: Record<string, string | undefined>): HttpOptions {
  const int = (name: string, fallback: number, min: number, max: number) => {
    const raw = env[name];
    if (raw === undefined || raw === "") return fallback;
    const value = Number(raw);
    if (!Number.isInteger(value) || value < min || value > max) throw new Error(`${name} must be an integer from ${min} to ${max}, not "${raw}"`);
    return value;
  };
  const base = (env.BASE_PATH ?? "").trim().replace(/\/+$/, "");
  if (base && !/^(\/[A-Za-z0-9._~-]+)+$/.test(base)) throw new Error(`BASE_PATH must look like /yorozu, not "${env.BASE_PATH}"`);
  const origins = (env.CORS_ORIGINS ?? "*").trim();
  return {
    port: int("PORT", defaults.port, 0, 65535),
    host: env.HOST?.trim() || defaults.host,
    basePath: base,
    trustProxy: int("TRUST_PROXY", defaults.trustProxy, 0, 10),
    rateLimit: int("RATE_LIMIT", defaults.rateLimit, 1, 1_000_000),
    rateWindowMs: int("RATE_LIMIT_WINDOW_MS", defaults.rateWindowMs, 1, 86_400_000),
    corsOrigins: origins === "*" ? "*" : origins.split(",").map((o) => o.trim()).filter(Boolean),
    maxBodyBytes: defaults.maxBodyBytes,
  };
}

/** The client's address: the socket's, or with N trusted proxies the Nth X-Forwarded-For entry from the right. */
export function clientIp(req: IncomingMessage, trustProxy: number): string {
  const socket = req.socket.remoteAddress ?? "unknown";
  const header = req.headers["x-forwarded-for"];
  if (!trustProxy || !header) return socket;
  const chain = [...String(header).split(",").map((s) => s.trim()).filter(Boolean), socket];
  return chain[Math.max(0, chain.length - 1 - trustProxy)];
}

/** The web Request for a Node request; the body streams through unread. */
function toRequest(req: IncomingMessage): Request {
  const headers = new Headers();
  for (const [name, value] of Object.entries(req.headers)) {
    if (value !== undefined) headers.set(name, Array.isArray(value) ? value.join(", ") : value);
  }
  const hasBody = req.method !== "GET" && req.method !== "HEAD";
  return new Request(new URL(req.url ?? "/", "http://localhost"), {
    method: req.method,
    headers,
    body: hasBody ? (Readable.toWeb(req) as ReadableStream) : undefined,
    duplex: "half",
  } as RequestInit);
}

export function createHttpServer(options: HttpOptions): Server {
  const handle = createHandler(options);
  return createHttp(async (req, res) => {
    const response = await handle(toRequest(req), clientIp(req, options.trustProxy));
    res.writeHead(response.status, Object.fromEntries(response.headers));
    res.end(req.method === "HEAD" ? undefined : Buffer.from(await response.arrayBuffer()));
  });
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  let options: HttpOptions;
  try {
    options = optionsFromEnv(process.env);
  } catch (error) {
    console.error((error as Error).message);
    process.exit(64);
  }
  const server = createHttpServer(options);
  server.listen(options.port, options.host, () => {
    const address = server.address();
    const port = typeof address === "object" && address ? address.port : options.port;
    console.error(`yorozu-help MCP on http://${options.host}:${port}${options.basePath}/mcp (health: ${options.basePath}/healthz)`);
  });
  const stop = () => server.close(() => process.exit(0));
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
}

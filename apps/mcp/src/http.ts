// Streamable HTTP transport, stateless: each POST gets a fresh server, so nothing is kept between requests.
// Run with `node src/http.ts`; settings come from the environment (optionsFromEnv).
import { createServer as createHttp, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { pathToFileURL } from "node:url";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import pkg from "../package.json" with { type: "json" };
import { createServer } from "./server.ts";

export interface HttpOptions {
  port: number;
  host: string;
  /** Path prefix the server answers under, like "/yorozu"; "" for none. */
  basePath: string;
  /** Number of reverse proxies in front whose X-Forwarded-For entries to trust; 0 uses the socket address. */
  trustProxy: number;
  /** Requests per client IP per window, for the MCP endpoint. */
  rateLimit: number;
  rateWindowMs: number;
  /** Allowed browser origins, or "*" for any. */
  corsOrigins: "*" | string[];
  maxBodyBytes: number;
}

export const defaults: HttpOptions = {
  port: 8790,
  host: "127.0.0.1",
  basePath: "",
  trustProxy: 0,
  rateLimit: 60,
  rateWindowMs: 60_000,
  corsOrigins: "*",
  maxBodyBytes: 64 * 1024,
};

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

/** Fixed-window counter per key. Returns seconds to wait, or 0 when the request may go ahead. */
export function rateLimiter(limit: number, windowMs: number, now: () => number = Date.now) {
  const windows = new Map<string, { start: number; count: number }>();
  return (key: string): number => {
    const t = now();
    if (windows.size > 10_000) for (const [k, w] of windows) if (t - w.start >= windowMs) windows.delete(k);
    const w = windows.get(key);
    if (!w || t - w.start >= windowMs) {
      windows.set(key, { start: t, count: 1 });
      return 0;
    }
    w.count++;
    return w.count > limit ? Math.max(1, Math.ceil((w.start + windowMs - t) / 1000)) : 0;
  };
}

const corsHeaders = {
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Accept, Authorization, Mcp-Session-Id, Mcp-Protocol-Version, Last-Event-ID",
  "Access-Control-Expose-Headers": "Mcp-Session-Id, Mcp-Protocol-Version, Retry-After",
  "Access-Control-Max-Age": "86400",
};

function send(res: ServerResponse, status: number, body: object, headers: Record<string, string> = {}) {
  res.writeHead(status, { "Content-Type": "application/json", ...headers }).end(JSON.stringify(body));
}
const rpcError = (code: number, message: string) => ({ jsonrpc: "2.0", error: { code, message }, id: null });

async function readJson(req: IncomingMessage, max: number): Promise<{ body?: unknown; status?: number }> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > max) return { status: 413 };
    chunks.push(chunk);
  }
  try {
    return { body: JSON.parse(Buffer.concat(chunks).toString("utf8")) };
  } catch {
    return { status: 400 };
  }
}

export function createHttpServer(options: HttpOptions): Server {
  const base = options.basePath;
  const mcpPaths = new Set([base || "/", `${base}/`, `${base}/mcp`]);
  const limited = rateLimiter(options.rateLimit, options.rateWindowMs);

  return createHttp(async (req, res) => {
    const path = new URL(req.url ?? "/", "http://localhost").pathname;
    const origin = req.headers.origin;
    if (origin && (options.corsOrigins === "*" || options.corsOrigins.includes(origin))) {
      res.setHeader("Access-Control-Allow-Origin", options.corsOrigins === "*" ? "*" : origin);
      if (options.corsOrigins !== "*") res.setHeader("Vary", "Origin");
      for (const [name, value] of Object.entries(corsHeaders)) res.setHeader(name, value);
    }
    if (req.method === "OPTIONS") return void res.writeHead(204).end();

    if (path === `${base}/healthz`) {
      if (req.method !== "GET" && req.method !== "HEAD") return send(res, 405, { error: "method not allowed" }, { Allow: "GET, HEAD" });
      return send(res, 200, { status: "ok", name: "yorozu-help", version: pkg.version });
    }
    if (!mcpPaths.has(path)) return send(res, 404, { error: "not found" });

    const wait = limited(clientIp(req, options.trustProxy));
    if (wait) return send(res, 429, rpcError(-32000, "Too many requests"), { "Retry-After": String(wait) });
    if (req.method !== "POST") return send(res, 405, rpcError(-32000, "Method not allowed: this server is stateless, POST only"), { Allow: "POST, OPTIONS" });

    const { body, status } = await readJson(req, options.maxBodyBytes);
    if (status === 413) return send(res, 413, rpcError(-32600, "Request too large"));
    if (status === 400) return send(res, 400, rpcError(-32700, "Parse error"));

    const server = createServer();
    const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
    res.on("close", () => {
      void transport.close();
      void server.close();
    });
    try {
      await server.connect(transport);
      await transport.handleRequest(req, res, body);
    } catch (error) {
      console.error("yorozu-help: request failed:", error);
      if (!res.headersSent) send(res, 500, rpcError(-32603, "Internal error"));
    }
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

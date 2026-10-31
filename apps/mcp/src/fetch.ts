// Stateless Streamable HTTP on web-standard Request and Response, so the same code serves Node (src/http.ts)
// and the website's Cloudflare Worker (apps/web/worker.mjs). Each POST gets a fresh server; nothing is kept between requests.
import { WebStandardStreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/webStandardStreamableHttp.js";
import pkg from "../package.json" with { type: "json" };
import { createServer } from "./server.ts";

export interface HandlerOptions {
  /** Path prefix the server answers under, like "/yorozu"; "" for none. */
  basePath: string;
  /** Requests per client IP per window, for the MCP endpoint. */
  rateLimit: number;
  rateWindowMs: number;
  /** Allowed browser origins, or "*" for any. */
  corsOrigins: "*" | string[];
  maxBodyBytes: number;
}

export const handlerDefaults: HandlerOptions = {
  basePath: "",
  rateLimit: 60,
  rateWindowMs: 60_000,
  corsOrigins: "*",
  maxBodyBytes: 64 * 1024,
};

/** Answers one request from the client at `clientIp`. */
export type Handler = (request: Request, clientIp: string) => Promise<Response>;

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

const json = (status: number, body: object, headers: Record<string, string> = {}) =>
  Response.json(body, { status, headers });
const rpcError = (code: number, message: string) => ({ jsonrpc: "2.0", error: { code, message }, id: null });

export function createHandler(options: HandlerOptions): Handler {
  const base = options.basePath;
  const mcpPaths = new Set([base || "/", `${base}/`, `${base}/mcp`]);
  const limited = rateLimiter(options.rateLimit, options.rateWindowMs);

  function cors(request: Request): Record<string, string> {
    const origin = request.headers.get("Origin");
    if (!origin || (options.corsOrigins !== "*" && !options.corsOrigins.includes(origin))) return {};
    if (options.corsOrigins === "*") return { "Access-Control-Allow-Origin": "*", ...corsHeaders };
    return { "Access-Control-Allow-Origin": origin, Vary: "Origin", ...corsHeaders };
  }

  async function route(request: Request, clientIp: string): Promise<Response> {
    const path = new URL(request.url).pathname;
    if (request.method === "OPTIONS") return new Response(null, { status: 204 });

    if (path === `${base}/healthz`) {
      if (request.method !== "GET" && request.method !== "HEAD") return json(405, { error: "method not allowed" }, { Allow: "GET, HEAD" });
      return json(200, { status: "ok", name: "yorozu-help", version: pkg.version });
    }
    if (!mcpPaths.has(path)) return json(404, { error: "not found" });

    const wait = limited(clientIp);
    if (wait) return json(429, rpcError(-32000, "Too many requests"), { "Retry-After": String(wait) });
    if (request.method !== "POST") return json(405, rpcError(-32000, "Method not allowed: this server is stateless, POST only"), { Allow: "POST, OPTIONS" });

    const server = createServer();
    const transport = new WebStandardStreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
      maxRequestBodySize: options.maxBodyBytes,
    });
    try {
      await server.connect(transport);
      return await transport.handleRequest(request);
    } catch (error) {
      console.error("yorozu-help: request failed:", error);
      return json(500, rpcError(-32603, "Internal error"));
    } finally {
      // With JSON responses the body is complete once handleRequest returns.
      void transport.close();
      void server.close();
    }
  }

  return async (request, clientIp) => {
    const response = await route(request, clientIp);
    const headers = cors(request);
    if (!Object.keys(headers).length) return response;
    const out = new Response(response.body, response);
    for (const [name, value] of Object.entries(headers)) out.headers.set(name, value);
    return out;
  };
}

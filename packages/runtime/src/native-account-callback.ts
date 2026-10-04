/** Production numeric-loopback endpoint factory. No listener is created until acquire(). */
import { createServer } from "node:http";
import type { NativeSiwcCallbackFactory, NativeSiwcCallbackEndpoint } from "./native-account-coordinator.js";

export function createNumericSiwcCallbackEndpointFactory(): NativeSiwcCallbackFactory {
  return Object.freeze({ acquire: async (handler: Parameters<NativeSiwcCallbackFactory["acquire"]>[0], signal: AbortSignal): Promise<NativeSiwcCallbackEndpoint> => {
    if (signal.aborted) throw new Error("Native callback unavailable");
    const server = createServer({ maxHeaderSize: 24_576, headersTimeout: 5000, requestTimeout: 5000, keepAliveTimeout: 1 }, (request, response) => {
      const contentLength = request.headers["content-length"];
      const send = (status: number, text: string): void => {
        if (response.destroyed) return;
        response.writeHead(status, { "content-type": "text/plain; charset=utf-8", "cache-control": "no-store", "referrer-policy": "no-referrer",
          "content-security-policy": "default-src 'none'; frame-ancestors 'none'", connection: "close" });
        response.end(text);
      };
      void Promise.resolve().then(() => handler({ method: request.method ?? "", url: request.url ?? "", host: request.headers.host ?? "",
        remoteAddress: request.socket.remoteAddress ?? "", rawHeaders: request.rawHeaders,
        hasBody: !!request.headers["transfer-encoding"] || contentLength !== undefined && contentLength !== "0" }))
        .then(reply => send(reply.status, reply.text), () => send(400, "This sign-in could not be completed. Return to Yorozu."));
    });
    server.maxConnections = 8;
    server.on("clientError", (_error, socket) => socket.destroy());
    let closure: Promise<void> | undefined;
    const close = (): Promise<void> => {
      if (!closure) closure = new Promise(resolve => {
        const timer = setTimeout(() => { server.closeAllConnections(); resolve(); }, 1500); timer.unref();
        try { server.close(() => { clearTimeout(timer); resolve(); }); } catch { clearTimeout(timer); resolve(); }
      });
      return closure;
    };
    try {
      await new Promise<void>((resolve, reject) => {
        const abort = (): void => { cleanup(); void close(); reject(new Error("Native callback unavailable")); };
        const error = (): void => { cleanup(); reject(new Error("Native callback unavailable")); };
        const cleanup = (): void => { signal.removeEventListener("abort", abort); server.removeListener("error", error); };
        signal.addEventListener("abort", abort, { once: true }); server.once("error", error);
        server.listen({ host: "127.0.0.1", port: 0, exclusive: true, signal }, () => { cleanup(); if (signal.aborted) abort(); else resolve(); });
      });
      server.on("error", () => { void close(); });
      const address = server.address();
      if (!address || typeof address === "string" || address.address !== "127.0.0.1" || !Number.isInteger(address.port) || address.port < 1024 || address.port > 65535)
        throw new Error("Native callback unavailable");
      return Object.freeze({ host: "127.0.0.1" as const, port: address.port, close });
    } catch { await close(); throw new Error("Native callback unavailable"); }
  } });
}

/** Native host transport. Constructing the factory opens no sockets. */
import { createServer } from "node:http";
import type { SiwcBrokerSelectorConfiguration } from "./siwc-inference-broker.js";

export function createNumericSiwcBrokerEndpoint(): SiwcBrokerSelectorConfiguration["openEndpoint"] {
  return async (handler, _identity, signal) => {
    if (signal.aborted) throw new Error("Inference endpoint unavailable");
    const server = createServer({ maxHeaderSize: 16 * 1024, requestTimeout: 125_000, headersTimeout: 10_000,
      keepAliveTimeout: 1000, requireHostHeader: true, joinDuplicateHeaders: false }, (request, response) => {
      const seen = new Set<string>(); let valid = request.rawHeaders.length <= 64;
      for (let i = 0; i < request.rawHeaders.length; i += 2) {
        const key = request.rawHeaders[i].toLowerCase();
        if (seen.has(key)) valid = false; seen.add(key);
      }
      if (!valid) { response.writeHead(400, { "content-type": "application/json", "cache-control": "no-store" }); response.end('{"error":{"code":"unsupported"}}'); return; }
      handler(request, response);
    });
    server.maxConnections = 16; server.maxHeadersCount = 32;
    let closed = false;
    const close = (): Promise<void> => new Promise(resolve => {
      if (closed) { resolve(); return; } closed = true; signal.removeEventListener("abort", abort);
      server.closeAllConnections(); try { server.close(() => resolve()); } catch { resolve(); }
    });
    const abort = (): void => { void close(); };
    signal.addEventListener("abort", abort, { once: true });
    server.on("clientError", (_error, socket) => socket.destroy());
    server.on("connection", socket => { socket.setTimeout(125_000, () => socket.destroy()); socket.on("error", () => {}); });
    server.on("error", abort);
    try {
      await new Promise<void>((resolve, reject) => {
        const stop = (): void => { cleanup(); reject(new Error("Inference endpoint unavailable")); };
        const ready = (): void => {
          if (closed || signal.aborted) {
            // A fake or a native bind may complete after the first close callback.
            server.closeAllConnections(); try { server.close(() => {}); } catch {}
            stop(); return;
          }
          cleanup(); resolve();
        };
        const cleanup = (): void => { server.removeListener("error", stop); signal.removeEventListener("abort", stop); };
        server.once("error", stop); signal.addEventListener("abort", stop, { once: true });
        if (signal.aborted) { stop(); return; }
        try { server.listen({ host: "127.0.0.1", port: 0, exclusive: true, signal }, ready); } catch { stop(); }
      });
      const address = server.address();
      if (closed || signal.aborted || !address || typeof address === "string" || address.address !== "127.0.0.1"
        || !Number.isInteger(address.port) || address.port < 1024 || address.port > 65535) throw new Error("Inference endpoint unavailable");
      return { host: "127.0.0.1", port: address.port, close };
    } catch { await close(); throw new Error("Inference endpoint unavailable"); }
  };
}

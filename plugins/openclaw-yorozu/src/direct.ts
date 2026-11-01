// The direct path (capability `direct`, #532 step 3): the plugin's own WebSocket listener on private addresses, and the
// probe that proves the host key before a device sends its Noise init. Imports only node built-ins and the pure wire and
// hub files; the WebSocket server is injected, so `node --test` and the relay's end-to-end test run it without OpenClaw.
import { isIP } from "node:net";
import type { NetworkInterfaceInfo } from "node:os";
import { CLOSE, type Hub, type Link, type Log } from "./hub.js";
import { b64u, decodeFrame, fromB64u, roomId, signFrame, verifyFrame, type Keypair } from "./wire.js";

export const DIRECT_PORT = 8738;
export const MAX_PENDING = 8;
export const PENDING_MS = 10_000;
export const MAX_FRAME_BYTES = 1024 * 1024;
/** The client pings every 25 s; a direct socket silent this long is gone. */
export const IDLE_MS = 90_000;
const PING = JSON.stringify({ type: "ping" });
const PONG = JSON.stringify({ type: "pong" });

const octets = (address: string): number[] => address.split(".").map(Number);

function hextets(address: string): number[] {
  const [head = "", tail] = address.split("::");
  const part = (text: string) => (text ? text.split(":").map((h) => parseInt(h, 16)) : []);
  const front = part(head);
  const back = tail === undefined ? [] : part(tail);
  return [...front, ...Array<number>(8 - front.length - back.length).fill(0), ...back];
}

/** Loopback, RFC 1918, ULA and 100.64.0.0/10 only: never a wildcard, link-local, mapped or public address. */
export function directAddress(address: string): boolean {
  const family = isIP(address);
  if (family === 4) {
    const [a, b = -1] = octets(address);
    return a === 127 || a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127);
  }
  if (family !== 6 || address.includes("%") || address.includes(".")) return false;
  const h = hextets(address);
  const loopback = h.slice(0, 7).every((x) => x === 0) && h[7] === 1;
  return loopback || ((h[0] ?? 0) & 0xfe00) === 0xfc00;
}

/** The addresses the listener binds: each allowed local address once. */
export const bindAddresses = (interfaces: NodeJS.Dict<NetworkInterfaceInfo[]>): string[] => [
  ...new Set(
    Object.values(interfaces)
      .flatMap((list) => list ?? [])
      .map((info) => info.address)
      .filter(directAddress),
  ),
];

export const probeText = (room: string, nonce: string): string => `yorozu-direct|${room}|${nonce}`;
export const validNonce = (nonce: unknown): nonce is string => typeof nonce === "string" && fromB64u(nonce)?.length === 32;

/** The host's answer to `{"type":"probe","nonce"}`: its Ed25519 key and a signature over the room and nonce. */
export const probeAnswer = (signing: Keypair, room: string, nonce: string): { type: "probe"; pubkey: string; sig: string } => ({
  type: "probe",
  pubkey: b64u(signing.publicKey),
  sig: signFrame(signing.privateKey, probeText(room, nonce)),
});

/** The client's check before it sends its init: the key is the room's and it signed this nonce. */
export function verifyProbe(room: string, nonce: string, answer: Record<string, unknown>): boolean {
  if (typeof answer.pubkey !== "string" || typeof answer.sig !== "string") return false;
  const pub = fromB64u(answer.pubkey);
  return pub?.length === 32 && roomId(pub) === room && verifyFrame(pub, probeText(room, nonce), answer.sig);
}

type Listener = (...args: any[]) => void;
/** What the listener uses of a `ws` socket and server. */
export type DirectSocket = {
  readonly readyState: number;
  send(data: string): void;
  close(code?: number, reason?: string): void;
  terminate(): void;
  on(event: string, listener: Listener): unknown;
};
export type DirectServer = { on(event: string, listener: Listener): unknown; close(callback?: (error?: Error) => void): void };
export type DirectServerFactory = (options: { host: string; port: number; maxPayload: number }) => DirectServer;

export type DirectOptions = {
  addresses: string[];
  port: number;
  keys: { signing: Keypair; room: string };
  hub: Pick<Hub, "handshake" | "open" | "handle" | "detach">;
  server: DirectServerFactory;
  /** Sends one message; the plugin routes it through OpenClaw's effect authority. */
  transmit?: (socket: DirectSocket, raw: string) => void;
  pendingMs?: number;
  log?: Log;
};

export type DirectListener = { readonly listening: boolean; readonly bound: string[]; update: (addresses: string[]) => Promise<void>; close: () => Promise<void> };

const OPEN = 1;
const size = (data: unknown): number =>
  Array.isArray(data) ? data.reduce((sum: number, part: Buffer) => sum + part.length, 0)
    : data instanceof ArrayBuffer ? data.byteLength
      : Buffer.isBuffer(data) ? data.length
        : String(data).length;

/** One `ws` server per address on `port`; at most 8 sockets wait for their handshake, each for 10 s. */
export async function serveDirect(opts: DirectOptions): Promise<DirectListener> {
  const { keys, hub, log } = opts;
  const transmit = opts.transmit ?? ((socket, raw) => socket.send(raw));
  const sockets = new Map<DirectSocket, string>();
  let pending = 0;

  const accept = (ws: DirectSocket, origin: unknown, host: string): void => {
    sockets.set(ws, host);
    let counted = true;
    pending++;
    const settle = () => {
      if (counted) pending--;
      counted = false;
    };
    const send = (raw: string) => {
      if (ws.readyState === OPEN) transmit(ws, raw);
    };
    const refuse = (reason: string) => {
      log?.info(`yorozu: direct connection refused (${reason})`);
      ws.close(CLOSE.unauthorized, reason);
    };
    const link: Link = {
      path: "direct",
      send: (payloads) => {
        for (const payload of payloads) send(JSON.stringify({ type: "frame", payload, sig: signFrame(keys.signing.privateKey, payload) }));
      },
      close: (code, reason) => ws.close(code, reason),
    };
    const deadline = setTimeout(() => refuse("handshake timed out"), opts.pendingMs ?? PENDING_MS);
    const idle = setTimeout(() => ws.terminate(), IDLE_MS);
    deadline.unref();
    idle.unref();
    ws.on("close", () => {
      clearTimeout(deadline);
      clearTimeout(idle);
      settle();
      sockets.delete(ws);
      hub.detach(link);
    });
    ws.on("error", (error: Error) => log?.info(`yorozu: direct socket error: ${error.message}`));
    // A browser page could reach loopback; the app sends no Origin.
    if (origin !== undefined) return refuse("browser origin");
    if (pending > MAX_PENDING) return refuse("too many pending connections");

    let device: Buffer | null = null;
    let probed = false;
    const receive = async (data: unknown, binary: boolean): Promise<void> => {
      if (ws.readyState !== OPEN) return;
      idle.refresh();
      if (size(data) > MAX_FRAME_BYTES) return ws.close(CLOSE.tooLarge, "too large");
      const text = binary ? "" : String(data);
      if (text === PING) return send(PONG);
      let msg: Record<string, unknown> | null = null;
      try {
        const value: unknown = JSON.parse(text);
        if (typeof value === "object" && value !== null && !Array.isArray(value)) msg = value as Record<string, unknown>;
      } catch {}
      const payload = msg?.type === "frame" && typeof msg.payload === "string" ? msg.payload : null;
      const sig = payload !== null && typeof msg?.sig === "string" ? msg.sig : null;
      const decoded = payload !== null && sig !== null ? decodeFrame(payload) : null;
      if (!device) {
        if (!probed) {
          if (msg?.type !== "probe" || !validNonce(msg.nonce)) return refuse("expected a probe");
          probed = true;
          return send(JSON.stringify(probeAnswer(keys.signing, keys.room, msg.nonce)));
        }
        if (payload === null || sig === null || decoded?.type !== "init") return refuse("expected an init frame");
        if (!(await hub.handshake(payload, sig, link))) return refuse("handshake refused");
        if (ws.readyState !== OPEN) return hub.detach(link);
        device = decoded.deviceSigningKey;
        clearTimeout(deadline);
        return settle();
      }
      if (payload === null || sig === null) return;
      if (!verifyFrame(device, payload, sig)) return refuse("bad frame signature");
      if (decoded?.type === "init") {
        if (!decoded.deviceSigningKey.equals(device) || !(await hub.handshake(payload, sig, link))) return refuse("handshake refused");
        return;
      }
      if (decoded?.type !== "box") return;
      const opened = hub.open(decoded, link);
      if (!opened) return;
      send(JSON.stringify({ type: "accepted", sig }));
      await hub.handle(opened);
    };
    let queue = Promise.resolve();
    ws.on("message", (data: unknown, binary: boolean) => {
      queue = queue.then(() => receive(data, binary)).catch((error: unknown) => log?.warn(`yorozu: direct message failed: ${String(error)}`));
    });
  };

  // `ws` closes a message over `maxPayload` with 1009 before the plugin sees it; up to that, oversized ones get 4103.
  const listen = (host: string): Promise<DirectServer | null> =>
    new Promise((resolve) => {
      const server = opts.server({ host, port: opts.port, maxPayload: 2 * MAX_FRAME_BYTES });
      server.on("connection", (ws: DirectSocket, request: { headers?: Record<string, unknown> } | undefined) =>
        accept(ws, request?.headers?.origin, host));
      let up = false;
      server.on("listening", () => {
        up = true;
        resolve(server);
      });
      server.on("error", (error: Error) => {
        log?.warn(`yorozu: direct listener on ${host} failed: ${error.message}`);
        if (up) return;
        server.close();
        resolve(null);
      });
    });

  const servers = new Map<string, DirectServer>();
  let closed = false;
  let queue = Promise.resolve();
  const closeSockets = (host?: string) => {
    for (const [ws, address] of sockets) {
      if (host !== undefined && address !== host) continue;
      ws.close(1001, "stopping");
      setTimeout(() => ws.terminate(), 1_000).unref();
    }
  };
  const update = (addresses: string[]): Promise<void> => {
    const next = queue.then(async () => {
      if (closed) return;
      for (const [address, server] of servers) {
        if (addresses.includes(address)) continue;
        servers.delete(address);
        closeSockets(address);
        server.close();
      }
      for (const host of new Set(addresses)) {
        if (!directAddress(host)) {
          log?.warn(`yorozu: direct listener skips ${host}: not a loopback or private address`);
          continue;
        }
        if (servers.has(host)) continue;
        const server = await listen(host);
        if (server) servers.set(host, server);
      }
    });
    queue = next.catch(() => {});
    return next;
  };
  await update(opts.addresses);
  const bound = [...servers.keys()];
  if (bound.length) log?.info(`yorozu: direct listener on port ${opts.port} (${bound.join(", ")})`);
  return {
    get listening() {
      return !closed && servers.size > 0;
    },
    get bound() { return [...servers.keys()]; },
    update,
    close: async () => {
      closed = true;
      await queue;
      closeSockets();
      await Promise.all([...servers.values()].map((server) => new Promise<void>((resolve) => server.close(() => resolve()))));
      servers.clear();
    },
  };
}

/** Compatibility facade. Rust owns the relay socket, IO deadlines, heartbeat and redials. */
import { EventEmitter } from "node:events";
import { randomUUID } from "node:crypto";
import { hostRequest, retainHostWorker, subscribeHostEvents } from "./rust-host.js";
const FRAME_BYTES = 1024 * 1024;
const OUTPUT_BYTES = 8 * 1024 * 1024;

export class RustRelaySocket extends EventEmitter {
  readyState = 1;
  bufferedAmount = 0;
  private writes = Promise.resolve();
  constructor(private readonly dir: string, private readonly port: string, readonly device: string) { super(); }
  send(frame: string): void {
    if (this.readyState !== 1) throw new Error("Relay connection is closed");
    const bytes = Buffer.byteLength(frame);
    if (bytes > FRAME_BYTES || this.bufferedAmount + bytes > OUTPUT_BYTES) {
      this.close(); throw new Error("Relay output limit");
    }
    this.bufferedAmount += bytes;
    this.writes = this.writes.then(async () => {
      // Unsent work remains bound to this socket, even when Rust has already reconnected.
      if (this.readyState !== 1) return;
      const result = await hostRequest(this.dir, { op: "relay_send", transportId: this.port, device: this.device, frame }) as { sent?: unknown };
      if (result?.sent !== true) throw new Error("Relay write remains unconfirmed");
    }).catch(() => {
      if (this.readyState !== 1) return;
      this.emit("error", new Error("Relay write remains unconfirmed")); this.close();
    }).finally(() => { this.bufferedAmount -= bytes; });
  }
  close(): void {
    if (this.readyState !== 1) return;
    this.readyState = 2;
    void hostRequest(this.dir, { op: "relay_disconnect", transportId: this.port, device: this.device })
      .catch(() => {}).finally(() => this.closed());
  }
  closed(): void {
    if (this.readyState === 3) return;
    this.readyState = 3; this.emit("close");
  }
}

export function startRustRelay(options: { dir: string; url: string; heartbeat: { pingMs: number; pongMs: number };
  onSocket(socket: RustRelaySocket): void; onState(state: string): void }): { close(): Promise<void> } {
  const { dir } = options;
  const release = retainHostWorker(dir);
  let port = ""; let socket: RustRelaySocket | undefined; let closing = false;
  let opening = Promise.resolve(); let recovery: ReturnType<typeof setTimeout> | undefined;
  let retryMs = 100;
  const recover = (): void => {
    if (closing || recovery) return;
    recovery = setTimeout(() => { recovery = undefined; opening = open(); void opening.catch(() => {}); }, retryMs);
    recovery.unref(); retryMs = Math.min(30_000, retryMs * 2);
  };
  const unsubscribe = subscribeHostEvents(dir, (event) => {
    if (closing) return;
    if (event.event === "lost") {
      socket?.closed(); socket = undefined; options.onState("relay-host-unavailable"); recover(); return;
    }
    if (event.transportId !== port) return;
    if (event.event === "open") {
      socket?.closed(); socket = new RustRelaySocket(dir, port, event.device);
      options.onSocket(socket); socket.emit("open");
    } else if (event.event === "error") {
      const known = ["connecting", "heartbeat-timeout", "relay-connect-unavailable"];
      options.onState(typeof event.frame === "string" && known.includes(event.frame) ? event.frame : "relay-frame-error");
    } else if (socket?.device === event.device) {
      if (event.event === "close") { socket.closed(); socket = undefined; }
      else if (event.event === "frame" && typeof event.frame === "string") socket.emit("message", event.frame);
    }
  });
  async function open(): Promise<void> {
    if (closing) return;
    port = randomUUID();
    try {
      const result = await hostRequest(dir, { op: "relay_open", transportId: port, url: options.url,
        pingMs: options.heartbeat.pingMs, pongMs: options.heartbeat.pongMs }) as { ready?: unknown };
      if (result?.ready !== true) throw new Error("Relay owner unavailable");
      retryMs = 100;
    } catch (error) { if (!closing) { options.onState("relay-host-unavailable"); recover(); } throw error; }
  }
  opening = open(); void opening.catch(() => {});
  return { async close() {
    if (closing) return;
    closing = true; if (recovery) clearTimeout(recovery);
    await opening.catch(() => {});
    await hostRequest(dir, { op: "relay_close", transportId: port }).catch(() => {});
    socket?.closed(); unsubscribe(); await release();
  } };
}

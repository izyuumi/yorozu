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
  private pending = 0;
  private input: { frame: string; token: string | undefined; bytes: number }[] = [];
  private inputBytes = 0;
  private reading = false;
  constructor(private readonly dir: string, private readonly port: string, readonly device: string) { super(); }
  send(frame: string): void {
    if (this.readyState !== 1) throw new Error("Relay connection is closed");
    const bytes = Buffer.byteLength(frame);
    if (bytes > FRAME_BYTES || this.bufferedAmount + bytes > OUTPUT_BYTES || this.pending >= 64) {
      this.close(); throw new Error("Relay output limit");
    }
    this.bufferedAmount += bytes; this.pending++;
    this.writes = this.writes.then(async () => {
      // Unsent work remains bound to this socket, even when Rust has already reconnected.
      if (this.readyState !== 1) return;
      const result = await hostRequest(this.dir, { op: "relay_send", transportId: this.port, device: this.device, frame }) as { sent?: unknown };
      if (result?.sent !== true) throw new Error("Relay write remains unconfirmed");
    }).catch(() => {
      if (this.readyState !== 1) return;
      this.emit("error", new Error("Relay write remains unconfirmed")); this.close();
    }).finally(() => { this.bufferedAmount -= bytes; this.pending--; });
  }
  /** Preserve arrival order while a handler's response/ack writes drain. */
  receive(frame: string, token: string | undefined): void {
    if (this.readyState !== 1) return;
    const bytes = Buffer.byteLength(frame);
    if (bytes > FRAME_BYTES || this.input.length >= 64 || this.inputBytes + bytes > OUTPUT_BYTES) {
      this.close(); return;
    }
    this.input.push({ frame, token, bytes }); this.inputBytes += bytes;
    if (this.reading) return;
    this.reading = true;
    const drain = (): void => {
      const next = this.readyState === 1 ? this.input.shift() : undefined;
      if (!next) { this.input = []; this.inputBytes = 0; this.reading = false; return; }
      this.inputBytes -= next.bytes;
      try { this.emit("message", next.frame, next.token); }
      catch { this.close(); }
      // This waits for synchronous response writes, never provider task completion.
      void this.writes.then(drain, () => { this.close(); drain(); });
    };
    drain();
  }
  /** Report the synchronous application boundary; Rust owns the cumulative replay fence. */
  handled(receiveToken: string | undefined, handled: boolean): void {
    if (receiveToken === undefined || this.readyState !== 1) return;
    if (this.pending >= 64) { this.close(); return; }
    this.pending++;
    this.writes = this.writes.then(async () => {
      if (this.readyState !== 1) return;
      const result = await hostRequest(this.dir, { op: "relay_handled", transportId: this.port,
        device: this.device, receiveToken, handled }) as { sent?: unknown };
      if (result?.sent !== true) throw new Error("Relay handling remains unconfirmed");
    }).catch(() => {
      if (this.readyState !== 1) return;
      this.emit("error", new Error("Relay handling remains unconfirmed")); this.close();
    }).finally(() => { this.pending--; });
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
      else if (event.event === "frame" && typeof event.frame === "string") socket.receive(event.frame, typeof event.receiveToken === "string" ? event.receiveToken : undefined);
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

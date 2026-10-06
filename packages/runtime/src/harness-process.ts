import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { randomUUID } from "node:crypto";
import { prepareHostListenerTransfer, releaseHostListener, validateHostListeners, type HostListenerLease, type HostListenerTransfer } from "./agent-listener.js";
import { HARNESS_FRAME_BYTES, HARNESS_PENDING_REQUESTS, validHarnessEvent, validHarnessExtensions, validHarnessLifecycle, type HarnessConfiguration, type HarnessEvent, type HarnessReady, type HarnessLifecycle } from "./harness-contract.js";

/** Live capabilities remain host memory; shared wire contracts contain no raw descriptor. */
export type SupervisedHarnessConfiguration = HarnessConfiguration & {
  inheritedListeners?: readonly HostListenerLease[];
  /** Host-minted callback, never serialized or taken from initialize/model input. */
  workerTool?(method: string, params: unknown, signal: AbortSignal): Promise<unknown>;
};

/** Bounded supervised process; never respawns or replays execution after failure. */
export class HarnessProcess {
  private child?: ChildProcessWithoutNullStreams;
  private pending = new Map<string, { resolve(v: any): void; reject(e: Error): void; timer: NodeJS.Timeout }>();
  private buffer = Buffer.alloc(0);
  private closing = false;
  private dead = false;
  private exited?: Promise<void>;
  private starting?: Promise<HarnessReady>;
  private listenerTransfer?: HostListenerTransfer;
  private sessionOpens: Promise<unknown> = Promise.resolve();
  private ready?: HarnessReady;
  private readonly toolAbort = new AbortController();
  private readonly toolRequests = new Set<string>();
  private readonly toolControllers = new Map<string, AbortController>();
  private activeTools = 0;
  private readonly lifecycle?: HarnessLifecycle;
  readonly listeners = new Set<(event: HarnessEvent) => void>();
  readonly failures = new Set<(reason: string) => void>();
  constructor(readonly configuration: SupervisedHarnessConfiguration) {
    // Keep ownership stable for this bridge even if a caller updates its next configuration.
    this.lifecycle = configuration.runtime ? { ...configuration.runtime } : undefined;
  }
  start(): Promise<HarnessReady> {
    if (this.dead || this.closing) return Promise.reject(new Error("Harness process already started or unavailable; no implicit restart"));
    return this.starting ??= this.startOnce().catch(error => {
      this.fail("Harness startup unavailable; no implicit restart"); throw error;
    });
  }
  get unavailable(): boolean { return this.dead || this.closing; }
  private async startOnce(): Promise<HarnessReady> {
    if (this.child || this.dead) throw new Error("Harness process already started or unavailable");
    // Neither adapter nor upstream gets ambient provider credentials or Yorozu secrets.
    const env: NodeJS.ProcessEnv = {};
    for (const key of ["PATH", "TMPDIR", "TEMP", "TMP", "LANG", "SystemRoot", "WINDIR"]) {
      if (process.env[key] !== undefined) env[key] = process.env[key];
    }
    const initialize = { ...this.configuration.initialize };
    const lifecycle = this.lifecycle;
    if (lifecycle !== undefined && !validHarnessLifecycle(lifecycle)) throw new Error("Invalid trusted harness lifecycle");
    if (initialize.lifecycle !== undefined) {
      const declared = initialize.lifecycle;
      if (!lifecycle || !validHarnessLifecycle(declared) || declared.mode !== lifecycle.mode
        || declared.mode === "connected" && lifecycle.mode === "connected" && declared.connectionId !== lifecycle.connectionId)
        throw new Error("Harness lifecycle must match trusted host configuration");
    }
    if (lifecycle) initialize.lifecycle = lifecycle;
    if (initialize.gatewayListener !== undefined) throw new Error("Gateway descriptor metadata must be synthesized by the host");
    const leases = this.configuration.inheritedListeners ?? [];
    if (lifecycle?.mode === "connected" && leases.length) throw new Error("Connected harness cannot inherit managed runtime listeners");
    if (leases.length) {
      if (this.configuration.pluginId !== "openclaw" || leases.length !== 1 || typeof initialize.agentId !== "string")
        throw new Error("Only a scoped OpenClaw Gateway may inherit one listener");
      const lease = leases[0];
      if (initialize.gatewayPort !== undefined && initialize.gatewayPort !== lease.port) throw new Error("Gateway port differs from the owned listener");
      const transfer = this.listenerTransfer = prepareHostListenerTransfer(leases, initialize.agentId);
      const descriptor = transfer.descriptors[0];
      initialize.gatewayPort = descriptor.port;
      initialize.gatewayListener = { transport: "inherited-fd-v1", fd: descriptor.fd, host: descriptor.host, port: descriptor.port };
    }
    let child: ChildProcessWithoutNullStreams;
    try {
      child = this.child = spawn(this.configuration.command, this.configuration.args, {
        stdio: ["pipe", "pipe", "pipe", ...(this.listenerTransfer?.descriptors.map(d => d.stdioFd) ?? [])], env,
      }) as ChildProcessWithoutNullStreams;
    } catch (error) { await this.listenerTransfer?.release(); throw error; }
    this.exited = new Promise(resolve => child.once("close", () => resolve()));
    child.stderr.resume(); // Diagnostics are not user history or model context.
    child.stdout.on("data", (chunk: Buffer) => {
      if (this.dead) return;
      this.buffer = Buffer.concat([this.buffer, chunk]);
      let newline: number;
      while ((newline = this.buffer.indexOf(10)) >= 0) {
        if (newline > HARNESS_FRAME_BYTES) return this.fail("Harness protocol frame exceeded its limit");
        const line = this.buffer.subarray(0, newline); this.buffer = this.buffer.subarray(newline + 1);
        try {
          const frame = JSON.parse(line.toString("utf8"));
          if (frame.jsonrpc !== "2.0") throw new Error("Invalid protocol");
          if (frame.method === "harness.event" && validHarnessEvent(frame.params)) {
            const kind = frame.params.kind as HarnessEvent["kind"];
            if ((kind === "action.open" || kind === "action.cancel") && !this.ready?.extensions?.conversationActions
              || (kind === "agent.message" || kind === "agent.message.status") && !this.ready?.extensions?.agentMessaging)
              throw new Error("Unnegotiated harness extension event");
            for (const listener of this.listeners) listener(frame.params);
          } else if (frame.method === "worker.memory" && typeof frame.id === "string") {
            this.receiveWorkerTool(frame);
          } else if (frame.method === "worker.memory.cancel") {
            // Private ordered transport: cancel only a request admitted from this
            // exact child. No model-owned execution selector or global abort.
            if (Object.keys(frame).length !== 3 || !frame.params || typeof frame.params !== "object"
              || Array.isArray(frame.params) || Object.keys(frame.params).length !== 1
              || typeof frame.params.requestId !== "string" || !this.toolRequests.has(frame.params.requestId))
              throw new Error("Invalid worker tool cancellation");
            this.toolControllers.get(frame.params.requestId)?.abort();
          } else if (typeof frame.id === "string" && ("result" in frame || "error" in frame)) {
            const pending = this.pending.get(frame.id);
            if (!pending) throw new Error("Unknown receipt");
            this.pending.delete(frame.id); clearTimeout(pending.timer);
            if (frame.error) pending.reject(new Error(`Harness refused request (${String(frame.error.code)})`));
            else pending.resolve(frame.result);
          } else throw new Error("Invalid frame");
        } catch { return this.fail("Harness protocol became unavailable"); }
      }
      if (this.buffer.length > HARNESS_FRAME_BYTES) this.fail("Harness protocol frame exceeded its limit");
    });
    child.once("error", () => this.fail("Harness process could not start"));
    child.once("close", () => this.fail("Harness process exited"));
    child.stdin.on("error", () => this.fail("Harness input became unavailable"));
    // Attach failure/protocol listeners first, then settle the actual spawn receipt.
    // Consumed capabilities cannot be reused by another process or restart.
    if (this.listenerTransfer) await this.listenerTransfer.afterSpawn(child);
    const ready = await this.request("initialize", { ...initialize, protocolVersion: 1 });
    if (!ready || ready.protocolVersion !== 1 || ready.pluginId !== this.configuration.pluginId
      || ready.upstreamVersion !== this.configuration.upstreamVersion || !ready.capabilities
      || ["backgroundTasks", "targetedSteer", "taskStop", "approvals", "reconnect", "attachments"].some(k => typeof ready.capabilities[k] !== "boolean")
      || ready.extensions !== undefined && !validHarnessExtensions(ready.extensions)
      || ready.lifecycle !== undefined && !validHarnessLifecycle(ready.lifecycle)
      || lifecycle?.mode === "connected" && (!ready.extensions?.connectedLifecycle || ready.lifecycle?.mode !== "connected"
        || ready.lifecycle.connectionId !== lifecycle.connectionId)
      || lifecycle?.mode !== "connected" && ready.lifecycle?.mode === "connected") {
      this.fail("Incompatible harness version or capability contract");
      throw new Error("Incompatible harness version or capability contract");
    }
    const agentId = this.configuration.initialize.agentId, isolation = this.configuration.initialize.isolation as Record<string, unknown> | undefined;
    if (agentId !== undefined && (ready.agentId !== agentId || lifecycle?.mode !== "connected" && (!isolation || !ready.isolation
      || ready.isolation.backend !== isolation.backend || ready.isolation.agentId !== agentId
      || ready.isolation.policyDigest !== isolation.policyDigest))) {
      this.fail("Harness did not confirm its scoped agent identity");
      throw new Error("Harness did not confirm its scoped agent identity");
    }
    if (initialize.workerMemory === true && (ready.workerMemory !== true || !this.configuration.workerTool)) {
      this.fail("Harness did not confirm uniform worker memory");
      throw new Error("Harness did not confirm uniform worker memory");
    }
    this.ready = ready;
    return ready;
  }
  private receiveWorkerTool(frame: Record<string, any>): void {
    if (Object.keys(frame).some(k => !["jsonrpc", "id", "method", "params"].includes(k))
      || !/^[a-zA-Z0-9_.-]{1,128}$/.test(frame.id) || frame.id.trim() !== frame.id || this.toolRequests.has(frame.id))
      throw new Error("Invalid or repeated worker tool request");
    const reply = (result?: unknown, error?: { code: number; message: string }) => {
      if (this.dead || this.closing || this.toolAbort.signal.aborted) return;
      const encoded = JSON.stringify({ jsonrpc: "2.0", id: frame.id, ...(error ? { error } : { result }) }) + "\n";
      if (Buffer.byteLength(encoded) > HARNESS_FRAME_BYTES || !this.child || this.child.stdin.writableLength > 8 * 1024 * 1024)
        return this.fail("Worker tool response exceeded its bound");
      this.child.stdin.write(encoded);
    };
    if (!this.ready || this.configuration.initialize.workerMemory !== true || !this.configuration.workerTool
      || this.activeTools >= HARNESS_PENDING_REQUESTS || this.toolRequests.size >= 4096) {
      reply(undefined, { code: -32003, message: "Worker tool unavailable" }); return;
    }
    this.toolRequests.add(frame.id); this.activeTools++;
    const controller = new AbortController();
    this.toolControllers.set(frame.id, controller);
    const signal = AbortSignal.any([this.toolAbort.signal, controller.signal]);
    // No replay. Durable mutation identity is checked independently by the memory store.
    // A native tool cancellation must also reach the final host approval/apply guard.
    void Promise.resolve().then(() => {
      signal.throwIfAborted();
      return this.configuration.workerTool!("worker.memory", frame.params, signal);
    }).then(value => reply(value), () => reply(undefined, { code: -32001, message: "Worker tool denied or unconfirmed; do not retry automatically" }))
      .finally(() => { this.toolControllers.delete(frame.id); this.activeTools--; });
  }
  request(method: string, params: Record<string, unknown>): Promise<any> {
    if (this.lifecycle?.mode === "connected" && method === "shutdown")
      return Promise.reject(new Error("Connected harness is externally managed; detach only"));
    // Hermes has one native opening gate even when sessions stream separately.
    // Serialize only opens; never serialize model turns across conversations.
    if (method === "session.open") {
      const opened = this.sessionOpens.then(() => this.send(method, params));
      this.sessionOpens = opened.catch(() => {}); return opened;
    }
    return this.send(method, params);
  }
  private send(method: string, params: Record<string, unknown>): Promise<any> {
    if (this.dead || !this.child || this.closing && method !== "shutdown" && method !== "detach") return Promise.reject(new Error("Harness unavailable"));
    if (this.pending.size >= HARNESS_PENDING_REQUESTS) return Promise.reject(new Error("Harness request window is full"));
    const id = randomUUID(); const encoded = JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n";
    if (Buffer.byteLength(encoded) > HARNESS_FRAME_BYTES) return Promise.reject(new Error("Harness request exceeded its limit"));
    if (this.child.stdin.writableLength > 8 * 1024 * 1024) {
      this.fail("Harness input queue exceeded its limit"); return Promise.reject(new Error("Harness unavailable"));
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => this.fail("Harness receipt is unconfirmed"), method === "initialize" ? 120_000 : 35_000);
      this.pending.set(id, { resolve, reject, timer });
      this.child!.stdin.write(encoded);
    });
  }
  invalidate(reason: string): void { this.fail(reason); }
  private fail(reason: string): void {
    if (this.dead) return;
    this.dead = true;
    this.toolAbort.abort(new Error("Owned harness is unavailable"));
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.reject(new Error(reason)); }
    this.pending.clear();
    if (!this.closing) for (const listener of this.failures) listener(reason);
    this.child?.kill("SIGTERM");
  }
  async close(): Promise<void> {
    if (this.closing) return this.exited;
    this.closing = true;
    this.toolAbort.abort(new Error("Owned harness is closing"));
    if (!this.dead) {
      // This process is our bridge. The harness behind a connection belongs to its
      // external owner; detach must only release the bridge's transport/session watch.
      await this.request(this.lifecycle?.mode === "connected" ? "detach" : "shutdown", {}).catch(() => {});
      this.child?.stdin.end();
    }
    this.fail("Harness closed");
    const timer = setTimeout(() => this.child?.kill("SIGKILL"), 5000);
    try { await this.exited; } finally {
      clearTimeout(timer);
      if (this.listenerTransfer) await this.listenerTransfer.release();
      else if (this.configuration.inheritedListeners?.length && typeof this.configuration.initialize.agentId === "string") {
        // An idle prepared actor can be retired before start. Release only its
        // authentic, still-held capabilities; never close another owner's socket.
        let held: readonly HostListenerLease[] = [];
        try { held = validateHostListeners(this.configuration.inheritedListeners, this.configuration.initialize.agentId); } catch { /* Never adopt/release unowned handles. */ }
        await Promise.all(held.map(releaseHostListener));
      }
    }
  }
}

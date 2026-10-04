import { randomUUID } from "node:crypto";
import { ChildProcess } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import { validAgentId } from "./agent-scope.js";

const leaseBrand: unique symbol = Symbol("HostListenerLease");
export interface HostListenerLease {
  readonly [leaseBrand]: true;
  readonly version: 1;
  readonly id: string;
  readonly agentId: string;
  readonly host: "127.0.0.1";
  readonly port: number;
}
export interface HostListenerDescriptor {
  readonly leaseId: string;
  readonly agentId: string;
  readonly host: "127.0.0.1";
  readonly port: number;
  /** Descriptor number in the child and initialize message, beginning at FD3. */
  readonly fd: number;
  /** Numeric stdio entry in the host's spawn call. Host only; never serialized. */
  readonly stdioFd: number;
}
export interface HostListenerTransfer {
  readonly descriptors: readonly HostListenerDescriptor[];
  /** Call immediately after spawn. Consumes once and closes all parent copies, even on failure. */
  afterSpawn(child: ChildProcess): Promise<void>;
  /** Idempotent cancellation, including synchronous spawn failure. */
  release(): Promise<void>;
}
interface LeaseState {
  lease: HostListenerLease;
  fd: number;
  server: net.Server;
  phase: "held" | "prepared" | "transferred" | "released";
  closing?: Promise<void>;
  transfer?: HostListenerTransfer;
}
interface TransferState { leases: LeaseState[]; phase: "pending" | "settling" | "done"; cancelPendingSpawn?: () => void }
const minted = new WeakSet<object>();
const leases = new WeakMap<object, LeaseState>();
const transfers = new WeakMap<object, TransferState>();
const numericPort = (port: unknown): port is number => Number.isInteger(port) && (port as number) >= 1024 && (port as number) <= 65535;
function closeServer(server: net.Server): Promise<void> {
  return new Promise((resolve, reject) => {
    server.close(error => {
      if (error && (error as NodeJS.ErrnoException).code !== "ERR_SERVER_NOT_RUNNING") reject(error);
      else resolve();
    });
  });
}
function stateOf(lease: unknown): LeaseState {
  if (!lease || typeof lease !== "object" || !minted.has(lease)) throw new Error("Listener lease was not minted by this host");
  const state = leases.get(lease);
  if (!state) throw new Error("Unknown host listener lease");
  return state;
}
function liveState(lease: unknown, agentId: string): LeaseState {
  const state = stateOf(lease);
  if (state.lease.agentId !== agentId) throw new Error("Listener lease belongs to another agent");
  // Check lifecycle before touching fd: a consumed descriptor may already be reused.
  if (state.phase !== "held") throw new Error("Listener lease is stale or already transferred");
  const address = state.server.address();
  if (!state.server.listening || !address || typeof address === "string"
    || address.address !== "127.0.0.1" || address.port !== state.lease.port
    || !fs.fstatSync(state.fd).isSocket()) throw new Error("Host listener descriptor is no longer live");
  return state;
}
/** Acquire only in trusted host code. Never accept a model/client supplied socket or fd.
 * Node26's public BoundSocket API binds numeric loopback before confinement. A child
 * can adopt the resulting descriptor under exact-port inbound permission and no bind grant.
 */
export async function acquireHostListener(agentId: string, port?: number): Promise<HostListenerLease> {
  if (!validAgentId(agentId)) throw new Error("Invalid listener agent identity");
  if (port !== undefined && !numericPort(port)) throw new Error("Invalid host listener port");
  if (process.platform !== "darwin" || typeof net.BoundSocket !== "function")
    throw new Error("This host cannot acquire a confined inherited listener");
  let bound: net.BoundSocket | undefined, server: net.Server | undefined;
  try {
    bound = new net.BoundSocket({ host: "127.0.0.1", port: port ?? 0 });
    const fd = bound.fd(), address = bound.address();
    if (!Number.isInteger(fd) || fd < 3 || typeof address === "string"
      || address.address !== "127.0.0.1" || !numericPort(address.port) || !fs.fstatSync(fd).isSocket())
      throw new Error("Invalid host bound listener descriptor");
    server = net.createServer(socket => socket.destroy());
    await new Promise<void>((resolve, reject) => {
      const fail = (error: Error): void => { reject(error); };
      server!.once("error", fail);
      server!.listen(bound!, () => { server!.removeListener("error", fail); resolve(); });
    });
    const lease = Object.freeze({ [leaseBrand]: true as const, version: 1 as const, id: randomUUID(),
      agentId, host: "127.0.0.1" as const, port: address.port });
    const state: LeaseState = { lease, fd, server, phase: "held" };
    minted.add(lease); leases.set(lease, state);
    server.on("error", () => { void releaseHostListener(lease).catch(() => {}); });
    liveState(lease, agentId);
    return lease;
  } catch (error) {
    if (server) await closeServer(server).catch(() => {});
    try { bound?.close(); } catch { /* An adopted descriptor belongs to server. */ }
    throw error;
  }
}
/** Inspect held capabilities only. Plain objects, persisted metadata and consumed leases fail closed. */
export function validateHostListeners(values: readonly HostListenerLease[], agentId: string): readonly HostListenerLease[] {
  if (!validAgentId(agentId) || !Array.isArray(values) || values.length > 4)
    throw new Error("Invalid inherited listener selection");
  if (new Set(values).size !== values.length) throw new Error("Duplicate host listener lease");
  const states = values.map(value => liveState(value, agentId));
  if (new Set(states.map(state => state.fd)).size !== states.length || new Set(states.map(state => state.lease.port)).size !== states.length)
    throw new Error("Duplicate host listener descriptor");
  return Object.freeze(states.map(state => state.lease));
}
function closeState(state: LeaseState, phase: "released" | "transferred"): Promise<void> {
  if (!state.closing) {
    state.phase = phase;
    state.closing = closeServer(state.server);
  }
  return state.closing;
}
function transferOf(value: HostListenerTransfer): TransferState {
  const state = transfers.get(value);
  if (!state) throw new Error("Listener transfer was not prepared by this host");
  return state;
}
async function cancelTransfer(transfer: HostListenerTransfer): Promise<void> {
  const state = transferOf(transfer);
  state.phase = "done";
  state.cancelPendingSpawn?.();
  await Promise.all(state.leases.map(lease => closeState(lease, "released")));
}
async function settleTransfer(transfer: HostListenerTransfer, child: ChildProcess): Promise<void> {
  const state = transferOf(transfer);
  if (state.phase !== "pending") throw new Error("Listener transfer has already been settled");
  state.phase = "settling";
  let inherited = false;
  try {
    if (!(child instanceof ChildProcess)) throw new Error("Invalid host spawn receipt");
    if (child.pid === undefined && (child.exitCode !== null || child.signalCode !== null))
      throw new Error("Child stopped before listener inheritance");
    if (!child.pid) await new Promise<void>((resolve, reject) => {
      const cleanup = (): void => { child.removeListener("error", failed); child.removeListener("spawn", spawned); state.cancelPendingSpawn = undefined; };
      const spawned = (): void => { cleanup(); resolve(); };
      const failed = (error: Error): void => { cleanup(); reject(error); };
      state.cancelPendingSpawn = () => failed(new Error("Listener transfer canceled before spawn receipt"));
      child.once("spawn", spawned); child.once("error", failed);
    });
    if (!Number.isInteger(child.pid) || child.pid! <= 0) throw new Error("Invalid host spawn receipt");
    if (state.phase !== "settling" || state.leases.some(lease => lease.phase !== "prepared"))
      throw new Error("Listener transfer was canceled before inheritance");
    inherited = true;
  } finally {
    state.phase = "done";
    await Promise.all(state.leases.map(lease => closeState(lease, inherited ? "transferred" : "released")));
  }
}
/** Compile isolation while held, then prepare once and place each stdioFd in its fd slot.
 * Call afterSpawn immediately on the real spawn result, or release after a synchronous
 * spawn exception. This capability and raw descriptor entries stay in host memory only.
 */
export function prepareHostListenerTransfer(values: readonly HostListenerLease[], agentId: string): HostListenerTransfer {
  const verified = validateHostListeners(values, agentId);
  if (!verified.length) throw new Error("No host listeners to transfer");
  const states = verified.map(value => stateOf(value));
  const descriptors = Object.freeze(states.map((state, index) => Object.freeze({ leaseId: state.lease.id,
    agentId, host: state.lease.host, port: state.lease.port, fd: index + 3, stdioFd: state.fd })));
  const transfer: HostListenerTransfer = Object.freeze({ descriptors,
    afterSpawn: (child: ChildProcess) => settleTransfer(transfer, child), release: () => cancelTransfer(transfer) });
  transfers.set(transfer, { leases: states, phase: "pending" });
  for (const state of states) { state.phase = "prepared"; state.transfer = transfer; }
  return transfer;
}
export async function releaseHostListener(lease: HostListenerLease): Promise<void> {
  const state = stateOf(lease);
  if (state.phase === "prepared" && state.transfer) return cancelTransfer(state.transfer);
  await closeState(state, "released");
}

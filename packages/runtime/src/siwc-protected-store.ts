/** Host-only JSON-lines bridge to one fixed signed native accounts helper.
 * No constructor/status I/O, environment discovery, plaintext store or helper restart. */
import { spawn, execFile } from "node:child_process";
import { randomBytes } from "node:crypto";
import { AsyncLocalStorage } from "node:async_hooks";
import { lstat, realpath } from "node:fs/promises";
import path from "node:path";
import type { Readable, Writable } from "node:stream";
import { SiwcAccountError, SIWC_AUTHORIZATION_URL, SIWC_RESOURCE, validateSiwcProtectedSnapshot,
  type SiwcProtectedAccountStore, type SiwcProtectedSnapshot } from "./siwc-account-lifecycle.js";

export const SIWC_HELPER_TEAM = "AN5KM8QGEF" as const; // Shipping signer in scripts/build-mac.sh.
export const SIWC_HELPER_IDENTIFIER = "to.yumi.yorozu.accounts" as const;
export const SIWC_HELPER_SNAPSHOT_BYTES = 1024 * 1024;
export const SIWC_HELPER_LINE_BYTES = SIWC_HELPER_SNAPSHOT_BYTES + 16 * 1024;
const MAX_PENDING = 32;
const ENV = Object.freeze({ PATH: "/usr/bin:/bin:/usr/sbin:/sbin", LANG: "C", LC_ALL: "C" });
const id = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_.:-]{1,128}$/.test(v);
const leaseId = (v: unknown): v is string => typeof v === "string" && /^[a-f0-9]{64}$/.test(v);
const fields = (v: unknown, keys: string[]): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v)
  && [Object.prototype, null].includes(Object.getPrototypeOf(v)) && Object.keys(v).every(k => keys.includes(k));
function fail(code: "invalid" | "unsupported" | "conflict" | "unknown"): never { throw new SiwcAccountError(code); }
export interface SiwcNativeStoreConfiguration {
  /** Trusted native app configuration only; never caller/renderer/env-derived. */
  signedResourcesPath: string; executable: string; appIdentifier?: string;
  /** Synchronously retire all account-backed execution owners when this helper/lease is lost. */
  fenceAccounts(): void;
  requestTimeoutMs?: number;
}
export interface SiwcHelperChild {
  stdin: Writable; stdout: Readable;
  once(event: "error" | "close", listener: (...args: any[]) => void): unknown;
  kill(signal?: NodeJS.Signals): boolean;
}
export interface SiwcHelperInspector {
  path(target: string): Promise<{ realPath: string; kind: "file" | "directory" | "symlink" | "other"; mode: number }>;
  /** Fixed codesign only, bounded output and deadline, sanitized environment, no shell. */
  codesign(args: readonly string[], signal: AbortSignal): Promise<{ stdout: string; stderr: string }>;
}
export interface SiwcNativeStoreDependencies {
  inspector?: SiwcHelperInspector;
  spawnHelper?: (executable: string, args: readonly string[], options: {
    stdio: readonly ["pipe", "pipe", "ignore"]; env: Readonly<Record<string, string>>; cwd: string; shell: false;
  }) => SiwcHelperChild;
  platform?: NodeJS.Platform;
}
const nativeInspector: SiwcHelperInspector = {
  async path(target) {
    const info = await lstat(target), physical = await realpath(target);
    return { realPath: physical, kind: info.isSymbolicLink() ? "symlink" : info.isFile() ? "file" : info.isDirectory() ? "directory" : "other", mode: info.mode };
  },
  codesign(args, signal) {
    return new Promise((resolve, reject) => execFile("/usr/bin/codesign", [...args],
      { env: ENV, timeout: 5000, maxBuffer: 32 * 1024, encoding: "utf8", signal },
      (error, stdout, stderr) => error ? reject(new SiwcAccountError("unsupported")) : resolve({ stdout, stderr })));
  },
};
function trustedPaths(config: SiwcNativeStoreConfiguration): { app: string; resources: string; executable: string; identifier: string; timeout: number } {
  if (!fields(config, ["signedResourcesPath", "executable", "appIdentifier", "fenceAccounts", "requestTimeoutMs"])
    || typeof config.fenceAccounts !== "function") fail("invalid");
  for (const value of [config.signedResourcesPath, config.executable]) {
    if (typeof value !== "string" || value.length > 4096 || !path.isAbsolute(value) || path.normalize(value) !== value || /[\x00-\x1f\x7f]/.test(value)) fail("invalid");
  }
  const resources = config.signedResourcesPath, contents = path.dirname(resources), app = path.dirname(contents);
  if (path.basename(resources) !== "Resources" || path.basename(contents) !== "Contents" || !path.basename(app).endsWith(".app")
    || config.executable !== path.join(resources, "yorozu-accounts")) fail("invalid");
  const identifier = config.appIdentifier ?? "to.yumi.yorozu";
  if (!/^[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+){1,12}$/.test(identifier) || identifier.length > 128) fail("invalid");
  const timeout = config.requestTimeoutMs ?? 30_000;
  if (!Number.isSafeInteger(timeout) || timeout < 1 || timeout > 30_000) fail("invalid");
  return { app, resources, executable: config.executable, identifier, timeout };
}
async function trustedHelper(config: ReturnType<typeof trustedPaths>, inspector: SiwcHelperInspector, signal: AbortSignal): Promise<void> {
  for (const target of [config.app, path.dirname(config.resources), config.resources, config.executable]) {
    const info = await inspector.path(target);
    if (signal.aborted || info.realPath !== target || info.kind !== (target === config.executable ? "file" : "directory")
      || !Number.isSafeInteger(info.mode) || (info.mode & 0o022) !== 0 || target === config.executable && !(info.mode & 0o100)) fail("unsupported");
  }
  for (const [target, identifier] of [[config.app, config.identifier], [config.executable, SIWC_HELPER_IDENTIFIER]]) {
    if (signal.aborted) fail("unsupported");
    const requirement = `identifier "${identifier}" and anchor apple generic and certificate leaf[subject.OU] = "${SIWC_HELPER_TEAM}"`;
    await inspector.codesign(["--verify", "--strict", "-R=" + requirement, target], signal);
    if (signal.aborted) fail("unsupported");
    const display = await inspector.codesign(["--display", "--verbose=4", "-r-", target], signal);
    if (display.stdout.length + display.stderr.length > 64 * 1024) fail("unsupported");
    const text = display.stdout + "\n" + display.stderr;
    const teams = [...text.matchAll(/^TeamIdentifier=(.*)$/gm)], ids = [...text.matchAll(/^Identifier=(.*)$/gm)];
    if (teams.length !== 1 || teams[0][1].trim() !== SIWC_HELPER_TEAM || ids.length !== 1 || ids[0][1].trim() !== identifier
      || !text.includes("designated =>") || !text.includes("anchor apple generic")
      || !new RegExp(`certificate leaf\\[subject\\.OU\\]\\s*=\\s*"?${SIWC_HELPER_TEAM}"?(?:\\s|$)`).test(text)) fail("unsupported");
  }
}
async function abortBound<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  return new Promise((resolve, reject) => {
    const abort = (): void => reject(new SiwcAccountError("unknown")); signal.addEventListener("abort", abort, { once: true });
    work.then(resolve, reject).finally(() => signal.removeEventListener("abort", abort));
    if (signal.aborted) abort();
  });
}
/** Duplicate-aware JSON parser for bounded native frames (including escaped member aliases). */
function frameJson(bytes: Buffer): unknown {
  const source = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
  let index = 0, nodes = 0;
  const space = (): void => { while (/[\x20\t\r\n]/.test(source[index] ?? "!")) index++; };
  const string = (): string => {
    const begin = index++; let escape = false;
    while (index < source.length) {
      const char = source[index++];
      if (!escape && char === '"') { const out = JSON.parse(source.slice(begin, index));
        if (typeof out !== "string" || out.length > 32_768) fail("unknown"); return out; }
      if (!escape && char === "\\") escape = true; else escape = false;
    } return fail("unknown");
  };
  const value = (depth: number): unknown => {
    space(); if (depth > 16 || ++nodes > 16_384) fail("unknown"); const c = source[index];
    if (c === '"') return string();
    if (c === "{") {
      index++; space(); const out: Record<string, unknown> = Object.create(null), seen = new Set<string>();
      if (source[index] === "}") { index++; return out; }
      while (true) { space(); if (source[index] !== '"') fail("unknown"); const key = string();
        if (seen.size >= 128 || seen.has(key) || ["__proto__", "constructor", "prototype"].includes(key)) fail("unknown"); seen.add(key);
        space(); if (source[index++] !== ":") fail("unknown"); out[key] = value(depth + 1); space();
        const separator = source[index++]; if (separator === "}") return out; if (separator !== ",") fail("unknown"); }
    }
    if (c === "[") {
      index++; space(); const out: unknown[] = []; if (source[index] === "]") { index++; return out; }
      while (true) { if (out.length >= 128) fail("unknown"); out.push(value(depth + 1)); space();
        const separator = source[index++]; if (separator === "]") return out; if (separator !== ",") fail("unknown"); }
    }
    for (const [literal, decoded] of [["true", true], ["false", false], ["null", null]] as const)
      if (source.startsWith(literal, index)) { index += literal.length; return decoded; }
    const number = /^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?/.exec(source.slice(index));
    if (!number) fail("unknown"); index += number[0].length; const n = Number(number[0]); if (!Number.isFinite(n)) fail("unknown"); return n;
  };
  const result = value(0); space(); if (index !== source.length) fail("unknown"); return result;
}
function boundedSnapshot(v: unknown, host?: { hostId: string; appName: string }): SiwcProtectedSnapshot {
  if (!validateSiwcProtectedSnapshot(v, host) || v.appName !== "Yorozu" || Buffer.byteLength(JSON.stringify(v)) > SIWC_HELPER_SNAPSHOT_BYTES) fail("invalid");
  return structuredClone(v);
}
type Command = "available" | "initialize" | "read" | "replace" | "lock" | "unlock" | "open-browser";
type State = "dormant" | "activating" | "active" | "unsupported" | "unknown" | "closed";
interface Pending { resolve(value: unknown): void; reject(error: SiwcAccountError): void; timer: NodeJS.Timeout; removeAbort(): void; }
interface Lease { id: string; binding: string; live: boolean; }
/** Only explicit activate/openBrowser host actions can start native work. */
export class SiwcNativeProtectedStore implements SiwcProtectedAccountStore {
  readonly protection = "os-protected" as const;
  private state: State = "dormant";
  private readonly config: ReturnType<typeof trustedPaths>;
  private child?: SiwcHelperChild;
  private buffer = Buffer.alloc(0);
  private pending = new Map<string, Pending>();
  private leases = new Map<string, Lease>();
  private locking = new Set<string>();
  private ownership = new AsyncLocalStorage<Lease>();
  private host?: { hostId: string; appName: string };
  private activation?: Promise<SiwcProtectedSnapshot>;
  private fenceCalled = false;
  private lost = new AbortController();
  constructor(private readonly supplied: SiwcNativeStoreConfiguration, private readonly dependencies: SiwcNativeStoreDependencies = {}) {
    this.config = trustedPaths(supplied); // Lexical checks only; no filesystem/process/credential work.
    this.supplied = Object.freeze({ ...supplied }); this.dependencies = Object.freeze({ ...dependencies });
  }
  available(): boolean { return this.state === "active"; } // Synchronous cached evidence only.
  status(): Readonly<{ productionReady: false; available: boolean; state: State }> {
    return Object.freeze({ productionReady: false, available: this.available(), state: this.state });
  }
  private terminal(state: "unknown" | "unsupported" | "closed"): void {
    if (["unknown", "unsupported", "closed"].includes(this.state)) return;
    this.state = state;
    this.buffer = Buffer.alloc(0);
    for (const lease of this.leases.values()) lease.live = false;
    this.leases.clear(); this.lost.abort();
    for (const p of this.pending.values()) { clearTimeout(p.timer); p.removeAbort(); p.reject(new SiwcAccountError(state === "unknown" ? "unknown" : "unsupported")); }
    this.pending.clear();
    if (!this.fenceCalled) { this.fenceCalled = true; try { this.supplied.fenceAccounts(); } catch { this.state = "unknown"; } }
    try { this.child?.stdin.destroy(); this.child?.kill("SIGTERM"); } catch { /* No confirmed physical-cessation claim. */ }
  }
  private data(chunk: unknown): void {
    if (!Buffer.isBuffer(chunk) || !["activating", "active"].includes(this.state)) { this.terminal("unknown"); return; }
    let offset = 0;
    while (offset < chunk.length) {
      const newline = chunk.indexOf(10, offset), end = newline < 0 ? chunk.length : newline;
      if (this.buffer.length + end - offset > SIWC_HELPER_LINE_BYTES) { this.terminal("unknown"); return; }
      this.buffer = Buffer.concat([this.buffer, chunk.subarray(offset, end)]);
      if (newline < 0) return;
      const line = this.buffer; this.buffer = Buffer.alloc(0); offset = newline + 1;
      try {
        const v = frameJson(line);
        if (!fields(v, ["version", "rid", "ok", "value", "error"]) || v.version !== 1 || !id(v.rid) || typeof v.ok !== "boolean") fail("unknown");
        const p = this.pending.get(v.rid); if (!p) fail("unknown");
        if (v.ok ? !Object.hasOwn(v, "value") || Object.hasOwn(v, "error")
          : !Object.hasOwn(v, "error") || Object.hasOwn(v, "value") || !["invalid", "unsupported", "conflict", "unknown"].includes(v.error)) fail("unknown");
        this.pending.delete(v.rid); clearTimeout(p.timer); p.removeAbort();
        if (v.ok) p.resolve(v.value);
        else { p.reject(new SiwcAccountError(v.error)); if (v.error === "unknown" || v.error === "unsupported") this.terminal(v.error); }
      } catch { this.terminal("unknown"); return; }
    }
  }
  private request(command: Command, payload?: unknown, signal?: AbortSignal): Promise<unknown> {
    if (!this.child || !["activating", "active"].includes(this.state)) return Promise.reject(new SiwcAccountError(this.state === "unknown" ? "unknown" : "unsupported"));
    if (signal?.aborted) return Promise.reject(new SiwcAccountError("invalid"));
    if (this.pending.size >= MAX_PENDING) return Promise.reject(new SiwcAccountError("conflict"));
    const rid = randomBytes(16).toString("hex"), frame = JSON.stringify({ version: 1, rid, command, ...(payload === undefined ? {} : { payload }) }) + "\n";
    if (Buffer.byteLength(frame) > SIWC_HELPER_LINE_BYTES + 1) return Promise.reject(new SiwcAccountError("invalid"));
    return new Promise((resolve, reject) => {
      const abort = (): void => this.terminal("unknown");
      const timer = setTimeout(abort, this.config.timeout); timer.unref();
      signal?.addEventListener("abort", abort, { once: true });
      this.pending.set(rid, { resolve, reject, timer, removeAbort: () => signal?.removeEventListener("abort", abort) });
      try { this.child!.stdin.write(frame, "utf8", error => { if (error) this.terminal("unknown"); }); }
      catch { this.terminal("unknown"); }
    });
  }
  async activate(signal?: AbortSignal): Promise<SiwcProtectedSnapshot> {
    if (this.available()) return this.read();
    if (this.state === "activating" && this.activation) return structuredClone(await this.activation);
    if (this.state !== "dormant") fail(this.state === "unknown" ? "unknown" : "unsupported");
    this.state = "activating";
    this.activation = (async () => {
      const controller = new AbortController(), abort = (): void => controller.abort(); signal?.addEventListener("abort", abort, { once: true });
      if (signal?.aborted) abort(); const timer = setTimeout(abort, 30_000); timer.unref();
      try {
        if ((this.dependencies.platform ?? process.platform) !== "darwin" || controller.signal.aborted) fail("unsupported");
        const inspector = this.dependencies.inspector ?? nativeInspector;
        await abortBound(trustedHelper(this.config, inspector, controller.signal), controller.signal);
        if (controller.signal.aborted || this.state !== "activating") fail("unknown");
        const launch = this.dependencies.spawnHelper ?? ((exe, args, options) => spawn(exe, [...args], { ...options, stdio: [...options.stdio] }) as SiwcHelperChild);
        const child = this.child = launch(this.config.executable, [], { stdio: ["pipe", "pipe", "ignore"], env: ENV, cwd: this.config.resources, shell: false });
        child.once("error", () => this.terminal("unknown")); child.once("close", () => this.terminal("unknown"));
        child.stdin.on("error", () => this.terminal("unknown")); child.stdout.on("error", () => this.terminal("unknown"));
        child.stdout.on("end", () => this.terminal("unknown")); child.stdout.on("data", (chunk: Buffer) => this.data(chunk));
        const available = await this.request("available", undefined, controller.signal);
        if (typeof available !== "boolean") { this.terminal("unknown"); fail("unknown"); }
        if (!available) { this.terminal("unsupported"); fail("unsupported"); }
        const raw = await this.request("initialize", { appName: "Yorozu" }, controller.signal);
        // A valid reply can be followed by EOF/abort/another malformed frame before
        // this continuation runs. A terminal helper must never be resurrected.
        if (this.state !== "activating" || controller.signal.aborted || this.lost.signal.aborted) fail("unknown");
        let snapshot: SiwcProtectedSnapshot; try { snapshot = boundedSnapshot(raw); } catch { this.terminal("unknown"); fail("unknown"); }
        this.host = { hostId: snapshot.hostId, appName: snapshot.appName }; this.state = "active"; return snapshot;
      } catch (error) {
        const uncertain = !!this.child || error instanceof SiwcAccountError && error.code === "unknown";
        this.terminal(uncertain ? "unknown" : "unsupported");
        throw new SiwcAccountError(this.state === "unknown" ? "unknown" : "unsupported");
      } finally { clearTimeout(timer); signal?.removeEventListener("abort", abort); controller.abort(); }
    })();
    return structuredClone(await this.activation);
  }
  async read(): Promise<SiwcProtectedSnapshot> {
    if (!this.available() || !this.host) fail(this.state === "unknown" ? "unknown" : "unsupported");
    const raw = await this.request("read");
    if (!this.available()) fail("unknown");
    try { return boundedSnapshot(raw, this.host); } catch { this.terminal("unknown"); return fail("unknown"); }
  }
  async replace(expectedRevision: number, next: SiwcProtectedSnapshot): Promise<"committed" | "conflict"> {
    const lease = this.ownership.getStore();
    if (!lease?.live || this.leases.get(lease.id) !== lease || !this.available()) fail(this.state === "unknown" ? "unknown" : "invalid");
    if (!Number.isSafeInteger(expectedRevision) || expectedRevision < 0 || next?.revision !== expectedRevision + 1 || !this.host) fail("invalid");
    const snapshot = boundedSnapshot(next, this.host);
    const value = await this.request("replace", { expectedRevision, next: snapshot });
    if (!this.available() || !lease.live) fail("unknown");
    if (value !== "committed" && value !== "conflict") { this.terminal("unknown"); fail("unknown"); }
    return value;
  }
  async withAccountLock<T>(accountBindingId: string, operation: () => Promise<T>): Promise<T> {
    if (!id(accountBindingId) || typeof operation !== "function") fail("invalid");
    if (!this.available()) fail(this.state === "unknown" ? "unknown" : "unsupported");
    if (this.leases.size + this.locking.size >= 32 || this.locking.has(accountBindingId) || [...this.leases.values()].some(l => l.binding === accountBindingId)) fail("conflict");
    this.locking.add(accountBindingId);
    let raw: unknown;
    try { raw = await this.request("lock", { accountBindingId }); } finally { this.locking.delete(accountBindingId); }
    if (!this.available() || !leaseId(raw) || this.leases.has(raw) || [...this.leases.values()].some(l => l.binding === accountBindingId)) { this.terminal("unknown"); fail("unknown"); }
    const lease: Lease = { id: raw, binding: accountBindingId, live: true }; this.leases.set(raw, lease);
    let lost!: () => void; const loss = new Promise<never>((_, reject) => { lost = () => reject(new SiwcAccountError("unknown")); this.lost.signal.addEventListener("abort", lost, { once: true }); });
    if (this.lost.signal.aborted) lost();
    try {
      const result = await Promise.race([this.ownership.run(lease, () => Promise.resolve().then(operation)), loss]);
      if (!lease.live || !this.available()) fail("unknown"); return result;
    } finally {
      this.lost.signal.removeEventListener("abort", lost);
      if (lease.live && this.available()) {
        try { const unlocked = await this.request("unlock", { lease: lease.id }); if (unlocked !== true || !this.available() || !lease.live) fail("unknown"); }
        catch { this.terminal("unknown"); fail("unknown"); }
      } else fail("unknown");
      lease.live = false; this.leases.delete(lease.id);
    }
  }
  async openBrowser(authorizationUrl: string, signal?: AbortSignal): Promise<Readonly<{ opened: boolean }>> {
    if (!this.available() || !this.host) fail(this.state === "unknown" ? "unknown" : "unsupported");
    if (!validAuthorizationUrl(authorizationUrl, this.host.hostId)) fail("invalid");
    const value = await this.request("open-browser", { authorizationUrl }, signal);
    if (!this.available()) fail("unknown");
    if (!fields(value, ["opened"]) || typeof value.opened !== "boolean") { this.terminal("unknown"); fail("unknown"); }
    return Object.freeze({ opened: value.opened });
  }
  close(): void { this.terminal("closed"); }
}
function validAuthorizationUrl(value: unknown, hostId: string): value is string {
  if (typeof value !== "string" || value.length > 48_000) return false;
  try {
    const u = new URL(value), p = u.searchParams;
    const allowed = ["client_id", "agent_name_hint", "ext_agent_host_id", "response_type", "redirect_uri", "scope", "resource", "state", "nonce", "code_challenge_method", "code_challenge", "id_token_hint", "login_hint"];
    if (u.origin + u.pathname !== SIWC_AUTHORIZATION_URL || u.username || u.password || u.hash || [...p.keys()].some(k => !allowed.includes(k) || p.getAll(k).length !== 1)
      || p.get("ext_agent_host_id") !== hostId || p.get("response_type") !== "code" || p.get("resource") !== SIWC_RESOURCE
      || p.get("scope") !== "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct" || p.get("code_challenge_method") !== "S256"
      || !["state", "nonce"].every(k => /^[A-Za-z0-9_-]{32,128}$/.test(p.get(k) ?? ""))
      || !/^[A-Za-z0-9_-]{43}$/.test(p.get("code_challenge") ?? "")
      || Buffer.from(p.get("code_challenge")!, "base64url").toString("base64url") !== p.get("code_challenge")) return false;
    const client = p.get("client_id"), initial = client === "dynamic_agent_client";
    if ((!initial && !/^oaiapp_[A-Za-z0-9_-]{1,128}$/.test(client ?? "")) || (initial ? p.get("agent_name_hint") !== "Yorozu" : p.has("agent_name_hint"))) return false;
    if (p.has("id_token_hint") && (initial || !/^[A-Za-z0-9._~-]{16,32768}$/.test(p.get("id_token_hint")!))
      || p.has("login_hint") && (initial || !/^[^\s\x00-\x1f]{1,256}$/.test(p.get("login_hint")!))) return false;
    const callback = new URL(p.get("redirect_uri") ?? "");
    return callback.protocol === "http:" && callback.hostname === "127.0.0.1" && callback.pathname === "/auth/callback" && !callback.username
      && !callback.password && !callback.search && !callback.hash && Number(callback.port) >= 1024 && Number(callback.port) <= 65535;
  } catch { return false; }
}

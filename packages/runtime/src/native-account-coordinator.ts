/** Native account commands only. Construction opens no browser, socket or protected store. */
import { createHash } from "node:crypto";
import { SIWC_AUTHORIZATION_URL, SiwcAccountError, SiwcAccountLifecycle, type SiwcAccountServices, type SiwcAccountStatus } from "./siwc-account-lifecycle.js";

export interface NativeSiwcCallbackRequest {
  method: string; url: string; host: string; remoteAddress: string; rawHeaders: readonly string[]; hasBody: boolean;
}
export interface NativeSiwcCallbackReply { status: number; text: string }
export interface NativeSiwcCallbackEndpoint { host: "127.0.0.1"; port: number; close(): void | Promise<void> }
export interface NativeSiwcCallbackFactory {
  acquire(handler: (request: NativeSiwcCallbackRequest) => Promise<NativeSiwcCallbackReply>, signal: AbortSignal): Promise<NativeSiwcCallbackEndpoint>;
}
export interface NativeSiwcBrowser {
  /** Host-only sensitive URL; it must never be serialized through a renderer/chat event. */
  openAuthorization(url: string, context: Readonly<{ operationId: string; signal: AbortSignal }>): Promise<{ status: "opened" | "rejected" | "unknown" }>;
}
export type NativeSiwcAccountCommand =
  | { operationId: string; method: "sign-in"; bindingId: string; returning: boolean }
  | { operationId: string; method: "cancel"; attemptId: string }
  | { operationId: string; method: "verify-pending" | "select" | "sign-out"; bindingId: string }
  | { operationId: string; method: "status" };
export type NativeSiwcOperationState = "pending" | "completed" | "cancelled" | "expired" | "rejected" | "unsupported" | "unknown";
export type NativeSiwcSafeStatus = Omit<SiwcAccountStatus, "nativeIntegration"> & { nativeIntegration: "wired-unverified" };
export interface NativeSiwcAccountResult {
  protocolVersion: 1; operationId: string; status: "pending" | "completed" | "rejected" | "unknown"; attemptId?: string;
  reason?: "unsupported" | "invalid" | "identity" | "permission" | "conflict" | "unknown" | "signed-out";
  account?: NativeSiwcSafeStatus;
  operations?: Array<{ operationId: string; status: "pending" | "completed" | "rejected" | "unknown"; attemptId?: string }>;
}
export type NativeSiwcLifecycle = Pick<SiwcAccountLifecycle, "beginSignIn" | "cancelSignIn" | "completeSignIn" | "verifyPending" | "selectAccount" | "signOut" | "status" | "close" | "getAccessToken" | "canExecute" | "isAccountCurrent">;
export interface NativeSiwcCoordinatorServices {
  /** Validate actual transport/native-app authority, including command-specific policy.
   * A model/chat/tool payload, claimed sender string or paired status privilege is insufficient. */
  validateSender(sender: unknown, command: Readonly<NativeSiwcAccountCommand>): boolean;
  /** Explicit native sign-in or host-owned saved-account activation only. Native storage
   * supplies/reuses the protected installation identity. Never called by status/construction. */
  initializeAccountServices(signal: AbortSignal): Promise<{ host: { hostId: string; appName: "Yorozu" }; services: SiwcAccountServices } | undefined>;
  nativeBrowser: NativeSiwcBrowser; callbackEndpoint: NativeSiwcCallbackFactory;
  /** Trusted host notification only; payload/URL/credentials are never passed. */
  onChange?(): void;
  /** Trusted test seam. Production uses the concrete lifecycle. Never supplied by a client. */
  makeLifecycle?(host: { hostId: string; appName: "Yorozu" }, services: SiwcAccountServices): NativeSiwcLifecycle;
}
interface Operation { digest: string; result: NativeSiwcAccountResult; work?: Promise<NativeSiwcAccountResult>; controller: AbortController }
interface Attempt { id: string; binding: string; operation: Operation; endpoint: NativeSiwcCallbackEndpoint;
  expiresAt: number; state: "awaiting" | "completing" | "closed"; timer: ReturnType<typeof setTimeout> }
const object = (v: unknown): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v);
const exact = (v: unknown, keys: string[]): v is Record<string, any> => object(v) && Object.keys(v).every(k => keys.includes(k));
const id = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_.:-]{1,128}$/.test(v);
const opaque = (v: unknown): v is string => typeof v === "string" && /^[a-f0-9]{64}$/.test(v);
const unavailable = (): NativeSiwcSafeStatus => ({ productionReady: false, nativeIntegration: "wired-unverified", available: false, state: "unsupported", accounts: [] });
function command(input: unknown): NativeSiwcAccountCommand | undefined {
  if (!object(input) || !id(input.operationId)) return;
  if (input.method === "status" && exact(input, ["operationId", "method"])) return { operationId: input.operationId, method: "status" };
  if (input.method === "cancel" && exact(input, ["operationId", "method", "attemptId"]) && opaque(input.attemptId)) return { operationId: input.operationId, method: "cancel", attemptId: input.attemptId };
  if (input.method === "sign-in" && exact(input, ["operationId", "method", "bindingId", "returning"]) && id(input.bindingId) && typeof input.returning === "boolean")
    return { operationId: input.operationId, method: "sign-in", bindingId: input.bindingId, returning: input.returning };
  if (["verify-pending", "select", "sign-out"].includes(input.method) && exact(input, ["operationId", "method", "bindingId"]) && id(input.bindingId))
    return { operationId: input.operationId, method: input.method, bindingId: input.bindingId } as NativeSiwcAccountCommand;
}
function safeStatus(v: SiwcAccountStatus, held: ReadonlySet<string>): NativeSiwcSafeStatus {
  if (!object(v) || !["available", "unsupported", "unknown"].includes(v.state) || !Array.isArray(v.accounts) || v.accounts.length > 32) return { ...unavailable(), state: "unknown" };
  const accounts: SiwcAccountStatus["accounts"] = [];
  for (const a of v.accounts) {
    if (!object(a) || !id(a.accountBindingId) || !["ready", "signed-out", "unknown"].includes(a.phase) || typeof a.planUse !== "boolean" || typeof a.active !== "boolean") return { ...unavailable(), state: "unknown" };
    const hold = held.has(a.accountBindingId);
    accounts.push({ accountBindingId: a.accountBindingId, phase: hold ? "unknown" : a.phase, planUse: !hold && a.planUse, active: !hold && a.active,
      ...(a.remoteRevocation !== undefined && ["confirmed", "unconfirmed"].includes(a.remoteRevocation) ? { remoteRevocation: a.remoteRevocation } : {}) });
  }
  return { ...unavailable(), available: v.available === true, state: v.state, accounts,
    ...(Number.isSafeInteger(v.revision) && v.revision! >= 0 ? { revision: v.revision } : {}),
    ...(id(v.activeAccountBindingId) && !held.has(v.activeAccountBindingId) ? { activeAccountBindingId: v.activeAccountBindingId } : {}) };
}
async function bounded<T>(work: Promise<T>, signal: AbortSignal): Promise<T> {
  if (signal.aborted) throw new Error("Native account operation uncertain");
  return new Promise((resolve, reject) => {
    const abort = (): void => reject(new Error("Native account operation uncertain"));
    signal.addEventListener("abort", abort, { once: true });
    work.then(resolve, reject).finally(() => signal.removeEventListener("abort", abort));
  });
}
const callbackReply = (status: number): NativeSiwcCallbackReply => ({ status, text: status === 200 ? "You may return to Yorozu." : "This sign-in could not be completed. Return to Yorozu." });

export function createNativeSiwcAccountCoordinator(services: NativeSiwcCoordinatorServices, now = Date.now) {
  let lifecycle: NativeSiwcLifecycle | undefined, accountServices: SiwcAccountServices | undefined;
  let initialization: Promise<NativeSiwcLifecycle | undefined> | undefined, closed = false, initUnknown = false;
  const operations = new Map<string, Operation>(), attempts = new Map<string, Attempt>(), activeBindings = new Set<string>(), held = new Set<string>();
  const closing = new Map<NativeSiwcCallbackEndpoint, Promise<void>>();
  const release = (endpoint: NativeSiwcCallbackEndpoint): Promise<void> => {
    if (!closing.has(endpoint)) {
      const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 2000); timer.unref();
      closing.set(endpoint, bounded(Promise.resolve().then(() => endpoint.close()), controller.signal).catch(() => {}).finally(() => clearTimeout(timer)));
    }
    return closing.get(endpoint)!;
  };
  const update = (op: Operation, state: NativeSiwcOperationState): void => { op.result = { protocolVersion: 1, operationId: op.result.operationId,
    status: state === "unsupported" || state === "cancelled" || state === "expired" ? "rejected" : state,
    ...(state === "unsupported" ? { reason: "unsupported" } : state === "cancelled" || state === "expired" ? { reason: "invalid" } : state === "unknown" ? { reason: "unknown" } : {}),
    ...(op.result.attemptId ? { attemptId: op.result.attemptId } : {}) }; };
  const notify = (): void => { try { services.onChange?.(); } catch {} };
  const cancel = async (a: Attempt, state: "cancelled" | "expired" | "unknown") => {
    if (a.state === "closed") return;
    const exchanging = a.state === "completing"; a.state = "closed"; clearTimeout(a.timer); activeBindings.delete(a.binding); a.operation.controller.abort();
    try { lifecycle?.cancelSignIn(a.id); } catch { state = "unknown"; }
    if (exchanging || state === "unknown") {
      state = "unknown"; held.add(a.binding);
      try { accountServices?.stopAccount(a.binding); } catch { initUnknown = true; }
    }
    update(a.operation, state); notify(); await release(a.endpoint);
  };
  const status = async (): Promise<NativeSiwcSafeStatus> => {
    if (!lifecycle) return initUnknown ? { ...unavailable(), state: "unknown" } : unavailable();
    try { return safeStatus(await lifecycle.status(), held); } catch { return { ...unavailable(), state: "unknown" }; }
  };
  const initialize = async (signal: AbortSignal): Promise<NativeSiwcLifecycle | undefined> => {
    if (closed || initUnknown) return;
    if (lifecycle) return lifecycle;
    if (!initialization) initialization = (async () => {
      try {
        const value = await bounded(Promise.resolve().then(() => services.initializeAccountServices(signal)), signal);
        if (!value) return;
        if (closed || signal.aborted || !exact(value, ["host", "services"]) || !exact(value.host, ["hostId", "appName"]) || !id(value.host.hostId) || value.host.appName !== "Yorozu") throw new Error("Native account identity unavailable");
        const next = services.makeLifecycle ? services.makeLifecycle(Object.freeze({ ...value.host }), value.services) : new SiwcAccountLifecycle(value.host, value.services, now);
        accountServices = value.services; lifecycle = next; return next;
      } catch { initUnknown = true; return; }
    })();
    return bounded(initialization, signal);
  };
  const validCallback = (r: NativeSiwcCallbackRequest, port: number): boolean => {
    if (r.method !== "GET" || r.host !== `127.0.0.1:${port}` || r.remoteAddress !== "127.0.0.1" || r.hasBody || typeof r.url !== "string"
      || Buffer.byteLength(r.url) > 16_384 || !/^\/auth\/callback(?:\?|$)/.test(r.url) || /[\x00-\x20\x7f#]/.test(r.url)
      || !Array.isArray(r.rawHeaders) || r.rawHeaders.length % 2 || r.rawHeaders.length > 64 || r.rawHeaders.some(v => typeof v !== "string" || /[\x00\r\n]/.test(v))
      || r.rawHeaders.reduce((n, v) => n + Buffer.byteLength(v), 0) > 8192) return false;
    const names = r.rawHeaders.filter((_, index) => index % 2 === 0).map(v => v.toLowerCase());
    return names.filter(v => v === "host").length === 1 && r.rawHeaders[names.indexOf("host") * 2 + 1] === r.host && !names.includes("transfer-encoding")
      && names.filter(v => v === "content-length").length <= 1 && names.every((v, index) => v !== "content-length" || r.rawHeaders[index * 2 + 1] === "0");
  };
  const signIn = async (c: Extract<NativeSiwcAccountCommand, { method: "sign-in" }>, op: Operation) => {
    if (activeBindings.has(c.bindingId) || activeBindings.size >= 8 || held.has(c.bindingId)) { update(op, "rejected"); return; }
    activeBindings.add(c.bindingId); let endpoint: NativeSiwcCallbackEndpoint | undefined, a: Attempt | undefined, begunId: string | undefined;
    try {
      const l = await initialize(op.controller.signal); if (!l) { update(op, initUnknown ? "unknown" : "unsupported"); return; }
      const opening = Promise.resolve().then(() => services.callbackEndpoint.acquire(async request => {
        if (!a || a.state === "closed" || closed) return callbackReply(410);
        if (now() >= a.expiresAt) { void cancel(a, "expired"); return callbackReply(410); }
        if (!validCallback(request, a.endpoint.port)) return callbackReply(400);
        if (a.state !== "awaiting") return callbackReply(409);
        a.state = "completing"; clearTimeout(a.timer); a.timer = setTimeout(() => { if (a) void cancel(a, "unknown"); }, 35_000); a.timer.unref();
        try {
          await l.completeSignIn(a.id, `http://127.0.0.1:${a.endpoint.port}${request.url}`);
          if (a.state === "completing" && !held.has(a.binding) && !closed) update(op, "completed");
          return callbackReply(op.result.status === "completed" ? 200 : 409);
        } catch (error) {
          if (a.state === "completing") {
            const known = error instanceof SiwcAccountError && ["invalid", "identity", "permission", "signed-out", "unsupported"].includes(error.code);
            update(op, known ? "rejected" : "unknown"); if (!known) held.add(a.binding);
          }
          return callbackReply(400);
        } finally { a.state = "closed"; clearTimeout(a.timer); activeBindings.delete(a.binding); notify(); void release(a.endpoint); }
      }, op.controller.signal));
      void opening.then(value => { if (op.controller.signal.aborted || closed) void release(value); }, () => {});
      endpoint = await bounded(opening, op.controller.signal);
      if (!exact(endpoint, ["host", "port", "close"]) || endpoint.host !== "127.0.0.1" || !Number.isInteger(endpoint.port) || endpoint.port < 1024 || endpoint.port > 65535 || typeof endpoint.close !== "function") throw new Error("Native callback unavailable");
      const begun = await bounded(l.beginSignIn({ accountBindingId: c.bindingId, returning: c.returning, callbackPort: endpoint.port }), op.controller.signal);
      if (opaque(begun.attemptId)) begunId = begun.attemptId;
      if (!opaque(begun.attemptId) || begun.callbackUri !== `http://127.0.0.1:${endpoint.port}/auth/callback` || !Number.isSafeInteger(begun.expiresAt)
        || begun.expiresAt <= now() || begun.expiresAt > now() + 300_000) throw new Error("Native account attempt unavailable");
      const authorization = new URL(begun.authorizationUrl);
      if (authorization.origin + authorization.pathname !== SIWC_AUTHORIZATION_URL || authorization.username || authorization.password || authorization.hash
        || begun.authorizationUrl.length > 16_384 || authorization.searchParams.get("redirect_uri") !== begun.callbackUri) throw new Error("Native authorization route unavailable");
      op.result.attemptId = begun.attemptId;
      a = { id: begun.attemptId, binding: c.bindingId, operation: op, endpoint, expiresAt: begun.expiresAt, state: "awaiting",
        timer: setTimeout(() => { if (a) void cancel(a, "expired"); }, begun.expiresAt - now()) }; a.timer.unref(); attempts.set(a.id, a);
      const browser = await bounded(services.nativeBrowser.openAuthorization(begun.authorizationUrl, Object.freeze({ operationId: c.operationId, signal: op.controller.signal })), op.controller.signal);
      if (browser.status !== "opened") await cancel(a, browser.status === "rejected" ? "cancelled" : "unknown");
    } catch (error) {
      if (a) await cancel(a, "unknown");
      else { const known = error instanceof SiwcAccountError && ["invalid", "identity", "conflict", "permission", "unsupported"].includes(error.code);
        update(op, known ? error.code === "unsupported" ? "unsupported" : "rejected" : "unknown");
        if (begunId) { try { lifecycle?.cancelSignIn(begunId); } catch { update(op, "unknown"); } }
        if (endpoint) await release(endpoint); }
    } finally { if (!a || a.state === "closed") activeBindings.delete(c.bindingId); }
  };
  return Object.freeze({
    /** Host-only explicit preparation, never a model/chat command. Reads saved native state
     * through the supplied service initializer; it opens no browser or callback endpoint. */
    activateSavedAccounts: async (signal?: AbortSignal): Promise<NativeSiwcLifecycle | undefined> => {
      if (closed || initUnknown || held.size || signal?.aborted) return;
      const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 35_000); timer.unref();
      const abort = (): void => controller.abort(); signal?.addEventListener("abort", abort, { once: true });
      try { const value = await initialize(controller.signal); return closed || initUnknown || held.size ? undefined : value; }
      catch { return; } finally { clearTimeout(timer); signal?.removeEventListener("abort", abort); }
    },
    /** Host-only reference, never a command/event result. Uncertainty prevents broker admission. */
    getLifecycle: (): NativeSiwcLifecycle | undefined => closed || initUnknown || held.size ? undefined : lifecycle,
    /** Trusted host publication path; does not initialize native services or allocate operation IDs. */
    getStatus: status,
    getResult: (operationId: string): NativeSiwcAccountResult | undefined => { const op = id(operationId) ? operations.get(operationId) : undefined; return op ? structuredClone(op.result) : undefined; },
    execute: async (sender: unknown, input: unknown): Promise<NativeSiwcAccountResult> => {
      const c = command(input), operationId = c?.operationId ?? "invalid";
      let authorized = false; try { if (c) authorized = services.validateSender(sender, Object.freeze({ ...c })) === true; } catch {}
      if (!c || !authorized || closed) return { protocolVersion: 1, operationId, status: "rejected", reason: "invalid" };
      const digest = createHash("sha256").update(JSON.stringify(c)).digest("hex"), previous = operations.get(c.operationId);
      if (previous) return previous.digest === digest ? structuredClone(previous.result) : { protocolVersion: 1, operationId, status: "rejected", reason: "conflict" };
      if (operations.size >= 256) return { protocolVersion: 1, operationId, status: "rejected", reason: "conflict" };
      const op: Operation = { digest, result: { protocolVersion: 1, operationId, status: "pending" }, controller: new AbortController() }; operations.set(operationId, op);
      const timer = setTimeout(() => op.controller.abort(), 35_000); timer.unref();
      op.work = (async () => {
        try {
          if (c.method === "sign-in") await signIn(c, op);
          else if (c.method === "cancel") { const a = attempts.get(c.attemptId); if (!a || a.state === "closed") update(op, "rejected");
            else { await cancel(a, "cancelled"); update(op, a.operation.result.status === "unknown" ? "unknown" : "completed"); } }
          else if (c.method === "status") { const account = await bounded(status(), op.controller.signal); update(op, "completed");
            op.result.account = account; op.result.operations = [...operations.values()].filter(v => v !== op).map(v => ({ operationId: v.result.operationId, status: v.result.status, ...(v.result.attemptId ? { attemptId: v.result.attemptId } : {}) })); }
          else if (!lifecycle || initUnknown) update(op, initUnknown ? "unknown" : "unsupported");
          else { if (c.method === "sign-out") { for (const a of attempts.values()) if (a.binding === c.bindingId && a.state !== "closed") void cancel(a, "unknown");
              const out = await bounded(lifecycle.signOut(c.bindingId), op.controller.signal);
              if (!out.accounts.some(a => a.accountBindingId === c.bindingId && a.phase === "signed-out")) throw new Error("Native sign-out unconfirmed");
              held.delete(c.bindingId); op.result.account = safeStatus(out, held); }
            else if (c.method === "select") { if (held.has(c.bindingId)) throw new Error("Native account held"); op.result.account = safeStatus(await bounded(lifecycle.selectAccount(c.bindingId), op.controller.signal), held); }
            else { const verified = await bounded(lifecycle.verifyPending(c.bindingId), op.controller.signal); held.delete(c.bindingId); op.result.account = safeStatus(verified, held); }
            const account = op.result.account; update(op, "completed"); op.result.account = account; }
        } catch (error) {
          const known = error instanceof SiwcAccountError && error.code !== "unknown";
          update(op, known ? "rejected" : "unknown"); if (known) op.result.reason = error.code;
          if (!known && "bindingId" in c) { held.add(c.bindingId); try { accountServices?.stopAccount(c.bindingId, "invalid"); } catch { initUnknown = true; } }
        } finally { clearTimeout(timer); notify(); }
        return structuredClone(op.result);
      })();
      return op.work;
    },
    close: async (): Promise<void> => { if (closed) return; closed = true; operations.forEach(op => op.controller.abort());
      try { lifecycle?.close(); } catch { initUnknown = true; }
      for (const a of attempts.values()) if (a.state !== "closed") await cancel(a, "unknown");
      await Promise.allSettled([...closing.values()]); },
  });
}

/** Host-only lifecycle logic. Native protected storage, TLS, JWT/JWKS verification,
 * callback listeners and browser presentation are deliberately injected and unwired. */
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import type { SiwcAccessToken, SiwcAccountIdentity } from "./siwc-inference-broker.js";

export const SIWC_AUTHORIZATION_URL = "https://auth.openai.com/api/accounts/authorize" as const;
export const SIWC_TOKEN_URL = "https://auth.openai.com/api/accounts/oauth/token" as const;
export const SIWC_DISCOVERY_URL = "https://auth.openai.com/.well-known/openid-configuration" as const;
export const SIWC_JWKS_URL = "https://auth.openai.com/.well-known/jwks.json" as const;
export const SIWC_ISSUER = "https://auth.openai.com" as const;
export const SIWC_RESOURCE = "https://api.openai.com/v1" as const;
export const SIWC_ACCOUNT_READINESS = Object.freeze({ productionReady: false, nativeIntegration: "unwired" as const });
const requestedScopes = Object.freeze(["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"]);
type Phase = "ready" | "signed-out" | "exchanging" | "refreshing" | "pending-verification" | "revoking";
export interface SiwcCredentials {
  accessToken: string; refreshToken?: string; idToken: string; expiresAt: number; earliestRefreshAt?: number;
}
export interface SiwcPendingCredentials {
  kind: "sign-in" | "refresh"; operationId: string; clientId: string; nonce?: string;
  credentials?: SiwcCredentials; scopes?: string[];
}
export interface SiwcStoredAccount {
  accountBindingId: string; registration?: { clientId: string; subject: string };
  phase: Phase; scopes: string[]; credentials?: SiwcCredentials; pending?: SiwcPendingCredentials;
  remoteRevocation?: "confirmed" | "unconfirmed";
}
/** Entire snapshot is protected, including pending rotated credentials and registration identity. */
export interface SiwcProtectedSnapshot {
  version: 1; revision: number; hostId: string; appName: string; callbackPath: "/auth/callback";
  activeAccountBindingId?: string; accounts: SiwcStoredAccount[];
}
export interface SiwcProtectedAccountStore {
  protection: "os-protected";
  available(): boolean;
  /** Must provide a crash-safe interprocess lock for this account (not merely a JS mutex).
   * Concurrent account writes still use the global atomic revision CAS below. */
  withAccountLock<T>(accountBindingId: string, operation: () => Promise<T>): Promise<T>;
  read(): Promise<SiwcProtectedSnapshot>;
  /** Atomic durable replacement of ALL token/expiry/scope/active-selection fields.
   * Resolve committed only after durability; throw on uncertain outcome. Never plaintext. */
  replace(expectedRevision: number, next: SiwcProtectedSnapshot): Promise<"committed" | "conflict">;
}
export interface SiwcAccountTransport {
  /** HTTPS, no redirects/cookies/ambient credentials, bounded bytes, obey abort.
   * Discovery is the sole GET; token and discovered revocation are form POSTs. */
  request(request: { url: string; method: "GET" | "POST"; form?: Readonly<Record<string, string>>; signal: AbortSignal }):
    Promise<{ status: number; body: unknown }>;
}
export interface SiwcVerifiedIdClaims {
  iss: string; aud: string | string[]; sub: string; exp: number; iat: number; nonce?: string; azp?: string;
}
export interface SiwcIdTokenVerifier {
  /** Must cryptographically verify with the exact official JWKS, enforce algorithm/key policy,
   * reject unsigned/malformed tokens and honor abort. Returned claims are rechecked below. */
  verify(input: { idToken: string; issuer: typeof SIWC_ISSUER; jwksUrl: typeof SIWC_JWKS_URL;
    audience: string; nonce?: string; signal: AbortSignal }):
    Promise<{ status: "verified"; claims: SiwcVerifiedIdClaims } | { status: "invalid" | "unavailable" }>;
}
export interface SiwcAccountServices {
  store: SiwcProtectedAccountStore; transport: SiwcAccountTransport; verifier: SiwcIdTokenVerifier;
  /** Synchronously fence/abort every existing execution broker for this exact binding.
   * Required before token rotation, sign-out or replacement. Must throw if fencing fails. */
  stopAccount(accountBindingId: string, reason?: SiwcAccountStopReason): void;
}
export type SiwcAccountStopReason = "refresh" | "replace" | "sign-out" | "select" | "close" | "invalid";
export type SiwcAccountErrorCode = "unsupported" | "invalid" | "identity" | "permission" | "conflict" | "unknown" | "signed-out";
export class SiwcAccountError extends Error {
  constructor(readonly code: SiwcAccountErrorCode) { super(`SIWC account ${code}`); this.name = "SiwcAccountError"; }
}
function fail(code: SiwcAccountErrorCode): never { throw new SiwcAccountError(code); }
const id = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_.:-]{1,128}$/.test(v);
const client = (v: unknown): v is string => typeof v === "string" && /^oaiapp_[A-Za-z0-9_-]{1,128}$/.test(v);
const subject = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_.:@|-]{1,256}$/.test(v);
const secret = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9._~-]{16,32768}$/.test(v);
const fields = (v: unknown, keys: string[]): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v)
  && Object.keys(v).every(k => keys.includes(k));
const integer = (v: unknown): v is number => Number.isSafeInteger(v) && (v as number) >= 0;
const equal = (a: string, b: string): boolean => Buffer.byteLength(a) === Buffer.byteLength(b) && timingSafeEqual(Buffer.from(a), Buffer.from(b));
function scopes(v: unknown): string[] {
  if (typeof v !== "string" || v.length > 512 || !/^[a-z._ ]+$/.test(v)) fail("permission");
  const out = v.split(" ").filter(Boolean);
  if (!out.length || new Set(out).size !== out.length || out.some(s => !requestedScopes.includes(s))) fail("permission");
  if (!out.includes("openid")) fail("permission");
  return out;
}
function credentials(v: unknown): v is SiwcCredentials {
  return fields(v, ["accessToken", "refreshToken", "idToken", "expiresAt", "earliestRefreshAt"])
    && secret(v.accessToken) && secret(v.idToken) && (v.refreshToken === undefined || secret(v.refreshToken))
    && integer(v.expiresAt) && (v.earliestRefreshAt === undefined || integer(v.earliestRefreshAt));
}
function storedAccount(v: unknown): v is SiwcStoredAccount {
  if (!fields(v, ["accountBindingId", "registration", "phase", "scopes", "credentials", "pending", "remoteRevocation"])
    || !id(v.accountBindingId) || !["ready", "signed-out", "exchanging", "refreshing", "pending-verification", "revoking"].includes(v.phase)
    || !Array.isArray(v.scopes) || v.scopes.length > 6 || v.scopes.some((s: unknown) => typeof s !== "string" || !requestedScopes.includes(s))
    || new Set(v.scopes).size !== v.scopes.length || v.registration !== undefined
      && (!fields(v.registration, ["clientId", "subject"]) || !client(v.registration.clientId) || !subject(v.registration.subject))
    || v.credentials !== undefined && !credentials(v.credentials)
    || v.remoteRevocation !== undefined && !["confirmed", "unconfirmed"].includes(v.remoteRevocation)) return false;
  if (v.pending !== undefined && (!fields(v.pending, ["kind", "operationId", "clientId", "nonce", "credentials", "scopes"])
    || !["sign-in", "refresh"].includes(v.pending.kind) || !/^[a-f0-9]{64}$/.test(v.pending.operationId)
    || !client(v.pending.clientId) || v.pending.nonce !== undefined && !secret(v.pending.nonce)
    || v.pending.credentials !== undefined && !credentials(v.pending.credentials)
    || v.pending.scopes !== undefined && (!Array.isArray(v.pending.scopes) || v.pending.scopes.length > 6
      || v.pending.scopes.some((s: unknown) => typeof s !== "string" || !requestedScopes.includes(s))
      || new Set(v.pending.scopes).size !== v.pending.scopes.length))) return false;
  if (["ready", "signed-out"].includes(v.phase)) return !v.pending && (v.phase === "ready"
    ? !!v.registration && !!v.credentials && v.scopes.includes("openid") : !v.credentials);
  if (v.phase === "revoking") return !!v.registration && !v.pending;
  if (!v.pending || v.phase === "refreshing" && (!v.registration || v.pending.kind !== "refresh")) return false;
  if (v.registration && v.registration.clientId !== v.pending.clientId) return false;
  if (v.pending.kind === "sign-in" && !secret(v.pending.nonce)) return false;
  return v.phase === "pending-verification" ? !!v.pending.credentials && !!v.pending.scopes?.includes("openid") : !v.pending.credentials;
}
/** Shared pure schema check for host/native bridge inputs; never reads protected state. */
export function validateSiwcProtectedSnapshot(v: unknown, host?: { hostId: string; appName: string }): v is SiwcProtectedSnapshot {
  return fields(v, ["version", "revision", "hostId", "appName", "callbackPath", "activeAccountBindingId", "accounts"])
    && v.version === 1 && integer(v.revision) && v.revision < Number.MAX_SAFE_INTEGER && id(v.hostId)
    && typeof v.appName === "string" && /^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$/.test(v.appName)
    && (!host || v.hostId === host.hostId && v.appName === host.appName) && v.callbackPath === "/auth/callback"
    && Array.isArray(v.accounts) && v.accounts.length <= 32 && v.accounts.every(storedAccount)
    && new Set(v.accounts.map((a: SiwcStoredAccount) => a.accountBindingId)).size === v.accounts.length
    && new Set(v.accounts.filter((a: SiwcStoredAccount) => a.registration).map((a: SiwcStoredAccount) => a.registration!.clientId)).size === v.accounts.filter((a: SiwcStoredAccount) => a.registration).length
    && (v.activeAccountBindingId === undefined || id(v.activeAccountBindingId) && v.accounts.some((a: SiwcStoredAccount) => a.accountBindingId === v.activeAccountBindingId));
}
interface Attempt { id: string; binding: string; callback: string; expiresAt: number; state: string; nonce: string; verifier: string;
  expected?: { clientId: string; subject: string }; }
export interface SiwcAccountStatus {
  productionReady: false; nativeIntegration: "unwired"; available: boolean; state: "available" | "unsupported" | "unknown";
  revision?: number; activeAccountBindingId?: string;
  accounts: Array<{ accountBindingId: string; phase: "ready" | "signed-out" | "unknown"; planUse: boolean; active: boolean;
    remoteRevocation?: "confirmed" | "unconfirmed" }>;
}
/** No constructor side effects; every method remains unsupported without ALL native services. */
export class SiwcAccountLifecycle {
  private attempts = new Map<string, Attempt>();
  private fenced = new Set<string>();
  /** Only a locally started routine rotation preserves already-admitted streams.
   * Persisted refreshing/pending records never reconstruct this authority. */
  private refreshContinuations = new Set<string>();
  private queues = new Map<string, Promise<unknown>>();
  private epochs = new Map<string, number>();
  private observed = new Set<string>();
  private ready = new Set<string>();
  private controllers = new Set<AbortController>();
  private inflightAttempts = new Map<string, { binding: string; controller: AbortController }>();
  private waiting = 0;
  private unknownStore = false;
  private closed = false;
  constructor(private readonly host: { hostId: string; appName: string }, private readonly services?: SiwcAccountServices,
    private readonly now: () => number = Date.now) {
    if (!fields(host, ["hostId", "appName"]) || !id(host.hostId) || typeof host.appName !== "string"
      || !/^[A-Za-z0-9][A-Za-z0-9 ._-]{0,63}$/.test(host.appName)) fail("invalid");
    this.host = Object.freeze({ ...host });
  }
  private requireServices(): SiwcAccountServices {
    const s = this.services;
    if (this.closed || !s || s.store?.protection !== "os-protected" || typeof s.store.available !== "function"
      || typeof s.store.withAccountLock !== "function" || typeof s.store.read !== "function" || typeof s.store.replace !== "function"
      || typeof s.transport?.request !== "function" || typeof s.verifier?.verify !== "function" || typeof s.stopAccount !== "function") fail("unsupported");
    try { if (!s.store.available()) fail("unsupported"); } catch { fail("unsupported"); }
    if (this.unknownStore) fail("unknown");
    return s;
  }
  private async read(): Promise<SiwcProtectedSnapshot> {
    const s = this.requireServices();
    let v: SiwcProtectedSnapshot; try { v = await s.store.read(); } catch { fail("unknown"); }
    if (!validateSiwcProtectedSnapshot(v, this.host)) fail("identity");
    for (const a of v.accounts) this.observed.add(a.accountBindingId);
    this.ready = new Set(v.accounts.filter(a => a.phase === "ready" && ["resource.invoke", "chatgpt.tokens.use.direct"].every(s => a.scopes.includes(s))).map(a => a.accountBindingId));
    return structuredClone(v);
  }
  private async commit(snapshot: SiwcProtectedSnapshot, record: SiwcStoredAccount, activate = false): Promise<SiwcProtectedSnapshot> {
    const next = structuredClone(snapshot); next.revision++;
    const index = next.accounts.findIndex(a => a.accountBindingId === record.accountBindingId);
    if (index < 0) { if (next.accounts.length >= 32) fail("invalid"); next.accounts.push(record); } else next.accounts[index] = record;
    if (activate) next.activeAccountBindingId = record.accountBindingId;
    if (!storedAccount(record)) fail("invalid");
    try {
      const result = await this.requireServices().store.replace(snapshot.revision, next);
      if (result === "conflict") fail("conflict");
      if (result !== "committed") { this.unknownStore = true; fail("unknown"); }
    } catch (error) {
      if (error instanceof SiwcAccountError && error.code === "conflict") throw error;
      this.unknownStore = true; fail("unknown");
    }
    for (const a of next.accounts) this.observed.add(a.accountBindingId);
    this.ready = new Set(next.accounts.filter(a => a.phase === "ready" && ["resource.invoke", "chatgpt.tokens.use.direct"].every(s => a.scopes.includes(s))).map(a => a.accountBindingId));
    return next;
  }
  private async serial<T>(binding: string, work: () => Promise<T>): Promise<T> {
    if (!id(binding)) fail("invalid");
    const s = this.requireServices();
    if (this.waiting >= 128 || this.queues.size >= 32 && !this.queues.has(binding)) fail("invalid");
    this.waiting++;
    const prior = this.queues.get(binding) ?? Promise.resolve();
    const current = prior.catch(() => {}).then(() => s.store.withAccountLock(binding, work));
    this.queues.set(binding, current);
    try { return await current; } catch (error) { if (error instanceof SiwcAccountError) throw error; return fail("unknown"); }
    finally { this.waiting--; if (this.queues.get(binding) === current) this.queues.delete(binding); }
  }
  private fence(binding: string, reason: SiwcAccountStopReason): void {
    if (this.epochs.size >= 64 && !this.epochs.has(binding)) fail("invalid");
    if (reason === "refresh" && !this.fenced.has(binding) && this.ready.has(binding)) this.refreshContinuations.add(binding);
    else this.refreshContinuations.delete(binding);
    this.fenced.add(binding);
    this.epochs.set(binding, (this.epochs.get(binding) ?? 0) + 1);
    this.stopOnly(binding, reason);
  }
  private stopOnly(binding: string, reason: SiwcAccountStopReason): void {
    if (reason !== "refresh") this.refreshContinuations.delete(binding);
    // Revocation must still reach the host when protected storage is unavailable/uncertain.
    try { if (typeof this.services?.stopAccount !== "function") fail("unsupported"); this.services.stopAccount(binding, reason); }
    catch { fail("unknown"); }
  }
  private async bounded<T>(work: (signal: AbortSignal) => Promise<T>, external?: AbortSignal): Promise<T> {
    if (external?.aborted) fail("unknown");
    const controller = new AbortController();
    this.controllers.add(controller);
    let timer: NodeJS.Timeout | undefined;
    const abort = (): void => controller.abort(); external?.addEventListener("abort", abort, { once: true });
    try {
      return await Promise.race([Promise.resolve().then(() => work(controller.signal)), new Promise<never>((_, reject) => {
        const stop = (): void => reject(new SiwcAccountError("unknown"));
        controller.signal.addEventListener("abort", stop, { once: true }); timer = setTimeout(abort, 30_000); timer.unref();
      })]);
    } catch { return fail("unknown"); }
    finally { if (timer) clearTimeout(timer); external?.removeEventListener("abort", abort); this.controllers.delete(controller); controller.abort(); }
  }
  async beginSignIn(input: { accountBindingId: string; callbackPort: number; returning: boolean }):
    Promise<Readonly<{ attemptId: string; authorizationUrl: string; callbackUri: string; expiresAt: number }>> {
    if (!fields(input, ["accountBindingId", "callbackPort", "returning"]) || !id(input.accountBindingId)
      || !Number.isInteger(input.callbackPort) || input.callbackPort < 1024 || input.callbackPort > 65535 || typeof input.returning !== "boolean") fail("invalid");
    return this.serial(input.accountBindingId, async () => {
      const snapshot = await this.read(), existing = snapshot.accounts.find(a => a.accountBindingId === input.accountBindingId);
      if (input.returning ? !existing?.registration : !!existing) fail("identity");
      for (const [key, attempt] of this.attempts) if (attempt.expiresAt <= this.now()) this.attempts.delete(key);
      if (this.attempts.size >= 8 || [...this.attempts.values()].some(a => a.binding === input.accountBindingId)) fail("conflict");
      const a: Attempt = { id: randomBytes(32).toString("hex"), binding: input.accountBindingId,
        callback: `http://127.0.0.1:${input.callbackPort}/auth/callback`, expiresAt: this.now() + 5 * 60_000,
        state: randomBytes(32).toString("base64url"), nonce: randomBytes(32).toString("base64url"), verifier: randomBytes(64).toString("base64url"),
        expected: existing?.registration ? { ...existing.registration } : undefined };
      const p: Record<string, string> = { client_id: a.expected?.clientId ?? "dynamic_agent_client", ext_agent_host_id: this.host.hostId,
        response_type: "code", redirect_uri: a.callback, scope: requestedScopes.join(" "), resource: SIWC_RESOURCE,
        state: a.state, nonce: a.nonce, code_challenge_method: "S256", code_challenge: createHash("sha256").update(a.verifier).digest("base64url") };
      if (!a.expected) p.agent_name_hint = this.host.appName;
      else if (existing?.phase === "ready" && existing.credentials) p.id_token_hint = existing.credentials.idToken;
      this.attempts.set(a.id, a);
      return Object.freeze({ attemptId: a.id, authorizationUrl: `${SIWC_AUTHORIZATION_URL}?${new URLSearchParams(p)}`,
        callbackUri: a.callback, expiresAt: a.expiresAt }); // Sensitive host-only browser instruction; NEVER status/renderer/log data.
    });
  }
  cancelSignIn(attemptId: string): void {
    if (typeof attemptId !== "string" || !/^[a-f0-9]{64}$/.test(attemptId)) fail("invalid");
    this.attempts.delete(attemptId);
    const live = this.inflightAttempts.get(attemptId);
    if (live) { try { this.fence(live.binding, "invalid"); } finally { live.controller.abort(); } }
  }
  async completeSignIn(attemptId: string, callbackUrl: string): Promise<SiwcAccountStatus> {
    this.requireServices();
    const a = this.attempts.get(attemptId);
    if (!a || a.expiresAt <= this.now() || typeof callbackUrl !== "string" || callbackUrl.length > 16_384) fail("invalid");
    this.attempts.delete(attemptId); // One-time consumption precedes any await, including rejected callbacks.
    let u: URL; try { u = new URL(callbackUrl); } catch { fail("invalid"); }
    if (u.origin + u.pathname !== a.callback || u.username || u.password || u.hash
      || [...u.searchParams.keys()].some(k => !["state", "code", "client_id", "scope", "error", "error_description", "error_uri"].includes(k))
      || [...u.searchParams.keys()].some(k => u.searchParams.getAll(k).length !== 1)
      || !equal(u.searchParams.get("state") ?? "", a.state)) fail("invalid");
    if (u.searchParams.has("error")) fail("permission");
    const suppliedClient = u.searchParams.get("client_id"), issuedClient = a.expected?.clientId ?? suppliedClient;
    if (!client(issuedClient) || suppliedClient !== null && suppliedClient !== issuedClient) fail("identity");
    const code = u.searchParams.get("code"); if (!code || code.length > 4096 || /[\x00-\x20\x7f]/.test(code)) fail("invalid");
    const controller = new AbortController(); this.inflightAttempts.set(attemptId, { binding: a.binding, controller });
    try { await this.serial(a.binding, async () => {
      if (controller.signal.aborted) fail("unknown");
      let snapshot = await this.read(); const old = snapshot.accounts.find(r => r.accountBindingId === a.binding);
      if (a.expected ? !old?.registration || old.registration.clientId !== a.expected.clientId || old.registration.subject !== a.expected.subject : !!old) fail("identity");
      if (snapshot.accounts.some(r => r.accountBindingId !== a.binding && (r.registration?.clientId === issuedClient || r.pending?.clientId === issuedClient))) fail("identity");
      this.fence(a.binding, "replace");
      const exchangeEpoch = this.epochs.get(a.binding);
      let record: SiwcStoredAccount = { accountBindingId: a.binding, registration: old?.registration,
        phase: "exchanging", scopes: [], pending: { kind: "sign-in", operationId: a.id, clientId: issuedClient, nonce: a.nonce } };
      snapshot = await this.commit(snapshot, record);
      const response = await this.bounded(signal => this.requireServices().transport.request({ url: SIWC_TOKEN_URL, method: "POST", signal,
        form: { grant_type: "authorization_code", client_id: issuedClient, code, code_verifier: a.verifier, redirect_uri: a.callback, resource: SIWC_RESOURCE } }), controller.signal);
      const parsed = this.parseTokens(response, undefined);
      record = { ...record, phase: "pending-verification", pending: { ...record.pending!, credentials: parsed.credentials, scopes: parsed.scopes } };
      await this.commit(snapshot, record); // Persist issued tokens BEFORE JWKS verification; never exchange this code twice.
      await this.verifyPendingLocked(a.binding, exchangeEpoch, controller.signal);
    }); } finally { this.inflightAttempts.delete(attemptId); controller.abort(); }
    return this.status();
  }
  private parseTokens(response: { status: number; body: unknown }, previous?: SiwcStoredAccount): { credentials: SiwcCredentials; scopes: string[] } {
    const v = response.body;
    if (response.status !== 200) fail("unknown");
    if (!fields(v, ["access_token", "refresh_token", "id_token", "token_type", "expires_in", "scope", "earliest_refresh_at"])
      || !secret(v.access_token) || v.token_type !== "Bearer" || !Number.isSafeInteger(v.expires_in) || v.expires_in < 1 || v.expires_in > 3600
      || v.refresh_token !== undefined && !secret(v.refresh_token) || v.id_token !== undefined && !secret(v.id_token)
      || !previous && !secret(v.id_token) || v.earliest_refresh_at !== undefined && (!integer(v.earliest_refresh_at)
        || v.earliest_refresh_at > Math.floor(this.now() / 1000) + 3600)) fail("invalid");
    const granted = scopes(v.scope);
    if (previous && (!secret(v.refresh_token) || v.refresh_token === previous.credentials?.refreshToken)) fail("invalid");
    if (granted.includes("offline_access") && !secret(v.refresh_token)) fail("permission");
    return { credentials: { accessToken: v.access_token, refreshToken: v.refresh_token,
      idToken: v.id_token ?? previous!.credentials!.idToken, expiresAt: this.now() + v.expires_in * 1000,
      ...(v.earliest_refresh_at === undefined ? {} : { earliestRefreshAt: v.earliest_refresh_at * 1000 }) }, scopes: granted };
  }
  async verifyPending(accountBindingId: string): Promise<SiwcAccountStatus> {
    const epoch = this.epochs.get(accountBindingId);
    await this.serial(accountBindingId, () => this.verifyPendingLocked(accountBindingId, epoch)); return this.status();
  }
  private async verifyPendingLocked(binding: string, epoch = this.epochs.get(binding), signal?: AbortSignal): Promise<void> {
    const snapshot = await this.read(), record = snapshot.accounts.find(r => r.accountBindingId === binding), p = record?.pending;
    if (!record || record.phase !== "pending-verification" || !p?.credentials || !p.scopes) fail("unknown");
    const result = await this.bounded(signal => this.requireServices().verifier.verify({ idToken: p.credentials!.idToken, issuer: SIWC_ISSUER,
      jwksUrl: SIWC_JWKS_URL, audience: p.clientId, ...(p.nonce === undefined ? {} : { nonce: p.nonce }), signal }), signal);
    if (result.status === "unavailable") fail("unknown");
    const c = result.status === "verified" ? result.claims : undefined;
    const audiences = c && (typeof c.aud === "string" ? [c.aud] : c.aud);
    if (!c || c.iss !== SIWC_ISSUER || !Array.isArray(audiences) || !audiences.length || audiences.length > 8
      || !audiences.every(client) || !audiences.includes(p.clientId) || audiences.length > 1 && c.azp !== p.clientId
      || c.azp !== undefined && c.azp !== p.clientId || !subject(c.sub) || !integer(c.exp) || c.exp * 1000 <= this.now()
      || !integer(c.iat) || c.iat * 1000 > this.now() + 5000 || c.iat > c.exp
      || p.nonce !== undefined && (typeof c.nonce !== "string" || !equal(c.nonce, p.nonce))
      || record.registration && (record.registration.clientId !== p.clientId || record.registration.subject !== c.sub)) {
      await this.commit(snapshot, { accountBindingId: binding, registration: record.registration, phase: "signed-out", scopes: [] });
      fail("identity");
    }
    if (p.credentials.expiresAt <= this.now() + 1000) fail("unknown");
    if (snapshot.accounts.some(r => r.accountBindingId !== binding && r.registration?.clientId === p.clientId)) fail("identity");
    if (epoch !== this.epochs.get(binding) || this.closed) fail("signed-out");
    if (p.kind === "sign-in" && snapshot.activeAccountBindingId && snapshot.activeAccountBindingId !== binding) this.stopOnly(snapshot.activeAccountBindingId, "select");
    await this.commit(snapshot, { accountBindingId: binding, registration: { clientId: p.clientId, subject: c.sub }, phase: "ready",
      scopes: p.scopes, credentials: p.credentials }, p.kind === "sign-in");
    if (epoch !== this.epochs.get(binding) || signal?.aborted || this.closed) fail("unknown");
    // Automatic rotation keeps new admission held until its scope comparison and
    // final protected read finish in getAccessToken(). Manual recovery has no
    // live continuation marker and can restore fresh admission here.
    if (!this.refreshContinuations.has(binding)) this.fenced.delete(binding);
  }
  async getAccessToken(accountBindingId: string, signal?: AbortSignal): Promise<SiwcAccessToken> {
    return this.serial(accountBindingId, async () => {
      let snapshot = await this.read(), record = snapshot.accounts.find(a => a.accountBindingId === accountBindingId);
      if (record && !["ready", "signed-out"].includes(record.phase)) fail("unknown");
      if (signal?.aborted || this.fenced.has(accountBindingId) || !record || record.phase !== "ready" || !record.registration || !record.credentials) fail("signed-out");
      if (!["resource.invoke", "chatgpt.tokens.use.direct"].every(s => record!.scopes.includes(s))) { this.fence(accountBindingId, "invalid"); fail("permission"); }
      if (record.credentials.expiresAt <= this.now() + 60_000) {
        try {
        if (!record.credentials.refreshToken || record.credentials.earliestRefreshAt !== undefined && this.now() < record.credentials.earliestRefreshAt) fail("permission");
        this.fence(accountBindingId, "refresh");
        const refreshEpoch = this.epochs.get(accountBindingId);
        const previous = record;
        record = { ...record, phase: "refreshing", pending: { kind: "refresh", operationId: randomBytes(32).toString("hex"), clientId: record.registration.clientId } };
        snapshot = await this.commit(snapshot, record); // Durable hold BEFORE consuming the rotating refresh token.
        const response = await this.bounded(s => this.requireServices().transport.request({ url: SIWC_TOKEN_URL, method: "POST", signal: s,
          form: { grant_type: "refresh_token", client_id: previous.registration!.clientId, refresh_token: previous.credentials!.refreshToken!, resource: SIWC_RESOURCE } }), signal);
        if (response.status !== 200 && fields(response.body, ["error", "error_description"]) && ["invalid_grant", "invalid_refresh_token", "token_expired",
          "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"].includes(response.body.error)) {
          await this.commit(snapshot, { accountBindingId, registration: previous.registration, phase: "signed-out", scopes: [] }); fail("signed-out");
        }
        const parsed = this.parseTokens(response, previous);
        if (fields(response.body, ["access_token", "refresh_token", "id_token", "token_type", "expires_in", "scope", "earliest_refresh_at"]) && response.body.id_token !== undefined) {
          await this.commit(snapshot, { ...record, credentials: undefined, phase: "pending-verification",
            pending: { ...record.pending!, credentials: parsed.credentials, scopes: parsed.scopes } });
          await this.verifyPendingLocked(accountBindingId, refreshEpoch);
        } else {
          await this.commit(snapshot, { accountBindingId, registration: previous.registration, phase: "ready", scopes: parsed.scopes, credentials: parsed.credentials });
        }
        snapshot = await this.read(); record = snapshot.accounts.find(a => a.accountBindingId === accountBindingId);
        if (!record || previous.scopes.length !== record.scopes.length || previous.scopes.some(s => !record!.scopes.includes(s))) fail("permission");
        if (refreshEpoch !== this.epochs.get(accountBindingId) || this.closed || signal?.aborted) fail("permission");
        this.refreshContinuations.delete(accountBindingId); this.fenced.delete(accountBindingId);
        } catch (error) { this.fence(accountBindingId, "invalid"); throw error; }
      }
      if (signal?.aborted || this.closed || this.fenced.has(accountBindingId) || !record?.registration || record.phase !== "ready" || !record.credentials
        || record.credentials.expiresAt <= this.now() + 1000 || !["resource.invoke", "chatgpt.tokens.use.direct"].every(s => record!.scopes.includes(s))) fail("permission");
      const identity: SiwcAccountIdentity = { accountBindingId, ...record.registration, verification: "host-validated-siwc-v1", storage: "os-protected" };
      return Object.freeze({ ...identity, audience: SIWC_RESOURCE, scopes: Object.freeze([...record.scopes]), expiresAt: record.credentials.expiresAt, accessToken: record.credentials.accessToken });
    });
  }
  async selectAccount(accountBindingId: string): Promise<SiwcAccountStatus> {
    await this.serial(accountBindingId, async () => {
      const snapshot = await this.read(), record = snapshot.accounts.find(a => a.accountBindingId === accountBindingId);
      if (!record || record.phase !== "ready" || this.fenced.has(accountBindingId)) fail("signed-out");
      if (snapshot.activeAccountBindingId && snapshot.activeAccountBindingId !== accountBindingId) this.stopOnly(snapshot.activeAccountBindingId, "select");
      await this.commit(snapshot, record, true);
    }); return this.status();
  }
  async signOut(accountBindingId: string): Promise<SiwcAccountStatus> {
    if (!id(accountBindingId)) fail("invalid");
    if (typeof this.services?.stopAccount !== "function") fail("unsupported");
    this.fence(accountBindingId, "sign-out"); // Immediate local stop even if another operation owns the lock.
    for (const [key, a] of this.attempts) if (a.binding === accountBindingId) this.attempts.delete(key);
    await this.serial(accountBindingId, async () => {
      let snapshot = await this.read(); const record = snapshot.accounts.find(a => a.accountBindingId === accountBindingId);
      if (!record?.registration) fail("identity");
      if (record.phase === "signed-out") return; // Preserve the durable result, including unconfirmed remote revocation.
      const token = record.pending?.credentials?.refreshToken ?? record.credentials?.refreshToken;
      // A lost rotation may have issued an unseen replacement. Revoking an already-invalid
      // older token returns 200 too, so it cannot confirm retirement of that unknown session.
      const knownLatest = record.phase === "ready" || record.phase === "pending-verification";
      snapshot = await this.commit(snapshot, { ...record, phase: "revoking", pending: undefined,
        credentials: record.pending?.credentials ?? record.credentials });
      let confirmed = false;
      try {
        if (token) {
          const discovery = await this.bounded(signal => this.requireServices().transport.request({ url: SIWC_DISCOVERY_URL, method: "GET", signal }));
          const d = discovery.body;
          if (discovery.status === 200 && d && typeof d === "object" && !Array.isArray(d)
            && (d as any).issuer === SIWC_ISSUER && (d as any).jwks_uri === SIWC_JWKS_URL) {
            const url = new URL((d as any).revocation_endpoint);
            if (url.origin === SIWC_ISSUER && !url.username && !url.password && !url.search && !url.hash && /^\/api\/accounts\/oauth\/[a-z-]{1,32}$/.test(url.pathname)) {
              const revoked = await this.bounded(signal => this.requireServices().transport.request({ url: url.href, method: "POST", signal,
                form: { token, token_type_hint: "refresh_token", client_id: record.registration!.clientId } }));
              confirmed = knownLatest && revoked.status === 200 && (revoked.body === "" || revoked.body === undefined);
            }
          }
        }
      } catch { /* Local sign-out completes; remote result remains unconfirmed. */ }
      await this.commit(snapshot, { accountBindingId, registration: record.registration, phase: "signed-out", scopes: [],
        remoteRevocation: confirmed ? "confirmed" : "unconfirmed" });
    }); return this.status();
  }
  async status(): Promise<SiwcAccountStatus> {
    const base = { ...SIWC_ACCOUNT_READINESS, available: false, accounts: [] };
    try {
      const snapshot = await this.read();
      return { ...base, available: true, state: "available", revision: snapshot.revision, activeAccountBindingId: snapshot.activeAccountBindingId,
        accounts: snapshot.accounts.map(a => ({ accountBindingId: a.accountBindingId, phase: this.fenced.has(a.accountBindingId) && a.phase === "ready" ? "unknown"
          : a.phase === "ready" || a.phase === "signed-out" ? a.phase : "unknown", active: a.accountBindingId === snapshot.activeAccountBindingId,
          planUse: a.phase === "ready" && !this.fenced.has(a.accountBindingId) && ["resource.invoke", "chatgpt.tokens.use.direct"].every(s => a.scopes.includes(s)),
          ...(a.remoteRevocation === undefined ? {} : { remoteRevocation: a.remoteRevocation }) })) };
    } catch (error) { return { ...base, state: error instanceof SiwcAccountError && error.code === "unsupported" ? "unsupported" : "unknown" }; }
  }
  close(): void {
    if (this.closed) return;
    this.attempts.clear();
    let failed = false;
    try { for (const binding of new Set([...this.observed, ...this.queues.keys()])) { try { this.fence(binding, "close"); } catch { failed = true; } } }
    finally { this.closed = true; this.refreshContinuations.clear(); for (const controller of this.controllers) controller.abort(); }
    if (failed) fail("unknown");
  }
  /** Host broker admission only; cached state, no protected store read or initialization. */
  canExecute(accountBindingId: string): boolean {
    if (!id(accountBindingId) || this.closed || this.unknownStore || this.fenced.has(accountBindingId) || !this.ready.has(accountBindingId)) return false;
    try { return this.services?.store.available() === true; } catch { return false; }
  }
  /** Currency for an already-admitted stream only. This never authorizes a new
   * provider dispatch or reads storage; getAccessToken still requires the exact
   * account lock and fresh validated credentials before every new dispatch. */
  isAccountCurrent(accountBindingId: string): boolean {
    if (!id(accountBindingId) || this.closed || this.unknownStore) return false;
    const rotating = this.refreshContinuations.has(accountBindingId);
    if (this.fenced.has(accountBindingId) && !rotating || !this.ready.has(accountBindingId) && !rotating) return false;
    try { return this.services?.store.available() === true; } catch { return false; }
  }
}

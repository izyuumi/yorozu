import { afterEach, describe, expect, it, vi } from "vitest";
import { createNativeSiwcAccountCoordinator, type NativeSiwcCallbackRequest, type NativeSiwcCoordinatorServices, type NativeSiwcLifecycle } from "./native-account-coordinator.js";
import { SIWC_AUTHORIZATION_URL, SIWC_ISSUER, SiwcAccountError, type SiwcAccountServices, type SiwcAccountStatus, type SiwcProtectedSnapshot } from "./siwc-account-lifecycle.js";

const NATIVE = Object.freeze({ peer: "authenticated-native-fixture" }), NOW = 1791158400000, ATTEMPT = "a".repeat(64);
const TOKEN = "synthetic-private-token", CALLBACK = "http://127.0.0.1:54321/auth/callback";
const accountStatus = (): SiwcAccountStatus => ({ productionReady: false, nativeIntegration: "unwired", available: true, state: "available", revision: 1,
  activeAccountBindingId: "account-one", accounts: [{ accountBindingId: "account-one", phase: "ready", planUse: true, active: true }] });
const req = (changes: Partial<NativeSiwcCallbackRequest> = {}): NativeSiwcCallbackRequest => ({ method: "GET", url: `/auth/callback?state=synthetic-state&code=${TOKEN}&client_id=oaiapp_fixture`,
  host: "127.0.0.1:54321", remoteAddress: "127.0.0.1", rawHeaders: ["Host", "127.0.0.1:54321"], hasBody: false, ...changes });
function deferred<T>() { let resolve!: (value: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { resolve, promise }; }
const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { vi.useRealTimers(); await Promise.all(cleanup.splice(0).map(fn => fn())); });
function fixture() {
  let callback!: (request: NativeSiwcCallbackRequest) => Promise<{ status: number; text: string }>, clock = NOW;
  const close = vi.fn(), stopAccount = vi.fn();
  const lifecycle: NativeSiwcLifecycle = {
    beginSignIn: vi.fn(async () => ({ attemptId: ATTEMPT, authorizationUrl: `${SIWC_AUTHORIZATION_URL}?redirect_uri=${encodeURIComponent(CALLBACK)}&state=synthetic-state&nonce=synthetic-nonce`, callbackUri: CALLBACK, expiresAt: clock + 300_000 })),
    cancelSignIn: vi.fn(), completeSignIn: vi.fn(async () => accountStatus()), verifyPending: vi.fn(async () => accountStatus()),
    selectAccount: vi.fn(async () => accountStatus()), signOut: vi.fn(async () => ({ ...accountStatus(), accounts: [{ accountBindingId: "account-one", phase: "signed-out" as const, planUse: false, active: false }] })),
    status: vi.fn(async () => ({ ...accountStatus(), credentials: { token: TOKEN } } as SiwcAccountStatus)), close: vi.fn(),
    canExecute: vi.fn(() => true), isAccountCurrent: vi.fn(() => true), getAccessToken: vi.fn(async () => { throw new Error("Synthetic fixture has no tokens"); }),
  };
  const nativeServices = { stopAccount } as unknown as SiwcAccountServices;
  const services: NativeSiwcCoordinatorServices = {
    validateSender: vi.fn((sender) => sender === NATIVE),
    initializeAccountServices: vi.fn(async () => ({ host: { hostId: "urn:uuid:synthetic-native-host", appName: "Yorozu" as const }, services: nativeServices })),
    nativeBrowser: { openAuthorization: vi.fn(async () => ({ status: "opened" as const })) },
    callbackEndpoint: { acquire: vi.fn(async handler => { callback = handler; return { host: "127.0.0.1" as const, port: 54321, close }; }) },
    makeLifecycle: vi.fn(() => lifecycle),
  };
  const coordinator = createNativeSiwcAccountCoordinator(services, () => clock); cleanup.push(() => coordinator.close());
  const sign = (operationId = "sign-one") => coordinator.execute(NATIVE, { operationId, method: "sign-in", bindingId: "account-one", returning: false });
  return { coordinator, services, lifecycle, close, stopAccount, sign, callback: (request = req()) => callback(request), advance: (n: number) => { clock += n; } };
}

describe("native-only account coordinator with inert services", () => {
  it("construction and preactivation status open nothing and read no account storage", async () => {
    const f = fixture(); expect(f.coordinator.getLifecycle()).toBeUndefined();
    const result = await f.coordinator.execute(NATIVE, { operationId: "status-one", method: "status" });
    expect(result).toMatchObject({ status: "completed", account: { available: false, state: "unsupported", accounts: [] } });
    expect(f.services.initializeAccountServices).not.toHaveBeenCalled(); expect(f.lifecycle.status).not.toHaveBeenCalled();
    expect(f.services.callbackEndpoint.acquire).not.toHaveBeenCalled(); expect(f.services.nativeBrowser.openAuthorization).not.toHaveBeenCalled();
  });
  it("activates saved state only through the explicit host seam and reuses the owned lifecycle without sign-in", async () => {
    const f = fixture(); expect(await f.coordinator.getStatus()).toMatchObject({ available: false });
    expect(f.services.initializeAccountServices).not.toHaveBeenCalled();
    expect(await f.coordinator.activateSavedAccounts()).toBe(f.lifecycle);
    expect(await f.coordinator.activateSavedAccounts()).toBe(f.lifecycle);
    expect(f.coordinator.getLifecycle()).toBe(f.lifecycle); expect(f.services.initializeAccountServices).toHaveBeenCalledOnce();
    expect(f.lifecycle.beginSignIn).not.toHaveBeenCalled(); expect(f.services.callbackEndpoint.acquire).not.toHaveBeenCalled();
    expect(f.services.nativeBrowser.openAuthorization).not.toHaveBeenCalled();
    const aborted = new AbortController(); aborted.abort();
    expect(await f.coordinator.activateSavedAccounts(aborted.signal)).toBeUndefined();
    await f.coordinator.close(); expect(await f.coordinator.activateSavedAccounts()).toBeUndefined();
    expect(f.services.initializeAccountServices).toHaveBeenCalledOnce();
  });
  it("refuses claimed native/chat/tool senders and all client authority/URL additions before activation", async () => {
    const f = fixture();
    for (const sender of [undefined, "native", { peer: "authenticated-native-fixture" }, { model: true }])
      expect((await f.coordinator.execute(sender, { operationId: "spoof", method: "sign-in", bindingId: "a", returning: false })).status).toBe("rejected");
    for (const extra of [{ hostId: "evil" }, { callbackPort: 1455 }, { authorizationUrl: "https://evil.example" }, { credentials: TOKEN }])
      expect((await f.coordinator.execute(NATIVE, { operationId: "extra", method: "sign-in", bindingId: "a", returning: false, ...extra })).status).toBe("rejected");
    expect(f.services.initializeAccountServices).not.toHaveBeenCalled();
  });
  it("initializes only after explicit sign-in, holds numeric endpoint before begin, and keeps sensitive browser URL off UI", async () => {
    const f = fixture(); const result = await f.sign();
    expect(result).toEqual({ protocolVersion: 1, operationId: "sign-one", status: "pending", attemptId: ATTEMPT });
    expect(f.services.callbackEndpoint.acquire).toHaveBeenCalledOnce(); expect(f.lifecycle.beginSignIn).toHaveBeenCalledWith({ accountBindingId: "account-one", callbackPort: 54321, returning: false });
    expect((f.services.callbackEndpoint.acquire as any).mock.invocationCallOrder[0]).toBeLessThan((f.lifecycle.beginSignIn as any).mock.invocationCallOrder[0]);
    expect(f.services.makeLifecycle).toHaveBeenCalledWith({ hostId: "urn:uuid:synthetic-native-host", appName: "Yorozu" }, expect.anything());
    const [url, context] = (f.services.nativeBrowser.openAuthorization as any).mock.calls[0]; expect(url).toContain("synthetic-nonce"); expect(context.operationId).toBe("sign-one");
    expect(JSON.stringify(result)).not.toMatch(/https?:|synthetic-state|synthetic-nonce/);
    expect(f.coordinator.getLifecycle()).toBe(f.lifecycle);
  });
  it("reuses the same operation receipt without repeating actions and rejects changed duplicate currency", async () => {
    const f = fixture(), first = await f.sign(); expect(await f.sign()).toEqual(first);
    expect((await f.coordinator.execute(NATIVE, { operationId: "sign-one", method: "sign-in", bindingId: "other", returning: false })).reason).toBe("conflict");
    expect(f.lifecycle.beginSignIn).toHaveBeenCalledOnce(); expect(f.services.nativeBrowser.openAuthorization).toHaveBeenCalledOnce();
  });
  it("accepts exactly one owned callback and returns only generic noncredential browser text", async () => {
    const f = fixture(); await f.sign(); const result = await f.callback();
    expect(result).toEqual({ status: 200, text: "You may return to Yorozu." }); expect(JSON.stringify(result)).not.toContain(TOKEN);
    expect(f.lifecycle.completeSignIn).toHaveBeenCalledWith(ATTEMPT, `${CALLBACK}?state=synthetic-state&code=${TOKEN}&client_id=oaiapp_fixture`);
    expect((await f.callback()).status).toBe(410); expect(f.lifecycle.completeSignIn).toHaveBeenCalledOnce(); expect(f.close).toHaveBeenCalledOnce();
    const status = await f.coordinator.execute(NATIVE, { operationId: "status-after", method: "status" });
    expect(status.operations).toContainEqual({ operationId: "sign-one", status: "completed", attemptId: ATTEMPT }); expect(JSON.stringify(status)).not.toContain(TOKEN);
  });
  it("rejects a duplicate while the same callback is being completed", async () => {
    const f = fixture(), finish = deferred<SiwcAccountStatus>(); (f.lifecycle.completeSignIn as any).mockImplementation(() => finish.promise);
    await f.sign(); const first = f.callback(); expect((await f.callback()).status).toBe(409);
    expect(f.lifecycle.completeSignIn).toHaveBeenCalledOnce(); finish.resolve(accountStatus()); expect((await first).status).toBe(200);
  });
  it("aborts an unresolved native browser request on exact user cancellation", async () => {
    const f = fixture(), entered = deferred<void>(), opened = deferred<{ status: "opened" }>(); let signal!: AbortSignal;
    (f.services.nativeBrowser.openAuthorization as any).mockImplementation((_url: string, context: any) => { signal = context.signal; entered.resolve(); return opened.promise; });
    const starting = f.sign(); await entered.promise;
    expect(f.coordinator.getResult("sign-one")).toMatchObject({ status: "pending", attemptId: ATTEMPT });
    expect((await f.coordinator.execute(NATIVE, { operationId: "cancel-browser", method: "cancel", attemptId: ATTEMPT })).status).toBe("completed");
    expect(signal.aborted).toBe(true); expect((await starting).status).toBe("rejected"); opened.resolve({ status: "opened" });
    expect(f.services.nativeBrowser.openAuthorization).toHaveBeenCalledOnce(); expect((await f.callback()).status).toBe(410);
  });
  it("rejects incorrect native identity and holds initialization uncertainty without retry", async () => {
    const f = fixture(); (f.services.initializeAccountServices as any).mockResolvedValue({ host: { hostId: "client-host", appName: "Other" }, services: {} });
    expect((await f.sign()).status).toBe("unknown"); expect((await f.sign("second-sign")).status).toBe("unknown");
    expect(f.services.initializeAccountServices).toHaveBeenCalledOnce(); expect(f.services.callbackEndpoint.acquire).not.toHaveBeenCalled(); expect(f.services.makeLifecycle).not.toHaveBeenCalled();
  });
  it("rejects method/path/body/header/host/remote/size attacks without consuming the correct callback", async () => {
    const f = fixture(); await f.sign();
    for (const changes of [{ method: "POST" }, { url: "/auth/%63allback?code=x" }, { host: "localhost:54321" }, { remoteAddress: "::1" }, { hasBody: true },
      { url: "/auth/callback?code=" + "x".repeat(16_384) }, { rawHeaders: ["Host", "127.0.0.1:54321", "Host", "127.0.0.1:54321"] },
      { rawHeaders: ["Host", "localhost:54321"] }, { rawHeaders: ["Host", "127.0.0.1:54321", "Transfer-Encoding", "chunked"] },
      { rawHeaders: ["Host", "127.0.0.1:54321", "Cookie", "x".repeat(8192)] }]) expect((await f.callback(req(changes))).status).toBe(400);
    expect(f.lifecycle.completeSignIn).not.toHaveBeenCalled(); expect((await f.callback()).status).toBe(200);
  });
  it("cancels an awaiting attempt exactly, closes once and never completes a late callback", async () => {
    const f = fixture(); await f.sign();
    expect((await f.coordinator.execute(NATIVE, { operationId: "cancel-one", method: "cancel", attemptId: ATTEMPT })).status).toBe("completed");
    expect(f.lifecycle.cancelSignIn).toHaveBeenCalledWith(ATTEMPT); expect(f.close).toHaveBeenCalledOnce(); expect((await f.callback()).status).toBe(410);
    expect(f.lifecycle.completeSignIn).not.toHaveBeenCalled();
  });
  it("holds cancellation after callback handoff as unknown, fences exact account and prevents late adoption visibility", async () => {
    const f = fixture(), done = deferred<SiwcAccountStatus>(); (f.lifecycle.completeSignIn as any).mockImplementation(() => done.promise);
    await f.sign(); const callback = f.callback(); await Promise.resolve();
    expect((await f.coordinator.execute(NATIVE, { operationId: "cancel-exchange", method: "cancel", attemptId: ATTEMPT })).status).toBe("unknown");
    expect(f.stopAccount).toHaveBeenCalledWith("account-one"); expect(f.coordinator.getLifecycle()).toBeUndefined(); done.resolve(accountStatus()); await callback;
    const result = await f.coordinator.execute(NATIVE, { operationId: "after-cancel", method: "status" });
    expect(result.account?.accounts[0]).toMatchObject({ phase: "unknown", planUse: false, active: false });
    expect(result.operations).toContainEqual({ operationId: "sign-one", status: "unknown", attemptId: ATTEMPT });
  });
  it("closes browser failure/uncertainty and holds its operation rather than reopening on duplicate", async () => {
    for (const failure of ["rejected", "unknown", "throw"] as const) {
      const f = fixture(); (f.services.nativeBrowser.openAuthorization as any).mockImplementation(async () => { if (failure === "throw") throw new Error(TOKEN); return { status: failure }; });
      const first = await f.sign(); expect(first.status).toBe(failure === "rejected" ? "rejected" : "unknown"); expect(JSON.stringify(first)).not.toContain(TOKEN);
      expect(await f.sign()).toEqual(first); expect(f.services.nativeBrowser.openAuthorization).toHaveBeenCalledOnce(); expect(f.close).toHaveBeenCalledOnce();
    }
  });
  it("rejects widened/invalid callback endpoint before begin or browser invocation", async () => {
    for (const bad of [{ host: "0.0.0.0", port: 54321 }, { host: "127.0.0.1", port: 80 }]) {
      const f = fixture(); (f.services.callbackEndpoint.acquire as any).mockResolvedValue({ ...bad, close: f.close });
      expect((await f.sign()).status).toBe("unknown"); expect(f.lifecycle.beginSignIn).not.toHaveBeenCalled(); expect(f.services.nativeBrowser.openAuthorization).not.toHaveBeenCalled(); expect(f.close).toHaveBeenCalledOnce();
    }
  });
  it("expires awaiting attempts with no callback execution and closes on teardown", async () => {
    vi.useFakeTimers(); const f = fixture(); await f.sign(); f.advance(300_001); await vi.advanceTimersByTimeAsync(300_001);
    expect(f.lifecycle.cancelSignIn).toHaveBeenCalledOnce(); expect(f.close).toHaveBeenCalledOnce(); expect((await f.callback()).status).toBe(410);
    await f.coordinator.close(); expect(f.lifecycle.close).toHaveBeenCalledOnce(); expect(f.close).toHaveBeenCalledOnce();
  });
  it("fences a previously obtained lifecycle before awaiting any callback endpoint teardown", async () => {
    const f = fixture(), released = deferred<void>(); f.close.mockImplementation(() => released.promise);
    await f.sign(); const lifecycle = f.coordinator.getLifecycle(), closing = f.coordinator.close();
    expect(lifecycle).toBe(f.lifecycle); expect(f.lifecycle.close).toHaveBeenCalledOnce();
    expect(f.coordinator.getLifecycle()).toBeUndefined(); released.resolve(); await closing;
    expect((f.lifecycle.close as any).mock.invocationCallOrder[0]).toBeLessThan(f.close.mock.invocationCallOrder[0]);
  });
  it("keeps select/signout/verify preactivation unsupported without initializing store", async () => {
    const f = fixture(); for (const method of ["select", "sign-out", "verify-pending"]) {
      expect(await f.coordinator.execute(NATIVE, { operationId: method, method, bindingId: "account-one" })).toMatchObject({ status: "rejected", reason: "unsupported" });
    }
    expect(f.services.initializeAccountServices).not.toHaveBeenCalled();
  });
  it("sanitizes lifecycle rejection and does not expose sensitive exception text", async () => {
    const f = fixture(); (f.lifecycle.beginSignIn as any).mockRejectedValue(new SiwcAccountError("identity"));
    expect((await f.sign()).status).toBe("rejected"); expect(f.close).toHaveBeenCalledOnce(); expect(f.services.nativeBrowser.openAuthorization).not.toHaveBeenCalled();
  });
  it("integrates the real lifecycle's exact in-flight cancellation without OAuth or native storage", async () => {
    const exchange = deferred<any>(), started = deferred<void>(), host = { hostId: "urn:uuid:synthetic-protected-installation", appName: "Yorozu" as const };
    let snapshot: SiwcProtectedSnapshot = { version: 1, revision: 0, ...host, callbackPath: "/auth/callback", accounts: [] };
    let callback!: (request: NativeSiwcCallbackRequest) => Promise<any>, browserUrl = "";
    const stopAccount = vi.fn(), native: SiwcAccountServices = {
      store: { protection: "os-protected", available: () => true, withAccountLock: async (_binding, work) => work(), read: async () => structuredClone(snapshot),
        replace: async (expected, next) => { if (expected !== snapshot.revision) return "conflict"; snapshot = structuredClone(next); return "committed"; } },
      transport: { request: vi.fn(async () => { started.resolve(); return exchange.promise; }) },
      verifier: { verify: vi.fn(async input => ({ status: "verified", claims: { iss: SIWC_ISSUER, aud: input.audience, sub: "synthetic-subject", nonce: input.nonce, iat: NOW / 1000, exp: NOW / 1000 + 3600 } })) }, stopAccount,
    };
    const coordinator = createNativeSiwcAccountCoordinator({ validateSender: sender => sender === NATIVE, initializeAccountServices: async () => ({ host, services: native }),
      nativeBrowser: { openAuthorization: async url => { browserUrl = url; return { status: "opened" }; } },
      callbackEndpoint: { acquire: async handler => { callback = handler; return { host: "127.0.0.1", port: 54321, close: vi.fn() }; } } }, () => NOW);
    cleanup.push(() => coordinator.close());
    const attempt = await coordinator.execute(NATIVE, { operationId: "real-core-sign", method: "sign-in", bindingId: "a", returning: false });
    const state = new URL(browserUrl).searchParams.get("state"), pending = callback(req({ url: `/auth/callback?state=${state}&code=synthetic-code&client_id=oaiapp_fixture` }));
    await started.promise;
    expect((await coordinator.execute(NATIVE, { operationId: "real-core-cancel", method: "cancel", attemptId: attempt.attemptId })).status).toBe("unknown");
    exchange.resolve({ status: 200, body: { token_type: "Bearer", access_token: "synthetic_access_1234567890", refresh_token: "synthetic_refresh_1234567890", id_token: "synthetic_id_token_1234567890",
      scope: "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct", expires_in: 3600 } }); await pending;
    expect(native.verifier.verify).not.toHaveBeenCalled(); expect(stopAccount).toHaveBeenCalledWith("a", "invalid");
    expect(coordinator.getLifecycle()).toBeUndefined(); expect((await coordinator.getStatus()).accounts[0]).toMatchObject({ phase: "unknown", planUse: false });
    expect((await coordinator.execute(NATIVE, { operationId: "real-core-sign", method: "sign-in", bindingId: "a", returning: false })).status).toBe("unknown");
    expect(native.transport.request).toHaveBeenCalledOnce();
  });
});

import { createHash } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { SiwcAccountLifecycle, SIWC_AUTHORIZATION_URL, SIWC_DISCOVERY_URL, SIWC_ISSUER, SIWC_JWKS_URL,
  SIWC_RESOURCE, SIWC_TOKEN_URL, type SiwcAccountServices, type SiwcAccountTransport, type SiwcIdTokenVerifier,
  type SiwcProtectedSnapshot, type SiwcStoredAccount } from "./siwc-account-lifecycle.js";

// Synthetic credentials and claims only. No fetch, listener, OS store, JWT implementation, or filesystem IO.
const NOW = 1_790_000_000_000;
const HOST = { hostId: "urn:uuid:synthetic-host", appName: "Yorozu" };
const SCOPES = ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"];
const ACCESS = "synthetic_access_1234567890", REFRESH = "synthetic_refresh_1234567890", ID_TOKEN = "synthetic_id_token_1234567890";
const NEXT_ACCESS = "rotated_access_1234567890", NEXT_REFRESH = "rotated_refresh_1234567890", NEXT_ID = "rotated_id_token_1234567890";
function ready(binding = "a", clientId = `oaiapp_${binding}`, sub = `subject-${binding}`, expiresAt = NOW + 3600_000): SiwcStoredAccount {
  return { accountBindingId: binding, registration: { clientId, subject: sub }, phase: "ready", scopes: [...SCOPES],
    credentials: { accessToken: ACCESS, refreshToken: REFRESH, idToken: ID_TOKEN, expiresAt } };
}
function token(overrides: Record<string, unknown> = {}) {
  return { status: 200, body: { access_token: NEXT_ACCESS, refresh_token: NEXT_REFRESH, id_token: NEXT_ID,
    token_type: "Bearer", expires_in: 3600, scope: SCOPES.join(" "), ...overrides } };
}
function deferred<T>() { let resolve!: (v: T) => void; const promise = new Promise<T>(r => { resolve = r; }); return { resolve, promise }; }
function fixture(accounts: SiwcStoredAccount[] = [], active?: string) {
  let snapshot: SiwcProtectedSnapshot = { version: 1, revision: 0, ...HOST, callbackPath: "/auth/callback", accounts,
    ...(active ? { activeAccountBindingId: active } : {}) };
  const commits: SiwcProtectedSnapshot[] = [], lockTails = new Map<string, Promise<unknown>>();
  let available = true, mutationFailure: "none" | "before" | "after" | "conflict" = "none";
  const request = vi.fn<SiwcAccountTransport["request"]>(async () => token());
  const verify = vi.fn<SiwcIdTokenVerifier["verify"]>(async input => ({ status: "verified", claims: {
    iss: SIWC_ISSUER, aud: input.audience, sub: `subject-${input.audience.slice(7)}`, nonce: input.nonce,
    exp: Math.floor(NOW / 1000) + 3600, iat: Math.floor(NOW / 1000) } }));
  const services: SiwcAccountServices = {
    store: { protection: "os-protected", available: () => available,
      async withAccountLock<T>(binding: string, work: () => Promise<T>) {
        const prior = lockTails.get(binding) ?? Promise.resolve(), next = prior.catch(() => {}).then(work);
        lockTails.set(binding, next); try { return await next; } finally { if (lockTails.get(binding) === next) lockTails.delete(binding); }
      }, async read() { return structuredClone(snapshot); }, async replace(expected, next) {
        if (mutationFailure === "before") throw new Error(`${REFRESH} private store error`);
        if (mutationFailure === "conflict" || expected !== snapshot.revision) return "conflict";
        snapshot = structuredClone(next); commits.push(structuredClone(next));
        if (mutationFailure === "after") throw new Error(`${ACCESS} durable receipt lost`);
        return "committed";
      } }, transport: { request }, verifier: { verify }, stopAccount: vi.fn() };
  let clock = NOW;
  const lifecycle = () => new SiwcAccountLifecycle(HOST, services, () => clock);
  return { services, request, verify, commits, lifecycle, get: () => structuredClone(snapshot),
    set: (v: SiwcProtectedSnapshot) => { snapshot = structuredClone(v); }, available: (v: boolean) => { available = v; },
    mutationFailure: (v: typeof mutationFailure) => { mutationFailure = v; }, advance: (ms: number) => { clock += ms; } };
}
async function auth(l: SiwcAccountLifecycle, binding = "a", returning = false, port = 1455) {
  const attempt = await l.beginSignIn({ accountBindingId: binding, callbackPort: port, returning });
  const params = new URL(attempt.authorizationUrl).searchParams;
  const callback = new URL(attempt.callbackUri); callback.search = new URLSearchParams({ code: "synthetic-code", state: params.get("state")!, client_id: `oaiapp_${binding}` }).toString();
  return { ...attempt, params, callback };
}
const secretsAbsent = (value: unknown, extra: string[] = []) => {
  const json = JSON.stringify(value); for (const s of [ACCESS, REFRESH, ID_TOKEN, NEXT_ACCESS, NEXT_REFRESH, NEXT_ID, ...extra]) expect(json).not.toContain(s);
};

describe("host-only SIWC lifecycle", () => {
  it("is inert and unavailable without all protected native seams", async () => {
    const l = new SiwcAccountLifecycle(HOST);
    expect(await l.status()).toEqual({ productionReady: false, nativeIntegration: "unwired", available: false, state: "unsupported", accounts: [] });
    await expect(l.beginSignIn({ accountBindingId: "a", callbackPort: 1455, returning: false })).rejects.toMatchObject({ code: "unsupported" });
    const f = fixture(); f.available(false);
    expect((await f.lifecycle().status()).state).toBe("unsupported"); expect(f.request).not.toHaveBeenCalled();
  });
  it("builds fresh initial state/nonce/PKCE and exact issued-client code exchange before atomic activation", async () => {
    const f = fixture([ready("existing")], "existing"), l = f.lifecycle(), a = await auth(l);
    expect(a.params.get("client_id")).toBe("dynamic_agent_client"); expect(a.params.get("agent_name_hint")).toBe("Yorozu");
    expect(a.params.get("ext_agent_host_id")).toBe(HOST.hostId); expect(a.params.get("resource")).toBe(SIWC_RESOURCE);
    expect(a.params.get("scope")).toBe(SCOPES.join(" ")); expect(a.params.get("code_challenge_method")).toBe("S256");
    expect(new URL(a.authorizationUrl).origin + new URL(a.authorizationUrl).pathname).toBe(SIWC_AUTHORIZATION_URL);
    f.request.mockImplementation(async request => {
      expect(f.get().accounts.find(v => v.accountBindingId === "a")?.phase).toBe("exchanging");
      expect(f.get().activeAccountBindingId).toBe("existing");
      expect(request).toMatchObject({ url: SIWC_TOKEN_URL, method: "POST", form: { grant_type: "authorization_code", client_id: "oaiapp_a",
        code: "synthetic-code", redirect_uri: a.callbackUri, resource: SIWC_RESOURCE } });
      expect(Object.keys(request.form!).sort()).toEqual(["client_id", "code", "code_verifier", "grant_type", "redirect_uri", "resource"]);
      expect(createHash("sha256").update(request.form!.code_verifier).digest("base64url")).toBe(a.params.get("code_challenge"));
      return token();
    });
    f.verify.mockImplementation(async input => {
      expect(f.get().accounts.find(v => v.accountBindingId === "a")?.phase).toBe("pending-verification");
      expect(f.get().activeAccountBindingId).toBe("existing"); expect(input).toMatchObject({ issuer: SIWC_ISSUER, jwksUrl: SIWC_JWKS_URL,
        audience: "oaiapp_a", nonce: a.params.get("nonce") });
      return { status: "verified", claims: { iss: SIWC_ISSUER, aud: "oaiapp_a", sub: "subject-a", exp: NOW / 1000 + 3600, iat: NOW / 1000, nonce: input.nonce } };
    });
    const result = await l.completeSignIn(a.attemptId, a.callback.href);
    expect(f.get().activeAccountBindingId).toBe("a"); expect(f.commits.map(s => s.accounts.find(r => r.accountBindingId === "a")?.phase))
      .toEqual(["exchanging", "pending-verification", "ready"]);
    expect(result.productionReady).toBe(false); secretsAbsent(result, [a.params.get("state")!, a.params.get("nonce")!, "synthetic-code"]);
    expect(await l.getAccessToken("a")).toMatchObject({ accountBindingId: "a", clientId: "oaiapp_a", subject: "subject-a", storage: "os-protected", accessToken: NEXT_ACCESS });
    await expect(l.completeSignIn(a.attemptId, a.callback.href)).rejects.toMatchObject({ code: "invalid" }); expect(f.request).toHaveBeenCalledTimes(1);
    const other = await auth(l, "b"); expect(other.params.get("state")).not.toBe(a.params.get("state")); expect(other.params.get("nonce")).not.toBe(a.params.get("nonce"));
    expect(other.params.get("code_challenge")).not.toBe(a.params.get("code_challenge"));
  });
  it("uses the exact returning client and host, omits app-name hint, and permits omitted callback client", async () => {
    const f = fixture([ready()], "a"), l = f.lifecycle(), a = await auth(l, "a", true, 23456);
    expect(a.params.get("client_id")).toBe("oaiapp_a"); expect(a.params.has("agent_name_hint")).toBe(false);
    expect(a.params.get("id_token_hint")).toBe(ID_TOKEN); a.callback.searchParams.delete("client_id");
    await l.completeSignIn(a.attemptId, a.callback.href);
    expect(f.request.mock.calls[0][0].form!.client_id).toBe("oaiapp_a"); expect(f.request.mock.calls[0][0].form!.redirect_uri).toBe(a.callbackUri);
  });
  it.each(["state", "duplicate", "host", "port", "path", "fragment", "credentials", "client", "entrypoint", "unknown-field", "expired"])
    ("rejects malformed/mismatched %s callback before token dispatch", async kind => {
      const f = fixture([ready()], "a"), l = f.lifecycle(), a = await auth(l, "a", true);
      if (kind === "state") a.callback.searchParams.set("state", "foreign-state");
      if (kind === "duplicate") a.callback.searchParams.append("code", "other-code");
      if (kind === "host") a.callback.hostname = "localhost";
      if (kind === "port") a.callback.port = "1456";
      if (kind === "path") a.callback.pathname = "/callback";
      if (kind === "fragment") a.callback.hash = "unsafe";
      if (kind === "credentials") a.callback.username = "inject";
      if (kind === "client") a.callback.searchParams.set("client_id", "oaiapp_foreign");
      if (kind === "entrypoint") a.callback.searchParams.set("client_id", "dynamic_agent_client");
      if (kind === "unknown-field") a.callback.searchParams.set("accountBindingId", "b");
      if (kind === "expired") f.advance(300_001);
      await expect(l.completeSignIn(a.attemptId, a.callback.href)).rejects.toBeInstanceOf(Error); expect(f.request).not.toHaveBeenCalled();
      expect(f.get().accounts[0].credentials!.accessToken).toBe(ACCESS); secretsAbsent(await l.status());
    });
  it("requires initial issued ID and consumes access_denied without emitting raw callback diagnostics", async () => {
    for (const kind of ["missing-client", "denied"]) {
      const f = fixture(), l = f.lifecycle(), a = await auth(l); a.callback.searchParams.delete("client_id");
      if (kind === "denied") { a.callback.searchParams.set("error", "access_denied"); a.callback.searchParams.set("error_description", ACCESS); }
      await expect(l.completeSignIn(a.attemptId, a.callback.href)).rejects.toThrow(kind === "denied" ? "SIWC account permission" : "SIWC account identity");
      expect(f.request).not.toHaveBeenCalled(); expect(f.get().accounts).toEqual([]); secretsAbsent(await l.status());
    }
  });
  it.each(["issuer", "audience", "nonce", "subject", "expiry", "azp", "unverified"])
    ("rejects %s identity without replacing the active account", async kind => {
      const f = fixture([ready("a"), ready("b")], "a"), l = f.lifecycle(), a = await auth(l, "b", true);
      f.verify.mockImplementation(async input => ({ status: "verified", claims: { iss: kind === "issuer" ? "https://foreign.example" : SIWC_ISSUER,
        aud: kind === "audience" ? "oaiapp_foreign" : "oaiapp_b", nonce: kind === "nonce" ? "wrong" : input.nonce,
        sub: kind === "subject" ? "subject-a" : "subject-b", exp: kind === "expiry" ? NOW / 1000 : NOW / 1000 + 3600,
        iat: NOW / 1000, ...(kind === "azp" ? { azp: "oaiapp_foreign" } : {}) } }));
      if (kind === "unverified") f.verify.mockResolvedValue({ status: "invalid" });
      await expect(l.completeSignIn(a.attemptId, a.callback.href)).rejects.toMatchObject({ code: "identity" });
      expect(f.get().activeAccountBindingId).toBe("a"); expect(f.get().accounts[0].credentials!.accessToken).toBe(ACCESS);
      expect(f.get().accounts[1].phase).toBe("signed-out"); expect(f.get().accounts[1].credentials).toBeUndefined();
    });
  it("retains validated identity-only registration but cannot provide inference access", async () => {
    const f = fixture(), l = f.lifecycle(), a = await auth(l); f.request.mockResolvedValue(token({ scope: "openid profile email", refresh_token: undefined }));
    const status = await l.completeSignIn(a.attemptId, a.callback.href);
    expect(status.accounts[0]).toMatchObject({ phase: "ready", planUse: false }); expect(f.get().accounts[0].registration?.subject).toBe("subject-a");
    await expect(l.getAccessToken("a")).rejects.toMatchObject({ code: "permission" });
  });
  it.each(["openid resource.invoke chatgpt.tokens.use.direct secret.admin", "resource.invoke chatgpt.tokens.use.direct", "openid openid"])
    ("rejects invalid granted scopes %s", async scope => {
      const f = fixture([ready("existing")], "existing"), l = f.lifecycle(), a = await auth(l); f.request.mockResolvedValue(token({ scope }));
      await expect(l.completeSignIn(a.attemptId, a.callback.href)).rejects.toMatchObject({ code: "permission" });
      expect(f.get().activeAccountBindingId).toBe("existing"); expect(f.verify).not.toHaveBeenCalled();
    });
  it("serializes refresh across separate lifecycle instances, records hold first, replaces the rotation atomically", async () => {
    const f = fixture([ready("a", "oaiapp_a", "subject-a", NOW + 10_000)], "a"), l1 = f.lifecycle(), l2 = f.lifecycle();
    const dispatched = deferred<void>(), response = deferred<Awaited<ReturnType<SiwcAccountTransport["request"]>>>();
    f.request.mockImplementation(async request => {
      expect(f.get().accounts[0].phase).toBe("refreshing"); expect(f.get().accounts[0].pending?.operationId).toMatch(/^[a-f0-9]{64}$/);
      expect(request.form).toEqual({ grant_type: "refresh_token", client_id: "oaiapp_a", refresh_token: REFRESH, resource: SIWC_RESOURCE });
      dispatched.resolve(); return response.promise;
    });
    const p1 = l1.getAccessToken("a"); await dispatched.promise; const p2 = l2.getAccessToken("a"); response.resolve(token());
    const [t1, t2] = await Promise.all([p1, p2]); expect(t1.accessToken).toBe(NEXT_ACCESS); expect(t2.accessToken).toBe(NEXT_ACCESS);
    expect(f.request).toHaveBeenCalledTimes(1); expect(f.get().accounts[0].credentials).toMatchObject({ accessToken: NEXT_ACCESS, refreshToken: NEXT_REFRESH, idToken: NEXT_ID });
    expect(f.get().accounts[0].pending).toBeUndefined(); expect(f.services.stopAccount).toHaveBeenCalledWith("a", "refresh");
  });
  it("does not replay a consumed refresh after an unknown reply or restart", async () => {
    const f = fixture([ready("a", "oaiapp_a", "subject-a", NOW)], "a"); f.request.mockRejectedValue(new Error(`${REFRESH} provider body`));
    await expect(f.lifecycle().getAccessToken("a")).rejects.toThrow("SIWC account unknown");
    expect(f.get().accounts[0].phase).toBe("refreshing");
    await expect(f.lifecycle().getAccessToken("a")).rejects.toMatchObject({ code: "unknown" }); expect(f.request).toHaveBeenCalledTimes(1);
    secretsAbsent(await f.lifecycle().status());
  });
  it("durably quarantines rotated credentials on JWKS outage and resumes only verification after restart", async () => {
    const f = fixture([ready("a", "oaiapp_a", "subject-a", NOW)], "a"); f.verify.mockResolvedValue({ status: "unavailable" });
    await expect(f.lifecycle().getAccessToken("a")).rejects.toMatchObject({ code: "unknown" });
    expect(f.get().accounts[0].phase).toBe("pending-verification"); expect(f.get().accounts[0].credentials).toBeUndefined();
    expect(f.get().accounts[0].pending?.credentials?.refreshToken).toBe(NEXT_REFRESH);
    const restarted = f.lifecycle(); await expect(restarted.getAccessToken("a")).rejects.toMatchObject({ code: "unknown" });
    f.verify.mockResolvedValue({ status: "verified", claims: { iss: SIWC_ISSUER, aud: "oaiapp_a", sub: "subject-a", exp: NOW / 1000 + 3600, iat: NOW / 1000 } });
    await restarted.verifyPending("a"); expect((await restarted.getAccessToken("a")).accessToken).toBe(NEXT_ACCESS); expect(f.request).toHaveBeenCalledTimes(1);
  });
  it("never dispatches on failed/uncertain durable hold, including a lost committed receipt", async () => {
    for (const kind of ["before", "after", "conflict"] as const) {
      const f = fixture([ready("a", "oaiapp_a", "subject-a", NOW)]); f.mutationFailure(kind); const l = f.lifecycle();
      await expect(l.getAccessToken("a")).rejects.toMatchObject({ code: kind === "conflict" ? "conflict" : "unknown" });
      expect(f.request).not.toHaveBeenCalled(); secretsAbsent(await l.status());
      f.mutationFailure("none"); if (kind === "after") {
        await expect(f.lifecycle().getAccessToken("a")).rejects.toMatchObject({ code: "unknown" }); expect(f.request).not.toHaveBeenCalled();
      }
    }
  });
  it("clears unusable refresh credentials while retaining issued-client identity", async () => {
    const f = fixture([ready("a", "oaiapp_a", "subject-a", NOW)], "a");
    f.request.mockResolvedValue({ status: 400, body: { error: "refresh_token_reused", error_description: REFRESH } });
    await expect(f.lifecycle().getAccessToken("a")).rejects.toMatchObject({ code: "signed-out" });
    expect(f.get().accounts[0]).toMatchObject({ phase: "signed-out", registration: { clientId: "oaiapp_a", subject: "subject-a" } });
    expect(f.get().accounts[0].credentials).toBeUndefined();
    const a = await auth(f.lifecycle(), "a", true); expect(a.params.has("id_token_hint")).toBe(false); secretsAbsent(await f.lifecycle().status());
  });
  it("refresh without a new ID token retains the established verified identity", async () => {
    const f = fixture([ready("a", "oaiapp_a", "subject-a", NOW)], "a"); f.request.mockResolvedValue(token({ id_token: undefined }));
    expect((await f.lifecycle().getAccessToken("a")).subject).toBe("subject-a"); expect(f.verify).not.toHaveBeenCalled();
    expect(f.get().accounts[0].credentials!.idToken).toBe(ID_TOKEN);
  });
  it("sign-out immediately fences an inflight refresh and never returns its late token", async () => {
    const f = fixture([ready("a", "oaiapp_a", "subject-a", NOW)], "a"), l = f.lifecycle();
    const dispatched = deferred<void>(), response = deferred<Awaited<ReturnType<SiwcAccountTransport["request"]>>>();
    f.request.mockImplementation(async request => {
      if (request.url === SIWC_TOKEN_URL) { dispatched.resolve(); return response.promise; }
      if (request.url === SIWC_DISCOVERY_URL) return { status: 200, body: { issuer: SIWC_ISSUER, jwks_uri: SIWC_JWKS_URL, revocation_endpoint: `${SIWC_ISSUER}/api/accounts/oauth/revoke` } };
      return { status: 200, body: "" };
    });
    const refreshing = l.getAccessToken("a"); await dispatched.promise; const stopped = l.signOut("a"); response.resolve(token());
    await expect(refreshing).rejects.toBeInstanceOf(Error); const status = await stopped;
    expect(status.accounts[0]).toMatchObject({ phase: "signed-out", remoteRevocation: "confirmed" });
    expect(f.request.mock.calls.at(-1)![0].form).toEqual({ token: NEXT_REFRESH, token_type_hint: "refresh_token", client_id: "oaiapp_a" });
    expect(f.get().accounts[0].credentials).toBeUndefined(); await expect(l.getAccessToken("a")).rejects.toMatchObject({ code: "signed-out" });
  });
  it("does not adopt late sign-in after sign-out fences the exact account", async () => {
    const f = fixture([ready()], "a"), l = f.lifecycle(), a = await auth(l, "a", true);
    const started = deferred<void>(), answer = deferred<Awaited<ReturnType<SiwcAccountTransport["request"]>>>();
    f.request.mockImplementation(async request => {
      if (request.url === SIWC_TOKEN_URL) { started.resolve(); return answer.promise; }
      return { status: 503, body: ACCESS };
    });
    const completing = l.completeSignIn(a.attemptId, a.callback.href); await started.promise; const stop = l.signOut("a"); answer.resolve(token());
    await expect(completing).rejects.toMatchObject({ code: "signed-out" }); await stop;
    expect(f.get().accounts[0].phase).toBe("signed-out"); expect(f.get().accounts[0].credentials).toBeUndefined();
  });
  it.each(["foreign-endpoint", "network-error", "body-on-200"])("clears local tokens with truthful unconfirmed revocation on %s", async kind => {
    const f = fixture([ready()], "a"), l = f.lifecycle();
    f.request.mockImplementation(async request => {
      if (request.url === SIWC_DISCOVERY_URL) return { status: 200, body: { issuer: SIWC_ISSUER, jwks_uri: SIWC_JWKS_URL,
        revocation_endpoint: kind === "foreign-endpoint" ? "https://foreign.example/revoke" : `${SIWC_ISSUER}/api/accounts/oauth/revoke` } };
      if (kind === "network-error") throw new Error(`${ACCESS} raw-provider-error`);
      return { status: 200, body: ACCESS };
    });
    const status = await l.signOut("a"); expect(status.accounts[0].remoteRevocation).toBe("unconfirmed");
    expect(f.get().accounts[0].credentials).toBeUndefined(); secretsAbsent(status);
    if (kind === "foreign-endpoint") expect(f.request).toHaveBeenCalledTimes(1);
  });
  it("switches only validated saved accounts and does not confuse same-subject registrations", async () => {
    const f = fixture([ready("a", "oaiapp_a", "same-sub"), ready("b", "oaiapp_b", "same-sub")], "a"), l = f.lifecycle();
    await l.selectAccount("b"); await l.selectAccount("a"); expect(f.get().activeAccountBindingId).toBe("a");
    expect(f.request).not.toHaveBeenCalled(); expect(f.services.stopAccount).toHaveBeenCalledWith("b", "select");
    await expect(l.beginSignIn({ accountBindingId: "a", callbackPort: 1455, returning: false })).rejects.toMatchObject({ code: "identity" });
  });
  it("cannot claim remote revocation of an unseen rotated session from old-token 200", async () => {
    const f = fixture([ready("a", "oaiapp_a", "subject-a", NOW)], "a"), l = f.lifecycle();
    f.request.mockRejectedValueOnce(new Error("lost rotation")); await expect(l.getAccessToken("a")).rejects.toMatchObject({ code: "unknown" });
    f.request.mockImplementation(async request => request.url === SIWC_DISCOVERY_URL
      ? { status: 200, body: { issuer: SIWC_ISSUER, jwks_uri: SIWC_JWKS_URL, revocation_endpoint: `${SIWC_ISSUER}/api/accounts/oauth/revoke` } }
      : { status: 200, body: "" });
    expect((await l.signOut("a")).accounts[0].remoteRevocation).toBe("unconfirmed"); const count = f.request.mock.calls.length;
    expect((await l.signOut("a")).accounts[0].remoteRevocation).toBe("unconfirmed"); expect(f.request).toHaveBeenCalledTimes(count);
  });
  it("closes all observed brokers even after storage becomes unavailable or one stop fails", async () => {
    const f = fixture([ready("a"), ready("b")]), l = f.lifecycle(); await l.status(); f.available(false);
    (f.services.stopAccount as any).mockImplementation((binding: string) => { if (binding === "a") throw new Error(ACCESS); });
    expect(() => l.close()).toThrow("SIWC account unknown"); expect(f.services.stopAccount).toHaveBeenCalledWith("b", "close");
    expect((await l.status()).state).toBe("unsupported");
  });
  it("refuses corrupt/foreign protected snapshots and client binding collisions", async () => {
    for (const change of ["host", "client-collision", "bad-phase", "plaintext"]) {
      const f = fixture([ready("a"), ready("b")]); const s = f.get();
      if (change === "host") s.hostId = "different-host";
      if (change === "client-collision") s.accounts[1].registration!.clientId = "oaiapp_a";
      if (change === "bad-phase") s.accounts[0].phase = "pending-verification";
      if (change === "plaintext") (f.services.store as any).protection = "plaintext";
      f.set(s); expect((await f.lifecycle().status()).available).toBe(false); expect(f.request).not.toHaveBeenCalled();
    }
    const f = fixture([ready()], "a"), l = f.lifecycle(), a = await auth(l, "b"); a.callback.searchParams.set("client_id", "oaiapp_a");
    await expect(l.completeSignIn(a.attemptId, a.callback.href)).rejects.toMatchObject({ code: "identity" }); expect(f.request).not.toHaveBeenCalled();
  });
  it("aborts closed or externally cancelled dispatch without replay and bounds host input", async () => {
    const f = fixture([ready("a", "oaiapp_a", "subject-a", NOW)]), l = f.lifecycle(), started = deferred<void>();
    f.request.mockImplementation(async () => { started.resolve(); return new Promise(() => {}); });
    const controller = new AbortController(), access = l.getAccessToken("a", controller.signal); await started.promise; controller.abort();
    await expect(access).rejects.toMatchObject({ code: "unknown" }); expect(f.get().accounts[0].phase).toBe("refreshing");
    await expect(l.getAccessToken("a")).rejects.toMatchObject({ code: "unknown" }); expect(f.request).toHaveBeenCalledTimes(1);
    l.close(); expect((await l.status()).state).toBe("unsupported");
    const clean = fixture().lifecycle(); for (const input of [{ accountBindingId: "../a", callbackPort: 1455, returning: false },
      { accountBindingId: "a", callbackPort: 80, returning: false }, { accountBindingId: "a", callbackPort: 1455, returning: false, clientId: "oaiapp_inject" }]) {
      await expect(clean.beginSignIn(input as any)).rejects.toMatchObject({ code: "invalid" });
    }
  });
  it("routine refresh privately holds admission without aborting its own broker signal", async () => {
    const f = fixture([ready("a", "oaiapp_a", "subject-a", NOW)], "a"), l = f.lifecycle(), broker = new AbortController();
    await l.status(); expect(l.canExecute("a")).toBe(true);
    (f.services.stopAccount as any).mockImplementation((_binding: string, reason: string) => { if (reason !== "refresh") broker.abort(); });
    f.request.mockImplementation(async request => { expect(broker.signal.aborted).toBe(false); expect(request.signal.aborted).toBe(false);
      expect(l.canExecute("a")).toBe(false); return token(); });
    expect((await l.getAccessToken("a", broker.signal)).accessToken).toBe(NEXT_ACCESS); expect(broker.signal.aborted).toBe(false);
    expect(l.canExecute("a")).toBe(true);
  });
  it("unknown or narrowed refresh retires the broker and keeps admission held", async () => {
    for (const failure of ["unknown", "narrowed"]) {
      const f = fixture([ready("a", "oaiapp_a", "subject-a", NOW)], "a"), l = f.lifecycle(), broker = new AbortController();
      (f.services.stopAccount as any).mockImplementation((_binding: string, reason: string) => { if (reason !== "refresh") broker.abort(); });
      if (failure === "unknown") f.request.mockRejectedValue(new Error(REFRESH));
      else f.request.mockResolvedValue(token({ scope: "openid offline_access resource.invoke chatgpt.tokens.use.direct" }));
      await expect(l.getAccessToken("a", broker.signal)).rejects.toBeInstanceOf(Error);
      expect(broker.signal.aborted).toBe(true); expect(l.canExecute("a")).toBe(false);
      expect(f.services.stopAccount).toHaveBeenCalledWith("a", "invalid");
    }
  });
  it("exact consumed-attempt cancellation aborts a late exchange without adopting or cancelling another attempt", async () => {
    const f = fixture([ready("existing")], "existing"), l = f.lifecycle(), a = await auth(l), b = await auth(l, "b");
    const started = deferred<void>(), late = deferred<Awaited<ReturnType<SiwcAccountTransport["request"]>>>(); let signal!: AbortSignal;
    f.request.mockImplementationOnce(async request => { signal = request.signal; started.resolve(); return late.promise; });
    const running = l.completeSignIn(a.attemptId, a.callback.href); await started.promise;
    l.cancelSignIn(a.attemptId); expect(signal.aborted).toBe(true); late.resolve(token());
    await expect(running).rejects.toMatchObject({ code: "unknown" }); expect(f.get().activeAccountBindingId).toBe("existing");
    expect(f.verify).not.toHaveBeenCalled(); expect(l.canExecute("a")).toBe(false);
    await l.completeSignIn(b.attemptId, b.callback.href); expect(f.get().activeAccountBindingId).toBe("b");
    l.cancelSignIn(a.attemptId); expect(l.canExecute("b")).toBe(true);
  });
  it("cancelled verification stays quarantined even when a verifier ignores abort", async () => {
    const f = fixture([ready("existing")], "existing"), l = f.lifecycle(), a = await auth(l), entered = deferred<void>();
    const late = deferred<Awaited<ReturnType<SiwcIdTokenVerifier["verify"]>>>(); f.verify.mockImplementation(async () => { entered.resolve(); return late.promise; });
    const running = l.completeSignIn(a.attemptId, a.callback.href); await entered.promise; l.cancelSignIn(a.attemptId);
    await expect(running).rejects.toMatchObject({ code: "unknown" });
    late.resolve({ status: "verified", claims: { iss: SIWC_ISSUER, aud: "oaiapp_a", sub: "subject-a", exp: NOW / 1000 + 3600, iat: NOW / 1000, nonce: a.params.get("nonce")! } });
    await Promise.resolve(); expect(f.get().activeAccountBindingId).toBe("existing");
    expect(f.get().accounts.find(v => v.accountBindingId === "a")?.phase).toBe("pending-verification");
  });
});

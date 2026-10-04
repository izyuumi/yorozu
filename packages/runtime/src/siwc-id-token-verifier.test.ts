import { constants, generateKeyPairSync, sign, type KeyObject } from "node:crypto";
import { describe, expect, it, vi } from "vitest";
import { createSiwcIdTokenVerifier, SIWC_ID_VERIFIER_READINESS, type SiwcOfficialJwksFetch } from "./siwc-id-token-verifier.js";
import { SIWC_ISSUER, SIWC_JWKS_URL, SiwcAccountLifecycle, type SiwcProtectedSnapshot } from "./siwc-account-lifecycle.js";

// Ephemeral synthetic keys are generated in memory; nothing loads/saves a key or opens a network connection.
const NOW = 1_790_000_000_000, CLIENT = "oaiapp_synthetic", NONCE = "synthetic_nonce_0123456789_abcdefghij";
const rsa = generateKeyPairSync("rsa", { modulusLength: 2048 });
const weak = generateKeyPairSync("rsa", { modulusLength: 1024 });
const publicJwk = { ...rsa.publicKey.export({ format: "jwk" }), kid: "synthetic-key", alg: "RS256", use: "sig" };
const baseClaims = { iss: SIWC_ISSUER, aud: CLIENT, sub: "synthetic-account", iat: NOW / 1000, exp: NOW / 1000 + 3600, nonce: NONCE };
const input = (idToken: string, extra = {}) => ({ idToken, issuer: SIWC_ISSUER, jwksUrl: SIWC_JWKS_URL, audience: CLIENT,
  nonce: NONCE, signal: new AbortController().signal, ...extra });
function encoded(v: unknown): string { return Buffer.from(typeof v === "string" ? v : JSON.stringify(v)).toString("base64url"); }
function signed(payload: unknown = baseClaims, header: unknown = { alg: "RS256", kid: "synthetic-key", typ: "JWT" }, key: KeyObject = rsa.privateKey,
  padding = constants.RSA_PKCS1_PADDING): string {
  const wire = `${encoded(header)}.${encoded(payload)}`;
  return `${wire}.${sign("RSA-SHA256", Buffer.from(wire), { key, padding }).toString("base64url")}`;
}
function fixture(body: unknown = { keys: [publicJwk] }) {
  const fetch = vi.fn<SiwcOfficialJwksFetch>(async () => ({ status: 200, body }));
  return { fetch, verifier: createSiwcIdTokenVerifier(fetch, () => NOW) };
}

describe("concrete RS256 SIWC ID verifier", () => {
  it("constructs without I/O and verifies a real synthetic RSA signature with exact public identity", async () => {
    const f = fixture(); expect(f.fetch).not.toHaveBeenCalled(); expect(SIWC_ID_VERIFIER_READINESS.productionReady).toBe(false);
    const result = await f.verifier.verify(input(signed({ ...baseClaims, email: "synthetic@example.invalid", private_note: "omit-this" })));
    expect(result).toEqual({ status: "verified", claims: baseClaims }); expect(f.fetch).toHaveBeenCalledTimes(1);
    expect(JSON.stringify(result)).not.toContain("private_note"); expect(JSON.stringify(result)).not.toContain("email");
    expect(Object.isFrozen((result as any).claims)).toBe(true);
  });
  it("works without a nonce on refresh while enforcing preserved client/subject/time identity", async () => {
    const f = fixture(), { nonce, ...refreshed } = baseClaims;
    expect(await f.verifier.verify(input(signed(refreshed), { nonce: undefined }))).toEqual({ status: "verified", claims: refreshed });
  });
  it("accepts multiple exact client audiences only with matching authorized party", async () => {
    const f = fixture(), payload = { ...baseClaims, aud: [CLIENT, "oaiapp_other"], azp: CLIENT };
    expect(await f.verifier.verify(input(signed(payload)))).toEqual({ status: "verified", claims: payload });
  });
  it.each(["none", "HS256", "PS256", "RS512", "ES256"])("rejects unsupported %s algorithm before JWKS fetch", async alg => {
    const f = fixture(); expect(await f.verifier.verify(input(signed(baseClaims, { alg, kid: "synthetic-key" })))).toEqual({ status: "invalid" });
    expect(f.fetch).not.toHaveBeenCalled();
  });
  it.each(["jku", "x5u", "crit", "b64", "jwk", "unknown"])("rejects JOSE header injection %s", async field => {
    const f = fixture(); const token = signed(baseClaims, { alg: "RS256", kid: "synthetic-key", [field]: "https://untrusted.example" });
    expect(await f.verifier.verify(input(token))).toEqual({ status: "invalid" }); expect(f.fetch).not.toHaveBeenCalled();
  });
  it.each(["missing-kid", "malformed-kid", "wrong-typ", "duplicate-header", "escaped-duplicate", "duplicate-payload", "nested-escaped-duplicate", "deep-payload", "invalid-utf8", "bom", "nonfinite", "lone-surrogate"])
    ("rejects malformed bounded JSON: %s", async kind => {
      const f = fixture(); let token = signed();
      if (kind === "missing-kid") token = signed(baseClaims, { alg: "RS256" });
      if (kind === "malformed-kid") token = signed(baseClaims, { alg: "RS256", kid: "../synthetic-key" });
      if (kind === "wrong-typ") token = signed(baseClaims, { alg: "RS256", kid: "synthetic-key", typ: "JOSE" });
      if (kind === "duplicate-header") token = signed(baseClaims, '{"alg":"none","alg":"RS256","kid":"synthetic-key"}');
      if (kind === "escaped-duplicate") token = signed(baseClaims, '{"alg":"RS256","kid":"synthetic-key","k\\u0069d":"synthetic-key"}');
      if (kind === "duplicate-payload") token = signed(`{"iss":"${SIWC_ISSUER}","sub":"synthetic-account","sub":"foreign"}`);
      if (kind === "nested-escaped-duplicate") token = signed(JSON.stringify(baseClaims).slice(0, -1) + ',"extra":{"a":1,"\\u0061":2}}');
      if (kind === "deep-payload") token = signed({ ...baseClaims, nested: [[[[[[[[[1]]]]]]]]] });
      if (kind === "invalid-utf8") { const parts = token.split("."); parts[0] = Buffer.from([0xc0, 0xaf]).toString("base64url"); token = parts.join("."); }
      if (kind === "bom") token = signed("\uFEFF" + JSON.stringify(baseClaims));
      if (kind === "nonfinite") token = signed('{"exp":1e999}');
      if (kind === "lone-surrogate") token = signed({ ...baseClaims, extra: "\uD800" });
      expect(await f.verifier.verify(input(token))).toEqual({ status: "invalid" }); expect(f.fetch).not.toHaveBeenCalled();
    });
  it.each(["padding", "noncanonical", "extra-segment", "invalid-char", "oversize"])("rejects noncanonical base64url %s", async kind => {
    const f = fixture(); let token = signed(); const parts = token.split(".");
    if (kind === "padding") parts[0] += "=";
    if (kind === "noncanonical") parts[2] = parts[2].slice(0, -1) + "B"; // Last low bits must be zero for canonical encoding.
    if (kind === "extra-segment") parts.push("extra");
    if (kind === "invalid-char") parts[0] = parts[0].slice(0, -1) + "+";
    if (kind === "oversize") parts[1] = "A".repeat(32_768);
    token = parts.join("."); expect(await f.verifier.verify(input(token))).toEqual({ status: "invalid" }); expect(f.fetch).not.toHaveBeenCalled();
  });
  it.each(["payload", "header", "signature", "short-signature", "pss-padding"])("rejects cryptographic tamper %s", async kind => {
    const f = fixture(); let token = signed(), parts = token.split(".");
    if (kind === "payload") parts[1] = encoded({ ...baseClaims, sub: "foreign-subject" });
    if (kind === "header") parts[0] = encoded({ alg: "RS256", kid: "synthetic-key" });
    if (kind === "signature") { const bytes = Buffer.from(parts[2], "base64url"); bytes[0] ^= 1; parts[2] = bytes.toString("base64url"); }
    if (kind === "short-signature") parts[2] = Buffer.alloc(255, 1).toString("base64url");
    if (kind === "pss-padding") parts = signed(baseClaims, undefined, rsa.privateKey, constants.RSA_PKCS1_PSS_PADDING).split(".");
    expect(await f.verifier.verify(input(parts.join(".")))).toEqual({ status: "invalid" });
  });
  it.each(["issuer", "audience", "duplicate-audience", "nonclient-audience", "multi-without-azp", "foreign-azp", "nonce", "subject", "expiry", "future-iat", "future-nbf", "fractional-exp", "unsafe-time"])
    ("rejects signed identity mismatch %s", async kind => {
      const f = fixture(); const payload: Record<string, unknown> = { ...baseClaims };
      if (kind === "issuer") payload.iss = "https://foreign.example";
      if (kind === "audience") payload.aud = "oaiapp_other";
      if (kind === "duplicate-audience") payload.aud = [CLIENT, CLIENT];
      if (kind === "nonclient-audience") payload.aud = [CLIENT, "dynamic_agent_client"];
      if (kind === "multi-without-azp") payload.aud = [CLIENT, "oaiapp_other"];
      if (kind === "foreign-azp") payload.azp = "oaiapp_other";
      if (kind === "nonce") payload.nonce = "foreign_nonce_012345678901234567890";
      if (kind === "subject") payload.sub = "../untrusted";
      if (kind === "expiry") payload.exp = NOW / 1000;
      if (kind === "future-iat") payload.iat = NOW / 1000 + 6;
      if (kind === "future-nbf") payload.nbf = NOW / 1000 + 6;
      if (kind === "fractional-exp") payload.exp = NOW / 1000 + 0.5;
      if (kind === "unsafe-time") payload.exp = Number.MAX_SAFE_INTEGER;
      expect(await f.verifier.verify(input(signed(payload)))).toEqual({ status: "invalid" });
    });
  it.each(["d", "p", "q", "dp", "dq", "qi", "oth", "k", "jku", "x5u", "x5c"])("rejects private or external JWK field %s", async field => {
    const f = fixture({ keys: [{ ...publicJwk, [field]: "synthetic-sensitive-material" }] });
    const result = await f.verifier.verify(input(signed())); expect(result).toEqual({ status: "unavailable" });
    expect(JSON.stringify(result)).not.toContain("synthetic-sensitive-material");
  });
  it.each(["duplicate-kid", "unknown-kid", "weak-rsa", "ec-confusion", "hs-confusion", "encrypt-use", "sign-ops", "unknown-field", "leading-zero", "bad-exponent", "too-many-keys"])
    ("rejects invalid public key set %s", async kind => {
      let body: unknown = { keys: [publicJwk] };
      if (kind === "duplicate-kid") body = { keys: [publicJwk, { ...publicJwk }] };
      if (kind === "unknown-kid") body = { keys: [{ ...publicJwk, kid: "other" }] };
      if (kind === "weak-rsa") body = { keys: [{ ...weak.publicKey.export({ format: "jwk" }), kid: "synthetic-key" }] };
      if (kind === "ec-confusion") body = { keys: [{ ...publicJwk, kty: "EC" }] };
      if (kind === "hs-confusion") body = { keys: [{ ...publicJwk, alg: "HS256" }] };
      if (kind === "encrypt-use") body = { keys: [{ ...publicJwk, use: "enc" }] };
      if (kind === "sign-ops") body = { keys: [{ ...publicJwk, key_ops: ["sign"] }] };
      if (kind === "unknown-field") body = { keys: [{ ...publicJwk, permission: "trusted" }] };
      if (kind === "leading-zero") body = { keys: [{ ...publicJwk, n: Buffer.concat([Buffer.from([0]), Buffer.from(publicJwk.n!, "base64url")]).toString("base64url") }] };
      if (kind === "bad-exponent") body = { keys: [{ ...publicJwk, e: Buffer.from([2]).toString("base64url") }] };
      if (kind === "too-many-keys") body = { keys: Array.from({ length: 33 }, (_, i) => ({ ...publicJwk, kid: String(i) })) };
      expect(await fixture(body).verifier.verify(input(signed()))).toEqual({ status: "unavailable" });
    });
  it("permits only public verify key operations and rejects signature from a different key", async () => {
    const f = fixture({ keys: [{ ...publicJwk, key_ops: ["verify"] }] }); expect((await f.verifier.verify(input(signed()))).status).toBe("verified");
    expect(await f.verifier.verify(input(signed(baseClaims, undefined, weak.privateKey)))).toEqual({ status: "invalid" });
  });
  it("rejects forged verifier route/client/nonce input before any key request", async () => {
    const f = fixture(); for (const extra of [{ issuer: "https://foreign.example" }, { jwksUrl: "https://foreign.example/keys" },
      { audience: "dynamic_agent_client" }, { nonce: "short" }, { url: "https://foreign.example" }]) {
      expect(await f.verifier.verify(input(signed(), extra) as any)).toEqual({ status: "invalid" });
    }
    expect(f.fetch).not.toHaveBeenCalled();
  });
  it("distinguishes unavailable fetch from invalid identity and emits no raw token/key/errors", async () => {
    const jwt = signed(), missing = createSiwcIdTokenVerifier(undefined, () => NOW);
    expect(await missing.verify(input(jwt))).toEqual({ status: "unavailable" });
    const f = fixture(); f.fetch.mockRejectedValue(new Error(jwt + JSON.stringify(publicJwk)));
    expect(await f.verifier.verify(input(jwt))).toEqual({ status: "unavailable" });
    f.fetch.mockResolvedValue({ status: 503, body: { error: jwt } }); expect(await f.verifier.verify(input(jwt))).toEqual({ status: "unavailable" });
    f.fetch.mockResolvedValue({ status: 200, body: { keys: "invalid" } }); expect(await f.verifier.verify(input(jwt))).toEqual({ status: "unavailable" });
  });
  it("honors cancelled JWKS fetch without a key retry", async () => {
    const f = fixture(), controller = new AbortController(); controller.abort();
    expect(await f.verifier.verify(input(signed(), { signal: controller.signal }))).toEqual({ status: "unavailable" }); expect(f.fetch).not.toHaveBeenCalled();
    const controller2 = new AbortController(); let started!: () => void; const entered = new Promise<void>(r => { started = r; });
    f.fetch.mockImplementation(async () => { started(); return new Promise(() => {}); });
    const outcome = f.verifier.verify(input(signed(), { signal: controller2.signal })); await entered; controller2.abort();
    expect(await outcome).toEqual({ status: "unavailable" }); expect(f.fetch).toHaveBeenCalledTimes(1);
  });
  it("accepts well-formed UTF-8/whitespace JSON and validates mandatory nonce", async () => {
    const f = fixture(), payload = { ...baseClaims, note: "synthetic unicode 😀" };
    expect((await f.verifier.verify(input(signed(JSON.stringify(payload, null, 2))))).status).toBe("verified");
    const { nonce, ...withoutNonce } = baseClaims;
    expect(await f.verifier.verify(input(signed(withoutNonce)))).toEqual({ status: "invalid" });
  });
  it("keeps real signed rotated tokens quarantined during missing-key evidence and resumes verification only", async () => {
    const f = fixture();
    let snapshot: SiwcProtectedSnapshot = { version: 1, revision: 0, hostId: "synthetic-host", appName: "Yorozu", callbackPath: "/auth/callback",
      activeAccountBindingId: "a", accounts: [{ accountBindingId: "a", registration: { clientId: CLIENT, subject: baseClaims.sub }, phase: "ready",
        scopes: ["openid", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"],
        credentials: { accessToken: "synthetic_old_access_123", refreshToken: "synthetic_old_refresh_123", idToken: signed(), expiresAt: NOW } }] };
    const request = vi.fn(async () => ({ status: 200, body: { access_token: "synthetic_rotated_access_123", refresh_token: "synthetic_rotated_refresh_123",
      id_token: signed(), token_type: "Bearer", expires_in: 3600, scope: "openid offline_access resource.invoke chatgpt.tokens.use.direct" } }));
    const services = { store: { protection: "os-protected" as const, available: () => true,
      withAccountLock: async <T>(_binding: string, work: () => Promise<T>) => work(), read: async () => structuredClone(snapshot),
      replace: async (expected: number, next: SiwcProtectedSnapshot) => { if (expected !== snapshot.revision) return "conflict" as const;
        snapshot = structuredClone(next); return "committed" as const; } }, transport: { request }, verifier: f.verifier, stopAccount: vi.fn() };
    const lifecycle = () => new SiwcAccountLifecycle({ hostId: "synthetic-host", appName: "Yorozu" }, services, () => NOW);
    f.fetch.mockResolvedValue({ status: 200, body: { keys: [{ ...publicJwk, kid: "not-yet-published" }] } });
    await expect(lifecycle().getAccessToken("a")).rejects.toMatchObject({ code: "unknown" });
    expect(snapshot.accounts[0].phase).toBe("pending-verification"); expect(snapshot.accounts[0].pending!.credentials!.refreshToken).toBe("synthetic_rotated_refresh_123");
    expect(snapshot.accounts[0].credentials).toBeUndefined();
    f.fetch.mockResolvedValue({ status: 200, body: { keys: [publicJwk] } });
    const restored = lifecycle(); await restored.verifyPending("a"); expect((await restored.getAccessToken("a")).accessToken).toBe("synthetic_rotated_access_123");
    expect(request).toHaveBeenCalledTimes(1); expect(f.fetch).toHaveBeenCalledTimes(2); expect(snapshot.accounts[0].pending).toBeUndefined();
  });
});

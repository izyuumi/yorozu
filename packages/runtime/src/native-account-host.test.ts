/** Composed account/lifecycle/person seams, synthetic credentials and fake native services. */
import { afterEach, expect, test, vi } from "vitest";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseSiwcAccountStatus, type YorozuEvent } from "@yorozu/shared";
import { createNativeAccountHost } from "./native-account-host.js";
import { PersonAgentStore } from "./agent-store.js";
import * as curated from "./curated-agent-runtime.js";
import type { PersonAgentHost } from "./person-agent-host.js";
import type { NativeSiwcCallbackRequest, NativeSiwcCallbackReply } from "./native-account-coordinator.js";
import { SIWC_DISCOVERY_URL, SIWC_ISSUER, SIWC_JWKS_URL, type SiwcProtectedSnapshot } from "./siwc-account-lifecycle.js";

const cleanup: Array<() => Promise<void>> = [];
afterEach(async () => { for (const close of cleanup.splice(0)) await close(); vi.restoreAllMocks(); });
const SCOPES = ["openid", "profile", "email", "offline_access", "resource.invoke", "chatgpt.tokens.use.direct"];
function fixture(ready = false, writerFails = false) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "native-account-host-fixture-"))), dir = join(root, "state"), home = join(root, "home"), resources = join(root, "Fixture.app", "Contents", "Resources");
  mkdirSync(resources, { recursive: true }); mkdirSync(home);
  let snapshot: SiwcProtectedSnapshot = { version: 1, revision: 0, hostId: "urn:uuid:synthetic-native-host", appName: "Yorozu", callbackPath: "/auth/callback", accounts: [] };
  if (ready) { snapshot.activeAccountBindingId = "account-a"; snapshot.accounts.push({ accountBindingId: "account-a", phase: "ready", registration: { clientId: "oaiapp_fixture", subject: "subject-fixture" },
    scopes: SCOPES, credentials: { accessToken: "synthetic_access_1234567890", refreshToken: "synthetic_refresh_1234567890", idToken: "synthetic_id_token_1234567890", expiresAt: Date.now() + 3_600_000 } }); }
  let active = false, browserUrl = "", callback!: (request: NativeSiwcCallbackRequest) => Promise<NativeSiwcCallbackReply>;
  const protectedStore = { protection: "os-protected" as const, available: () => active,
    activate: vi.fn(async () => { active = true; return structuredClone(snapshot); }),
    read: vi.fn(async () => structuredClone(snapshot)),
    replace: vi.fn(async (revision: number, next: SiwcProtectedSnapshot): Promise<"committed" | "conflict"> => {
      if (revision !== snapshot.revision) return "conflict"; snapshot = structuredClone(next); return "committed";
    }), withAccountLock: async <T>(_binding: string, work: () => Promise<T>) => work(),
    openBrowser: vi.fn(async (url: string) => { browserUrl = url; return { opened: true }; }), close: vi.fn(() => { active = false; }) };
  const request = vi.fn(async (input: any) => input.url === SIWC_DISCOVERY_URL ? { status: 200, body: { issuer: SIWC_ISSUER, jwks_uri: SIWC_JWKS_URL } }
    : { status: 200, body: { access_token: "synthetic_access_1234567890", refresh_token: "synthetic_refresh_1234567890", id_token: "synthetic_id_token_1234567890", token_type: "Bearer", expires_in: 3600, scope: SCOPES.join(" ") } });
  const verify = vi.fn(async (input: any) => ({ status: "verified" as const, claims: { iss: SIWC_ISSUER, aud: input.audience, sub: "subject-fixture", nonce: input.nonce,
    exp: Math.floor(Date.now() / 1000) + 3600, iat: Math.floor(Date.now() / 1000) } }));
  const acquire = vi.fn(async (handler: typeof callback) => { callback = handler; return { host: "127.0.0.1" as const, port: 54321, close: vi.fn() }; });
  const openBroker = vi.fn(async () => ({ host: "127.0.0.1" as const, port: 54322, close: vi.fn() }));
  const host = createNativeAccountHost(resources, dir, { protectedStore, accountServices: { transport: { request }, verifier: { verify } }, callbackEndpoint: { acquire },
    brokerEndpoint: openBroker, inferenceTransport: vi.fn(async () => { throw new Error("No provider execution"); }),
    retainJournalWriter: () => { if (writerFails) throw new Error("Synthetic writer unavailable"); return () => {}; }, homeDirectory: home });
  const store = new PersonAgentStore(dir, { protectedRoots: host.platform.protectedRoots });
  store.create({ id: "alice", name: "Alice", role: "Fixture", pluginId: "hermes", model: "selected-model", accountBindingId: "account-a", allowedTools: ["file", "memory", "delegation"], directories: [] }, 0);
  let selectBroker!: curated.CuratedAgentRuntimeConfiguration["selectBroker"];
  vi.spyOn(curated, "createCuratedAgentRuntimeFactory").mockImplementation((_store, config) => { selectBroker = config.selectBroker; return vi.fn() as any; });
  host.platform.createFactory(store);
  const retirement = vi.fn(async () => {});
  host.bindPeople({ store, runtime: { held: () => undefined, retireAccount: retirement } } as unknown as PersonAgentHost);
  cleanup.push(async () => { await host.close(); rmSync(root, { recursive: true, force: true }); });
  const control = (id: string, data: any, sender = { local: true, paired: false }) => host.control({ id, threadId: "settings", ts: Date.now(), agentId: "main", kind: "siwc_account_control", data: { version: 1, ...data } } as YorozuEvent, sender);
  const complete = () => {
    const state = new URL(browserUrl).searchParams.get("state")!, url = `/auth/callback?${new URLSearchParams({ code: "synthetic-code", state, client_id: "oaiapp_fixture" })}`;
    return callback({ method: "GET", host: "127.0.0.1:54321", remoteAddress: "127.0.0.1", rawHeaders: ["Host", "127.0.0.1:54321"], hasBody: false, url });
  };
  return { root, dir, home, host, store, protectedStore, request, verify, acquire, openBroker, control, complete, retirement,
    select: (scope = store.resolveScope("alice")) => selectBroker(store.list().agents[0], { id: "a".repeat(64), kind: "ordinary", scratchRoot: root, workspace: root, memoryDir: root }, scope) };
}

test("construction and hundreds of status publications do not activate native storage or consume mutation admission", async () => {
  const f = fixture(); expect(f.host.status()).toMatchObject({ nativeIntegration: "wired-unverified", available: false });
  for (let i = 0; i < 260; i++) await f.control(`status-${i}`, { method: "status" });
  expect(f.protectedStore.activate).not.toHaveBeenCalled(); expect(f.protectedStore.read).not.toHaveBeenCalled(); expect(f.acquire).not.toHaveBeenCalled();
  const signed = await f.control("sign-after-polls", { method: "sign-in", bindingId: "account-a" });
  expect(signed.lastControlResult?.status).toBe("pending"); expect(f.protectedStore.openBrowser).toHaveBeenCalledOnce();
});

test("claimed/paired sign-in and widened commands refuse before journal or native activation", async () => {
  const f = fixture();
  await expect(f.control("paired-sign", { method: "sign-in" }, { local: false, paired: true })).rejects.toThrow();
  await expect(f.control("model-sign", { method: "sign-in" }, { local: false, paired: false })).rejects.toThrow();
  await expect(f.control("wide-sign", { method: "sign-in", authorizationUrl: "https://invalid.example" })).rejects.toThrow();
  expect(f.protectedStore.activate).not.toHaveBeenCalled(); expect(f.protectedStore.openBrowser).not.toHaveBeenCalled();
});

test("an unavailable account journal preserves the person platform and refuses account execution", async () => {
  const f = fixture(true, true); expect(f.host.status()).toMatchObject({ available: false, state: "unknown", accounts: [] });
  expect(f.store.list().agents[0].id).toBe("alice"); expect(await f.select()).toBeUndefined();
  await expect(f.control("unavailable-sign", { method: "sign-in" })).rejects.toThrow(); expect(f.protectedStore.activate).not.toHaveBeenCalled();
});

test("exact pending sign-in survives status polls; callback completion publishes safe terminal receipt and account binding", async () => {
  const f = fixture(), pending = await f.control("sign-one", { method: "sign-in", bindingId: "account-a" });
  expect(pending.lastControlResult).toMatchObject({ operationId: "sign-one", status: "pending", attemptId: expect.any(String) });
  expect((await f.control("status-during-sign", { method: "status" })).lastControlResult).toEqual(pending.lastControlResult);
  expect((await f.complete()).status).toBe(200);
  await vi.waitFor(() => expect(f.host.status().lastControlResult).toEqual({ operationId: "sign-one", status: "completed" }));
  const status = parseSiwcAccountStatus(f.host.status()); expect(status.accounts[0]).toMatchObject({ accountBindingId: "account-a", phase: "ready", planUse: true });
  expect(JSON.stringify(status)).not.toMatch(/synthetic_access|synthetic_refresh|synthetic_id_token|oaiapp_|subject-fixture|https?:/);
  await f.control("sign-one", { method: "sign-in", bindingId: "account-a" }); expect(f.protectedStore.openBrowser).toHaveBeenCalledOnce();
});

test("a callback change during an older status read forces trailing publication", async () => {
  const f = fixture(); await f.control("sign-race", { method: "sign-in", bindingId: "account-a" });
  let release!: () => void, entered!: () => void; const reading = new Promise<void>(resolve => { entered = resolve; });
  f.protectedStore.read.mockImplementationOnce(async () => {
    const stale = { version: 1 as const, revision: 0, hostId: "urn:uuid:synthetic-native-host", appName: "Yorozu", callbackPath: "/auth/callback" as const, accounts: [] };
    entered(); await new Promise<void>(resolve => { release = resolve; }); return stale;
  });
  const poll = f.control("stale-poll", { method: "status" }); await reading; expect((await f.complete()).status).toBe(200); release(); await poll;
  expect(f.host.status().accounts[0]?.phase).toBe("ready"); expect(f.host.status().lastControlResult?.status).toBe("completed");
});

test("explicit selected person preparation reuses saved protected account without browser; copied scopes never activate", async () => {
  const f = fixture(true), scope = f.store.resolveScope("alice");
  await expect(f.select(structuredClone(scope))).rejects.toThrow(); expect(f.protectedStore.activate).not.toHaveBeenCalled();
  const selected = await f.select(scope); expect(selected).toMatchObject({ accountBindingId: "account-a", agentId: "alice", model: "selected-model" });
  expect(f.protectedStore.activate).toHaveBeenCalledOnce(); expect(f.protectedStore.openBrowser).not.toHaveBeenCalled(); expect(f.acquire).not.toHaveBeenCalled();
  for (const root of [join(f.home, "Library", "Keychains"), join(f.home, "Library", "Application Support", "Yorozu", "ProtectedAccounts"), join(f.dir, "siwc-account-controls-v1")]) expect(scope.deniedRoots).toContain(root);
  await f.control("sign-out-saved", { method: "sign-out", bindingId: "account-a" }, { local: false, paired: true });
  expect(f.retirement).toHaveBeenCalledWith("account-a");
});

/** Native composition root. Saved credentials remain confined to the trusted host;
 * renderer settings publish only the closed shared status schema. */
import { closeSync, constants, fstatSync, openSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseSiwcAccountControl, parseSiwcAccountStatus, type SiwcAccountStatusData, type SiwcAccountControlResult, type YorozuEvent } from "@yorozu/shared";
import { harnessDigest } from "./harness-ledger.js";
import { SiwcNativeProtectedStore, SIWC_HELPER_RELATIVE_EXECUTABLE } from "./siwc-protected-store.js";
import { createSiwcAccountHttps } from "./siwc-account-https.js";
import { createSiwcIdTokenVerifier } from "./siwc-id-token-verifier.js";
import { createSiwcHttpsTransport } from "./siwc-https-transport.js";
import { createNumericSiwcBrokerEndpoint } from "./siwc-broker-endpoint.js";
import { createNativeSiwcAccountCoordinator, type NativeSiwcAccountCommand, type NativeSiwcCoordinatorServices } from "./native-account-coordinator.js";
import { createNumericSiwcCallbackEndpointFactory } from "./native-account-callback.js";
import { SiwcControlJournal } from "./siwc-control-journal.js";
import { createSiwcPersonBroker, type SiwcPersonBrokerServices } from "./siwc-person-broker.js";
import { packagedPersonAgentPlatform } from "./packaged-agent-runtime.js";
import type { PersonAgentHost } from "./person-agent-host.js";
import type { PersonAgentStore } from "./agent-store.js";
import type { SiwcProtectedAccountStore, SiwcProtectedSnapshot, SiwcAccountServices } from "./siwc-account-lifecycle.js";

interface ProtectedHostStore extends SiwcProtectedAccountStore {
  activate(signal?: AbortSignal): Promise<SiwcProtectedSnapshot>;
  openBrowser(url: string, signal?: AbortSignal): Promise<Readonly<{ opened: boolean }>>;
  close(): void;
}
/** A provenance object minted only by the production transport handler. */
export interface NativeAccountSender { local: boolean; paired: boolean }
export interface NativeAccountHostDependencies {
  protectedStore?: ProtectedHostStore;
  accountServices?: Pick<SiwcAccountServices, "transport" | "verifier">;
  callbackEndpoint?: NativeSiwcCoordinatorServices["callbackEndpoint"];
  inferenceTransport?: SiwcPersonBrokerServices["transport"];
  brokerEndpoint?: SiwcPersonBrokerServices["openEndpoint"];
  retainJournalWriter?(root: string): () => void;
  homeDirectory?: string;
}
function safeReceipt(value: { operationId: string; status: SiwcAccountControlResult["status"]; attemptId?: string; reason?: string }): SiwcAccountControlResult {
  const reasons = ["unsupported", "invalid", "identity", "permission", "conflict", "unknown", "signed-out", "local-sign-in-required", "busy"];
  return { operationId: value.operationId, status: value.status,
    ...(value.status === "pending" && value.attemptId ? { attemptId: value.attemptId } : {}),
    ...(value.reason ? { reason: (reasons.includes(value.reason) ? value.reason : "unknown") as SiwcAccountControlResult["reason"] } : {}) };
}
/** Packaging metadata is a necessary gate, never proof of native account readiness. */
function provisionedHelper(resources: string): boolean {
  try {
    const fd = openSync(join(resources, "YorozuAccounts.app", "Contents", "Resources", "accounts-helper.json"), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    try {
      const stat = fstatSync(fd);
      if (!stat.isFile() || stat.nlink !== 1 || stat.size > 64 * 1024) return false;
      const value = JSON.parse(readFileSync(fd, "utf8"));
      return value.schemaVersion === 1 && value.kind === "yorozu-accounts-helper" && value.provisioning === "static-input-checks";
    } finally { closeSync(fd); }
  } catch { return false; }
}
export function createNativeAccountHost(resources: string, dir: string, dependencies: NativeAccountHostDependencies = {}) {
  const provisioned = provisionedHelper(resources);
  let people: PersonAgentHost | undefined, store: PersonAgentStore | undefined, closed = false;
  let changed = (): void => {};
  let cached: SiwcAccountStatusData = { version: 1, productionReady: false, nativeIntegration: "wired-unverified",
    available: false, state: "unsupported", accounts: [] };
  let journal: SiwcControlJournal | undefined;
  try { journal = new SiwcControlJournal(dir, { retainWriter: dependencies.retainJournalWriter }); }
  catch { cached = { ...cached, state: "unknown" }; }
  if (journal?.lastResult) cached.lastControlResult = safeReceipt(journal.lastResult);
  let lastMutationOperationId = cached.lastControlResult?.operationId;
  const retirements = new Set<Promise<void>>();
  const stopAccount: SiwcAccountServices["stopAccount"] = (binding, reason) => {
    // Rotation holds admission temporarily. Retiring here would abort the very
    // request obtaining the rotated credential and make every refresh unknown.
    // Active-account selection is a UI default, not revocation of explicit bindings.
    if (reason === "refresh" || reason === "select") return;
    broker.stopAccount(binding);
    if (people) {
      const retirement = people.runtime.retireAccount(binding); retirements.add(retirement);
      void retirement.catch(() => {}).finally(() => retirements.delete(retirement));
    }
  };
  const protectedStore = dependencies.protectedStore ?? new SiwcNativeProtectedStore({ signedResourcesPath: resources,
    executable: join(resources, SIWC_HELPER_RELATIVE_EXECUTABLE), fenceAccounts: () => {
      // Helper loss must fence the owned executions even if registry readback is
      // damaged or has changed since those actors were prepared.
      for (const binding of broker.stopAll()) stopAccount(binding, "invalid");
    } });
  const https = dependencies.accountServices ? undefined : createSiwcAccountHttps();
  const accountServices = dependencies.accountServices ?? { transport: https!, verifier: createSiwcIdTokenVerifier(signal => https!.fetchJwks(signal)) };
  const authorized = (sender: unknown, command: Readonly<NativeSiwcAccountCommand>): boolean => {
    if (!sender || typeof sender !== "object") return false;
    const s = sender as NativeAccountSender;
    return command.method === "sign-in" ? s.local === true : s.local === true || s.paired === true;
  };
  const coordinator = createNativeSiwcAccountCoordinator({ validateSender: authorized,
    initializeAccountServices: async signal => {
      const snapshot = await protectedStore.activate(signal);
      if (snapshot.appName !== "Yorozu") return;
      return { host: { hostId: snapshot.hostId, appName: "Yorozu" }, services: { store: protectedStore, ...accountServices, stopAccount } };
    }, nativeBrowser: { openAuthorization: async (url, context) => {
      try { return { status: (await protectedStore.openBrowser(url, context.signal)).opened ? "opened" : "rejected" }; }
      catch { return { status: "unknown" }; }
    } }, callbackEndpoint: dependencies.callbackEndpoint ?? createNumericSiwcCallbackEndpointFactory(), onChange: () => { void refresh(); } });
  const assertScope: SiwcPersonBrokerServices["assertScope"] = (agent, scope) => {
    if (closed || !store) throw new Error("Person account owner unavailable");
    store.assertActorScope(scope);
    if (harnessDigest(store.list().agents.find(a => a.id === agent.id)) !== harnessDigest(agent)) throw new Error("Person account binding changed");
  };
  const broker = createSiwcPersonBroker({ onLeaseChange: (id, state) => people?.runtime.brokerLeaseChanged(id, state), getAccounts: () => coordinator.getLifecycle(), assertScope,
    isExecutionCurrent: (_agent, _execution, scope) => !closed && !!people && scope.chain.every(id => !people!.runtime.held(id) && !people!.runtime.platformStore.hasUnconfirmedActions(id, false)),
    transport: dependencies.inferenceTransport ?? createSiwcHttpsTransport(), openEndpoint: dependencies.brokerEndpoint ?? createNumericSiwcBrokerEndpoint() });
  let refreshing: Promise<void> | undefined, refreshDirty = false;
  const refresh = (): Promise<void> => {
    if (closed) return Promise.resolve();
    refreshDirty = true;
    if (!refreshing) refreshing = (async () => {
      while (refreshDirty && !closed) {
        refreshDirty = false;
        const status = await coordinator.getStatus(), live = lastMutationOperationId ? coordinator.getResult(lastMutationOperationId) : undefined;
        const receipt = live ? safeReceipt(live) : cached.lastControlResult;
        if (!closed) { cached = parseSiwcAccountStatus({ version: 1, ...status, ...(receipt ? { lastControlResult: receipt } : {}) }); changed(); }
      }
    })().catch(() => { if (!closed) { cached = { ...cached, available: false, state: "unknown", accounts: [], activeAccountBindingId: undefined }; changed(); } }).finally(() => {
      refreshing = undefined; if (refreshDirty && !closed) void refresh();
    });
    return refreshing;
  };
  const home = dependencies.homeDirectory ?? homedir();
  const platform = packagedPersonAgentPlatform(resources, { protectedRoots: [join(resources, "YorozuAccounts.app"), join(home, "Library", "Keychains"),
    join(home, "Library", "Application Support", "Yorozu", "ProtectedAccounts"), join(dir, "siwc-account-controls-v1")],
    bindStore: selected => { if (store && store !== selected) throw new Error("Person store owner changed"); store = selected; },
    selectBroker: async (agent, execution, scope) => {
      if (!journal || !agent.accountBindingId || !agent.model) return;
      assertScope(agent, scope);
      const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 10_000); timer.unref();
      try { if (!await coordinator.activateSavedAccounts(controller.signal)) return; await refresh(); return await broker.selectBroker(agent, execution, scope); }
      finally { clearTimeout(timer); }
    }, releaseBroker: (agent, execution) => broker.release(agent, execution) });
  return Object.freeze({ platform, provisioned,
    bindPeople(selected: PersonAgentHost): void { if (people || selected.store !== store) throw new Error("Person account owner changed"); people = selected; },
    bindChanged(callback: () => void): void { changed = callback; },
    status(): SiwcAccountStatusData { return structuredClone(cached); },
    async control(event: YorozuEvent, sender: NativeAccountSender): Promise<SiwcAccountStatusData> {
      if (closed || !journal || event.kind !== "siwc_account_control") throw new Error("Native account control unavailable");
      const input = parseSiwcAccountControl(event.data), { version: _version, ...data } = input;
      const command = { operationId: event.id, ...data, ...(data.method === "sign-in" ? {
        bindingId: data.bindingId ?? `siwc-${harnessDigest(["siwc-account-binding-v1", event.id])}`, returning: data.returning ?? false } : {}) } as NativeSiwcAccountCommand;
      if (!authorized(sender, command)) throw new Error("Native account sender unavailable");
      if (command.method === "sign-in" && !provisioned) return parseSiwcAccountStatus({ ...cached, available: false, state: "unsupported",
        lastControlResult: { operationId: event.id, status: "rejected", reason: "unsupported" } });
      if (command.method === "status") { await refresh(); return structuredClone(cached); }
      const dispatch = async (): Promise<SiwcAccountControlResult> => {
        const result = await coordinator.execute(sender, command);
        return safeReceipt(result);
      };
      const { operationId, ...normalized } = command;
      const result = await journal.execute(operationId, { version: 1, ...normalized }, dispatch);
      lastMutationOperationId = operationId; cached = { ...cached, lastControlResult: safeReceipt(result) };
      await refresh();
      return structuredClone(cached);
    }, async close(): Promise<void> {
      if (closed) return; closed = true; journal?.close();
      try { await coordinator.close(); } finally {
        try { await broker.close(); await Promise.allSettled([...retirements]); } finally { protectedStore.close(); }
      }
    } });
}

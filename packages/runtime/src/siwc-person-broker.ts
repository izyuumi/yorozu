/** Bind the exact host-minted person scope to a local inference broker. No account
 * discovery, login, sockets, or provider traffic occurs at construction. */
import type { PersonAgent } from "./agent-store.js";
import type { EffectiveAgentScope } from "./agent-scope.js";
import type { PersonAgentExecution } from "./person-agent-runtime.js";
import type { SelectedAgentBroker } from "./curated-agent-runtime.js";
import { harnessDigest } from "./harness-ledger.js";
import { createSiwcBrokerSelector, type SiwcAccessToken, type SiwcBrokerSelectorConfiguration } from "./siwc-inference-broker.js";

// Pinned Hermes f97608f toolsets.py and adapter.mjs nativeTools selection.
// These are model function schemas, NOT filesystem/account grants. Hermes owns
// memory and native child reasoning inside its existing isolated profile. A
// restricted execution gets a separate profile; it never inherits private roots.
// `team` is a legacy scope label, not permission to execute another person agent.
const FUNCTIONS: Readonly<Record<string, readonly string[]>> = Object.freeze({
  file: Object.freeze(["read_file", "write_file", "patch", "search_files"]),
  memory: Object.freeze([]), delegation: Object.freeze([]), team: Object.freeze([]),
});
const NATIVE_FUNCTIONS = Object.freeze(["memory", "delegate_task"]);
const INBOX_FUNCTIONS = Object.freeze(["send_agent_message", "read_agent_messages"]);
export interface SiwcPersonAccountService {
  getAccessToken(binding: string, signal?: AbortSignal): Promise<SiwcAccessToken>;
  /** Permanent currency for admitted streams; routine rotation is not revocation.
   * Every new provider request still obtains a token under the native account lock. */
  isAccountCurrent(binding: string): boolean;
}
export interface SiwcPersonBrokerServices {
  getAccounts(): SiwcPersonAccountService | undefined;
  /** Validates original scope provenance and registry revision; never accepts a client clone. */
  assertScope(agent: Readonly<PersonAgent>, scope: EffectiveAgentScope): void;
  isExecutionCurrent(agent: Readonly<PersonAgent>, execution: Readonly<PersonAgentExecution>, scope: EffectiveAgentScope): boolean;
  transport: SiwcBrokerSelectorConfiguration["transport"];
  openEndpoint: SiwcBrokerSelectorConfiguration["openEndpoint"];
  onLeaseChange?: SiwcBrokerSelectorConfiguration["onLeaseChange"];
}
/** Match adapter nativeTools plus its platform.team selection. Team membership
 * is taken only from the host-validated agent, never from request tools or a
 * legacy `team` grant. Native inbox recipients remain host checked separately.
 * Inert pinned-Hermes discovery tests exercise the complete assembled request.
 */
export function siwcHermesFunctions(scope: EffectiveAgentScope, platformTeam = false): readonly string[] {
  if (!Array.isArray(scope.allowedTools) || scope.allowedTools.some(tool => !Object.hasOwn(FUNCTIONS, tool)))
    throw new Error("Selected tools require a verified native provider path");
  return Object.freeze([...new Set([...NATIVE_FUNCTIONS,
    ...scope.allowedTools.flatMap(tool => FUNCTIONS[tool]), ...(platformTeam ? INBOX_FUNCTIONS : [])])].sort());
}
export function createSiwcPersonBroker(services: SiwcPersonBrokerServices, now: () => number = Date.now) {
  const contexts = new Map<string, { agent: Readonly<PersonAgent>; execution: Readonly<PersonAgentExecution>; scope: EffectiveAgentScope;
    binding: string; active: boolean }>();
  let closed = false;
  const selector = createSiwcBrokerSelector({ onLeaseChange: services.onLeaseChange, transport: services.transport, openEndpoint: services.openEndpoint,
    selectGrant: async (agent, execution, signal) => {
      const context = contexts.get(`${agent.id}:${execution.id}`), accounts = services.getAccounts();
      if (!context || !context.active || closed || !accounts || !agent.model || !agent.accountBindingId) return;
      services.assertScope(context.agent, context.scope);
      if (!services.isExecutionCurrent(context.agent, context.execution, context.scope)) return;
      const token = await accounts.getAccessToken(agent.accountBindingId, signal);
      if (token.accountBindingId !== context.binding) return;
      const { accountBindingId, clientId, subject, verification, storage } = token;
      return { agentId: agent.id, executionId: execution.id, model: agent.model, scopeDigest: harnessDigest(context.scope),
        account: { accountBindingId, clientId, subject, verification, storage }, allowedFunctionNames: siwcHermesFunctions(context.scope, context.agent.teamIds.length > 0),
        budget: { maxRequests: 1000, maxConcurrent: 8, maxRequestBytes: 4 * 1024 * 1024, maxResponseBytes: 32 * 1024 * 1024,
          maxTotalBytes: 64 * 1024 * 1024, maxEventBytes: 1024 * 1024, requestTimeoutMs: 120_000, expiresAt: now() + 24 * 60 * 60_000 },
        getAccessToken: (requestSignal: AbortSignal) => {
          const current = services.getAccounts();
          if (current !== accounts) throw new Error("Selected account owner changed");
          return accounts.getAccessToken(context.binding, requestSignal);
        }, isCurrent: () => {
          try { services.assertScope(context.agent, context.scope);
            return context.active && !closed && services.getAccounts() === accounts && accounts.isAccountCurrent(context.binding)
              && services.isExecutionCurrent(context.agent, context.execution, context.scope);
          } catch { return false; }
        } };
    } });
  const release = async (agentId: string, executionId: string): Promise<void> => {
    const key = `${agentId}:${executionId}`, context = contexts.get(key);
    if (context) context.active = false;
    contexts.delete(key); await selector.release(agentId, executionId);
  };
  return Object.freeze({
    async selectBroker(agent: Readonly<PersonAgent>, execution: Readonly<PersonAgentExecution>, scope: EffectiveAgentScope): Promise<SelectedAgentBroker | undefined> {
      if (closed || agent.pluginId !== "hermes" || !agent.accountBindingId || !agent.model) return;
      services.assertScope(agent, scope); siwcHermesFunctions(scope, agent.teamIds.length > 0);
      const key = `${agent.id}:${execution.id}`, previous = contexts.get(key);
      if (previous && (harnessDigest(previous.agent) !== harnessDigest(agent) || previous.scope !== scope
        || harnessDigest(previous.execution) !== harnessDigest(execution))) throw new Error("Execution broker identity is immutable");
      if (!previous) {
        if (contexts.size >= 128) throw new Error("Execution broker budget exceeded");
        contexts.set(key, { agent: Object.freeze(structuredClone(agent)), execution: Object.freeze(structuredClone(execution)),
          scope, binding: agent.accountBindingId, active: true });
      }
      try { return await selector.selectBroker(agent, execution); }
      catch { await release(agent.id, execution.id); throw new Error("Selected account broker is unavailable"); }
    },
    release,
    /** Immediate fence, followed by bounded endpoint retirement. Routine rotation
     * remains inside the lifecycle and must not abort its own token exchange. */
    stopAccount(binding: string): void {
      for (const context of contexts.values()) if (context.binding === binding && context.active) {
        context.active = false; void release(context.agent.id, context.execution.id).catch(() => {});
      }
    },
    /** Helper/lease loss fences observed executions without reading another store. */
    stopAll(): readonly string[] {
      const bindings = [...new Set([...contexts.values()].map(context => context.binding))];
      for (const context of contexts.values()) context.active = false;
      for (const context of [...contexts.values()]) void release(context.agent.id, context.execution.id).catch(() => {});
      return Object.freeze(bindings);
    },
    async close(): Promise<void> { closed = true; for (const context of contexts.values()) context.active = false; await selector.close(); },
  });
}

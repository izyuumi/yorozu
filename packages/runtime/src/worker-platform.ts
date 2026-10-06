/** Opt-in replacement composition. Transport/auth/leases remain outside the harness loop. */
import type { PersonAgentHarnessDescriptor } from "@yorozu/shared";
import type { PersonAgentStore, PersonAgentPlugin } from "./agent-store.js";
import type { PersonAgentPlatform } from "./person-agent-host.js";
import type { PersonAgentRuntimeFactory } from "./person-agent-runtime.js";
import { validAgentId } from "./agent-scope.js";

/** Trusted bundled code only. Registering an adapter does not register or impersonate an agent. */
export interface WorkerHarnessAdapter {
  id: PersonAgentPlugin;
  label: string;
  memory: "worker-memory-v1";
  createFactory(store: PersonAgentStore): PersonAgentRuntimeFactory;
}
export interface MinimalWorkerSelection {
  adapters: readonly WorkerHarnessAdapter[];
  initialAgent?: PersonAgentPlatform["initialAgent"];
  secretaryAgentId: string;
  resourceRoots?: PersonAgentPlatform["resourceRoots"];
  protectedRoots?: readonly string[];
}

/** Existing agents-v1 is the sole durable identity registry; this map is code, not identity.
 * No discovery, SDK execution loop, ambient config, provider fallback or profile import.
 */
export function createMinimalWorkerPlatform(selection: MinimalWorkerSelection): PersonAgentPlatform {
  if (!selection.adapters.length || selection.adapters.length > 2) throw new Error("Select reviewed worker adapters explicitly");
  if (!validAgentId(selection.secretaryAgentId)) throw new Error("Minimal workers require an explicit secretary identity; no legacy planner fallback");
  const adapters = new Map<PersonAgentPlugin, WorkerHarnessAdapter>();
  for (const adapter of selection.adapters) {
    if (!["hermes", "openclaw"].includes(adapter.id) || adapters.has(adapter.id) || adapter.memory !== "worker-memory-v1"
      || typeof adapter.createFactory !== "function" || !adapter.label.trim() || adapter.label.length > 128)
      throw new Error("Invalid or duplicate worker harness adapter");
    adapters.set(adapter.id, Object.freeze({ ...adapter }));
  }
  const descriptors: PersonAgentHarnessDescriptor[] = [...adapters.values()].map(a => ({
    id: a.id, label: a.label, available: true, modes: ["managed"], capabilities: ["worker-memory-v1"],
  }));
  return {
    workerMemory: true,
    initialAgent: selection.initialAgent && structuredClone(selection.initialAgent),
    secretaryAgentId: selection.secretaryAgentId,
    resourceRoots: selection.resourceRoots && structuredClone(selection.resourceRoots),
    protectedRoots: selection.protectedRoots && [...selection.protectedRoots],
    catalog: () => ({ harnesses: structuredClone(descriptors) }),
    createFactory(store) {
      const factories = new Map([...adapters].map(([id, adapter]) => [id, adapter.createFactory(store)]));
      return (agent, scope, execution) => {
        if (agent.runtime?.mode === "connected") throw new Error("Uniform-memory connected adapters are not implemented");
        const factory = factories.get(agent.pluginId);
        if (!factory) throw new Error("Agent selects an unregistered worker harness; no fallback");
        return factory(agent, scope, execution);
      };
    },
  };
}

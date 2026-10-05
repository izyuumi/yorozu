/** Explicit host connection composition. No discovery, credentials lookup or native launch. */
import { lstatSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import type { PersonAgentPlatform } from "./person-agent-host.js";
import { safeAgentPath } from "./agent-scope.js";
import { OPENCLAW_RUNTIME_PIN, CuratedRuntimeUnavailable } from "./curated-agent-runtime.js";

export interface SelectedOpenClawConnection {
  version: 1; connectionId: string; endpoint: string; nativeAgentId: string; sessionKey: string; sessionId: string; token: string; uiTargetId?: string;
}
export interface ConnectedAgentPlatformConfiguration {
  node: string; openclawAdapter: string; codeReadPaths: string[];
  /** The host registered these after explicit selection. Values expose no connection secrets. */
  connections: Array<{ id: string; label: string; available: boolean; unavailableReason?: string }>;
  selectConnection(id: string): SelectedOpenClawConnection | undefined | Promise<SelectedOpenClawConnection | undefined>;
}
const text = (v: unknown, max: number): v is string => typeof v === "string" && v.trim().length > 0 && v.length <= max && !/[\0\r\n]/.test(v);
const fields = (v: unknown, allowed: string[]): v is Record<string, any> => !!v && typeof v === "object" && !Array.isArray(v)
  && Object.keys(v).every(k => allowed.includes(k));

/** Managed and connected lifecycle share the app/history, while keeping authority explicit.
 * The owned bridge remains isolated. An existing external Gateway keeps its own native
 * permission policy; selecting a connection does not claim to retrofit its OS sandbox.
 */
export function withConnectedAgentPlatform(managed: PersonAgentPlatform, input: ConnectedAgentPlatformConfiguration): PersonAgentPlatform {
  if (!fields(input, ["node", "openclawAdapter", "codeReadPaths", "connections", "selectConnection"]) || typeof input.selectConnection !== "function"
    || !Array.isArray(input.connections) || input.connections.length > 16 || !Array.isArray(input.codeReadPaths) || input.codeReadPaths.length > 16)
    throw new CuratedRuntimeUnavailable("runtime", "Explicit host connection configuration is required");
  const connections = structuredClone(input.connections);
  for (const connection of connections) if (!fields(connection, ["id", "label", "available", "unavailableReason"])
    || !text(connection.id, 128) || !text(connection.label, 80) || typeof connection.available !== "boolean"
    || connection.unavailableReason !== undefined && !text(connection.unavailableReason, 512)) throw new CuratedRuntimeUnavailable("runtime", "Invalid connection catalog");
  if (new Set(connections.map(c => c.id)).size !== connections.length) throw new CuratedRuntimeUnavailable("runtime", "Duplicate host connection identity");
  const node = safeAgentPath(input.node, true), adapter = safeAgentPath(input.openclawAdapter, true), select = input.selectConnection;
  const codeReadPaths = input.codeReadPaths.map(path => safeAgentPath(path, true));
  if (!lstatSync(node).isFile() || !lstatSync(adapter).isFile()) throw new CuratedRuntimeUnavailable("runtime", "The selected bridge code is unavailable");
  const manifest = JSON.parse(readFileSync(join(dirname(adapter), "manifest.json"), "utf8"));
  if (manifest?.pluginId !== "openclaw" || manifest?.protocolVersion !== 1 || manifest?.upstream?.version !== OPENCLAW_RUNTIME_PIN.version)
    throw new CuratedRuntimeUnavailable("runtime", "Connected bridge does not match the approved adapter pin");
  return { ...managed,
    catalog: () => {
      const catalog: ReturnType<NonNullable<PersonAgentPlatform["catalog"]>> = managed.catalog?.() ?? {};
      const harnesses = (catalog.harnesses ?? []).filter(h => h.id !== "openclaw");
      return { ...catalog, harnesses: [...harnesses, { id: "openclaw", label: "OpenClaw", available: connections.some(c => c.available),
        modes: ["connected"], capabilities: ["connected-lifecycle-v1"], ...(!connections.some(c => c.available) ? { unavailableReason: "No selected OpenClaw connection is available." } : {}) }],
        connections: connections.map(c => ({ ...c, pluginId: "openclaw" as const })) };
    },
    createFactory: store => {
      const managedFactory = managed.createFactory(store);
      return async (agent, scope, execution) => {
        if (agent.runtime?.mode !== "connected") return managedFactory(agent, scope, execution);
        const connectionId = agent.runtime.connectionId;
        const registered = connections.find(c => c.id === connectionId);
        if (agent.pluginId !== "openclaw" || !registered?.available) throw new CuratedRuntimeUnavailable("runtime", "The selected connection is unavailable; no discovery or managed launch was attempted");
        if (agent.directories.length) throw new CuratedRuntimeUnavailable("scope", "Connected agents use their external harness's resource policy; managed shared-folder grants cannot be applied to an existing Gateway");
        const selected = await select(connectionId);
        if (!fields(selected, ["version", "connectionId", "endpoint", "nativeAgentId", "sessionKey", "sessionId", "token", "uiTargetId"])
          || selected.version !== 1 || selected.connectionId !== connectionId || !text(selected.endpoint, 512)
          || !text(selected.nativeAgentId, 128) || !text(selected.sessionKey, 512) || !text(selected.sessionId, 512) || !text(selected.token, 4096)
          || selected.uiTargetId !== undefined && !text(selected.uiTargetId, 128)) throw new CuratedRuntimeUnavailable("auth", "The exact host-selected connection is unavailable");
        const url = new URL(selected.endpoint), port = Number(url.port);
        if (url.protocol !== "ws:" || url.hostname !== "127.0.0.1" || url.username || url.password || url.search || url.hash
          || url.pathname !== "/" || !Number.isInteger(port) || port < 1024 || port > 65535)
          throw new CuratedRuntimeUnavailable("runtime", "The connected bridge requires an exact numeric-loopback Gateway endpoint");
        return { configuration: { pluginId: "openclaw", upstreamVersion: OPENCLAW_RUNTIME_PIN.version, command: node, args: [adapter], runtime: agent.runtime,
          initialize: { lifecycle: agent.runtime, connection: structuredClone(selected), upstreamVersion: OPENCLAW_RUNTIME_PIN.version } },
          runtime: { command: node, args: [adapter], runtimeDir: execution.scratchRoot, readPaths: [dirname(adapter), ...codeReadPaths], brokerPorts: [port] } };
      };
    },
  };
}

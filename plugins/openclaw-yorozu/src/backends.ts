import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import type { OpenClawConfig } from "openclaw/plugin-sdk/channel-core";
import { errorTag, type Keyed } from "./cards.js";
import type { Store } from "./ledger.js";
import { yorozuRuntime } from "./runtime.js";

const CHANNEL_ID = "yorozu";
type Log = ChannelGatewayContext["log"];
export type HermesSection = { enabled?: boolean };
export type HermesBackend = { url: URL; key: string };
export const KEY_FILE = join(homedir(), ".hermes-yorozu-test", "yorozu-plugin.key");

export function hermesSection(cfg: OpenClawConfig): HermesSection | undefined {
  const yorozu = (cfg.channels as Record<string, unknown> | undefined)?.[CHANNEL_ID] as
    { backends?: { hermes?: HermesSection } } | undefined;
  return yorozu?.backends?.hermes;
}

export function resolveHermesBackend(cfg: OpenClawConfig, log?: Log, keyFile = KEY_FILE): HermesBackend | undefined {
  const hermes = hermesSection(cfg);
  if (hermes === undefined) return undefined;
  if (hermes.enabled !== true) {
    log?.info("yorozu: hermes backend off: disabled");
    return undefined;
  }

  const off = (reason: string): undefined => {
    log?.warn(`yorozu: hermes backend off: ${reason}`);
    return undefined;
  };
  let stat;
  try {
    stat = statSync(keyFile);
  } catch (error) {
    return off(`key file unreadable (${errorTag(error)})`);
  }
  if (!stat.isFile()) return off("key file is not a regular file");
  if ((stat.mode & 0o077) !== 0) {
    const mode = (stat.mode & 0o7777).toString(8).padStart(4, "0");
    return off(`key file mode is ${mode}; group and other must have no access (0600 or 0400)`);
  }

  let key;
  try {
    key = readFileSync(keyFile, "utf8");
  } catch (error) {
    return off(`key file unreadable (${errorTag(error)})`);
  }
  key = key.trim().replace(/^(["'])(.*)\1$/s, "$2");
  if (!key) return off("key file is empty");

  log?.info("yorozu: hermes backend on");
  return { url: new URL("http://127.0.0.1:8652"), key };
}

type ClaimCommand = { key: string; nativeName?: string; textAliases?: string[] };

export async function warnBackendClaims(cfg: OpenClawConfig, log?: Log): Promise<void> {
  try {
    const [{ listChatCommands }, { listSkillCommandsForAgents }, { matchPluginCommand }] = await Promise.all([
      import("openclaw/plugin-sdk/command-auth-native"),
      import("openclaw/plugin-sdk/skill-commands-runtime"),
      import("openclaw/plugin-sdk/plugin-runtime"),
    ]);
    const commands: ClaimCommand[] = listChatCommands({ skillCommands: listSkillCommandsForAgents({ cfg }) });
    const labels = commands
      .filter((command) => command.nativeName?.toLowerCase() === "backend"
        || command.textAliases?.some((alias) => alias.toLowerCase() === "/backend"))
      .map((command) => command.key);
    const plugin = matchPluginCommand("/backend hermes");
    if (plugin) labels.push(`plugin:${plugin.command.pluginId}/${plugin.command.name}`);
    for (const label of labels) {
      log?.warn(`yorozu: /backend is claimed by ${label}; with the Hermes backend off, /backend hermes won't reach the agent`);
    }
  } catch (error) {
    log?.warn(`yorozu: /backend claim check skipped: ${errorTag(error)}`);
  }
}

export type KeyRecord = { keyAttempt: number; session?: string; ended?: true };

export function hermesKeys(): Keyed<KeyRecord> {
  return yorozuRuntime.getRuntime().state.openKeyedStore<KeyRecord>({
    namespace: "hermes-keys", maxEntries: 10_000, overflowPolicy: "evict-oldest",
  });
}

type Unsettled = { runId: string; messageId: string };
type Route = { session: string; unsettled: Unsettled[] };
type Current = { assertCurrent(): void };
type Guarded<T> = Store<T> & {
  register(key: string, value: T, opts: Current): Promise<void>;
  delete(key: string, opts: Current): Promise<boolean>;
};

export type HermesState = {
  routedToHermes(convId: string): boolean;
  setRoute(convId: string, messageId: string): Promise<"set" | "already">;
  session(convId: string): string | undefined;
  dropRoute(convId: string): Promise<void>;
  unsettled(convId: string, exceptMessageId?: string): string[];
  addUnsettled(convId: string, runId: string, messageId: string): Promise<void>;
  removeUnsettled(convId: string, runId: string): Promise<void>;
  serial(convId: string, fn: () => Promise<void>): Promise<void>;
};

export async function createHermesState(
  open: <T>(opts: { namespace: string; retention: "retained" }) => Guarded<T>,
  _log?: Log,
): Promise<HermesState> {
  const store = () => open<Route>({ namespace: "backends", retention: "retained" });
  const routes = new Map<string, Route>();
  for (const { key, value } of await store().entries()) {
    const unsettled = (value.unsettled as (Unsettled | string)[])
      .map((entry) => (typeof entry === "string" ? { runId: entry, messageId: "" } : entry));
    routes.set(key, { ...value, unsettled });
  }
  const chains = new Map<string, Promise<void>>();
  const generations = new Map<string, number>();
  let generation = 0;

  async function save(convId: string, next: Route | undefined): Promise<void> {
    const before = routes.get(convId);
    const mine = ++generation;
    generations.set(convId, mine);
    if (next) routes.set(convId, next);
    else routes.delete(convId);
    const current = {
      assertCurrent: () => {
        if (generations.get(convId) !== mine) throw new Error("superseded");
      },
    };
    try {
      if (next) await store().register(convId, next, current);
      else await store().delete(convId, current);
    } catch (error) {
      if (generations.get(convId) === mine) {
        if (before) routes.set(convId, before);
        else routes.delete(convId);
      }
      throw error;
    }
  }

  return {
    routedToHermes: (convId) => routes.has(convId),
    async setRoute(convId, messageId) {
      if (routes.has(convId)) return "already";
      await save(convId, { session: `yorozu-${convId}-${messageId}`, unsettled: [] });
      return "set";
    },
    session: (convId) => routes.get(convId)?.session,
    dropRoute: (convId) => save(convId, undefined),
    unsettled: (convId, exceptMessageId) => (routes.get(convId)?.unsettled ?? [])
      .filter((entry) => exceptMessageId === undefined || entry.messageId !== exceptMessageId)
      .map((entry) => entry.runId),
    async addUnsettled(convId, runId, messageId) {
      const route = routes.get(convId);
      if (!route || route.unsettled.some((entry) => entry.runId === runId)) return;
      await save(convId, { ...route, unsettled: [...route.unsettled, { runId, messageId }] });
    },
    async removeUnsettled(convId, runId) {
      const route = routes.get(convId);
      if (!route?.unsettled.some((entry) => entry.runId === runId)) return;
      await save(convId, { ...route, unsettled: route.unsettled.filter((entry) => entry.runId !== runId) });
    },
    serial(convId, fn) {
      const next = (chains.get(convId) ?? Promise.resolve()).then(fn).catch(() => {});
      chains.set(convId, next);
      void next.then(() => {
        if (chains.get(convId) === next) chains.delete(convId);
      });
      return next;
    },
  };
}

let shared: HermesState | undefined;

export async function openHermesState(log?: Log): Promise<HermesState | undefined> {
  try {
    return shared ??= await createHermesState(
      <T>(opts: { namespace: string; retention: "retained" }) =>
        yorozuRuntime.getRuntime().state.openKeyedStore<T>(opts) as unknown as Guarded<T>,
      log,
    );
  } catch (error) {
    log?.warn(`yorozu: hermes state unavailable: ${errorTag(error)}`);
    return undefined;
  }
}

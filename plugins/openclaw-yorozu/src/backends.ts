import { readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import type { OpenClawConfig } from "openclaw/plugin-sdk/channel-core";
import { errorTag } from "./cards.js";

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

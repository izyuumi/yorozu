import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import type { OpenClawConfig } from "openclaw/plugin-sdk/channel-core";
import { sendDurableMessageBatch } from "openclaw/plugin-sdk/channel-outbound";
import { resolveThreadSessionKeys } from "openclaw/plugin-sdk/routing";
import { PEER, resolveOwnerRoute } from "./conversation.js";
import { listConversations } from "./history.js";
import { yorozuRuntime } from "./runtime.js";

const CHANNEL_ID = "yorozu";

const store = () =>
  yorozuRuntime.getRuntime().state.openKeyedStore<string>({ namespace: "gateway", retention: "retained" });

// Why OpenClaw will not update this Gateway by itself, the same conditions its auto-updater checks.
function autoUpdateBlockers(cfg: OpenClawConfig): string[] {
  const env = process.env;
  const blockers: string[] = [];
  if (cfg.update?.auto?.enabled !== true) {
    blockers.push("Automatic updates are off. Turn them on with `openclaw config set update.auto.enabled true`.");
  }
  if (cfg.update?.checkOnStart === false) {
    blockers.push("Update checks are off. Turn them on with `openclaw config set update.checkOnStart true`.");
  }
  if (/^(1|true|yes|on)$/i.test(env.OPENCLAW_NO_AUTO_UPDATE?.trim() ?? "")) {
    blockers.push("`OPENCLAW_NO_AUTO_UPDATE` is set in the Gateway's environment. Remove it.");
  }
  // `openclaw gateway install` puts these into the launchd, systemd or Scheduled Task environment.
  if (env.OPENCLAW_SERVICE_MARKER?.trim() !== "openclaw" || env.OPENCLAW_SERVICE_KIND?.trim() !== "gateway") {
    blockers.push("The Gateway is not running as a service. Install it as one with `openclaw gateway install`.");
  }
  return blockers;
}

// Posts into the most recent conversation and mirrors the text into its transcript, so a device that
// connects later finds it in history. Returns false when there is no conversation to post into.
async function post(cfg: OpenClawConfig, agent: string, accountId: string, text: string): Promise<boolean> {
  const convId = listConversations(agent).conversations.find((c) => !c.archived)?.convId;
  if (!convId) return false;
  const route = resolveOwnerRoute(cfg, agent, accountId);
  const { sessionKey } = resolveThreadSessionKeys({ baseSessionKey: route.sessionKey, threadId: convId });
  const sent = await sendDurableMessageBatch({
    cfg,
    channel: CHANNEL_ID,
    to: PEER,
    accountId,
    threadId: convId,
    payloads: [{ text }],
    durability: "best_effort",
    mirror: { sessionKey, agentId: route.agentId, text },
  });
  if (sent.status !== "sent") throw new Error(`notice not sent: ${sent.status}`);
  return true;
}

export async function announceGatewayState(
  ctx: Pick<ChannelGatewayContext, "cfg" | "accountId" | "log">,
  agent: string,
): Promise<void> {
  const { cfg, accountId, log } = ctx;
  const version = yorozuRuntime.getRuntime().version;
  const before = await store().lookup("version");
  if (before !== version) {
    if (before && (await post(cfg, agent, accountId, `Updated OpenClaw ${before} → ${version}`))) {
      log?.info?.(`yorozu: posted OpenClaw update ${before} → ${version}`);
    }
    await store().register("version", version);
  }

  const blockers = autoUpdateBlockers(cfg);
  const condition = blockers.join("\n");
  if (condition === ((await store().lookup("auto-update")) ?? "")) return;
  const text = `OpenClaw can't keep this Gateway up to date by itself:\n\n${blockers.map((b) => `- ${b}`).join("\n")}\n\nWith these fixed, OpenClaw updates the Gateway when it is idle and restarts it.`;
  if (blockers.length && !(await post(cfg, agent, accountId, text))) return;
  await store().register("auto-update", condition);
}

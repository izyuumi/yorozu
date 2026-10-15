import { DEFAULT_ACCOUNT_ID } from "openclaw/plugin-sdk/account-id";
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import {
  buildThreadAwareOutboundSessionRoute,
  createChatChannelPlugin,
  type ChannelPlugin,
  type OpenClawConfig,
} from "openclaw/plugin-sdk/channel-core";
import { chunkMarkdownText } from "openclaw/plugin-sdk/reply-runtime";
import { channelReadyPatch, channelStoppedPatch } from "openclaw/plugin-sdk/gateway-runtime";
import { DEFAULT_CHUNK_LIMIT, handleMessage, PEER, resolveOwnerRoute, sendConversationText } from "./conversation.js";
import { listCronJobs } from "./cron.js";
import { loadHostKeys } from "./keys.js";
import { runRelayHost } from "./relay.js";

export const CHANNEL_ID = "yorozu";
// Same default as the Mac app's `relay.url` (docs/setup.md).
const DEFAULT_RELAY_URL = "wss://relay.yumi.to";

/** `channels.yorozu`; every key is optional, so the channel runs with no entry at all. */
type YorozuConfig = {
  enabled?: boolean;
  agent?: string;
  relayUrl?: string;
  mediaMaxMb?: number;
  textChunkLimit?: number;
};

export type YorozuAccount = {
  accountId: string;
  enabled: boolean;
  configured: boolean;
  agent: string;
  relayUrl: string;
};

function resolveAccount(cfg: OpenClawConfig): YorozuAccount {
  const section = ((cfg.channels as Record<string, unknown> | undefined)?.[CHANNEL_ID] ??
    {}) as YorozuConfig;
  return {
    accountId: DEFAULT_ACCOUNT_ID,
    enabled: section.enabled !== false,
    configured: true,
    agent: section.agent?.trim() || "main",
    relayUrl: section.relayUrl?.trim() || DEFAULT_RELAY_URL,
  };
}

/** Stays pending until the Gateway aborts the account, then settles within a second or so. */
async function startAccount(ctx: ChannelGatewayContext<YorozuAccount>): Promise<void> {
  const { account, abortSignal } = ctx;
  const keys = await loadHostKeys();
  ctx.log?.info?.(`[${account.accountId}] yorozu started (agent ${account.agent}, room ${keys.room})`);
  ctx.setStatus({ accountId: account.accountId, running: true, connected: false, lifecycle: "starting" });
  try {
    await runRelayHost({
      relayUrl: account.relayUrl,
      keys,
      signal: abortSignal,
      log: ctx.log,
      onMessage: (message) =>
        void handleMessage({ cfg: ctx.cfg, accountId: account.accountId, log: ctx.log, agent: account.agent }, message),
      onRequest: async (event) => {
        if (event.kind !== "cron_list") return undefined;
        try {
          return { kind: "cron_list", data: { jobs: await listCronJobs(ctx.cfg, account.agent) } };
        } catch (error) {
          ctx.log?.warn?.(`yorozu: cron list failed: ${String(error)}`);
          return { kind: "cron_list", data: { jobs: [], error: String(error).slice(0, 500) } };
        }
      },
      onStatus: ({ connected, error }) =>
        ctx.setStatus(
          connected
            ? { accountId: account.accountId, ...channelReadyPatch() }
            : { accountId: account.accountId, connected: false, lifecycle: "recovering", lastError: error ?? null },
        ),
    });
  } finally {
    ctx.setStatus({ accountId: account.accountId, ...channelStoppedPatch() });
    ctx.log?.info?.(`[${account.accountId}] yorozu stopped`);
  }
}

export const yorozuPlugin: ChannelPlugin<YorozuAccount> = createChatChannelPlugin({
  base: {
    id: CHANNEL_ID,
    meta: {
      id: CHANNEL_ID,
      label: "Yorozu",
      selectionLabel: "Yorozu",
      docsPath: "/channels/yorozu",
      blurb: "Yorozu apps for iPhone, iPad and Mac, over an end-to-end-encrypted relay.",
    },
    reload: { configPrefixes: [`channels.${CHANNEL_ID}`] },
    config: {
      listAccountIds: () => [DEFAULT_ACCOUNT_ID],
      defaultAccountId: () => DEFAULT_ACCOUNT_ID,
      resolveAccount,
      inspectAccount: (cfg) => {
        const { enabled, configured } = resolveAccount(cfg);
        return { enabled, configured };
      },
    },
    capabilities: { chatTypes: ["direct"] },
    gateway: { startAccount },
    messaging: {
      normalizeTarget: () => PEER,
      // A delivery's thread is its conversation: `agent:<agent>:yorozu:direct:owner:thread:<convId>`.
      resolveOutboundSessionRoute: ({ cfg, agentId, accountId, threadId, currentSessionKey }) => {
        const route = resolveOwnerRoute(cfg, agentId, accountId);
        return buildThreadAwareOutboundSessionRoute({
          route: {
            sessionKey: route.sessionKey,
            baseSessionKey: route.sessionKey,
            peer: { kind: "direct", id: PEER },
            chatType: "direct",
            from: `${CHANNEL_ID}:${PEER}`,
            to: PEER,
          },
          threadId: typeof threadId === "string" ? threadId.toLowerCase() : threadId,
          currentSessionKey,
          precedence: ["threadId", "currentSession"],
        });
      },
    },
  },
  outbound: {
    deliveryMode: "direct",
    chunker: chunkMarkdownText,
    chunkerMode: "markdown",
    textChunkLimit: DEFAULT_CHUNK_LIMIT,
    sendText: async ({ threadId, text }) => ({ channel: CHANNEL_ID, messageId: sendConversationText({ threadId, text }) }),
  },
});

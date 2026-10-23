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
import { loadAttachmentIndex, mediaMaxBytes } from "./attachments.js";
import {
  DEFAULT_CHUNK_LIMIT,
  handleMessage,
  PEER,
  resolveOwnerRoute,
  sendConversationMedia,
  sendConversationText,
} from "./conversation.js";
import { isId } from "./envelope.js";
import { answerRequest } from "./history.js";
import { listCronJobs } from "./cron.js";
import { loadHostKeys } from "./keys.js";
import { notifyReply, runRelayHost } from "./relay.js";
import { runParked } from "./retry.js";
import { yorozuRuntime } from "./runtime.js";
import { applyPatch, watchSessions } from "./sessions.js";

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
  await loadAttachmentIndex().catch((error: unknown) => ctx.log?.warn?.(`yorozu: attachment index failed: ${String(error)}`));
  const maxBytes = mediaMaxBytes(ctx.cfg, account.accountId);
  ctx.log?.info?.(`[${account.accountId}] yorozu started (agent ${account.agent}, room ${keys.room})`);
  ctx.setStatus({ accountId: account.accountId, running: true, connected: false, lifecycle: "starting" });
  watchSessions(account.agent, abortSignal, ctx.log);
  const turn = { cfg: ctx.cfg, accountId: account.accountId, log: ctx.log, agent: account.agent, mediaMaxBytes: maxBytes };
  runParked(abortSignal, (message, attempt) => void handleMessage(turn, message, attempt));
  try {
    await runRelayHost({
      relayUrl: account.relayUrl,
      keys,
      signal: abortSignal,
      log: ctx.log,
      mediaMaxBytes: maxBytes,
      agent: account.agent,
      hostVersion: yorozuRuntime.getRuntime().version,
      onMessage: (message) => void handleMessage(turn, message),
      onRequest: async (event) => {
        if (event.kind === "conv_list" || event.kind === "history") return answerRequest(ctx.cfg, account.agent, event, ctx.log);
        if (event.kind === "conv_patch") return applyPatch(account.agent, event.data, ctx.log);
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
    capabilities: { chatTypes: ["direct"], media: true },
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
    // Core calls this once per file, the caption on the first; a turn's own grouped media goes out in `deliver`.
    sendMedia: async ({ cfg, accountId, threadId, text, mediaUrl, mediaAccess, mediaLocalRoots, mediaReadFile }) => ({
      channel: CHANNEL_ID,
      messageId: await sendConversationMedia({
        threadId,
        text,
        mediaUrl,
        maxBytes: mediaMaxBytes(cfg, accountId),
        access: { mediaAccess, localRoots: mediaLocalRoots, readFile: mediaReadFile },
      }),
    }),
    // A delivery (cron) pushes once per payload, after all its chunks went out, like a turn's reply (#431).
    afterDeliverPayload: async ({ target, payload, results }) => {
      const convId = String(target.threadId ?? "").toLowerCase();
      const messageId = results[0]?.messageId;
      if (isId(convId) && messageId && payload.text?.trim()) await notifyReply(convId, messageId, payload.text);
    },
  },
});

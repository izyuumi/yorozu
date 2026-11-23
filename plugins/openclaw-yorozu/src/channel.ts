import { DEFAULT_ACCOUNT_ID } from "openclaw/plugin-sdk/account-id";
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import {
  buildThreadAwareOutboundSessionRoute,
  createChatChannelPlugin,
  type ChannelPlugin,
  type OpenClawConfig,
} from "openclaw/plugin-sdk/channel-core";
import {
  normalizeMessagePresentation,
  renderMessagePresentationChartFallbackText,
  renderMessagePresentationTableFallbackText,
} from "openclaw/plugin-sdk/interactive-runtime";
import { chunkMarkdownText } from "openclaw/plugin-sdk/reply-runtime";
import { resolveThreadSessionKeys } from "openclaw/plugin-sdk/routing";
import { channelReadyPatch, channelStoppedPatch } from "openclaw/plugin-sdk/gateway-runtime";
import { loadAttachmentIndex, mediaMaxBytes } from "./attachments.js";
import { hermesKeys, hermesSection, openHermesState, resolveHermesBackend, warnBackendClaims } from "./backends.js";
import { channelCard, MESSAGE_TOOL_HINTS, PRESENTATION_CAPABILITIES, renderedPayload } from "./cards.js";
import {
  DEFAULT_CHUNK_LIMIT,
  handleMessage,
  liveTurn,
  mediaUrls,
  replyTarget,
  resolveOwnerRoute,
  sendConversationMedia,
  sendConversationPayload,
  sendConversationText,
} from "./conversation.js";
import type { PresentationSdk } from "./presentation.js";
import { isId } from "./envelope.js";
import { answerRequest } from "./history.js";
import { listCronJobs } from "./cron.js";
import { DIRECT_PORT } from "./direct.js";
import { hermesClients, routedRerun, routeMessage, type HermesDeps } from "./hermes-turn.js";
import { loadHostKeys } from "./keys.js";
import { notifyReply, runRelayHost } from "./relay.js";
import { loadMessageTimes } from "./activity.js";
import { loadReactions, reactionActions, userReaction } from "./reactions.js";
import { loadReplies } from "./replies.js";
import { park, runParked } from "./retry.js";
import { openLedger } from "./runs.js";
import { yorozuRuntime } from "./runtime.js";
import { applyPatch, setThreadBase, watchSessions } from "./sessions.js";
import { currentConversation, looksLikeOwner, PEER } from "./target.js";
import { announceGatewayState } from "./updates.js";

export const CHANNEL_ID = "yorozu";
const DEFAULT_RELAY_URL = "wss://relay.yumi.to";

type YorozuConfig = {
  enabled?: boolean;
  agent?: string;
  relayUrl?: string;
  mediaMaxMb?: number;
  textChunkLimit?: number;
  direct?: { enabled?: boolean; port?: number; bonjour?: boolean };
};

export type YorozuAccount = {
  accountId: string;
  enabled: boolean;
  configured: boolean;
  agent: string;
  relayUrl: string;
  directPort: number | null;
  directBonjour: boolean;
};

const port = (value: unknown): number =>
  Number.isInteger(value) && (value as number) >= 1024 && (value as number) <= 65535 ? (value as number) : DIRECT_PORT;

function resolveAccount(cfg: OpenClawConfig): YorozuAccount {
  const section = ((cfg.channels as Record<string, unknown> | undefined)?.[CHANNEL_ID] ??
    {}) as YorozuConfig;
  return {
    accountId: DEFAULT_ACCOUNT_ID,
    enabled: section.enabled !== false,
    configured: true,
    agent: section.agent?.trim() || "main",
    relayUrl: section.relayUrl?.trim() || DEFAULT_RELAY_URL,
    directBonjour: section.direct?.bonjour !== false,
    directPort: section.direct?.enabled === false ? null : port(section.direct?.port),
  };
}

const presentationSdk: PresentationSdk = {
  normalize: normalizeMessagePresentation,
  tableAlt: renderMessagePresentationTableFallbackText,
  chartAlt: renderMessagePresentationChartFallbackText,
};

let outboundLog: ChannelGatewayContext["log"];

const deliveryReplyTo = (cfg: OpenClawConfig, threadId?: string | number | null, replyToId?: string | null) =>
  replyTarget(cfg, resolveOwnerRoute(cfg, resolveAccount(cfg).agent).agentId, String(threadId ?? "").toLowerCase(), replyToId);

async function startAccount(ctx: ChannelGatewayContext<YorozuAccount>): Promise<void> {
  const { account, abortSignal } = ctx;
  outboundLog = ctx.log;
  const route = resolveOwnerRoute(ctx.cfg, account.agent, account.accountId);
  const agent = route.agentId;
  setThreadBase(agent, route.sessionKey);
  const keys = await loadHostKeys();
  await loadAttachmentIndex().catch((error: unknown) => ctx.log?.warn?.(`yorozu: attachment index failed: ${String(error)}`));
  await loadMessageTimes().catch((error: unknown) => ctx.log?.warn?.(`yorozu: message times failed: ${String(error)}`));
  await loadReplies().catch((error: unknown) => ctx.log?.warn?.(`yorozu: replies failed: ${String(error)}`));
  await loadReactions().catch((error: unknown) => ctx.log?.warn?.(`yorozu: reactions failed: ${String(error)}`));
  const { claim } = await openLedger({ cfg: ctx.cfg, agent, log: ctx.log });
  const maxBytes = mediaMaxBytes(ctx.cfg, account.accountId);
  ctx.log?.info?.(`[${account.accountId}] yorozu started (agent ${agent}, room ${keys.room})`);
  ctx.setStatus({ accountId: account.accountId, running: true, connected: false, lifecycle: "starting" });
  watchSessions(agent, abortSignal, ctx.log);
  const turn = { cfg: ctx.cfg, accountId: account.accountId, log: ctx.log, agent, mediaMaxBytes: maxBytes, presentationSdk };
  const hermesCfg = hermesSection(ctx.cfg);
  const hermes = resolveHermesBackend(ctx.cfg, ctx.log);
  if (hermesCfg) void warnBackendClaims(ctx.cfg, ctx.log);
  const hermesKeyStore = hermesCfg ? hermesKeys() : undefined;
  const state = hermes && (await openHermesState(ctx.log));
  const deps: HermesDeps | undefined = hermes && hermesKeyStore && state
    ? { client: hermesClients.create(hermes), apiKey: hermes.key, state, keys: hermesKeyStore, turn, park, log: ctx.log }
    : undefined;
  runParked(abortSignal, (message, attempt) =>
    void (hermesKeyStore
      ? routedRerun({ keys: hermesKeyStore, turn, deps, log: ctx.log }, message, attempt)
      : handleMessage(turn, message, attempt)));
  void announceGatewayState(turn, agent).catch((error: unknown) => ctx.log?.warn?.(`yorozu: gateway notice failed: ${String(error)}`));
  try {
    await runRelayHost({
      relayUrl: account.relayUrl,
      keys,
      signal: abortSignal,
      log: ctx.log,
      mediaMaxBytes: maxBytes,
      agent,
      hostVersion: yorozuRuntime.getRuntime().version,
      ...(account.directPort !== null && { directPort: account.directPort }),
      directBonjour: account.directBonjour,
      claim,
      onMessage: (message) => void (deps ? routeMessage(deps, message) : handleMessage(turn, message)),
      liveTurn,
      onReaction: (reaction) => {
        const { sessionKey } = resolveThreadSessionKeys({ baseSessionKey: route.sessionKey, threadId: reaction.convId });
        userReaction(reaction, { agentId: route.agentId, sessionKey });
      },
      onRequest: async (event) => {
        if (event.kind === "conv_list" || event.kind === "history") return answerRequest(ctx.cfg, agent, event, ctx.log);
        if (event.kind === "conv_patch") return applyPatch(agent, event.data, ctx.log);
        if (event.kind !== "cron_list") return undefined;
        try {
          return { kind: "cron_list", data: { jobs: await listCronJobs(ctx.cfg, agent) } };
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
    capabilities: { chatTypes: ["direct"], media: true, reply: true, reactions: true, reactionSlots: "single" },
    gateway: { startAccount },
    actions: reactionActions,
    agentPrompt: { messageToolHints: () => [...MESSAGE_TOOL_HINTS] },
    messaging: {
      normalizeTarget: () => PEER,
      targetResolver: { looksLikeId: looksLikeOwner, hint: PEER },
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
  threading: {
    resolveReplyToMode: () => "off",
    resolveAutoThreadId: currentConversation,
  },
  outbound: {
    deliveryMode: "direct",
    chunker: chunkMarkdownText,
    chunkerMode: "markdown",
    textChunkLimit: DEFAULT_CHUNK_LIMIT,
    sendText: async ({ cfg, threadId, text, replyToId }) => ({
      channel: CHANNEL_ID,
      messageId: sendConversationText({ threadId, text, replyTo: deliveryReplyTo(cfg, threadId, replyToId) }),
    }),
    sendMedia: async ({ cfg, accountId, threadId, text, mediaUrl, mediaAccess, mediaLocalRoots, mediaReadFile, replyToId }) => ({
      channel: CHANNEL_ID,
      messageId: await sendConversationMedia({
        threadId,
        text,
        mediaUrl,
        maxBytes: mediaMaxBytes(cfg, accountId),
        access: { mediaAccess, localRoots: mediaLocalRoots, readFile: mediaReadFile },
        replyTo: deliveryReplyTo(cfg, threadId, replyToId),
      }),
    }),
    presentationCapabilities: PRESENTATION_CAPABILITIES,
    renderPresentation: ({ payload, presentation }) => renderedPayload(payload, presentation, presentationSdk, outboundLog),
    sendPayload: async ({ cfg, accountId, threadId, payload, mediaAccess, mediaLocalRoots, mediaReadFile, replyToId }) => ({
      channel: CHANNEL_ID,
      messageId: await sendConversationPayload({
        cfg,
        accountId,
        threadId,
        text: payload.text,
        mediaUrls: mediaUrls(payload.mediaUrl, ...(payload.mediaUrls ?? [])),
        presentation: channelCard(payload),
        sdk: presentationSdk,
        log: outboundLog,
        maxBytes: mediaMaxBytes(cfg, accountId),
        access: { mediaAccess, localRoots: mediaLocalRoots, readFile: mediaReadFile },
        replyTo: deliveryReplyTo(cfg, threadId, replyToId),
      }),
    }),
    afterDeliverPayload: async ({ target, payload, results }) => {
      const convId = String(target.threadId ?? "").toLowerCase();
      const messageId = results[0]?.messageId;
      if (isId(convId) && messageId && payload.text?.trim()) await notifyReply(convId, messageId, payload.text);
    },
  },
});

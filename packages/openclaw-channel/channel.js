import { homedir } from "node:os";
import { join } from "node:path";
import {
  buildChannelOutboundSessionRoute,
  createChannelPluginBase,
  createChatChannelPlugin,
} from "openclaw/plugin-sdk/channel-core";
import {
  buildChannelInboundEventContext,
  dispatchChannelInboundTurn,
  resolveChannelInboundRouteEnvelope,
  toInboundMediaFacts,
} from "openclaw/plugin-sdk/channel-inbound";
import { saveMediaBuffer } from "openclaw/plugin-sdk/media-store";
import { getAgentScopedMediaLocalRoots } from "openclaw/plugin-sdk/media-runtime";
import { loadOutboundMediaFromUrl } from "openclaw/plugin-sdk/outbound-media";
import { createChannelReplyPipeline } from "openclaw/plugin-sdk/channel-reply-pipeline";
import { PlatformMessageNotDispatchedError } from "openclaw/plugin-sdk/error-runtime";
import { applySessionModelSelection } from "openclaw/plugin-sdk/model-session-runtime";
import { buildPreparedModelsProviderData } from "openclaw/plugin-sdk/models-provider-runtime";
import { getSessionEntry, resolveStorePath } from "openclaw/plugin-sdk/session-store-runtime";
import { getRuntimeConfigSnapshot } from "openclaw/plugin-sdk/runtime-config-snapshot";
import { createInboundDispatcher } from "./dispatch.js";
import { CAPABILITIES } from "./capabilities.js";
import { createAttachmentSaver, loadReplyAttachments, replyMediaUrls } from "./media.js";
import { createProgress } from "./progress.js";
import { createModelResponder } from "./models.js";
import { createRuns } from "./runs.js";
import { connectYorozu } from "./socket.js";

// One Yorozu thread = one OpenClaw direct peer, so each thread gets its own session
// (session.dmScope per-channel-peer). Target: `yorozu:<threadId>`.
// Access control is the socket's 0600 mode: only this Mac's user reaches it, so every
// inbound message is the owner's.

const DEFAULT_SOCKET = join(homedir(), "Library/Application Support/Yorozu/channel.sock");

const dispatchInbound = createInboundDispatcher({
  resolveRoute: resolveChannelInboundRouteEnvelope,
  buildContext: buildChannelInboundEventContext,
  createReplyPipeline: createChannelReplyPipeline,
  attachments: createAttachmentSaver({ saveMedia: saveMediaBuffer, toMediaFacts: toInboundMediaFacts }),
  dispatchTurn: dispatchChannelInboundTurn,
});

const respondModel = createModelResponder({
  resolveRoute: resolveChannelInboundRouteEnvelope,
  buildModelsData: buildPreparedModelsProviderData,
  getSessionEntry,
  resolveStorePath,
  applySelection: applySessionModelSelection,
});

const section = (cfg) => cfg.channels?.yorozu ?? {};

const resolveAccount = (cfg)=> {
  const s = section(cfg);
  return { accountId: "default", enabled: s.enabled !== false, configured: true, socketPath: s.socketPath ?? DEFAULT_SOCKET };
};

export const normalizeYorozuTarget = (value)=> {
  const id = value.trim().replace(/^yorozu:/i, "").trim();
  return id && id.length <= 128 && !/\s/.test(id) ? id : undefined;
};

let link;
let runs;

/** OpenClaw's tool hooks, registered in index.js: they see whichever account is running. */
export const progress = createProgress({
  runFor: (sessionKey) => runs?.runFor(sessionKey),
  send: (frame) => link?.send(frame) ?? false,
});

/** Text plus the payload's files; a file that cannot be sent is named in the text instead. */
async function withAttachments(text, urls, options) {
  if (!urls.length) return { text };
  const { attachments, notes } = await loadReplyAttachments(urls, loadOutboundMediaFromUrl, options);
  return { text: [text, ...notes].filter((part) => part.trim()).join("\n\n"), attachments };
}

async function send(to, text, attachments) {
  const threadId = normalizeYorozuTarget(to);
  if (!threadId) throw new Error("Yorozu target must be yorozu:<threadId>");
  if (!link?.connected) {
    throw new PlatformMessageNotDispatchedError("Yorozu is not running", { cause: undefined, retryable: true });
  }
  try {
    return { messageId: await link.deliver(threadId, text, attachments?.length ? { attachments } : undefined) };
  } catch (cause) {
    throw new PlatformMessageNotDispatchedError(`Yorozu delivery failed: ${String(cause)}`, { cause, retryable: true });
  }
}

export const yorozuPlugin = createChatChannelPlugin({
  base: {
    ...createChannelPluginBase({
      id: "yorozu",
      meta: {
        id: "yorozu",
        label: "Yorozu",
        selectionLabel: "Yorozu",
        blurb: "Chat with OpenClaw from Yorozu on this Mac, iPhone and iPad.",
        docsPath: "/channels/yorozu",
      },
      capabilities: { chatTypes: ["direct"], media: true, reactions: false, threads: false, nativeCommands: false },
      reload: { configPrefixes: ["channels.yorozu"] },
      config: {
        listAccountIds: () => ["default"],
        defaultAccountId: () => "default",
        resolveAccount,
        inspectAccount: (cfg) => {
          const account = resolveAccount(cfg);
          return { accountId: "default", enabled: account.enabled, configured: true };
        },
        isEnabled: (account) => account.enabled,
        isConfigured: () => true,
      },
    }),
    messaging: {
      targetPrefixes: ["yorozu"],
      normalizeTarget: normalizeYorozuTarget,
      inferTargetChatType: () => "direct",
      targetResolver: { looksLikeId: (value) => normalizeYorozuTarget(value) !== undefined, hint: "<yorozu:threadId>" },
      resolveOutboundSessionRoute: (params) => {
        const peer = normalizeYorozuTarget(params.target);
        return peer ? buildChannelOutboundSessionRoute({
          cfg: params.cfg, agentId: params.agentId, channel: "yorozu",
          ...(params.accountId !== undefined ? { accountId: params.accountId } : {}),
          peer: { kind: "direct", id: peer }, chatType: "direct", from: `yorozu:${peer}`, to: `yorozu:${peer}`,
        }) : null;
      },
    },
    gateway: {
      startAccount: async (ctx) => {
        ctx.setStatus({ accountId: ctx.accountId, running: true, connected: false });
        const accountRuns = createRuns((frame) => current.send(frame));
        runs = accountRuns;
        const current = connectYorozu({
          path: ctx.account.socketPath,
          capabilities: CAPABILITIES,
          onOpen: () => accountRuns.replay(),
          onAbort: (messageId) => accountRuns.abort(messageId),
          onModelRequest: (frame) => respondModel({ cfg: getRuntimeConfigSnapshot() ?? ctx.cfg, accountId: ctx.accountId, frame }),
          onStatus: (connected) => ctx.setStatus({ accountId: ctx.accountId, running: true, connected }),
          onError: (message) => ctx.log?.warn?.(`yorozu: ${message}`),
          onInbound: (message) =>
            accountRuns.run(message, (signal, begin) =>
              dispatchInbound({
                // Hot reload replaces the snapshot without necessarily restarting this account.
                cfg: getRuntimeConfigSnapshot() ?? ctx.cfg,
                accountId: ctx.accountId,
                message,
                log: ctx.log,
                ...(current.streaming ? { preview: (reply) => current.send({ type: "reply_preview", ...reply }) } : {}),
                deliver: async (payload, reply) => {
                  // Reply files were already copied into OpenClaw's media store, under these roots.
                  const { text, attachments } = await withAttachments(
                    typeof payload?.text === "string" ? payload.text : "", replyMediaUrls(payload),
                    { mediaLocalRoots: getAgentScopedMediaLocalRoots(getRuntimeConfigSnapshot() ?? ctx.cfg) });
                  if (text.trim() || attachments?.length || reply) {
                    if (reply) await current.deliver(message.threadId, text, { ...reply, ...(attachments?.length ? { attachments } : {}) });
                    else await send(message.threadId, text, attachments);
                  }
                },
              }, signal, begin)),
        });
        link = current;
        await new Promise((resolve) => {
          if (ctx.abortSignal.aborted) return resolve();
          ctx.abortSignal.addEventListener("abort", () => resolve(), { once: true });
        });
        current.close();
        if (link === current) link = undefined;
        if (runs === accountRuns) runs = undefined;
        ctx.setStatus({ accountId: ctx.accountId, running: false, connected: false });
      },
    },
  },
  outbound: {
    base: {
      deliveryMode: "gateway",
      resolveTarget: ({ to }) => {
        const threadId = normalizeYorozuTarget(to ?? "");
        return threadId ? { ok: true, to: threadId } : { ok: false, error: new Error("Yorozu target must be yorozu:<threadId>") };
      },
    },
    attachedResults: {
      channel: "yorozu",
      sendText: ({ to, text }) => send(to, text),
      sendMedia: async ({ to, text = "", mediaUrl, mediaAccess, mediaLocalRoots, mediaReadFile }) => {
        const reply = await withAttachments(text, [mediaUrl], { mediaAccess, mediaLocalRoots, mediaReadFile });
        return send(to, reply.text, reply.attachments);
      },
    },
  },
});

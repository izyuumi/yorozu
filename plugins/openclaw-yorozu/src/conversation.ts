/**
 * Text in and out (#424). A device's `message` runs one agent turn in its conversation's thread session,
 * `agent:<agent>:yorozu:direct:owner:thread:<convId>`: every paired device is the one peer `owner` (#415).
 * The run's progress and replies go to every served device (`broadcast`): `run_started`, `typing` while it runs,
 * `tool` per tool call, then one `reply` per chunk. Slash commands are plain text; core handles `/new` in the thread.
 * A turn that replied ends with one push (`notifyReply`, #431), not one per chunk.
 * `sendText` is the outbound adapter's, for deliveries that start outside a turn (cron `delivery.channel: yorozu`).
 * Attachments (#430): a message's uploaded files reach the turn as media facts; a reply's media is announced in
 * its `reply`, grouped, and downloaded by each device on request (src/attachments.ts).
 */
import { randomUUID } from "node:crypto";
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import type { OpenClawConfig } from "openclaw/plugin-sdk/channel-core";
import {
  buildChannelInboundEventContext,
  runChannelInboundEvent,
  toInboundMediaFactsWithMetadata,
} from "openclaw/plugin-sdk/channel-inbound";
import { getAgentScopedMediaLocalRoots } from "openclaw/plugin-sdk/media-local-roots";
import { createTypingCallbacks } from "openclaw/plugin-sdk/channel-outbound";
import { chunkMarkdownText, resolveTextChunkLimit } from "openclaw/plugin-sdk/reply-runtime";
import { resolveAgentRoute, resolveThreadSessionKeys } from "openclaw/plugin-sdk/routing";
import { stageOutbound, uploadedFiles, type MediaAccess } from "./attachments.js";
import { isId, type Attachment, type Event, type Message, type ToolStatus } from "./envelope.js";
import { liveReplyIds } from "./history.js";
import { noteFirstMessage } from "./push.js";
import { broadcast, notifyReply } from "./relay.js";
import { yorozuRuntime } from "./runtime.js";

const CHANNEL_ID = "yorozu";
/** The one channel peer: all devices are the owner's. */
export const PEER = "owner";
/** OpenClaw's own default when `channels.yorozu.textChunkLimit` is unset. */
export const DEFAULT_CHUNK_LIMIT = 4000;
/** The contract asks for a typing repeat at least every 10 s; clients drop it after 30 s without one. */
const TYPING_KEEPALIVE_MS = 8_000;
const TYPING_MAX_MS = 30 * 60 * 1000;

/** `agent:<agent>:yorozu:direct:owner`, the base every conversation's thread key hangs off. */
export function resolveOwnerRoute(cfg: OpenClawConfig, agentId: string, accountId?: string | null) {
  return resolveAgentRoute({
    cfg,
    channel: CHANNEL_ID,
    accountId,
    defaultAgentId: agentId,
    peer: { kind: "direct", id: PEER },
    dmScope: "per-channel-peer",
  });
}

/**
 * One reply per chunk of `text`, each with its own `messageId`: from `ids` (the transcript's) when given.
 * Attachments ride on the last one, or on a reply of their own when there is no text: one group, as the agent sent them.
 */
export function replyEvents(
  cfg: OpenClawConfig,
  convId: string,
  text: string,
  accountId?: string | null,
  ids?: (chunk: number) => string,
  attachments: Attachment[] = [],
): Event[] {
  const limit = resolveTextChunkLimit(cfg, CHANNEL_ID, accountId, { fallbackLimit: DEFAULT_CHUNK_LIMIT });
  const chunks = chunkMarkdownText(text, limit).filter((chunk) => chunk.trim());
  if (attachments.length && !chunks.length) chunks.push("");
  return chunks.map((chunk, k) => ({
    kind: "reply",
    data: {
      convId,
      messageId: ids?.(k) ?? randomUUID(),
      text: chunk,
      ts: Date.now(),
      ...(attachments.length && k === chunks.length - 1 ? { attachments } : {}),
    },
  }));
}

/** A reply payload's media URLs, in order, once each. */
export function mediaUrls(...urls: (string | null | undefined)[]): string[] {
  return [...new Set(urls.map((url) => url?.trim()).filter((url): url is string => !!url))];
}

type TurnContext = Pick<ChannelGatewayContext, "cfg" | "accountId" | "log"> & { agent: string; mediaMaxBytes: number };

/** Runs the turn for one message; never throws (a failure goes to the devices as `error run_failed`). */
export async function handleMessage(ctx: TurnContext, message: Message): Promise<void> {
  const { cfg, accountId, log } = ctx;
  const { convId, messageId, text } = message;
  const send = (...events: Event[]) => void broadcast(events);
  const route = resolveOwnerRoute(cfg, ctx.agent, accountId);
  const { sessionKey } = resolveThreadSessionKeys({ baseSessionKey: route.sessionKey, threadId: convId });
  const files = await uploadedFiles(message.attachments);
  if (files.length < (message.attachments?.length ?? 0)) log?.warn("yorozu: a message names attachments this host does not hold");
  const media = await toInboundMediaFactsWithMetadata(
    files.map((file) => ({ path: file.path, contentType: file.mime, fileName: file.name, messageId })),
  );
  const access: MediaAccess = { localRoots: getAgentScopedMediaLocalRoots(cfg, route.agentId) };
  await noteFirstMessage(convId, text).catch((error: unknown) => log?.warn(`yorozu: push title failed: ${String(error)}`));
  /** The turn's first reply chunk: what its one push names and previews. */
  let firstReply: { messageId: string; text: string } | undefined;

  /** Transcript messages this turn's replies already took their ids from. */
  const usedReplies = new Set<string>();
  let started = false;
  const runStarted = () => {
    if (started) return;
    started = true;
    send({ kind: "run_started", data: { convId, messageId } });
  };
  let typing = false;
  let typingAt = 0;
  const setTyping = (active: boolean) => {
    if (!active && !typing) return;
    // Core refreshes typing on tool starts too; one repeat per keepalive is enough for every device.
    if (active && typing && Date.now() - typingAt < TYPING_KEEPALIVE_MS / 2) return;
    typing = active;
    typingAt = Date.now();
    send({ kind: "typing", data: { convId, active } });
  };
  const typingCallbacks = createTypingCallbacks({
    start: async () => {
      runStarted();
      setTyping(true);
    },
    stop: async () => setTyping(false),
    onStartError: (error) => log?.warn(`yorozu: typing failed: ${String(error)}`),
    keepaliveIntervalMs: TYPING_KEEPALIVE_MS,
    maxDurationMs: TYPING_MAX_MS,
  });
  const tool = (callId: string | undefined, name: string | undefined, status: ToolStatus) => {
    const n = name?.trim();
    if (!callId || !n) return;
    send({ kind: "tool", data: { convId, messageId, callId: callId.slice(0, 128), name: n.slice(0, 128), status } });
  };

  const ctxPayload = buildChannelInboundEventContext({
    channel: CHANNEL_ID,
    accountId: route.accountId,
    messageId,
    messageIdFull: messageId,
    timestamp: Date.now(),
    from: `${CHANNEL_ID}:${PEER}`,
    sender: { id: PEER },
    conversation: { kind: "direct", id: PEER, threadId: convId },
    route: {
      agentId: route.agentId,
      dmScope: "per-channel-peer",
      accountId: route.accountId,
      routeSessionKey: sessionKey,
      dispatchSessionKey: sessionKey,
    },
    reply: { to: PEER, originatingTo: PEER, messageThreadId: convId },
    message: { body: text, bodyForAgent: text, rawBody: text, commandBody: text },
    media,
    access: { commands: { authorized: true } },
  });

  try {
    await runChannelInboundEvent({
      channel: CHANNEL_ID,
      accountId: route.accountId,
      raw: message,
      adapter: {
        ingest: () => ({ id: messageId, timestamp: Date.now(), rawText: text, raw: message }),
        resolveTurn: () => ({
          cfg,
          channel: CHANNEL_ID,
          accountId: route.accountId,
          route: { agentId: route.agentId, dmScope: "per-channel-peer", sessionKey },
          ctxPayload,
          dispatchReplyFromConfig: yorozuRuntime.getRuntime().channel.reply.dispatchReplyFromConfig,
          record: { onRecordError: (error) => log?.warn(`yorozu: session record failed: ${String(error)}`) },
          dispatcherOptions: { typingCallbacks },
          delivery: {
            deliver: async (payload, info) => {
              // Tool summaries are the `tool` events; replies arrive whole, never as streamed blocks.
              const urls = mediaUrls(payload.mediaUrl, ...(payload.mediaUrls ?? []));
              if (info.kind === "tool" || (!payload.text?.trim() && !urls.length)) return;
              runStarted();
              const ids = liveReplyIds(route.agentId, sessionKey, messageId, usedReplies);
              const { attachments, failures } = await stageOutbound(urls, ctx.mediaMaxBytes, access, ids?.(0));
              const body = [payload.text ?? "", ...failures].filter((line) => line.trim()).join("\n\n");
              const replies = replyEvents(cfg, convId, body, route.accountId, ids, attachments);
              const first = replies[0];
              if (!firstReply && first?.kind === "reply") firstReply = { messageId: first.data.messageId, text: body || "📎" };
              send(...replies);
            },
            onError: (error, info) => log?.warn(`yorozu: ${info.kind} reply failed: ${String(error)}`),
          },
          replyOptions: {
            disableBlockStreaming: true,
            allowToolLifecycleWhenProgressHidden: true,
            suppressDefaultToolProgressMessages: true,
            onAgentRunStart: () => {
              runStarted();
              return undefined;
            },
            onToolStart: ({ toolCallId, name, phase }) => {
              if (!phase || phase === "start") tool(toolCallId, name, "running");
            },
            onItemEvent: ({ toolCallId, name, phase, status }) => {
              if (phase === "end") tool(toolCallId, name, !status || status === "completed" ? "done" : "failed");
            },
          },
        }),
      },
    });
  } catch (error) {
    log?.warn(`yorozu: run failed: ${String(error)}`);
    send({ kind: "error", data: { code: "run_failed", message: String(error).slice(0, 500), convId, messageId } });
  } finally {
    setTyping(false);
    if (firstReply) {
      await notifyReply(convId, firstReply.messageId, firstReply.text).catch((error: unknown) =>
        log?.warn(`yorozu: notify failed: ${String(error)}`),
      );
    }
  }
}

const deliveryConv = (threadId: string | number | null | undefined): string => {
  const convId = String(threadId ?? "").toLowerCase();
  if (!isId(convId)) throw new Error("yorozu: a delivery needs the conversation id as threadId");
  return convId;
};

/** The outbound adapter's `sendText`: a delivery into conversation `threadId` from outside a turn. */
export function sendConversationText(params: { threadId?: string | number | null; text: string }): string {
  const convId = deliveryConv(params.threadId);
  const reply: Event = {
    kind: "reply",
    data: { convId, messageId: randomUUID(), text: params.text, ts: Date.now() },
  };
  broadcast([reply]);
  return reply.data.messageId;
}

/** The outbound adapter's `sendMedia`: one file (and its caption) into conversation `threadId`. */
export async function sendConversationMedia(params: {
  threadId?: string | number | null;
  text?: string;
  mediaUrl?: string;
  maxBytes: number;
  access: MediaAccess;
}): Promise<string> {
  const convId = deliveryConv(params.threadId);
  const { attachments, failures } = await stageOutbound(mediaUrls(params.mediaUrl), params.maxBytes, params.access);
  const text = [params.text ?? "", ...failures].filter((line) => line.trim()).join("\n\n");
  const reply: Event = {
    kind: "reply",
    data: { convId, messageId: randomUUID(), text, ts: Date.now(), ...(attachments.length ? { attachments } : {}) },
  };
  broadcast([reply]);
  return reply.data.messageId;
}

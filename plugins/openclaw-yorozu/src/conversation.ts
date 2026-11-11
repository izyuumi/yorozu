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
import { chunkMarkdownText, chunkMarkdownTextWithMode, resolveChunkMode, resolveTextChunkLimit } from "openclaw/plugin-sdk/reply-runtime";
import { resolveAgentRoute, resolveThreadSessionKeys } from "openclaw/plugin-sdk/routing";
import { stageOutbound, uploadedFiles, type MediaAccess } from "./attachments.js";
import { cardFor, cardKey, DROPPED, errorTag, replyChunks, turnCardKey, withCard } from "./cards.js";
import { isId, type Attachment, type Event, type Message, type ReplyTo, type ToolStatus } from "./envelope.js";
import { itemText, liveReplyIds, liveSessionId } from "./history.js";
import type { Presentation, PresentationSdk } from "./presentation.js";
import { storeCard } from "./presentations.js";
import { noteReply } from "./replies.js";
import { noteFirstMessage } from "./push.js";
import { activityTurn, broadcast, notifyReply } from "./relay.js";
import { isTemporary, park } from "./retry.js";
import { yorozuRuntime } from "./runtime.js";
import { maybeTitle } from "./sessions.js";
import { PEER } from "./target.js";

const CHANNEL_ID = "yorozu";
export const DEFAULT_CHUNK_LIMIT = 4000;
const TYPING_KEEPALIVE_MS = 8_000;
const TYPING_MAX_MS = 30 * 60 * 1000;

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

export function replyEvents(
  cfg: OpenClawConfig,
  convId: string,
  text: string,
  accountId?: string | null,
  ids?: { id: (chunk: number) => string; ts: number },
  attachments: Attachment[] = [],
  replyTo?: ReplyTo,
  presentation?: Presentation,
): Event[] {
  const limit = resolveTextChunkLimit(cfg, CHANNEL_ID, accountId, { fallbackLimit: DEFAULT_CHUNK_LIMIT });
  const chunks = chunkMarkdownText(text, limit).filter((chunk) => chunk.trim());
  if ((attachments.length || presentation) && !chunks.length) chunks.push("");
  const events = chunks.map((chunk, k): Event => {
    const messageId = ids?.id(k) ?? randomUUID();
    return {
      kind: "reply",
      data: {
        convId,
        messageId,
        text: chunk,
        ts: ids?.ts ?? Date.now(),
        ...(attachments.length && k === chunks.length - 1 ? { attachments } : {}),
        ...(replyTo && k === 0 ? { replyTo: noteReply(messageId, replyTo) } : {}),
      },
    };
  });
  return withCard(events, presentation);
}

/** A payload's text and card as sent (`cardFor`), with one content-free line for a card that was dropped. */
function payloadCard(payload: { text?: string; presentation?: unknown }, sdk: PresentationSdk, log?: ChannelGatewayContext["log"]) {
  const card = cardFor(payload.presentation, payload.text, sdk);
  if (card.dropped) log?.warn(DROPPED);
  return card;
}

const NOT_KEPT = "yorozu: a card went out without being stored; history will not show it";
const runningTurns = new Map<string, { messageId: string; agentId: string; sessionKey: string }>();

export function replyTarget(cfg: OpenClawConfig, agent: string, convId: string, id?: string | null, current?: Message): ReplyTo | undefined {
  const messageId = id?.trim().toLowerCase();
  if (!isId(messageId)) return undefined;
  const text = messageId === current?.messageId ? current.text : itemText(cfg, agent, convId, messageId);
  return { messageId, ...(text ? { text } : {}) };
}

export function mediaUrls(...urls: (string | null | undefined)[]): string[] {
  return [...new Set(urls.map((url) => url?.trim()).filter((url): url is string => !!url))];
}

type TurnContext = Pick<ChannelGatewayContext, "cfg" | "accountId" | "log"> & {
  agent: string;
  mediaMaxBytes: number;
  presentationSdk: PresentationSdk;
};

export async function handleMessage(ctx: TurnContext, message: Message, attempt = 0): Promise<void> {
  const { cfg, accountId, log } = ctx;
  const { convId, messageId, text } = message;
  const send = (...events: Event[]) => void broadcast(events);
  const route = resolveOwnerRoute(cfg, ctx.agent, accountId);
  const { sessionKey } = resolveThreadSessionKeys({ baseSessionKey: route.sessionKey, threadId: convId });
  const files = await uploadedFiles(message.attachments);
  const held = new Set(files.map((file) => file.id));
  const missing = (message.attachments ?? []).filter((a) => !held.has(a.id)).map((a) => a.name);
  if (missing.length) {
    log?.warn(`yorozu: a message names ${missing.length} attachment(s) this host does not hold`);
    if (attempt === 0) {
      send({
        kind: "error",
        data: { code: "attachment_missing", message: `not on the host, so the agent did not get them: ${missing.join(", ")}`, convId, messageId },
      });
    }
  }
  const media = await toInboundMediaFactsWithMetadata(
    files.map((file) => ({ path: file.path, contentType: file.mime, fileName: file.name, messageId })),
  );
  const access: MediaAccess = { localRoots: getAgentScopedMediaLocalRoots(cfg, route.agentId) };
  await noteFirstMessage(convId, text).catch((error: unknown) => log?.warn(`yorozu: push title failed: ${String(error)}`));
  const quote = message.replyTo;
  if (quote) noteReply(messageId, quote);
  let firstReply: { messageId: string; text: string } | undefined;

  const usedReplies = new Set<string>();
  let toolRan = false;
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
  const calls = new Set<string>();
  const tool = (callId: string | undefined, name: string | undefined, status: ToolStatus) => {
    const n = name?.trim();
    if (!callId || !n) return;
    toolRan = true;
    send({ kind: "tool", data: { convId, messageId, callId: callId.slice(0, 128), name: n.slice(0, 128), status } });
    if (calls.has(callId)) return;
    calls.add(callId);
    activityTurn(convId, { kind: "step", steps: calls.size });
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
    ...(quote && { supplemental: { quote: { id: quote.messageId, fullId: quote.messageId, body: quote.text, senderAllowed: true } } }),
    access: { commands: { authorized: true } },
  });

  // As the app reads a turn's end: a reply is done, a reported failure failed, a retry still running, nothing gone.
  let ended: "failed" | "retrying" | undefined;
  const turn = { messageId, agentId: route.agentId, sessionKey };
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
              const urls = mediaUrls(payload.mediaUrl, ...(payload.mediaUrls ?? []));
              if (info.kind === "tool") return;
              // OpenClaw hands a message-tool card here as it came; this is the only place it is checked.
              const card = payloadCard(payload, ctx.presentationSdk, log);
              if (!card.text.trim() && !urls.length && !card.presentation) return;
              runStarted();
              // A transcript message's ids only for a payload with text or a file of its own. With a card, only a
              // message saying the payload's text: a card-only payload (a `message` tool send, whose transcript
              // message holds a tool call and no text) or one whose text no message says must not take the ids of
              // some other reply's text, and leaves that message to it.
              const ids = !card.presentation
                ? payload.text?.trim() || urls.length ? liveReplyIds(route.agentId, sessionKey, messageId, usedReplies) : undefined
                : payload.text?.trim() ? liveReplyIds(route.agentId, sessionKey, messageId, usedReplies, payload.text) : undefined;
              const { attachments, failures } = await stageOutbound(urls, ctx.mediaMaxBytes, access, ids?.id(0));
              const body = [card.text, ...failures].filter((line) => line.trim()).join("\n\n");
              const replyTo = replyTarget(cfg, ctx.agent, convId, payload.replyToId, message);
              const replies = replyEvents(cfg, convId, body, route.accountId, ids, attachments, replyTo, card.presentation);
              const first = replies[0];
              if (!firstReply && first?.kind === "reply") firstReply = { messageId: first.data.messageId, text: body || "📎" };
              send(...replies);
              // After the reply and not awaited: a slow or failing store costs the history card, never the reply.
              const carrier = replies.at(-1);
              if (card.presentation && carrier?.kind === "reply") {
                const { presentation } = card;
                // With a transcript message's ids, history puts the card on that message. Without, the card is kept
                // by its turn with the reply that carried it, which history shows again under the same ids.
                const sessionId = ids?.sessionId ?? liveSessionId(route.agentId, sessionKey);
                const key = ids ? cardKey(ids.sessionId, ids.eventId) : sessionId && turnCardKey(sessionId, messageId, carrier.data.messageId);
                if (!key) log?.warn(NOT_KEPT);
                else {
                  void storeCard(convId, key, ids ? { presentation } : { presentation, reply: replyChunks(replies) }).catch(
                    (error: unknown) => log?.warn(`yorozu: a card was not stored (${errorTag(error)}); history will not show it`),
                  );
                }
              }
            },
            onError: (error, info) => log?.warn(`yorozu: ${info.kind} reply failed: ${String(error)}`),
          },
          replyOptions: {
            disableBlockStreaming: true,
            allowToolLifecycleWhenProgressHidden: true,
            suppressDefaultToolProgressMessages: true,
            onAgentRunStart: () => {
              // The turn sendPayload stores cards under: from its agent run's start, so a message that waits in
              // OpenClaw's queue behind a running turn does not take that turn's cards. One run per session at a time.
              runningTurns.set(convId, turn);
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
    const retrying = !firstReply && !toolRan && isTemporary(error) && (await park(message, attempt).catch(() => false));
    log?.warn(`yorozu: run failed${retrying ? ` (retry ${attempt + 1} queued)` : ""}: ${String(error)}`);
    if (!retrying) send({ kind: "error", data: { code: "run_failed", message: String(error).slice(0, 500), convId, messageId } });
    ended = retrying ? "retrying" : "failed";
  } finally {
    if (runningTurns.get(convId) === turn) runningTurns.delete(convId);
    setTyping(false);
    if (ended !== "retrying") activityTurn(convId, { kind: firstReply ? "done" : (ended ?? "gone") });
    if (firstReply) {
      await notifyReply(convId, firstReply.messageId, firstReply.text).catch((error: unknown) =>
        log?.warn(`yorozu: notify failed: ${String(error)}`),
      );
    }
  }
  void maybeTitle(cfg, route.agentId, convId, log);
}

// "no conversation reference found" is one of OpenClaw's permanent delivery errors
// (src/infra/outbound/delivery-queue-recovery-policy.ts), so a send without a conversation is not queued for retries.
export const NO_CONVERSATION = "yorozu: no conversation reference found; a delivery needs the conversation id as threadId";

const deliveryConv = (threadId: string | number | null | undefined): string => {
  const convId = String(threadId ?? "").toLowerCase();
  if (!isId(convId)) throw new Error(NO_CONVERSATION);
  return convId;
};

const quoted = (messageId: string, replyTo?: ReplyTo) => (replyTo ? { replyTo: noteReply(messageId, replyTo) } : {});

export function sendConversationText(params: { threadId?: string | number | null; text: string; replyTo?: ReplyTo }): string {
  const convId = deliveryConv(params.threadId);
  const messageId = randomUUID();
  broadcast([{ kind: "reply", data: { convId, messageId, text: params.text, ts: Date.now(), ...quoted(messageId, params.replyTo) } }]);
  return messageId;
}

export async function sendConversationMedia(params: {
  threadId?: string | number | null;
  text?: string;
  mediaUrl?: string;
  maxBytes: number;
  access: MediaAccess;
  replyTo?: ReplyTo;
}): Promise<string> {
  const convId = deliveryConv(params.threadId);
  const { attachments, failures } = await stageOutbound(mediaUrls(params.mediaUrl), params.maxBytes, params.access);
  const text = [params.text ?? "", ...failures].filter((line) => line.trim()).join("\n\n");
  const messageId = randomUUID();
  const reply: Event = {
    kind: "reply",
    data: { convId, messageId, text, ts: Date.now(), ...(attachments.length ? { attachments } : {}), ...quoted(messageId, params.replyTo) },
  };
  broadcast([reply]);
  return messageId;
}

/** An explicit-target payload OpenClaw hands to `sendPayload`: the id of its first reply, or "" when nothing was sent.
 * - With the card `renderPresentation` put in `channelData.yorozu`: chunked text, files and the card on the last
 *   chunk. During that conversation's running turn, the card is stored under the turn for history.
 * - Without a card (some other `channelData`, a location, or a card that was dropped): exactly what OpenClaw does
 *   for a channel with no `sendPayload` (`src/infra/outbound/deliver-core.ts:342-397`, `message-plan.ts`): one
 *   `sendText` per text chunk, or one `sendMedia` per file with the text on the first. Nothing sendable sends
 *   nothing and does not throw; OpenClaw records a result without an id as not delivered. */
export async function sendConversationPayload(params: {
  cfg: OpenClawConfig;
  accountId?: string | null;
  threadId?: string | number | null;
  text?: string;
  mediaUrls: string[];
  presentation?: unknown;
  sdk: PresentationSdk;
  maxBytes: number;
  access: MediaAccess;
  replyTo?: ReplyTo;
  log?: ChannelGatewayContext["log"];
}): Promise<string> {
  const convId = deliveryConv(params.threadId);
  const card = payloadCard(params, params.sdk, params.log);
  const { threadId, replyTo } = params;
  if (!card.presentation) {
    const text = params.text ?? "";
    const sent: string[] = [];
    for (const [k, mediaUrl] of params.mediaUrls.entries()) {
      sent.push(await sendConversationMedia({ threadId, text: k === 0 ? text : "", mediaUrl, maxBytes: params.maxBytes, access: params.access, replyTo }));
    }
    if (!params.mediaUrls.length) {
      // `planOutboundTextMessageUnits`, with the channel's chunker and limit as the outbound adapter declares them.
      const limit = resolveTextChunkLimit(params.cfg, CHANNEL_ID, params.accountId, { fallbackLimit: DEFAULT_CHUNK_LIMIT });
      const blocks = resolveChunkMode(params.cfg, CHANNEL_ID, params.accountId) === "newline" ? chunkMarkdownTextWithMode(text, limit, "newline") : [text];
      if (!blocks.length && text) blocks.push(text);
      for (const block of blocks) {
        const chunks = chunkMarkdownText(block, limit);
        for (const chunk of chunks.length || !block ? chunks : [block]) sent.push(sendConversationText({ threadId, text: chunk, replyTo }));
      }
    }
    return sent[0] ?? "";
  }
  const { attachments, failures } = await stageOutbound(params.mediaUrls, params.maxBytes, params.access);
  const text = [card.text, ...failures].filter((line) => line.trim()).join("\n\n");
  const replies = replyEvents(params.cfg, convId, text, params.accountId, undefined, attachments, replyTo, card.presentation);
  broadcast(replies);
  const turn = runningTurns.get(convId);
  const sessionId = turn && liveSessionId(turn.agentId, turn.sessionKey);
  const carrier = replies.at(-1);
  if (turn && sessionId && carrier?.kind === "reply") {
    // Core mirrors the sent text into the transcript; history finds that message by its text and puts the card on it.
    void storeCard(convId, turnCardKey(sessionId, turn.messageId, carrier.data.messageId), {
      presentation: card.presentation, reply: replyChunks(replies),
    }).catch((error: unknown) => params.log?.warn(`yorozu: a card was not stored (${errorTag(error)}); history will not show it`));
  } else params.log?.warn(NOT_KEPT);
  const first = replies[0];
  return first?.kind === "reply" ? first.data.messageId : "";
}

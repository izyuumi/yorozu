/**
 * The message tool's target and thread on this channel, without OpenClaw runtime imports.
 *
 * The channel has one peer, the owner, and a conversation is the thread id of a send. Core takes a
 * message-tool send with no target through this plugin only on a host that sets
 * `channels.yorozu`; without it such a send from a Yorozu turn goes to core's private source-reply
 * sink. Explicit `owner` resolves on every host: without a thread the adapter throws
 * `yorozu: no conversation reference found; …` (permanent in OpenClaw's delivery queue, so not retried);
 * an explicit UUID threadId is delivered.
 */
import { isId } from "./envelope.js";

const CHANNEL_ID = "yorozu";
export const PEER = "owner";

/** `owner`, in any case, with or without the channel prefix: the only target id there is. */
export const looksLikeOwner = (raw: string): boolean => /^(?:yorozu:)?owner$/i.test(raw.trim());

/** Core's `isConfiguredChannel`: `channels.yorozu` is present and not disabled. */
export function channelConfigured(cfg: { channels?: unknown }): boolean {
  const section = (cfg.channels as Record<string, unknown> | null | undefined)?.[CHANNEL_ID];
  return typeof section === "object" && section !== null && !Array.isArray(section) && (section as { enabled?: unknown }).enabled !== false;
}

/** The part of core's `ChannelThreadingToolContext` that names the turn a message-tool call runs in. */
export type TurnContext = {
  currentChannelProvider?: string;
  currentChannelId?: string;
  currentMessagingTarget?: string;
  currentThreadTs?: string;
};

/**
 * The conversation a message-tool send with no `threadId` of its own belongs to: the one of the Yorozu
 * turn that makes the call. Without a known conversation (another channel's turn, a cron run without
 * a conversation, no turn at all), the adapter rejects the send for missing threadId.
 *
 * The channels.yorozu gate exists because core reuses resolveAutoThreadId when matching a finished
 * send against the turn's reply route, omitting the provider in that hook's toolContext.
 * Probe (a): an implicit-thread send with a channel hint matches only after this change on configured
 * hosts; without channels.yorozu it stays unmatched. Explicit own/other threads match/reject in both.
 */
export function currentConversation(params: { cfg: { channels?: unknown }; toolContext?: TurnContext }): string | undefined {
  const { cfg, toolContext } = params;
  if (!toolContext || !channelConfigured(cfg)) return undefined;
  const provider = toolContext.currentChannelProvider?.trim().toLowerCase();
  if (provider && provider !== CHANNEL_ID) return undefined;
  if (!looksLikeOwner(toolContext.currentMessagingTarget ?? toolContext.currentChannelId ?? "")) return undefined;
  const convId = toolContext.currentThreadTs?.trim().toLowerCase();
  return isId(convId) ? convId : undefined;
}

/**
 * The message tool's target and thread on this channel. This file imports nothing, so the tests can load it.
 *
 * The channel has one peer, the owner, and a conversation is the thread id of a send. Core takes a
 * message-tool send through this plugin only on a host that sets `channels.yorozu`; without it a
 * send from a Yorozu turn goes to core's private source-reply sink and none of this runs.
 */
const CHANNEL_ID = "yorozu";
export const PEER = "owner";
/** A conversation id, as `isId` in envelope.ts has it. */
const ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

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
 * turn that makes the call, and nothing otherwise (another channel's turn, a cron run without a
 * conversation, no turn at all), so such a send fails as before rather than land somewhere else.
 *
 * Nothing on a host without `channels.yorozu`: there core also asks this to match a send against the
 * turn's own reply route, and the answer has to stay what it was.
 */
export function currentConversation(params: { cfg: { channels?: unknown }; toolContext?: TurnContext }): string | undefined {
  const { cfg, toolContext } = params;
  if (!toolContext || !channelConfigured(cfg)) return undefined;
  const provider = toolContext.currentChannelProvider?.trim().toLowerCase();
  if (provider && provider !== CHANNEL_ID) return undefined;
  if (!looksLikeOwner(toolContext.currentMessagingTarget ?? toolContext.currentChannelId ?? "")) return undefined;
  const convId = toolContext.currentThreadTs?.trim().toLowerCase();
  return convId && ID.test(convId) ? convId : undefined;
}

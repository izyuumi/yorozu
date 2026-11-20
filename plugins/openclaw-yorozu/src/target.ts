import { isId } from "./envelope.js";

const CHANNEL_ID = "yorozu";
export const PEER = "owner";

export const looksLikeOwner = (raw: string): boolean => /^(?:yorozu:)?owner$/i.test(raw.trim());

export function channelConfigured(cfg: { channels?: unknown }): boolean {
  const section = (cfg.channels as Record<string, unknown> | null | undefined)?.[CHANNEL_ID];
  return typeof section === "object" && section !== null && !Array.isArray(section) && (section as { enabled?: unknown }).enabled !== false;
}

export type TurnContext = {
  currentChannelProvider?: string;
  currentChannelId?: string;
  currentMessagingTarget?: string;
  currentThreadTs?: string;
};

export function currentConversation(params: { cfg: { channels?: unknown }; toolContext?: TurnContext }): string | undefined {
  const { cfg, toolContext } = params;
  if (!toolContext || !channelConfigured(cfg)) return undefined;
  const provider = toolContext.currentChannelProvider?.trim().toLowerCase();
  if (provider && provider !== CHANNEL_ID) return undefined;
  if (!looksLikeOwner(toolContext.currentMessagingTarget ?? toolContext.currentChannelId ?? "")) return undefined;
  const convId = toolContext.currentThreadTs?.trim().toLowerCase();
  return isId(convId) ? convId : undefined;
}

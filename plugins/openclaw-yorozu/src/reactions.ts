import { jsonResult, readReactionParams, resolveReactionMessageId } from "openclaw/plugin-sdk/channel-actions";
import type { ChannelMessageActionAdapter } from "openclaw/plugin-sdk/channel-contract";
import { parseThreadSessionSuffix } from "openclaw/plugin-sdk/routing";
import { enqueueRoutedSystemEvent } from "openclaw/plugin-sdk/system-event-runtime";
import { isId, type Reaction, type Reactions } from "./envelope.js";
import { broadcast } from "./relay.js";
import { yorozuRuntime } from "./runtime.js";

const store = () =>
  yorozuRuntime.getRuntime().state.openKeyedStore<Reactions>({
    namespace: "reactions",
    maxEntries: 10_000,
    overflowPolicy: "evict-oldest",
  });
const known = new Map<string, Reactions>();

export async function loadReactions(): Promise<void> {
  for (const { key, value } of await store().entries()) known.set(key, value);
}

export const reactionsOf = (messageId: string): Reactions | undefined => known.get(messageId);

// One slot per person: adding replaces, removing clears the slot when it holds that emoji.
// Sends the change to every device and returns it, or nothing when nothing changed.
function apply(reaction: Reaction & { by: "user" | "agent" }): Reaction | undefined {
  const { messageId, emoji, by } = reaction;
  const next = { ...known.get(messageId) };
  if (reaction.remove ? next[by] !== emoji : next[by] === emoji) return undefined;
  if (reaction.remove) delete next[by];
  else next[by] = emoji;
  if (next.user || next.agent) {
    known.set(messageId, next);
    void store().register(messageId, next).catch(() => {});
  } else {
    known.delete(messageId);
    void store().delete(messageId).catch(() => {});
  }
  const sent: Reaction = { convId: reaction.convId, messageId, emoji, by, ...(reaction.remove ? { remove: true as const } : {}) };
  broadcast([{ kind: "reaction", data: sent }]);
  return sent;
}

// The user's reaction reaches the agent as a system line at the start of its next turn; it never wakes the agent.
export function userReaction(reaction: Reaction, route: { agentId: string; sessionKey: string }): void {
  const sent = apply({ ...reaction, by: "user" });
  if (!sent) return;
  enqueueRoutedSystemEvent(`Yorozu reaction ${sent.remove ? "removed" : "added"}: ${sent.emoji} on msg ${sent.messageId}`, route, {
    contextKey: `yorozu:reaction:${sent.messageId}`,
    replace: true,
  });
}

export const reactionActions: ChannelMessageActionAdapter = {
  describeMessageTool: () => ({ actions: ["react"] }),
  supportsAction: ({ action }) => action === "react",
  handleAction: async ({ action, params, sessionKey, toolContext }) => {
    if (action !== "react") throw new Error(`Action ${action} is not supported for yorozu.`);
    const messageId = String(resolveReactionMessageId({ args: params, toolContext }) ?? "").trim().toLowerCase();
    const thread = params.threadId ?? toolContext?.currentThreadTs ?? parseThreadSessionSuffix(sessionKey).threadId;
    const convId = String(thread ?? "").trim().toLowerCase();
    if (!isId(messageId) || !isId(convId)) throw new Error("react needs a Yorozu messageId in a Yorozu conversation");
    const { emoji, remove, isEmpty } = readReactionParams(params, { removeErrorMessage: "Emoji is required to remove a Yorozu reaction." });
    if (emoji.length > 32) throw new Error("emoji must be at most 32 characters");
    const current = known.get(messageId)?.agent;
    if (remove || isEmpty) {
      if (current) apply({ convId, messageId, emoji: current, remove: true, by: "agent" });
      return jsonResult({ ok: true, removed: current ?? null });
    }
    apply({ convId, messageId, emoji, by: "agent" });
    return jsonResult({ ok: true, added: emoji });
  },
};

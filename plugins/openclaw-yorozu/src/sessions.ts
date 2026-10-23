/**
 * Titles, rename, archive and delete (#428), on the conversation's thread session entry.
 *
 * - **Title**: after a conversation's first turn the plugin asks OpenClaw's own generator
 *   (`generateConversationLabel`, the agent's `utilityModel`, then its primary model) for a title of the first user
 *   message and writes it as the entry's `displayName`. Core titles only `dashboard:`/`ios-`/`node-` sessions itself
 *   (docs/openclaw-channel.md, Q6).
 * - **Rename** writes the entry's `label`, which wins over `displayName` as in core's `deriveSessionTitle`; an empty
 *   rename clears it, so the generated title shows again.
 * - **Archive** sets `archivedAt` (and `archiveReason: "manual"`, as `sessions.patch` does) and clears `pinnedAt`;
 *   unarchive clears both.
 * - **Pin** sets `pinnedAt` (kept if already pinned), unpin clears it, as `sessions.patch` does; an archived
 *   conversation cannot be pinned.
 * - **Delete** archives first, then deletes the entry, its transcript moved to the store's archive as
 *   `sessions.delete` does by default, and drops the conversation's read cursor.
 *
 * Every change, whoever made it (a device, the Control UI, the agent), reaches every device as `conv_update`: the
 * plugin watches session-entry commits (`subscribeSessionChanges`) and sends a conversation's state when it differs
 * from what it last sent.
 */
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import type { OpenClawConfig } from "openclaw/plugin-sdk/channel-core";
import { generateConversationLabel } from "openclaw/plugin-sdk/reply-runtime";
import {
  deleteSessionEntry,
  getSessionEntry,
  loadTranscriptEventsSync,
  patchSessionEntry,
} from "openclaw/plugin-sdk/session-store-runtime";
import { isId, type ConvPatch, type ConvUpdate, type Event } from "./envelope.js";
import { forgetCursor } from "./reads.js";
import { broadcast } from "./relay.js";
import { yorozuRuntime } from "./runtime.js";

const prefix = (agent: string) => `agent:${agent}:yorozu:direct:owner:thread:`;
export const TITLE_MAX = 60;
const TITLE_SOURCE_MAX = 1000;
const TITLE_TIMEOUT_MS = 20_000;
/** Core's dashboard title prompt (`DASHBOARD_SESSION_TITLE_PROMPT`), so Yorozu titles read like the Control UI's. */
const TITLE_PROMPT =
  "Generate a concise session title (3-6 words, max 60 characters) from the supplied source message. Use the same language as the message, in sentence case: capitalize only the first word and words that language always capitalizes. No emoji. Return only the title.";

type Entry = NonNullable<ReturnType<typeof getSessionEntry>>;

/** A conversation's title: the manual `label`, else the generated `displayName`. */
export const titleOf = (entry: Pick<Entry, "label" | "displayName">): string | undefined =>
  entry.label?.trim() || entry.displayName?.trim() || undefined;

/** The channel's agent while the account runs, for Gateway methods that name a conversation. */
export const channelAgent = (): string | undefined => watchedAgent;

const stateOf = (convId: string, entry: Entry | undefined): ConvUpdate => {
  if (!entry) return { convId, deleted: true };
  const title = titleOf(entry);
  return {
    convId,
    ...(title ? { title } : {}),
    ...(entry.archivedAt !== undefined ? { archived: true } : {}),
    ...(entry.pinnedAt !== undefined ? { pinnedAt: entry.pinnedAt } : {}),
  };
};

/** What each conversation's devices were last told, so a commit that changed nothing they show sends nothing. */
const sent = new Map<string, string>();
const SENT_MAX = 4000;

/** Sends the conversation's state to every device if it changed since the last time. */
export function announce(agent: string, convId: string): void {
  const update = stateOf(convId, getSessionEntry({ agentId: agent, sessionKey: prefix(agent) + convId }));
  const key = JSON.stringify(update);
  if (sent.get(convId) === key) return;
  sent.delete(convId);
  sent.set(convId, key);
  for (const old of sent.keys()) if (sent.size > SENT_MAX) sent.delete(old);
  broadcast([{ kind: "conv_update", data: update }]);
}

/** The channel's agent, while the account runs: whose conversations `conversationTitle` reads. */
let watchedAgent: string | undefined;

/** The conversation's title now, for push previews (src/push.ts); undefined before it has one. */
export function conversationTitle(convId: string): string | undefined {
  if (!watchedAgent) return undefined;
  try {
    const entry = getSessionEntry({ agentId: watchedAgent, sessionKey: prefix(watchedAgent) + convId });
    return entry ? titleOf(entry) : undefined;
  } catch {
    return undefined;
  }
}

/** Watches the agent's Yorozu thread sessions until `signal` aborts; any change of a title or archive goes out. */
export function watchSessions(agent: string, signal: AbortSignal, log?: ChannelGatewayContext["log"]): void {
  watchedAgent = agent;
  const start = prefix(agent);
  let unsubscribe: (() => void) | undefined;
  try {
    unsubscribe = yorozuRuntime.getRuntime().gateway.subscribeSessionChanges(({ agentId, sessionKey }) => {
      if (agentId !== agent || !sessionKey.startsWith(start)) return;
      const convId = sessionKey.slice(start.length);
      if (!isId(convId)) return;
      try {
        announce(agent, convId);
      } catch (error) {
        log?.warn(`yorozu: session change not sent: ${String(error)}`);
      }
    });
  } catch (error) {
    // Only this plugin's own writes are then announced.
    log?.warn(`yorozu: session changes unavailable: ${String(error)}`);
  }
  signal.addEventListener("abort", () => {
    unsubscribe?.();
    if (watchedAgent === agent) watchedAgent = undefined;
  }, { once: true });
}

/** A device's `conv_patch`: answered by the `conv_update` every device gets, or `error` to that device. */
export async function applyPatch(agent: string, patch: ConvPatch, log?: ChannelGatewayContext["log"]): Promise<Event | undefined> {
  const { convId } = patch;
  const sessionKey = prefix(agent) + convId;
  try {
    const entry = getSessionEntry({ agentId: agent, sessionKey });
    if (!entry) {
      // Already gone (deleted on another device): say so, so this one drops it too.
      sent.delete(convId);
      announce(agent, convId);
      return undefined;
    }
    if (patch.deleted) {
      if (entry.archivedAt === undefined) await archive(agent, sessionKey, true);
      // Gateway rule: a session is deleted only once archived. `archiveTranscript` as `sessions.delete` does.
      await deleteSessionEntry({ agentId: agent, sessionKey, archiveTranscript: true });
      await forgetCursor(convId);
    } else {
      if (patch.title !== undefined) {
        const label = clip(patch.title.trim());
        await patchSessionEntry({ agentId: agent, sessionKey, preserveActivity: true, update: () => ({ label: label || undefined }) });
      }
      if (patch.archived !== undefined) await archive(agent, sessionKey, patch.archived);
      if (patch.pinned !== undefined) {
        if (patch.pinned && getSessionEntry({ agentId: agent, sessionKey })?.archivedAt !== undefined) {
          return { kind: "error", data: { code: "bad_request", message: "cannot pin an archived conversation", convId } };
        }
        await pin(agent, sessionKey, patch.pinned);
      }
    }
    announce(agent, convId);
    return undefined;
  } catch (error) {
    log?.warn(`yorozu: conv_patch failed: ${String(error)}`);
    return { kind: "error", data: { code: "internal", message: String(error).slice(0, 500), convId } };
  }
}

async function archive(agent: string, sessionKey: string, archived: boolean): Promise<void> {
  await patchSessionEntry({
    agentId: agent,
    sessionKey,
    preserveActivity: true,
    update: (entry) =>
      archived
        ? entry.archivedAt === undefined ? { archivedAt: Date.now(), archiveReason: "manual", pinnedAt: undefined } : null
        : entry.archivedAt === undefined ? null : { archivedAt: undefined, archiveReason: undefined, archivedBy: undefined },
  });
}

async function pin(agent: string, sessionKey: string, pinned: boolean): Promise<void> {
  await patchSessionEntry({
    agentId: agent,
    sessionKey,
    preserveActivity: true,
    update: (entry) =>
      pinned
        ? entry.pinnedAt === undefined ? { pinnedAt: Date.now() } : null
        : entry.pinnedAt === undefined ? null : { pinnedAt: undefined },
  });
}

/** Conversations whose title is being made, so two quick turns ask once. */
const titling = new Set<string>();

/**
 * After a turn: a conversation with neither `label` nor `displayName` gets a generated title of its first user
 * message that is not a slash command. Never throws; a failed attempt is tried again after the next turn.
 */
export async function maybeTitle(cfg: OpenClawConfig, agent: string, convId: string, log?: ChannelGatewayContext["log"]): Promise<void> {
  const sessionKey = prefix(agent) + convId;
  if (titling.has(sessionKey)) return;
  titling.add(sessionKey);
  try {
    const entry = getSessionEntry({ agentId: agent, sessionKey });
    if (!entry?.sessionId || titleOf(entry)) return;
    const source = firstUserText(agent, sessionKey, entry.sessionId);
    if (!source) return;
    const raw = await generateConversationLabel({
      userMessage: source,
      prompt: TITLE_PROMPT,
      cfg,
      agentId: agent,
      maxLength: TITLE_MAX * 2,
      timeoutMs: TITLE_TIMEOUT_MS,
    });
    const title = raw ? normalizeTitle(raw) : null;
    if (!title) return;
    // A rename that landed meanwhile wins.
    await patchSessionEntry({
      agentId: agent,
      sessionKey,
      preserveActivity: true,
      update: (current) => (titleOf(current) ? null : { displayName: title }),
    });
    announce(agent, convId);
  } catch (error) {
    log?.warn(`yorozu: title failed: ${String(error)}`);
  } finally {
    titling.delete(sessionKey);
  }
}

/** At most `TITLE_MAX` characters, never half a surrogate pair. */
const clip = (text: string) => [...text].slice(0, TITLE_MAX).join("");

type Fields = Record<string, unknown>;
const obj = (v: unknown): Fields | undefined => (typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Fields) : undefined);
const textOf = (content: unknown): string =>
  typeof content === "string"
    ? content
    : Array.isArray(content)
      ? content.map((part) => (obj(part)?.type === "text" && typeof obj(part)?.text === "string" ? (obj(part)!.text as string) : "")).join("\n")
      : "";

function firstUserText(agent: string, sessionKey: string, sessionId: string): string | undefined {
  for (const raw of loadTranscriptEventsSync({ agentId: agent, sessionId, sessionKey })) {
    const message = obj(obj(raw)?.message);
    if (obj(raw)?.type !== "message" || message?.role !== "user") continue;
    const text = textOf(message.content).trim();
    if (text && !text.startsWith("/")) return text.slice(0, TITLE_SOURCE_MAX);
  }
  return undefined;
}

/** As core's `normalizeDashboardSessionTitle`: the first line, without a `Title:` lead or quotes. */
function normalizeTitle(raw: string): string | null {
  const line = raw.replace(/\r/g, "").split("\n").map((l) => l.trim()).find((l) => l && !l.startsWith("```"));
  const title = line?.replace(/^\s*(?:title\s*:\s*)?/i, "").replace(/^["'`]+|["'`]+$/g, "").replace(/\s+/g, " ").trim();
  return title ? clip(title) : null;
}

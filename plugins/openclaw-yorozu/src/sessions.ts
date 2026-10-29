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

const bases = new Map<string, string>();
/** Threads hang off the owner's routed session key, which bindings and identity links can change. */
export function setThreadBase(agent: string, baseSessionKey: string): void {
  bases.set(agent, baseSessionKey);
}
export const prefix = (agent: string) => `${bases.get(agent) ?? `agent:${agent}:yorozu:direct:owner`}:thread:`;
export const TITLE_MAX = 60;
const TITLE_SOURCE_MAX = 1000;
const TITLE_TIMEOUT_MS = 20_000;
const TITLE_PROMPT =
  "Generate a concise session title (3-6 words, max 60 characters) from the supplied source message. Use the same language as the message, in sentence case: capitalize only the first word and words that language always capitalizes. No emoji. Return only the title.";

type Entry = NonNullable<ReturnType<typeof getSessionEntry>>;

export const titleOf = (entry: Pick<Entry, "label" | "displayName">): string | undefined =>
  entry.label?.trim() || entry.displayName?.trim() || undefined;

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

const sent = new Map<string, string>();
const SENT_MAX = 4000;

export function announce(agent: string, convId: string): void {
  const update = stateOf(convId, getSessionEntry({ agentId: agent, sessionKey: prefix(agent) + convId }));
  const key = JSON.stringify(update);
  if (sent.get(convId) === key) return;
  sent.delete(convId);
  sent.set(convId, key);
  for (const old of sent.keys()) if (sent.size > SENT_MAX) sent.delete(old);
  broadcast([{ kind: "conv_update", data: update }]);
}

let watchedAgent: string | undefined;

export function conversationTitle(convId: string): string | undefined {
  if (!watchedAgent) return undefined;
  try {
    const entry = getSessionEntry({ agentId: watchedAgent, sessionKey: prefix(watchedAgent) + convId });
    return entry ? titleOf(entry) : undefined;
  } catch {
    return undefined;
  }
}

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
    log?.warn(`yorozu: session changes unavailable: ${String(error)}`);
  }
  signal.addEventListener("abort", () => {
    unsubscribe?.();
    if (watchedAgent === agent) watchedAgent = undefined;
  }, { once: true });
}

export async function applyPatch(agent: string, patch: ConvPatch, log?: ChannelGatewayContext["log"]): Promise<Event | undefined> {
  const { convId } = patch;
  const sessionKey = prefix(agent) + convId;
  try {
    const entry = getSessionEntry({ agentId: agent, sessionKey });
    if (!entry) {
      sent.delete(convId);
      announce(agent, convId);
      return undefined;
    }
    if (patch.deleted) {
      if (entry.archivedAt === undefined) await archive(agent, sessionKey, true);
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

const titling = new Set<string>();

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

function normalizeTitle(raw: string): string | null {
  const line = raw.replace(/\r/g, "").split("\n").map((l) => l.trim()).find((l) => l && !l.startsWith("```"));
  const title = line?.replace(/^\s*(?:title\s*:\s*)?/i, "").replace(/^["'`]+|["'`]+$/g, "").replace(/\s+/g, " ").trim();
  return title ? clip(title) : null;
}

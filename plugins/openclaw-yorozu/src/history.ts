/**
 * History from the Gateway transcript (#427): `conv_list` lists the owner's Yorozu thread sessions of the
 * configured agent, `history` pages one conversation's transcript. The transcript is the source of truth (#415);
 * clients cache what they fetched and ask again on open and reconnect.
 *
 * A session's transcript becomes a list of items, each with the `seq` of the transcript event it starts at:
 * user messages (their id is the client's `messageId`, kept in the transport metadata), assistant text chunked as
 * live replies are (so chunks match the `reply`s a device already holds), one `tools` row per run, and `/new`
 * reset markers. Cron deliveries are mirrored into the transcript as assistant messages and come out as `agent`.
 */
import { createHash } from "node:crypto";
import type { ChannelGatewayContext } from "openclaw/plugin-sdk/channel-contract";
import type { OpenClawConfig } from "openclaw/plugin-sdk/channel-core";
import { chunkMarkdownText, resolveTextChunkLimit } from "openclaw/plugin-sdk/reply-runtime";
import {
  getSessionEntry,
  listSessionEntries,
  loadTranscriptEventsSync,
} from "openclaw/plugin-sdk/session-store-runtime";
import { messageTime, revOf } from "./activity.js";
import { attachmentAt, attachmentsOf } from "./attachments.js";
import { DEFAULT_CHUNK_LIMIT } from "./conversation.js";
import {
  isId,
  type Attachment,
  type ConvList,
  type ConvSummary,
  type Event,
  type History,
  type HistoryItem,
  type HistoryRequest,
  type HistoryTool,
  type ToolStatus,
} from "./envelope.js";
import { titleOf } from "./sessions.js";

const CHANNEL_ID = "yorozu";
/** Items per page, and the page's JSON budget: one box, far below the relay's 1 MiB, paced one page at a time. */
const PAGE_ITEMS = 60;
const PAGE_BYTES = 192 * 1024;
/** One item's text beyond this is cut (a pasted user message can reach 700 KiB); the transcript keeps it whole. */
const ITEM_CHARS = 60_000;
const LIST_MAX = 2000;
/** Built item lists, by session key, rebuilt when the transcript grows. */
const CACHE_MAX = 8;
const cache = new Map<string, { sessionId: string; rev: number; items: HistoryItem[] }>();

const prefix = (agent: string) => `agent:${agent}:yorozu:direct:owner:thread:`;

/** A device's `conv_list` or `history` request; a store failure goes back as `error internal`. */
export function answerRequest(
  cfg: OpenClawConfig,
  agent: string,
  request: Event,
  log?: ChannelGatewayContext["log"],
): Event | undefined {
  try {
    if (request.kind === "conv_list") return { kind: "conv_list", data: listConversations(agent) };
    if (request.kind === "history") return { kind: "history", data: historyPage(cfg, agent, request.data) };
  } catch (error) {
    log?.warn(`yorozu: ${request.kind} failed: ${String(error)}`);
    const convId = request.kind === "history" ? request.data.convId : undefined;
    return { kind: "error", data: { code: "internal", message: String(error).slice(0, 500), ...(convId ? { convId } : {}) } };
  }
  return undefined;
}

export function listConversations(agent: string): ConvList {
  const start = prefix(agent);
  const conversations: ConvSummary[] = [];
  for (const { sessionKey, entry } of listSessionEntries({ agentId: agent, readOnly: true })) {
    const convId = sessionKey.startsWith(start) ? sessionKey.slice(start.length) : "";
    if (!isId(convId) || !entry.sessionId) continue;
    const title = titleOf(entry);
    const rev = revOf(agent, sessionKey, entry.sessionId);
    const sessionId = entry.sessionId;
    conversations.push({
      convId,
      // The last message's time, not the entry's: a rename or pin must not reorder the list (src/activity.ts).
      updatedAt: messageTime(convId, rev, () => lastMessageTime(agent, sessionKey, sessionId), entry.updatedAt ?? 0),
      rev,
      ...(title ? { title } : {}),
      ...(entry.archivedAt !== undefined ? { archived: true as const } : {}),
      ...(entry.pinnedAt !== undefined ? { pinnedAt: entry.pinnedAt } : {}),
    });
  }
  conversations.sort((a, b) => b.updatedAt - a.updatedAt);
  return { conversations: conversations.slice(0, LIST_MAX) };
}

/**
 * One page: with `before`, the newest items older than it; with `after`, the oldest items newer than it; with
 * neither, the newest. Items come oldest first; `more` says whether another page lies further that way.
 */
export function historyPage(cfg: OpenClawConfig, agent: string, request: HistoryRequest): History {
  const { convId, before, after } = request;
  const sessionKey = prefix(agent) + convId;
  const entry = getSessionEntry({ agentId: agent, sessionKey });
  const empty: History = { convId, items: [], more: false, rev: 0, ...(before !== undefined ? { before } : {}), ...(after !== undefined ? { after } : {}) };
  if (!entry?.sessionId) return empty;
  const rev = revOf(agent, sessionKey, entry.sessionId);
  let built = cache.get(sessionKey);
  if (!built || built.sessionId !== entry.sessionId || built.rev !== rev) {
    const events = loadTranscriptEventsSync({ agentId: agent, sessionId: entry.sessionId, sessionKey });
    built = { sessionId: entry.sessionId, rev, items: buildItems(cfg, entry.sessionId, events) };
    cache.delete(sessionKey);
    cache.set(sessionKey, built);
    for (const key of cache.keys()) if (cache.size > CACHE_MAX) cache.delete(key);
  }
  // Items of one transcript event share its seq, so a page never splits them: the cursor is a seq.
  const groups: HistoryItem[][] = [];
  for (const item of built.items) {
    const last = groups.at(-1);
    if (last && last[0]!.seq === item.seq) last.push(item);
    else groups.push([item]);
  }
  const picked: HistoryItem[][] = [];
  let bytes = 0;
  let more = false;
  const take = (group: HistoryItem[]) => {
    const size = group.reduce((n, item) => n + Buffer.byteLength(JSON.stringify(item)), 0);
    const count = picked.reduce((n, g) => n + g.length, 0);
    if (picked.length && (count + group.length > PAGE_ITEMS || bytes + size > PAGE_BYTES)) return false;
    bytes += size;
    return true;
  };
  if (after !== undefined) {
    for (const group of groups) {
      if (group[0]!.seq <= after) continue;
      if (!take(group)) { more = true; break; }
      picked.push(group);
    }
  } else {
    for (let i = groups.length - 1; i >= 0; i--) {
      const group = groups[i]!;
      if (before !== undefined && group[0]!.seq >= before) continue;
      if (!take(group)) { more = true; break; }
      picked.unshift(group);
    }
  }
  const page = picked.flat();
  return { ...empty, items: page, more, rev };
}

/** A reply chunk's id: the transcript message's own for the first chunk, derived from it for the others. */
const chunkId = (sessionId: string, eventId: string, k: number) =>
  k === 0 && isId(eventId) ? eventId : derivedId(sessionId, eventId, `${k}`);

/**
 * The ids and time a live reply of the turn for `messageId` gets, so a device that saw it live and later fetches the
 * page holds one item, not two, at one `ts` (read cursors compare `ts` across devices): the first assistant
 * message with text after that user message which `used` does not hold yet (core writes it before it delivers).
 * Undefined when it is not found; the reply then keeps random ids and the send time, and the client matches it by
 * text.
 */
export function liveReplyIds(
  agent: string,
  sessionKey: string,
  messageId: string,
  used: Set<string>,
): { id: (chunk: number) => string; ts: number } | undefined {
  try {
    const sessionId = getSessionEntry({ agentId: agent, sessionKey })?.sessionId;
    if (!sessionId) return undefined;
    const events = loadTranscriptEventsSync({ agentId: agent, sessionId, sessionKey });
    let inTurn = false;
    for (const raw of events) {
      const event = obj(raw);
      const message = obj(event?.message);
      if (event?.type !== "message" || !message || typeof event.id !== "string") continue;
      if (message.role === "user") inTurn = obj(obj(message.__openclaw)?.transport)?.messageId === messageId;
      else if (inTurn && message.role === "assistant" && textOf(message.content).trim() && !used.has(event.id)) {
        used.add(event.id);
        const eventId = event.id;
        return { id: (k) => chunkId(sessionId, eventId, k), ts: timeOf(event, message) || Date.now() };
      }
    }
  } catch {
    // The store is busy or gone: random ids.
  }
  return undefined;
}


type Fields = Record<string, unknown>;
const obj = (v: unknown): Fields | undefined => (typeof v === "object" && v !== null && !Array.isArray(v) ? (v as Fields) : undefined);

/** A stable lowercase UUID for an item that has no id of its own. */
function derivedId(...parts: string[]): string {
  const h = createHash("sha256").update(parts.join("\u0000")).digest("hex");
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-4${h.slice(13, 16)}-${((parseInt(h[16]!, 16) & 3) | 8).toString(16)}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

const textOf = (content: unknown): string =>
  typeof content === "string"
    ? content
    : Array.isArray(content)
      ? content.map((part) => (obj(part)?.type === "text" && typeof obj(part)?.text === "string" ? (obj(part)!.text as string) : "")).filter(Boolean).join("\n\n")
      : "";

/** The files OpenClaw appended to a user message as `<file name=…>…</file>` (a document's extracted text). */
const FILE_BLOCK = /\n*<file name="[^"]*"[^>]*>[\s\S]*?<\/file>/g;
/** A `MEDIA:` directive takes its whole line (core's parser); the live `reply` carried the text without it. */
const MEDIA_LINE = /^[ \t]*MEDIA:[ \t]*`?([^\n`]+)`?[ \t]*$/gm;

/** A user message's files (`__openclaw.media`, by media URL) that this plugin stored, as the live `message` named them. */
function userFiles(message: Fields): Attachment[] {
  const media = obj(message.__openclaw)?.media;
  if (!Array.isArray(media)) return [];
  return media.flatMap((m) => {
    const url = obj(m)?.url;
    const found = typeof url === "string" ? attachmentAt(url) : undefined;
    return found ? [found] : [];
  });
}

/** An assistant text without its `MEDIA:` lines; the files went out with the reply `replyId` (`attachmentsOf`). */
const withoutMedia = (text: string): string => text.replace(MEDIA_LINE, "").replace(/\n{3,}/g, "\n\n").trim();

const cut = (text: string) => (text.length > ITEM_CHARS ? `${text.slice(0, ITEM_CHARS)}…` : text);

/** The newest user or agent message's own time in the transcript; undefined when it has none or cannot be read. */
function lastMessageTime(agent: string, sessionKey: string, sessionId: string): number | undefined {
  try {
    const events = loadTranscriptEventsSync({ agentId: agent, sessionId, sessionKey });
    for (let i = events.length - 1; i >= 0; i--) {
      const event = obj(events[i]);
      const message = obj(event?.message);
      if (event?.type !== "message" || !message || (message.role !== "user" && message.role !== "assistant")) continue;
      if (!textOf(message.content).trim()) continue;
      const at = timeOf(event, message);
      if (at > 0) return at;
    }
  } catch {
    // The store is busy or gone: the entry's time for now, read again on the next list.
  }
  return undefined;
}

function timeOf(event: Fields, message?: Fields): number {
  if (Number.isSafeInteger(message?.timestamp)) return message!.timestamp as number;
  const parsed = typeof event.timestamp === "string" ? Date.parse(event.timestamp) : NaN;
  return Number.isFinite(parsed) ? parsed : 0;
}

function buildItems(cfg: OpenClawConfig, sessionId: string, events: unknown[]): HistoryItem[] {
  const limit = resolveTextChunkLimit(cfg, CHANNEL_ID, undefined, { fallbackLimit: DEFAULT_CHUNK_LIMIT });
  const items: HistoryItem[] = [];
  /** The run's tools row, keyed by the user message that started it; reset by every user message and reset. */
  let tools: Extract<HistoryItem, { kind: "tools" }> | undefined;
  let lastUser: string | undefined;
  const pending = new Map<string, { status: ToolStatus }>();
  const closeRun = () => {
    for (const call of pending.values()) if (call.status === "running") call.status = "failed";
    pending.clear();
    tools = undefined;
  };
  events.forEach((raw, index) => {
    const event = obj(raw);
    if (!event) return;
    const seq = Number.isSafeInteger(event.seq) ? (event.seq as number) : index;
    const eventId = typeof event.id === "string" ? event.id : `${seq}`;
    if (event.type === "reset") {
      closeRun();
      lastUser = undefined;
      items.push({ kind: "reset", id: derivedId(sessionId, eventId), seq, ts: timeOf(event) });
      return;
    }
    const message = obj(event.message);
    if (event.type !== "message" || !message) return;
    const ts = timeOf(event, message);
    if (message.role === "user") {
      closeRun();
      // OpenClaw's own user-role turns (a subagent's results, another session's message, a restart recovery) carry a
      // provenance other than `external_user`: the agent reads them, but they are not the owner's words to show.
      const provenance = obj(message.provenance)?.kind;
      if (typeof provenance === "string" && provenance !== "external_user") {
        lastUser = undefined;
        return;
      }
      const files = userFiles(message);
      const media = obj(message.__openclaw)?.media;
      const withMedia = Array.isArray(media) && media.length > 0;
      const text = withMedia ? textOf(message.content).replace(FILE_BLOCK, "").trim() : textOf(message.content);
      const sent = obj(obj(obj(message.__openclaw)?.transport))?.messageId;
      const id = isId(sent) ? sent : isId(eventId) ? eventId : derivedId(sessionId, eventId);
      lastUser = id;
      if (text.trim() || files.length) {
        items.push({ kind: "user", id, seq, ts, text: cut(text), ...(files.length ? { attachments: files } : {}) });
      }
    } else if (message.role === "assistant") {
      const content = Array.isArray(message.content) ? message.content : [];
      for (const part of content.map(obj)) {
        if (part?.type !== "toolCall" || typeof part.id !== "string" || typeof part.name !== "string") continue;
        if (!tools) {
          tools = { kind: "tools", id: lastUser ?? derivedId(sessionId, eventId, "tools"), seq, ts, tools: [] };
          items.push(tools);
        }
        const call: HistoryTool = { callId: part.id.slice(0, 128), name: part.name.slice(0, 128), status: "running" };
        tools.tools.push(call);
        pending.set(part.id, call);
      }
      // Trimmed, as core trims a reply before delivery, so a chunk equals the live `reply` it was.
      const text = withoutMedia(textOf(message.content).trim());
      const files = attachmentsOf(chunkId(sessionId, eventId, 0));
      if (!text && !files.length) return;
      const chunks = chunkMarkdownText(text, limit).filter((chunk) => chunk.trim());
      // As `replyEvents` sends them: the files on the last chunk, or on an item of their own.
      if (!chunks.length) chunks.push("");
      chunks.forEach((chunk, k) => {
        const id = chunkId(sessionId, eventId, k);
        const last = k === chunks.length - 1 && files.length;
        items.push({ kind: "agent", id, seq, ts, text: cut(chunk), ...(last ? { attachments: files } : {}) });
      });
    } else if (message.role === "toolResult" && typeof message.toolCallId === "string") {
      const call = pending.get(message.toolCallId);
      if (call) call.status = message.isError === true ? "failed" : "done";
    }
  });
  // A run still open at the end of the transcript keeps its running calls; live `tool` events finish them.
  return items;
}

// Stands in for OpenClaw and for the plugin files that need a running Gateway (genui-hooks.ts maps them here), so
// the tests run the real conversation.ts, history.ts, sessions.ts and presentations.ts. It holds no tests.
export const host = {
  /** sessionKey → entry, sessionId → transcript events, namespace → keyed store rows, and every broadcast event. */
  sessions: new Map(),
  transcripts: new Map(),
  stores: new Map(),
  sent: [],
  /** Overrides a keyed store's `maxEntries`, to reach the cap with a few rows. */
  cap: undefined,
  /** Plays OpenClaw for one turn: gets the plugin's `deliver`. */
  run: undefined,
};

// The keyed state store as the plugin uses it: bounded, oldest row dropped.
const openKeyedStore = ({ namespace, maxEntries }) => {
  const rows = host.stores.get(namespace) ?? host.stores.set(namespace, new Map()).get(namespace);
  return {
    register: async (key, value) => {
      rows.delete(key);
      rows.set(key, value);
      for (const old of rows.keys()) {
        if (rows.size <= (host.cap ?? maxEntries)) break;
        rows.delete(old);
      }
    },
    lookup: async (key) => rows.get(key),
    delete: async (key) => rows.delete(key),
    entries: async () => [...rows].map(([key, value]) => ({ key, value })),
  };
};

// openclaw/plugin-sdk/*
export const resolveTextChunkLimit = (cfg, _channel, _account, { fallbackLimit }) => cfg.limit ?? fallbackLimit;
export const chunkMarkdownText = (text, limit) => text.match(new RegExp(`[\\s\\S]{1,${limit}}`, "g")) ?? [];
export const resolveAgentRoute = ({ defaultAgentId, accountId }) => ({
  agentId: defaultAgentId, accountId: accountId ?? "default", sessionKey: `agent:${defaultAgentId}:yorozu:direct:owner`,
});
export const resolveThreadSessionKeys = ({ baseSessionKey, threadId }) => ({ sessionKey: `${baseSessionKey}:thread:${threadId}` });
export const getSessionEntry = ({ sessionKey }) => host.sessions.get(sessionKey);
export const listSessionEntries = () => [...host.sessions].map(([sessionKey, entry]) => ({ sessionKey, entry }));
export const loadTranscriptEventsSync = ({ sessionId }) => host.transcripts.get(sessionId) ?? [];
export const patchSessionEntry = async ({ sessionKey, update }) => {
  const entry = host.sessions.get(sessionKey);
  const patch = entry && update(entry);
  if (patch) host.sessions.set(sessionKey, { ...entry, ...patch });
};
export const deleteSessionEntry = async ({ sessionKey }) => void host.sessions.delete(sessionKey);
export const generateConversationLabel = async () => null;
export const buildChannelInboundEventContext = (context) => context;
export const toInboundMediaFactsWithMetadata = async () => [];
export const getAgentScopedMediaLocalRoots = () => [];
export const createTypingCallbacks = () => ({});
export const runChannelInboundEvent = async ({ adapter }) => {
  await host.run?.(adapter.resolveTurn().delivery.deliver);
};

// ./runtime.js, ./relay.js, ./push.js, ./retry.js, ./activity.js, ./attachments.js, ./reactions.js, ./reads.js
export const yorozuRuntime = { getRuntime: () => ({ state: { openKeyedStore }, channel: { reply: {} } }) };
export const broadcast = (events) => host.sent.push(...events);
export const activityTurn = () => {};
export const notifyReply = async () => {};
export const noteFirstMessage = async () => {};
export const isTemporary = () => false;
export const park = async () => false;
export const messageTime = (_convId, _rev, read, fallback) => read() ?? fallback;
export const revOf = (_agent, _sessionKey, sessionId) => (host.transcripts.get(sessionId) ?? []).length;
export const stageOutbound = async () => ({ attachments: [], failures: [] });
export const uploadedFiles = async () => [];
export const attachmentAt = () => undefined;
export const attachmentsOf = () => [];
export const reactionsOf = () => undefined;
export const forgetCursor = async () => {};

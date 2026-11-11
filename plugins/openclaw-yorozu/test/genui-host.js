// Stands in for OpenClaw and for the plugin files that need a running Gateway (genui-hooks.ts maps them here), so
// the tests run the real conversation.ts, history.ts, sessions.ts and presentations.ts. It holds no tests.
export const host = {
  /** sessionKey → entry, sessionId → transcript events, namespace → keyed store rows, and every broadcast event. */
  sessions: new Map(),
  transcripts: new Map(),
  stores: new Map(),
  sent: [],
  reactions: new Map(),
  /** Overrides a keyed store's `maxEntries`, to reach the cap with a few rows. */
  cap: undefined,
  /** Plays OpenClaw for one turn: gets the plugin's `deliver` and the run's `start`. */
  run: undefined,
  /** The agent run starts only when `run` calls `start`, as for a message waiting behind a running turn. */
  queued: false,
  /** Overrides staging a reply's files: gets the media URLs. */
  stage: undefined,
  /** Makes a keyed store's `register` fail ("reject") or never finish ("hang"). */
  register: undefined,
  /** Makes `lookup` fail ("reject"), never finish ("hang"), or hang only for cards ("cards-hang"). */
  lookup: undefined,
};

// The keyed state store as the plugin uses it: bounded, oldest row dropped.
const openKeyedStore = ({ namespace, maxEntries }) => {
  const rows = host.stores.get(namespace) ?? host.stores.set(namespace, new Map()).get(namespace);
  return {
    register: async (key, value) => {
      if (host.register === "reject") throw new Error("store down");
      if (host.register === "hang") await new Promise(() => {});
      rows.delete(key);
      rows.set(key, value);
      for (const old of rows.keys()) {
        if (rows.size <= (host.cap ?? maxEntries)) break;
        rows.delete(old);
      }
    },
    lookup: async (key) => {
      if (typeof host.lookup === "function") await host.lookup(namespace, key);
      if (host.lookup === "reject") throw new Error("store down");
      if (host.lookup === "hang" || (host.lookup === "cards-hang" && namespace === "presentations")) await new Promise(() => {});
      return rows.get(key);
    },
    delete: async (key) => rows.delete(key),
    entries: async () => [...rows].map(([key, value]) => ({ key, value })),
  };
};

// openclaw/plugin-sdk/*
export const resolveTextChunkLimit = (cfg, _channel, _account, { fallbackLimit }) => cfg.limit ?? fallbackLimit;
export const chunkMarkdownText = (text, limit) => text.match(new RegExp(`[\\s\\S]{1,${limit}}`, "g")) ?? [];
export const resolveChunkMode = (cfg) => cfg.chunkMode ?? "length";
export const chunkMarkdownTextWithMode = (text, limit) => text.split("\n\n").flatMap((part) => chunkMarkdownText(part, limit));
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
// The agent run starts (`onAgentRunStart`) before `host.run`, or, with `host.queued`, when `host.run` calls `start`.
export const runChannelInboundEvent = async ({ adapter }) => {
  const turn = adapter.resolveTurn();
  const start = () => turn.replyOptions?.onAgentRunStart?.("run");
  if (!host.queued) start();
  await host.run?.(turn.delivery.deliver, start);
};

// What channel.ts takes from openclaw/plugin-sdk/*: the plugin object as declared, and the presentation SDK as in
// presentations.test.ts.
export const DEFAULT_ACCOUNT_ID = "default";
export const createChatChannelPlugin = (plugin) => plugin;
export const defineChannelPluginEntry = (entry) => entry;
export const ErrorCodes = { UNAVAILABLE: "UNAVAILABLE" };
export const errorShape = (code, message) => ({ code, message });
export const beginPairing = async () => {};
export const unpairDevice = async () => false;
export const buildThreadAwareOutboundSessionRoute = ({ route }) => route;
export const normalizeMessagePresentation = (raw) => raw;
export const renderMessagePresentationTableFallbackText = (b) => `${b.caption}`;
export const renderMessagePresentationChartFallbackText = (b) => `${b.title}`;
export const channelReadyPatch = () => ({});
export const channelStoppedPatch = () => ({});

// ./runtime.js, ./relay.js, ./push.js, ./retry.js, ./activity.js, ./attachments.js, ./reactions.js, ./reads.js,
// ./keys.js, ./cron.js, ./updates.js
export const loadHostKeys = async () => ({ room: "room" });
export const listCronJobs = async () => [];
export const announceGatewayState = async () => {};
export const runRelayHost = async () => {};
export const runParked = () => {};
export const loadAttachmentIndex = async () => {};
export const mediaMaxBytes = () => 1;
export const loadMessageTimes = async () => {};
export const loadReactions = async () => {};
export const reactionActions = {};
export const userReaction = () => {};
export const yorozuRuntime = { getRuntime: () => ({ state: { openKeyedStore }, channel: { reply: {} } }) };
export const broadcast = (events) => host.sent.push(...events);
export const activityTurn = () => {};
export const notifyReply = async () => {};
export const noteFirstMessage = async () => {};
export const isTemporary = () => false;
export const park = async () => false;
export const messageTime = (_convId, _rev, read, fallback) => read() ?? fallback;
export const revOf = (_agent, _sessionKey, sessionId) => (host.transcripts.get(sessionId) ?? []).length;
export const stageOutbound = async (urls) => host.stage?.(urls) ?? { attachments: [], failures: [] };
export const uploadedFiles = async () => [];
export const attachmentAt = () => undefined;
export const attachmentsOf = () => [];
export const reactionsOf = (messageId) => host.reactions.get(messageId);
export const forgetCursor = async () => {};

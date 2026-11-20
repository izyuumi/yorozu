export const host = {
  sessions: new Map(),
  transcripts: new Map(),
  stores: new Map(),
  sent: [],
  reactions: new Map(),
  cap: undefined,
  run: undefined,
  queued: false,
  stage: undefined,
  register: undefined,
  entries: undefined,
  calls: undefined,
  lookup: undefined,
};

const openKeyedStore = ({ namespace, maxEntries }) => {
  const rows = host.stores.get(namespace) ?? host.stores.set(namespace, new Map()).get(namespace);
  return {
    register: async (key, value) => {
      if (typeof host.register === "function") await host.register(namespace, key, value);
      if (host.register === "reject") throw new Error("store down");
      if (host.register === "hang") await new Promise(() => {});
      if (host.register === "slow") await new Promise((resolve) => setImmediate(resolve));
      rows.delete(key);
      rows.set(key, value);
      const cap = host.cap ?? maxEntries;
      if (cap !== undefined) {
        for (const old of rows.keys()) {
          if (rows.size <= cap) break;
          rows.delete(old);
        }
      }
      host.calls?.push({ kind: "write", namespace, key, value });
    },
    lookup: async (key) => {
      if (typeof host.lookup === "function") await host.lookup(namespace, key);
      if (host.lookup === "reject") throw new Error("store down");
      if (host.lookup === "hang" || (host.lookup === "cards-hang" && namespace === "presentations")) await new Promise(() => {});
      return rows.get(key);
    },
    delete: async (key) => rows.delete(key),
    entries: async () => {
      if (host.entries === "reject") throw new Error("store down");
      return [...rows].map(([key, value]) => ({ key, value }));
    },
  };
};

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
export const runChannelInboundEvent = async ({ adapter }) => {
  const turn = adapter.resolveTurn();
  host.calls?.push({ kind: "dispatch", messageId: turn.ctxPayload.messageId });
  const start = () => turn.replyOptions?.onAgentRunStart?.("run");
  if (!host.queued) start();
  const dispatchResult = await host.run?.(turn.delivery.deliver, start, turn.ctxPayload);
  return { dispatched: true, dispatchResult };
};

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

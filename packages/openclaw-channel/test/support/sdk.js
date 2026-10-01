// OpenClaw boundary fixture: no installed SDK, gateway, credentials, or user config.
export const state = { config: null, turns: [], selections: [], pipelines: [], entries: new Map() };
export const sdk = {
  buildChannelOutboundSessionRoute: () => { throw new Error("outbound route is outside this regression"); },
  saveMediaBuffer: () => { throw new Error("media is outside this regression"); },
  createChannelPluginBase: (base) => base,
  createChatChannelPlugin: ({ base, outbound }) => ({ ...base, outbound }),
  getRuntimeConfigSnapshot: () => state.config,
  resolveChannelInboundRouteEnvelope: ({ cfg, peer }) => ({
    route: { agentId: cfg.agent, accountId: "default", sessionKey: `${cfg.agent}:${peer.id}` },
    buildEnvelope: ({ body }) => body,
  }),
  buildChannelInboundEventContext: (context) => context,
  createChannelReplyPipeline: ({ cfg }) => (state.pipelines.push(cfg), {}),
  dispatchChannelInboundTurn: async (plan) => {
    state.turns.push(plan);
    await state.turn?.(plan);
    return { dispatched: true };
  },
  toInboundMediaFacts: (media) => media,
  buildPreparedModelsProviderData: async (cfg, agentId) => {
    await state.catalog?.(cfg, agentId);
    return {
      providers: ["fixture"], byProvider: new Map([["fixture", new Set([cfg.model])]]),
      modelNames: new Map(), resolvedDefault: { provider: "fixture", model: cfg.model },
      modelCatalog: [],
    };
  },
  getSessionEntry: ({ sessionKey }) => state.entries.get(sessionKey),
  resolveStorePath: (store, { agentId }) => `${store}/${agentId}`,
  applySessionModelSelection: async (params) => {
    state.selections.push(params);
    return { status: "applied", effectiveModelRef: `${params.request.provider}/${params.request.model}` };
  },
  PlatformMessageNotDispatchedError: Error,
};

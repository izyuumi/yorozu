// Answers the host's model-select-v1 frames (docs/architecture.md, channel socket section)
// for one Yorozu thread = one OpenClaw session. `sdk` is injected so tests can fake it.
import { randomUUID } from "node:crypto";

const fail = (error) => (error instanceof Error ? error.message : String(error));

/**
 * @param {{ resolveRoute: Function, buildModelsData: Function, getSessionEntry: Function, resolveStorePath: Function, applySelection: Function }} sdk
 * @returns {(params: { cfg: object, accountId: string, frame: object }) => Promise<object>} Resolves with the reply frame; never rejects.
 */
export const createModelResponder = (sdk) => {
  // The route exists before the first message, so a draft resolves like any thread.
  const route = ({ cfg, accountId, threadId }) =>
    sdk.resolveRoute({ cfg, channel: "yorozu", accountId, peer: { kind: "direct", id: threadId } }).route;

  const catalog = async ({ cfg, accountId, frame }) => {
    const { agentId } = route({ cfg, accountId, threadId: frame.threadId });
    const { byProvider, providers, modelNames } = await sdk.buildModelsData(cfg, agentId);
    // Only models this agent may use come back: the SDK leaves the others out, with no reason.
    const models = providers.flatMap((provider) => [...(byProvider.get(provider) ?? [])].map((model) => ({
      id: `${provider}/${model}`,
      label: modelNames.get(`${provider}/${model}`) ?? model,
      available: true,
    })));
    return { type: "model_catalog", requestId: frame.requestId, models };
  };

  const selection = ({ cfg, accountId, frame }) => {
    const { agentId, sessionKey } = route({ cfg, accountId, threadId: frame.threadId });
    const entry = sdk.getSessionEntry({ agentId, sessionKey });
    const model = entry?.providerOverride && entry.modelOverride ? `${entry.providerOverride}/${entry.modelOverride}` : null;
    return { type: "model_selection", requestId: frame.requestId, model };
  };

  const select = async ({ cfg, accountId, frame }) => {
    const { agentId, sessionKey } = route({ cfg, accountId, threadId: frame.threadId });
    const data = await sdk.buildModelsData(cfg, agentId);
    const { provider: defaultProvider, model: defaultModel } = data.resolvedDefault;
    let provider = defaultProvider;
    let model = defaultModel;
    if (frame.model !== null) {
      const split = typeof frame.model === "string" ? frame.model.indexOf("/") : -1;
      if (split <= 0) return { ok: false, error: `Unknown model "${frame.model}"` };
      provider = frame.model.slice(0, split);
      model = frame.model.slice(split + 1);
      if (!data.byProvider.get(provider)?.has(model)) return { ok: false, error: `Model "${frame.model}" is not allowed` };
    }
    const storePath = sdk.resolveStorePath(cfg.session?.store, { agentId });
    const existing = sdk.getSessionEntry({ agentId, sessionKey, storePath });
    // A draft has no session yet: the selection creates it, and the first message reuses it.
    const sessionEntry = existing ?? { sessionId: randomUUID(), updatedAt: Date.now() };
    const current = existing?.providerOverride && existing.modelOverride
      ? { provider: existing.providerOverride, model: existing.modelOverride }
      : { provider: defaultProvider, model: defaultModel };
    const applied = await sdk.applySelection({
      cfg, agentId, sessionKey, storePath, sessionEntry,
      sessionStore: { [sessionKey]: sessionEntry },
      allowCreate: existing === undefined,
      defaultProvider, defaultModel,
      currentProvider: current.provider, currentModel: current.model,
      modelCatalog: data.modelCatalog,
      canPersistStickyModelSelection: false, // never change agent or global defaults
      request: { provider, model, isDefault: frame.model === null, runtime: { kind: "clear" } },
      markLiveSwitchPending: true,
    });
    if (applied.status !== "applied") return { ok: false, error: applied.message };
    return { ok: true, model: frame.model === null ? null : applied.effectiveModelRef };
  };

  return async (params) => {
    const { frame } = params;
    try {
      if (frame.type === "model_catalog_request") return await catalog(params);
      if (frame.type === "model_selection_request") return selection(params);
      const result = await select(params);
      return { type: "model_select_result", requestId: frame.requestId, ...result };
    } catch (error) {
      // The host drops a reply of the wrong type until its 10 s timeout, so a failed read is
      // answered with the right type and no usable payload: the host rejects that at once.
      if (frame.type === "model_catalog_request") return { type: "model_catalog", requestId: frame.requestId, error: fail(error) };
      if (frame.type === "model_selection_request") return { type: "model_selection", requestId: frame.requestId, error: fail(error) };
      return { type: "model_select_result", requestId: frame.requestId, ok: false, error: fail(error) };
    }
  };
};

import { createPluginRuntimeStore, type PluginRuntime } from "openclaw/plugin-sdk/runtime-store";

/** The host's plugin runtime, set at registration; its `state` holds the device allowlist. */
export const yorozuRuntime = createPluginRuntimeStore<PluginRuntime>({
  pluginId: "yorozu",
  errorMessage: "Yorozu runtime not initialised",
});

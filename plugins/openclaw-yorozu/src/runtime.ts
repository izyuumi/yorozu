import { createPluginRuntimeStore, type PluginRuntime } from "openclaw/plugin-sdk/runtime-store";

export const yorozuRuntime = createPluginRuntimeStore<PluginRuntime>({
  pluginId: "yorozu",
  errorMessage: "Yorozu runtime not initialised",
});

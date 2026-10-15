import { defineChannelPluginEntry } from "openclaw/plugin-sdk/channel-core";
import { createPluginRuntimeStore, type PluginRuntime } from "openclaw/plugin-sdk/runtime-store";
import { yorozuPlugin } from "./src/channel.js";

export const yorozuRuntime = createPluginRuntimeStore<PluginRuntime>({
  pluginId: "yorozu",
  errorMessage: "Yorozu runtime not initialised",
});

export default defineChannelPluginEntry({
  id: "yorozu",
  name: "Yorozu",
  description: "Yorozu channel over an end-to-end-encrypted relay",
  plugin: yorozuPlugin,
  setRuntime: yorozuRuntime.setRuntime,
});

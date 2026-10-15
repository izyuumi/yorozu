import { defineChannelPluginEntry } from "openclaw/plugin-sdk/channel-core";
import { yorozuPlugin } from "./src/channel.js";
import { yorozuRuntime } from "./src/runtime.js";

export { yorozuRuntime };

export default defineChannelPluginEntry({
  id: "yorozu",
  name: "Yorozu",
  description: "Yorozu channel over an end-to-end-encrypted relay",
  plugin: yorozuPlugin,
  setRuntime: yorozuRuntime.setRuntime,
});

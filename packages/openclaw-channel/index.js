import { defineChannelPluginEntry } from "openclaw/plugin-sdk/channel-core";
import { progress, yorozuPlugin } from "./channel.js";

export default defineChannelPluginEntry({
  id: "yorozu",
  name: "Yorozu",
  description: "Yorozu app as an OpenClaw chat channel, over Yorozu's local channel socket.",
  plugin: yorozuPlugin,
  // Observe-only tool hooks (progress-v1); before_tool_call needs no conversation access.
  registerFull(api) {
    api.on("before_tool_call", progress.before);
    api.on("after_tool_call", progress.after);
  },
});

import { defineChannelPluginEntry } from "openclaw/plugin-sdk/channel-core";
import { ErrorCodes, errorShape, type GatewayRequestHandlerOptions } from "openclaw/plugin-sdk/gateway-runtime";
import { CARD_GUIDANCE } from "./src/cards.js";
import { yorozuPlugin } from "./src/channel.js";
import { listDevices } from "./src/devices.js";
import { isId } from "./src/envelope.js";
import { prepareToolPresentation } from "./src/presentation.js";
import { beginPairing, unpairDevice } from "./src/relay.js";
import { yorozuRuntime } from "./src/runtime.js";
import { prefix } from "./src/sessions.js";

export { yorozuRuntime };

export type DeviceRow = { id: string; name?: string; pairedAt: number };

/** Whether the hook's session is a Yorozu conversation of its agent. */
const ownSession = (ctx: { agentId?: string; sessionKey?: string }): boolean => {
  const agent = ctx.agentId ?? ctx.sessionKey?.match(/^agent:([^:]+):/)?.[1];
  const start = agent ? prefix(agent) : undefined;
  return !!start && !!ctx.sessionKey?.startsWith(start) && isId(ctx.sessionKey.slice(start.length));
};

const method =
  (run: (params: Record<string, unknown>) => Promise<unknown>) =>
  async ({ params, respond }: GatewayRequestHandlerOptions) => {
    try {
      respond(true, await run(params ?? {}));
    } catch (error) {
      respond(false, undefined, errorShape(ErrorCodes.UNAVAILABLE, error instanceof Error ? error.message : String(error)));
    }
  };

export default defineChannelPluginEntry({
  id: "yorozu",
  name: "Yorozu",
  description: "Yorozu channel over an end-to-end-encrypted relay",
  plugin: yorozuPlugin,
  setRuntime: yorozuRuntime.setRuntime,
  registerCliMetadata(api) {
    api.registerCli(
      async ({ program }) => {
        const { registerYorozuCli } = await import("./src/cli.js");
        registerYorozuCli(program);
      },
      { descriptors: [{ name: "yorozu", description: "Pair and manage Yorozu devices", hasSubcommands: true }] },
    );
  },
  registerFull(api) {
    // Another plugin's prompt hook may replace the developer instructions that carry groupSystemPrompt; appendSystemContext survives that.
    api.on("before_prompt_build", (_event, ctx) => (ownSession(ctx) ? { appendSystemContext: CARD_GUIDANCE } : undefined));
    api.on("before_tool_call", (event, ctx) => {
      if (event.toolName !== "message") return;
      const { params } = event;
      if (params.channel !== "yorozu" && !(params.channel == null && ownSession(ctx))) return;
      const presentation = prepareToolPresentation(params.presentation);
      return presentation !== params.presentation ? { params: { ...params, presentation } } : undefined;
    });
    const admin = { scope: "operator.admin" } as const;
    api.registerGatewayMethod("yorozu.pair.begin", method(beginPairing), admin);
    api.registerGatewayMethod(
      "yorozu.devices.list",
      method(async () => ({
        devices: (await listDevices()).map((d): DeviceRow => ({ id: d.signingPub, name: d.name, pairedAt: d.pairedAt })),
      })),
      admin,
    );
    api.registerGatewayMethod(
      "yorozu.devices.remove",
      method(async ({ id }) => {
        const query = typeof id === "string" ? id.trim() : "";
        const matches = query ? (await listDevices()).filter((d) => d.signingPub.startsWith(query)) : [];
        if (matches.length > 1) throw new Error(`${query} matches ${matches.length} devices; give more of the id`);
        const key = matches[0]?.signingPub;
        return { removed: key && (await unpairDevice(key)) ? key : null };
      }),
      admin,
    );
  },
});

import { defineChannelPluginEntry } from "openclaw/plugin-sdk/channel-core";
import { ErrorCodes, errorShape, type GatewayRequestHandlerOptions } from "openclaw/plugin-sdk/gateway-runtime";
import { holdTime } from "./src/activity.js";
import { yorozuPlugin } from "./src/channel.js";
import { listDevices } from "./src/devices.js";
import { beginPairing, unpairDevice } from "./src/relay.js";
import { yorozuRuntime } from "./src/runtime.js";
import { channelAgent } from "./src/sessions.js";

export { yorozuRuntime };

/** One row of `yorozu.devices.list`; `id` is the device's Ed25519 relay key, base64url. */
export type DeviceRow = { id: string; name?: string; pairedAt: number };

/** A Gateway method for the CLI (`src/cli.ts`): its result, or a thrown error as `UNAVAILABLE`. */
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
    const admin = { scope: "operator.admin" } as const;
    // The Mac app's import from Yorozu 0.5 gives each imported conversation its last 0.5 message's time (src/activity.ts).
    api.registerGatewayMethod(
      "yorozu.conversations.time",
      method(async (params) => {
        const agent = channelAgent();
        if (!agent) throw new Error("the Yorozu channel is not running");
        return holdTime(agent, params);
      }),
      admin,
    );
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

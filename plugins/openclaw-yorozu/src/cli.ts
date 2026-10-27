import type { OpenClawPluginApi } from "openclaw/plugin-sdk/channel-core";
import { addGatewayClientOptions, callGatewayFromCli, type GatewayRpcOpts } from "openclaw/plugin-sdk/gateway-runtime";
import { renderQrTerminal } from "openclaw/plugin-sdk/media-runtime";
import type { DeviceRow } from "../index.js";
import type { Pairing } from "./relay.js";

type Program = Parameters<Parameters<OpenClawPluginApi["registerCli"]>[0]>[0]["program"];

const call = async <T>(method: string, opts: GatewayRpcOpts, params?: unknown): Promise<T> =>
  (await callGatewayFromCli(method, { ...opts, json: true }, params, { progress: false })) as T;

const time = (ms: number): string => new Date(ms).toLocaleString();
const print = (line: string): void => void process.stdout.write(`${line}\n`);

export function registerYorozuCli(program: Program): void {
  const yorozu = program.command("yorozu").description("Pair and manage Yorozu devices");

  addGatewayClientOptions(
    yorozu.command("pair").description("Print a one-time pairing QR for a new device (valid 10 minutes)"),
  ).action(async (opts: GatewayRpcOpts) => {
    const pairing = await call<Pairing>("yorozu.pair.begin", opts);
    print(await renderQrTerminal(pairing.webLink, { small: true }));
    print(`Scan with the Yorozu app, or open: ${pairing.link}`);
    print(`Host fingerprint: ${pairing.fingerprint} (the app shows it too; they must match)`);
    print(`One device, until ${time(pairing.expiresAt)}.`);
    if (pairing.devices >= 16) print("16 devices are paired: the new one replaces the oldest.");
  });

  const devices = addGatewayClientOptions(yorozu.command("devices").description("List paired devices")).action(
    async (opts: GatewayRpcOpts) => {
      const { devices } = await call<{ devices: DeviceRow[] }>("yorozu.devices.list", opts);
      if (devices.length === 0) return print("No paired devices. Pair one with `openclaw yorozu pair`.");
      for (const d of devices) print(`${d.id}  ${d.name ?? "(unnamed)"}  paired ${time(d.pairedAt)}`);
    },
  );

  addGatewayClientOptions(
    devices.command("remove <id>").description("Unpair a device (its id, or a unique start of it)"),
  ).action(async (id: string, opts: GatewayRpcOpts) => {
    const { removed } = await call<{ removed: string | null }>("yorozu.devices.remove", opts, { id });
    print(removed ? `Removed ${removed}.` : `No paired device matches ${id}.`);
    if (!removed) process.exitCode = 1;
  });
}

import { yorozuRuntime } from "./runtime.js";

export type Device = {
  signingPub: string;
  staticPub: string;
  name?: string;
  pairedAt: number;
  push?: boolean;
};

export const MAX_DEVICES = 16;

const store = () =>
  yorozuRuntime.getRuntime().state.openKeyedStore<Device>({ namespace: "devices", retention: "retained" });

export const getDevice = (signingPub: string): Promise<Device | undefined> => store().lookup(signingPub);

export async function listDevices(): Promise<Device[]> {
  return (await store().entries()).map((entry) => entry.value).sort((a, b) => a.pairedAt - b.pairedAt);
}

export async function putDevice(device: Device): Promise<string[]> {
  const others = (await listDevices()).filter((d) => d.signingPub !== device.signingPub);
  const evicted = others.slice(0, Math.max(0, others.length - MAX_DEVICES + 1)).map((d) => d.signingPub);
  for (const key of evicted) await store().delete(key);
  await store().register(device.signingPub, device);
  return evicted;
}

export const removeDevice = (signingPub: string): Promise<boolean> => store().delete(signingPub);

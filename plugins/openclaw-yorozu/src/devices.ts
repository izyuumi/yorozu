/**
 * The device allowlist: paired devices in the plugin's keyed state store (`<stateDir>/state/openclaw.sqlite`,
 * namespace `devices`), keyed by the device's Ed25519 relay key. `openclaw yorozu pair` adds devices and
 * `openclaw yorozu devices remove` takes them out, both through the running relay host (`src/relay.ts`), which
 * reads the list on every handshake, announces it to the relay on every registration and revokes a removed
 * device at the relay at once.
 */
import { yorozuRuntime } from "./runtime.js";

/** One paired device. Keys are base64url, 32 bytes each. */
export type Device = {
  /** Ed25519 relay key: the store key, what the relay knows the device by, and what signs its frames. */
  signingPub: string;
  /** X25519 static key the device's handshake must authenticate. */
  staticPub: string;
  /** Device model from its `peer_info`, diagnostic only. */
  name?: string;
  /** Epoch ms. The oldest device makes way past `MAX_DEVICES`, as on the relay. */
  pairedAt: number;
};

/** The relay remembers at most this many devices a room. */
export const MAX_DEVICES = 16;

const store = () =>
  yorozuRuntime.getRuntime().state.openKeyedStore<Device>({ namespace: "devices", retention: "retained" });

export const getDevice = (signingPub: string): Promise<Device | undefined> => store().lookup(signingPub);

/** Oldest first. */
export async function listDevices(): Promise<Device[]> {
  return (await store().entries()).map((entry) => entry.value).sort((a, b) => a.pairedAt - b.pairedAt);
}

/** Adds or replaces a device; past `MAX_DEVICES` the oldest others are removed first. Returns their keys. */
export async function putDevice(device: Device): Promise<string[]> {
  const others = (await listDevices()).filter((d) => d.signingPub !== device.signingPub);
  const evicted = others.slice(0, Math.max(0, others.length - MAX_DEVICES + 1)).map((d) => d.signingPub);
  for (const key of evicted) await store().delete(key);
  await store().register(device.signingPub, device);
  return evicted;
}

export const removeDevice = (signingPub: string): Promise<boolean> => store().delete(signingPub);

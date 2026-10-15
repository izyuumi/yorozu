/**
 * The device allowlist: paired devices in the plugin's keyed state store (`<stateDir>/state/openclaw.sqlite`,
 * namespace `devices`), keyed by the device's Ed25519 relay key. Empty until pairing (#423) adds devices. The
 * relay host reads it on every handshake and announces it to the relay on every registration, so a change
 * applies to the next handshake and to the relay's known devices on the next reconnect.
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

/** Adds or replaces a device; past `MAX_DEVICES` the oldest others are removed first. */
export async function putDevice(device: Device): Promise<void> {
  const others = (await listDevices()).filter((d) => d.signingPub !== device.signingPub);
  for (const old of others.slice(0, Math.max(0, others.length - MAX_DEVICES + 1))) {
    await store().delete(old.signingPub);
  }
  await store().register(device.signingPub, device);
}

export const removeDevice = (signingPub: string): Promise<boolean> => store().delete(signingPub);

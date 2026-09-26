/** Authenticated peer claims; never infer capabilities from an app version string. */
export interface PeerInfoData {
  appVersion: string;
  protocolMin: number;
  protocolMax: number;
  capabilities: string[];
  requiredCapabilities: string[];
  computerName?: string;
}

export type PeerCompatibility =
  | { state: "legacy" }
  | { state: "compatible"; version: number; capabilities: string[] }
  | { state: "update-required"; reason: string };

const boundedText = (value: unknown, max: number): value is string =>
  typeof value === "string" && Buffer.byteLength(value) > 0 && Buffer.byteLength(value) <= max && !/[\u0000-\u001f\u007f]/.test(value);
const capabilityList = (value: unknown): value is string[] => Array.isArray(value) && value.length <= 32 &&
  value.every((item) => boundedText(item, 48) && /^[a-z][a-z0-9-]{0,47}$/.test(item)) && new Set(value).size === value.length;

/** Throws on malformed claims instead of treating them as an older peer. */
export function parsePeerInfo(value: unknown): PeerInfoData {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Error("Invalid peer information");
  const info = value as Record<string, unknown>;
  if (!boundedText(info.appVersion, 64) || !Number.isInteger(info.protocolMin) || !Number.isInteger(info.protocolMax) ||
    (info.protocolMin as number) < 1 || (info.protocolMax as number) > 65_535 || (info.protocolMin as number) > (info.protocolMax as number) ||
    !capabilityList(info.capabilities) || !capabilityList(info.requiredCapabilities) ||
    !info.requiredCapabilities.every((capability) => (info.capabilities as string[]).includes(capability)) ||
    ("computerName" in info && !boundedText(info.computerName, 256))) throw new Error("Invalid peer information");
  return {
    appVersion: info.appVersion, protocolMin: info.protocolMin as number, protocolMax: info.protocolMax as number,
    capabilities: info.capabilities, requiredCapabilities: info.requiredCapabilities,
    ...(typeof info.computerName === "string" ? { computerName: info.computerName } : {}),
  };
}

export function localPeerInfo(appVersion: string, computerName?: string): PeerInfoData {
  return {
    appVersion: boundedText(appVersion, 64) ? appVersion : "unknown",
    protocolMin: 1, protocolMax: 1,
    capabilities: ["peer-info", "host-name", "channel-sequence", "admission-status-v1", "admission-expiry-v1", "exact-stop-v1", "offline-approval-v1", "thread-search-v1", "attachment-chunks-v1"],
    requiredCapabilities: ["channel-sequence", "exact-stop-v1", "offline-approval-v1"],
    ...(boundedText(computerName, 256) ? { computerName } : {}),
  };
}

export function negotiatePeerInfo(local: PeerInfoData, peer?: PeerInfoData): PeerCompatibility {
  if (peer === undefined) return { state: "legacy" };
  const version = Math.min(local.protocolMax, peer.protocolMax);
  if (version < Math.max(local.protocolMin, peer.protocolMin)) {
    return { state: "update-required", reason: "Update Yorozu on this device and its host Mac: protocol versions do not overlap." };
  }
  if (local.requiredCapabilities.some((capability) => !peer.capabilities.includes(capability)) ||
      peer.requiredCapabilities.some((capability) => !local.capabilities.includes(capability))) {
    return { state: "update-required", reason: "Update Yorozu on this device and its host Mac: a required security or protocol capability is unavailable." };
  }
  return { state: "compatible", version, capabilities: local.capabilities.filter((capability) => peer.capabilities.includes(capability)) };
}

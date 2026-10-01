import type { PeerCompatibility, PeerInfoData, YorozuEvent } from "@yorozu/shared";
import { syncHostRequest } from "./rust-sync.js";
/** Public metadata and authenticated claim policy are supplied by the portable host. */
export function hostPeerInfo(dir: string, appVersion: string, computerName?: string): PeerInfoData {
  const result = syncHostRequest(dir, { op: "peer_host_info", appVersion, ...(computerName === undefined ? {} : { computerName }) });
  if (!result.info || typeof result.info !== "object") throw new Error("Peer information remains unconfirmed");
  return result.info as PeerInfoData;
}
export function claimPeer(dir: string, event: YorozuEvent): PeerCompatibility {
  const result = syncHostRequest(dir, { op: "peer_claim", event });
  const compatibility = result.compatibility as PeerCompatibility | undefined;
  if (!compatibility || !["compatible", "update-required"].includes(compatibility.state)) throw new Error("Peer information remains unconfirmed");
  return compatibility;
}

import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { localPeerInfo, negotiatePeerInfo, parsePeerInfo, type YorozuEvent } from "@yorozu/shared";
import { claimPeer, hostPeerInfo } from "./session-peers.js";
import { closeSyncHost } from "./rust-sync.js";

test("Rust host negotiation preserves the released cross-language claim and metadata contracts", () => {
  const dir = mkdtempSync(join(tmpdir(), "yorozu-peer-contract-"));
  try {
    for (const [version, name] of [["0.6-alpha", "仕事用 Mac"], ["v\nforged", "猫".repeat(86)], ["x".repeat(65), undefined]] as const)
      expect(hostPeerInfo(dir, version, name)).toEqual(localPeerInfo(version, name));
    const local = localPeerInfo("0.6-alpha");
    const ordinary = localPeerInfo("99.0-beta");
    const claims: unknown[] = [ordinary, { ...ordinary, protocolMin: 1.0, protocolMax: 65535 },
      { ...ordinary, protocolMin: 2, protocolMax: 3 },
      { ...ordinary, capabilities: ordinary.capabilities.filter((c) => c !== "offline-approval-v1"), requiredCapabilities: ["channel-sequence", "exact-stop-v1"] },
      { ...ordinary, capabilities: [...ordinary.capabilities, "future-safety"], requiredCapabilities: ["future-safety"] },
      ...[{ appVersion: "a".repeat(65) }, { appVersion: "v1\nforged" }, { computerName: "猫".repeat(86) },
        { computerName: null }, { protocolMin: 0 }, { protocolMin: 2 }, { protocolMax: 65536 }, { protocolMax: 1.5 },
        { capabilities: ["peer-info", "peer-info"] }, { capabilities: ["bad capability"] },
        { capabilities: ["peer-info\n"] }, { requiredCapabilities: ["unadvertised"] },
        { capabilities: Array.from({ length: 33 }, (_, i) => `cap-${i}`) }].map((change) => ({ ...ordinary, ...change })),
    ];
    for (const peerInfo of claims) {
      let expected;
      try { expected = negotiatePeerInfo(local, parsePeerInfo(peerInfo)); }
      catch { expected = { state: "update-required", reason: "Invalid peer information." }; }
      const event = { id: "claim", threadId: "", ts: 0, agentId: "phone", kind: "thread_list", data: { threads: [], peerInfo } } as YorozuEvent;
      expect(claimPeer(dir, event)).toEqual(expected);
    }
    for (const change of [{ kind: "message" }, { id: "" }, { id: "🙂".repeat(65) },
      { data: { threads: [], peerInfo: ordinary, peerInfoSupported: "yes" } },
      { data: { threads: [], peerInfo: ordinary, peerInfoError: null } },
      { data: { threads: [], peerInfo: ordinary, peerInfoReplyTo: "reflected" } }]) {
      const event = { id: "claim", threadId: "", ts: 0, agentId: "phone", kind: "thread_list", data: { threads: [], peerInfo: ordinary }, ...change } as YorozuEvent;
      expect(claimPeer(dir, event)).toEqual({ state: "update-required", reason: "Invalid peer information." });
    }
  } finally { closeSyncHost(dir); rmSync(dir, { recursive: true, force: true }); }
});

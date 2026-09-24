import { expect, test } from "vitest";
import { localPeerInfo, negotiatePeerInfo, parsePeerInfo } from "./peer-info.js";

test("capabilities and protocol range decide compatibility independently of app versions", () => {
  const local = localPeerInfo("1.0");
  expect(negotiatePeerInfo(local)).toEqual({ state: "legacy" });
  expect(negotiatePeerInfo(local, localPeerInfo("99.0-beta"))).toMatchObject({ state: "compatible", version: 1 });
  expect(negotiatePeerInfo(local, { ...local, protocolMin: 2, protocolMax: 3 })).toMatchObject({ state: "update-required" });
  expect(negotiatePeerInfo(local, { ...local, capabilities: ["peer-info"], requiredCapabilities: [] })).toMatchObject({ state: "update-required" });
});

test("peer schema bounds byte lengths, ranges and capability identifiers", () => {
  const peer = localPeerInfo("1.0", "仕事用 Mac");
  expect(parsePeerInfo(peer)).toEqual(peer);
  for (const change of [
    { appVersion: "a".repeat(65) }, { appVersion: "v1\nforged" }, { computerName: "猫".repeat(86) },
    { computerName: null }, { protocolMin: 0 }, { protocolMin: 2 }, { protocolMax: 65_536 },
    { protocolMax: 1.5 }, { capabilities: ["peer-info", "peer-info"] },
    { capabilities: ["bad capability"] }, { capabilities: ["peer-info\n"] }, { requiredCapabilities: ["unadvertised"] },
    { capabilities: Array.from({ length: 33 }, (_, i) => `cap-${i}`) },
  ]) expect(() => parsePeerInfo({ ...peer, ...change })).toThrow("Invalid peer information");
});

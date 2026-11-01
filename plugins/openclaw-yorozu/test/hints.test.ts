import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import type { NetworkInterfaceInfo } from "node:os";
import { test } from "node:test";
import type { DirectHints } from "../src/envelope.ts";
registerHooks({ resolve(specifier, context, next) {
  if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
    const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
    if (existsSync(ts)) return next(ts.href, context);
  }
  return next(specifier, context);
} });
const { directHints, resolveMagicDNS, watchDirect } = await import("../src/hints.ts");
const { Hub } = await import("../src/hub.ts");
const { encodeEvent, parseEvent } = await import("../src/envelope.ts");
const { x25519Keypair } = await import("../src/wire.ts");
const info = (address: string, cidr: string | null, netmask = "255.255.255.0"): NetworkInterfaceInfo => ({
  address, cidr, netmask, family: address.includes(":") ? "IPv6" : "IPv4", mac: "", internal: false,
});

test("hints classify Tailscale before ULA, retain prefixes, exclude loopback/public, sort and dedupe", () => {
  const interfaces = { en0: [info("192.168.1.5", null), info("fd00::5", "fd00::5/64"),
    info("10.0.0.4", "10.0.0.4/16"), info("fd01::1", null, "ffff:ffff:ffff:ffff::"),
    info("100.100.1.2", "100.100.1.2/32"), info("fd7a:115c:a1e0::1", "fd7a:115c:a1e0::1/128"),
    info("127.0.0.1", "127.0.0.1/8"), info("::1", "::1/128"), info("0:0:0:0:0:0:0:1", null),
    info("8.8.8.8", "8.8.8.8/32"), info("192.168.1.5", "192.168.1.5/25")] };
  assert.deepEqual(directHints(interfaces, 8738, "host.tail.ts.net"), {
    port: 8738, lan: [{ address: "10.0.0.4", prefix: 16 }, { address: "192.168.1.5", prefix: 24 },
      { address: "fd00::5", prefix: 64 }, { address: "fd01::1", prefix: 64 }],
    tailscale: [{ address: "100.100.1.2" }, { address: "fd7a:115c:a1e0::1" }], magicDNS: "host.tail.ts.net",
  });
});

test("MagicDNS accepts only ts.net names, strips trailing dot, silently handles failures and timeout", async () => {
  assert.equal(await resolveMagicDNS("100.100.1.2", async () => ["host.local", "host.tail.ts.net."]), "host.tail.ts.net");
  for (const names of [["evilts.net"], ["host.ts.net.evil"], [".ts.net"], ["bad name.ts.net"]]) {
    assert.equal(await resolveMagicDNS("100.100.1.2", async () => names), undefined);
  }
  assert.equal(await resolveMagicDNS("100.100.1.2", async () => { throw new Error("no PTR"); }), undefined);
  const keepAlive = setTimeout(() => {}, 100);
  try { assert.equal(await resolveMagicDNS("100.100.1.2", () => new Promise(() => {}), 5), undefined); }
  finally { clearTimeout(keepAlive); }
});

test("watcher publishes bound hints on changes, resolves only changed Tailscale IPv4, stops cleanly", async () => {
  let interfaces = { en0: [info("192.168.1.5", null), info("100.100.1.2", "100.100.1.2/32"), info("10.9.9.9", "10.9.9.9/24")] };
  let bound: string[] = [];
  let resolves = 0;
  const sent: (DirectHints | undefined)[] = [];
  const logs: string[] = [];
  const stop = await watchDirect({
    listener: { get bound() { return bound; }, get listening() { return bound.length > 0; },
      update: async (addresses) => { bound = addresses.filter((address) => address !== "10.9.9.9"); }, close: async () => {} },
    port: 8738, intervalMs: 5, source: () => interfaces,
    reverse: async () => { resolves++; return ["host.tail.ts.net"]; },
    changed: (hints) => { sent.push(hints); }, log: { info: (s) => logs.push(s), warn: assert.fail },
  });
  const until = async (condition: () => boolean) => {
    for (let i = 0; i < 100 && !condition(); i++) await new Promise((r) => setTimeout(r, 5));
    assert.ok(condition());
  };
  try {
    assert.equal(sent[0]?.magicDNS, "host.tail.ts.net");
    assert.deepEqual(sent[0]?.lan, [{ address: "192.168.1.5", prefix: 24 }], "failed binds are excluded");
    interfaces = { en0: [info("10.0.0.4", "10.0.0.4/16"), info("100.100.1.2", "100.100.1.2/32")] };
    await until(() => sent.length === 2);
    assert.equal(resolves, 1);
    assert.ok(logs.some((s) => s.includes("+10.0.0.4") && s.includes("-192.168.1.5")));
    interfaces = { en0: [info("100.100.1.3", "100.100.1.3/32")] };
    await until(() => sent.length === 3);
    assert.equal(resolves, 2);
    interfaces = { en0: [] };
    await until(() => sent.length === 4);
    assert.equal(sent[3], undefined);
  } finally { await stop(); }
  interfaces = { en0: [info("192.168.1.5", null)] };
  await new Promise((r) => setTimeout(r, 15));
  assert.equal(sent.length, 4);
});

test("Hub sends hints immediately after peer_info and on change only to direct-capable sessions", async () => {
  let hints: DirectHints | undefined = { port: 8738, lan: [{ address: "10.0.0.4", prefix: 24 }], tailscale: [] };
  const peer = { app: "test", protocolMin: 3, protocolMax: 3, capabilities: [] as string[] };
  const hub = new Hub({ keys: { static: x25519Keypair(), room: "test" }, peerInfo: () => peer,
    staticKeyOf: async () => undefined, directHints: () => hints, onMessage: () => {}, dispatch: async () => false });
  const received: Record<string, unknown[][]> = {};
  for (const [key, capabilities] of [["old", []], ["new", ["direct"]]] as const) {
    received[key] = [];
    const entry = { session: { seal: (bytes: Uint8Array) => Buffer.from(bytes).toString() } as any,
      link: { path: "relay" as const, send: (payloads: string[]) => received[key]!.push(payloads.map((s) => JSON.parse(s))) } };
    hub.served.set(key, entry);
    await hub.handle({ deviceKey: key, entry, plain: encodeEvent({ kind: "peer_info", data: { ...peer, capabilities: [...capabilities] } }) });
  }
  assert.equal(received.old!.length, 0);
  assert.deepEqual(received.new, [[{ kind: "direct_hints", data: hints }]]);
  hints = { ...hints, lan: [{ address: "192.168.1.5", prefix: 24 }] };
  hub.broadcast([{ kind: "direct_hints", data: hints }]);
  assert.equal(received.old!.length, 0);
  assert.deepEqual(received.new![1], [{ kind: "direct_hints", data: hints }]);
  const last = hints;
  hints = undefined;
  hub.broadcast([{ kind: "direct_hints", data: last }]);
  assert.equal(received.new!.length, 2);
  assert.deepEqual(parseEvent(encodeEvent({ kind: "direct_hints", data: last })), { kind: "unknown", name: "direct_hints" });
});

import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { test } from "node:test";

registerHooks({ resolve(specifier, context, next) {
  if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
    const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
    if (existsSync(ts)) return next(ts.href, context);
  }
  return next(specifier, context);
} });
const { Announcer, pairer, PendingPairings } = await import("../src/pairing.ts");
const { helloProof } = await import("../src/wire.ts");

test("three announces during a held read coalesce into two sends, the last with the fresh list", async () => {
  const gate = Promise.withResolvers<void>();
  const messages: unknown[] = [];
  const send = (raw: string) => { messages.push(JSON.parse(raw)); };
  let devices = ["A"];
  let reads = 0;
  const announcer = new Announcer({
    relaySend: () => send,
    allowlist: async () => {
      const snapshot = [...devices];
      if (++reads === 1) await gate.promise;
      return snapshot;
    },
  });
  announcer.announce();
  devices = ["A", "B"];
  announcer.announce();
  devices = ["A", "B", "C"];
  announcer.announce();
  gate.resolve();
  await announcer.idle();
  assert.deepEqual(messages, [
    { type: "devices", devices: ["A"] },
    { type: "devices", devices: ["A", "B", "C"] },
  ]);
});

test("an allowlist read failure warns without throwing and the next announce recovers", async () => {
  const warnings: string[] = [];
  const messages: unknown[] = [];
  const send = (raw: string) => { messages.push(JSON.parse(raw)); };
  let failing = true;
  const announcer = new Announcer({
    relaySend: () => send,
    allowlist: async () => {
      if (failing) throw new Error("synthetic read failure");
      return ["A"];
    },
    log: { info: assert.fail, warn: (message) => { warnings.push(message); } },
  });
  assert.doesNotThrow(() => announcer.announce());
  await assert.doesNotReject(announcer.idle());
  assert.deepEqual(messages, []);
  assert.equal(warnings.length, 1);
  assert.match(warnings[0]!, /allowlist.*synthetic read failure/);
  failing = false;
  announcer.announce();
  await announcer.idle();
  assert.deepEqual(messages, [{ type: "devices", devices: ["A"] }]);
});

test("a link change during a read drops the old snapshot and registration announces on the new link", async () => {
  const gate = Promise.withResolvers<void>();
  const oldMessages: unknown[] = [];
  const newMessages: unknown[] = [];
  let send = (raw: string) => { oldMessages.push(JSON.parse(raw)); };
  let devices = ["A"];
  let reads = 0;
  const announcer = new Announcer({
    relaySend: () => send,
    allowlist: async () => {
      const snapshot = [...devices];
      if (++reads === 1) await gate.promise;
      return snapshot;
    },
  });
  announcer.announce();
  send = (raw) => { newMessages.push(JSON.parse(raw)); };
  devices = ["A", "B"];
  announcer.announce();
  gate.resolve();
  await announcer.idle();
  assert.deepEqual(oldMessages, []);
  assert.deepEqual(newMessages, [{ type: "devices", devices: ["A", "B"] }]);
});

test("offline pairing sends nothing; the next registration announce includes the device", async () => {
  const messages: unknown[] = [];
  const send = (raw: string) => { messages.push(JSON.parse(raw)); };
  let connected = false;
  const devices: string[] = [];
  const opts = {
    allowlist: async () => [...devices],
    relaySend: () => connected ? send : null,
  };
  const announcer = new Announcer(opts);
  const pending = new PendingPairings();
  const pair = pairer({
    ...opts, pending,
    put: async (device) => { devices.push(device.signingPub); return []; },
    forget: () => {},
  }, announcer);
  const now = Date.now();
  const secret = pending.add(now + 10_000);
  assert.equal(await pair(helloProof(secret, "static", "A"), "static", "A", now, "direct"), true);
  await announcer.idle();
  assert.deepEqual(messages, []);
  connected = true;
  announcer.announce();
  await announcer.idle();
  assert.deepEqual(messages, [{ type: "devices", devices: ["A"] }]);
});

test("pairing during a held registration announce returns before the read, then refreshes the roster", { timeout: 2_000 }, async () => {
  const gate = Promise.withResolvers<void>();
  const messages: unknown[] = [];
  const send = (raw: string) => { messages.push(JSON.parse(raw)); };
  const devices = ["A"];
  let reads = 0;
  const opts = {
    relaySend: () => send,
    allowlist: async () => {
      const snapshot = [...devices];
      if (++reads === 1) await gate.promise;
      return snapshot;
    },
  };
  const announcer = new Announcer(opts);
  const pending = new PendingPairings();
  const pair = pairer({
    ...opts, pending,
    put: async (device) => { devices.push(device.signingPub); return []; },
    forget: () => {},
  }, announcer);
  announcer.announce();
  try {
    const now = Date.now();
    const secret = pending.add(now + 10_000);
    assert.equal(await pair(helloProof(secret, "static", "B"), "static", "B", now, "relay"), true);
    assert.deepEqual(messages, [], "handshake completes while registration's read is held");
  } finally {
    gate.resolve();
  }
  await announcer.idle();
  assert.deepEqual(messages.at(-1), { type: "devices", devices: ["A", "B"] });
});

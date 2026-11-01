import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { test } from "node:test";
import type { Received } from "../src/envelope.ts";

// The plugin's files import siblings as `./x.js`, which the Gateway's loader maps to `./x.ts`; do the same here.
registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  },
});
const { DIRECT, parseEvent } = await import("../src/envelope.ts");

const CONV = "6f1c2a3b-4d5e-4f60-8a7b-9c0d1e2f3a4b";
const MSG = "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";
const parse = (value: unknown): Received | null => parseEvent(Buffer.from(JSON.stringify(value)));

test("unknown fields are ignored, at the top and in the data", () => {
  const data = { convId: CONV, messageId: MSG, text: "hi", future: { nested: [1] } };
  assert.deepEqual(parse({ kind: "message", data, extra: true }), { kind: "message", data });
  const peer = { protocolMin: 3, protocolMax: 3, app: "yorozu", capabilities: ["resume", "someday"], extra: 1 };
  assert.equal(parse({ kind: "peer_info", data: peer })?.kind, "peer_info");
});

test("an unknown kind is unknown, not invalid, so the session answers unsupported and stays", () => {
  assert.deepEqual(parse({ kind: "someday", data: {} }), { kind: "unknown", name: "someday" });
  assert.deepEqual(parse({ kind: "someday" }), { kind: "unknown", name: "someday" });
});

test("unknown enum values and false flags pass validation", () => {
  const ref = { convId: CONV, messageId: MSG };
  for (const [kind, data] of [
    ["reaction", { ...ref, emoji: "👍", by: "someone" }],
    ["reaction", { ...ref, emoji: "👍", remove: false }],
    ["tool", { ...ref, callId: "c", name: "n", status: "paused" }],
    ["device_patch", { id: "d", removed: false }],
    ["conv_patch", { convId: CONV, deleted: false }],
    ["foreground", { convId: null, active: true, mode: "someday" }],
    ["error", { code: "someday", message: "m" }],
  ] as const) {
    assert.equal(parse({ kind, data })?.kind, kind, `${kind} ${JSON.stringify(data)}`);
  }
});

test("malformed fields are still refused", () => {
  const ref = { convId: CONV, messageId: MSG };
  assert.equal(parse({ kind: "reaction", data: { ...ref, emoji: "👍", by: 1 } })?.kind, "invalid");
  assert.equal(parse({ kind: "tool", data: { ...ref, callId: "c", name: "n", status: 1 } })?.kind, "invalid");
  assert.equal(parse({ kind: "device_patch", data: { id: "d", removed: "yes" } })?.kind, "invalid");
});

test("the direct capability is named and not yet listed", () => {
  assert.equal(DIRECT, "direct");
});

import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { test } from "node:test";

registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  },
});

const { PUSH_PROXY } = await import("../src/envelope.ts");
const { RelaySession } = await import("../src/relay-session.ts");

test("closing the relay session stops advertising push-proxy", () => {
  const session = new RelaySession();
  const send = () => {};
  const frames = () => {};
  session.registered({ send, frames, pushProxy: true });
  assert.equal(session.pushProxy, true);
  assert.ok(session.capabilities([], { liveActivity: false, direct: false }).includes(PUSH_PROXY));

  session.closed();
  assert.equal(session.send, null);
  assert.equal(session.frames, null);
  assert.equal(session.pushProxy, false);
  assert.equal(session.capabilities([], { liveActivity: false, direct: false }).includes(PUSH_PROXY), false);
});

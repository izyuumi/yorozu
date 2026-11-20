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
const { channelConfigured, currentConversation, looksLikeOwner, PEER } = await import("../src/target.ts");

const CONV = "3f2b8c1e-5a4d-4e6f-9a7b-0c1d2e3f4a5b";
const configured = { channels: { yorozu: {} } };

const turn = { currentChannelProvider: "yorozu", currentChannelId: PEER, currentThreadTs: CONV };

test("the owner is the only target id", () => {
  for (const raw of ["owner", "OWNER", "Owner", "yorozu:owner", "Yorozu:OWNER", " owner "]) assert.equal(looksLikeOwner(raw), true, raw);
  for (const raw of ["", "owners", "the owner", "user:owner", "@owner", "yorozu:", "yorozu:someone", "telegram:owner", CONV, "+15551234567"]) {
    assert.equal(looksLikeOwner(raw), false, raw);
  }
});

test("a configured Yorozu turn supplies a missing threadId", () => {
  for (const cfg of [configured, { channels: { yorozu: { agent: "main" } } }, { channels: { yorozu: { enabled: true } } }]) {
    assert.equal(channelConfigured(cfg), true, JSON.stringify(cfg));
    assert.equal(currentConversation({ cfg, toolContext: turn }), CONV, JSON.stringify(cfg));
  }
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentThreadTs: CONV.toUpperCase() } }), CONV);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentChannelId: undefined, currentMessagingTarget: PEER } }), CONV);
  assert.equal(currentConversation({ cfg: configured, toolContext: { currentChannelId: PEER, currentThreadTs: CONV } }), CONV);
});

test("a send outside a Yorozu turn gets no conversation", () => {
  assert.equal(currentConversation({ cfg: configured }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: {} }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentThreadTs: undefined } }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentThreadTs: "1700000000.000100" } }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentChannelProvider: "telegram" } }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentChannelId: "-1003841603622" } }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentMessagingTarget: "user:someone" } }), undefined);
});

test("without an enabled channels.yorozu section automatic thread inference stays disabled", () => {
  for (const cfg of [{}, { channels: {} }, { channels: { telegram: {} } }, { channels: { yorozu: { enabled: false } } }, { channels: { yorozu: null } }]) {
    assert.equal(channelConfigured(cfg), false, JSON.stringify(cfg));
    assert.equal(currentConversation({ cfg, toolContext: turn }), undefined, JSON.stringify(cfg));
  }
});

test("an empty messaging target blocks fallback to the channel id", () => {
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentMessagingTarget: "" } }), undefined);
});

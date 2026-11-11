import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { test } from "node:test";

// Match the Gateway's sibling .js -> .ts resolution, as in envelope.test.ts.
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

// What core's message tool hands `threading.resolveAutoThreadId` in a Yorozu turn (OpenClaw 2026.9.8):
// the turn's `reply.to` as the channel id and its `messageThreadId` as the thread.
const turn = { currentChannelProvider: "yorozu", currentChannelId: PEER, currentThreadTs: CONV };

test("the owner is the only target id", () => {
  for (const raw of ["owner", "OWNER", "Owner", "yorozu:owner", "Yorozu:OWNER", " owner "]) assert.equal(looksLikeOwner(raw), true, raw);
  for (const raw of ["", "owners", "the owner", "user:owner", "@owner", "yorozu:", "yorozu:someone", "telegram:owner", CONV, "+15551234567"]) {
    assert.equal(looksLikeOwner(raw), false, raw);
  }
});

// With channels.yorozu configured, a send with no target and an explicit owner send both infer this thread.
test("a configured Yorozu turn supplies a missing threadId", () => {
  for (const cfg of [configured, { channels: { yorozu: { agent: "main" } } }, { channels: { yorozu: { enabled: true } } }]) {
    assert.equal(channelConfigured(cfg), true, JSON.stringify(cfg));
    assert.equal(currentConversation({ cfg, toolContext: turn }), CONV, JSON.stringify(cfg));
  }
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentThreadTs: CONV.toUpperCase() } }), CONV);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentChannelId: undefined, currentMessagingTarget: PEER } }), CONV);
  // Core leaves the provider out when it matches a finished send against the turn's reply route.
  assert.equal(currentConversation({ cfg: configured, toolContext: { currentChannelId: PEER, currentThreadTs: CONV } }), CONV);
});

// Explicit owner resolves on every host; without a known threadId the adapter rejects the send.
test("a send outside a Yorozu turn gets no conversation", () => {
  assert.equal(currentConversation({ cfg: configured }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: {} }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentThreadTs: undefined } }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentThreadTs: "1700000000.000100" } }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentChannelProvider: "telegram" } }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentChannelId: "-1003841603622" } }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentMessagingTarget: "user:someone" } }), undefined);
});

// Core's private source-reply sink handles a send with no target on an unconfigured host.
test("without an enabled channels.yorozu section automatic thread inference stays disabled", () => {
  for (const cfg of [{}, { channels: {} }, { channels: { telegram: {} } }, { channels: { yorozu: { enabled: false } } }, { channels: { yorozu: null } }]) {
    assert.equal(channelConfigured(cfg), false, JSON.stringify(cfg));
    // This hook also runs during reply-route matching; explicit UUID threadId bypasses it when sending.
    assert.equal(currentConversation({ cfg, toolContext: turn }), undefined, JSON.stringify(cfg));
  }
});

test("an empty messaging target blocks fallback to the channel id", () => {
  // Empty is present under ??; declining inference is safe because it cannot choose a conversation.
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentMessagingTarget: "" } }), undefined);
});

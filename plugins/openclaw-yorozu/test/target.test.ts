import assert from "node:assert/strict";
import { test } from "node:test";
import { channelConfigured, currentConversation, looksLikeOwner, PEER } from "../src/target.ts";

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

// (a) the target inferred from the turn and (b) `target: "owner"` reach the plugin alike: `to` is the owner
// either way, and the thread comes from the turn.
test("a send from a Yorozu turn lands in that turn's conversation", () => {
  assert.equal(currentConversation({ cfg: configured, toolContext: turn }), CONV);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentThreadTs: CONV.toUpperCase() } }), CONV);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentChannelId: undefined, currentMessagingTarget: PEER } }), CONV);
  // Core leaves the provider out when it matches a finished send against the turn's reply route.
  assert.equal(currentConversation({ cfg: configured, toolContext: { currentChannelId: PEER, currentThreadTs: CONV } }), CONV);
});

// (c) no turn, or not a Yorozu one: no conversation is made up, so the send fails as it did before.
test("a send outside a Yorozu turn gets no conversation", () => {
  assert.equal(currentConversation({ cfg: configured }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: {} }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentThreadTs: undefined } }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentThreadTs: "1700000000.000100" } }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentChannelProvider: "telegram" } }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentChannelId: "-1003841603622" } }), undefined);
  assert.equal(currentConversation({ cfg: configured, toolContext: { ...turn, currentMessagingTarget: "user:someone" } }), undefined);
});

// Core's `isConfiguredChannel` decides which path a send from a Yorozu turn takes.
test("without channels.yorozu the plugin stays out of the send", () => {
  for (const cfg of [{}, { channels: {} }, { channels: { telegram: {} } }, { channels: { yorozu: { enabled: false } } }, { channels: { yorozu: null } }]) {
    assert.equal(channelConfigured(cfg), false, JSON.stringify(cfg));
    // Core's private source-reply sink delivers; the plugin names no thread, as before it had this hook.
    assert.equal(currentConversation({ cfg, toolContext: turn }), undefined, JSON.stringify(cfg));
  }
});

test("with channels.yorozu the send resolves and routes", () => {
  for (const cfg of [configured, { channels: { yorozu: { agent: "main" } } }, { channels: { yorozu: { enabled: true } } }]) {
    assert.equal(channelConfigured(cfg), true, JSON.stringify(cfg));
    assert.equal(looksLikeOwner(turn.currentChannelId), true);
    assert.equal(currentConversation({ cfg, toolContext: turn }), CONV, JSON.stringify(cfg));
  }
});

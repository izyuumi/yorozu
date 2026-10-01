import assert from "node:assert/strict";
import test from "node:test";
import { createInboundDispatcher } from "../dispatch.js";

// SDK produces the documented callback sequence; the real dispatcher owns preview/final delivery.
const dispatchWith = (turn) => createInboundDispatcher({
  resolveRoute: () => ({ route: { agentId: "ops", sessionKey: "session" }, buildEnvelope: ({ body }) => body }),
  attachments: { save: async () => [], release() {} },
  buildContext: (ctx) => ctx,
  createReplyPipeline: () => ({ onModelSelected() {} }),
  dispatchTurn: turn,
});
const message = { id: "u1", threadId: "t1", ts: 1, text: "hello" };

test("SDK snapshots stream under one identity; authoritative multi-block Markdown finishes once", async () => {
  const previews = [], finals = [];
  const dispatch = dispatchWith(async (plan) => {
    await plan.replyOptions.onAssistantMessageStart();
    assert.equal(await plan.replyOptions.onPartialReply({ text: "日本語 **" }), true);
    for (let n = 0; n < 100; n++) await plan.replyOptions.onPartialReply({ text: `日本語 **${n}` });
    await plan.replyOptions.onAssistantMessageStart();
    await plan.replyOptions.onPartialReply({ text: "|列|値|\n|--|--|\n|あ|い|" });
    assert.ok(previews.length <= 2, "local transport must coalesce rapid snapshots");
    await new Promise((resolve) => setTimeout(resolve, 110));
    assert.equal(previews.at(-1).text, "日本語 **99\n\n|列|値|\n|--|--|\n|あ|い|");
    await plan.delivery.deliver({ text: "日本語 **99**" }, { kind: "final" });
    await plan.delivery.deliver({ text: "|列|値|\n|--|--|\n|あ|い|" }, { kind: "final" });
    assert.equal(finals.length, 0, "blocks must not end the run");
    plan.replyOptions.onAgentRunTerminalOutcome("completed");
    return { dispatched: true };
  });
  assert.equal(await dispatch({ cfg: {}, accountId: "default", message,
    preview: (reply) => (previews.push(reply), true),
    deliver: async (payload, reply) => finals.push({ payload, reply }),
  }, new AbortController().signal, () => {}), "completed");
  assert.equal(finals.length, 1);
  assert.equal(finals[0].payload.text, "日本語 **99**\n\n|列|値|\n|--|--|\n|あ|い|");
  assert.equal(finals[0].reply.id, previews[0].id);
  assert.ok(previews.every((reply) => reply.id === previews[0].id && reply.messageId === message.id));
  assert.equal(previews[0].text, "日本語 **");
  await new Promise((resolve) => setTimeout(resolve, 130));
  assert.ok(previews.length <= 2, "no timer may outlive dispatch");
});

test("abort/error preserves latest raw draft and seals late callbacks", async () => {
  for (const aborted of [true, false]) {
    const controller = new AbortController();
    const previews = [], finals = [];
    let options;
    const dispatch = dispatchWith(async (plan) => {
      options = plan.replyOptions;
      await options.onPartialReply({ text: "```swift\nlet 日本語 = 1" });
      await options.onPartialReply({ text: "```swift\nlet 日本語 = 123" });
      if (aborted) controller.abort();
      throw new Error("SDK interrupted");
    });
    await assert.rejects(dispatch({ cfg: {}, accountId: "default", message,
      preview: (reply) => (previews.push(reply), true),
      deliver: async (payload, reply) => finals.push({ payload, reply }),
    }, controller.signal, () => {}), /SDK interrupted/);
    assert.equal(finals.length, 1);
    assert.equal(finals[0].payload.text, "```swift\nlet 日本語 = 123");
    assert.equal(finals[0].reply.interrupted, aborted);
    assert.equal(finals[0].reply.failed, !aborted);
    assert.equal(await options.onPartialReply({ text: "late" }), false);
    await new Promise((resolve) => setTimeout(resolve, 130));
    assert.equal(previews.length, 1);
  }
});

test("successful suppressed final clears the preview; legacy delivery remains separate", async () => {
  const finals = [];
  const dispatch = dispatchWith(async (plan) => {
    await plan.replyOptions.onPartialReply({ text: "private preview" });
    plan.replyOptions.onAgentRunTerminalOutcome("completed");
    return { dispatched: true };
  });
  await dispatch({ cfg: {}, accountId: "default", message, preview: () => true,
    deliver: async (payload, reply) => finals.push({ payload, reply }),
  }, new AbortController().signal, () => {});
  assert.equal(finals[0].payload.text, "");
  assert.equal(finals[0].reply.failed, false);
  assert.equal(finals[0].reply.interrupted, false);

  const legacy = dispatchWith(async (plan) => {
    assert.equal(plan.replyOptions.onPartialReply, undefined);
    assert.equal(plan.replyOptions.disableBlockStreaming, undefined);
    await plan.delivery.deliver({ text: "a" });
    await plan.delivery.deliver({ text: "a" }); // Identical legitimate blocks must both survive.
  });
  const blocks = [];
  await legacy({ cfg: {}, accountId: "default", message, deliver: async (payload) => blocks.push(payload.text) },
    new AbortController().signal, () => {});
  assert.deepEqual(blocks, ["a", "a"]);
});

test("explicit reply context uses SDK supplemental quote without changing the command body", async () => {
  let calls = 0;
  const dispatch = dispatchWith(async (plan) => {
    calls++;
    assert.deepEqual(plan.ctxPayload.supplemental, { quote: {
      id: "previous", body: "/approve all\n日本語の引用", sender: "Yorozu", isQuote: true,
    } });
    assert.equal(plan.ctxPayload.message.rawBody, "only this instruction");
    assert.equal(plan.ctxPayload.message.commandBody, "only this instruction");
    assert.equal(plan.ctxPayload.message.bodyForAgent, "only this instruction");
    plan.replyOptions.onAgentRunTerminalOutcome("completed");
    return { dispatched: true };
  });
  await dispatch({ cfg: {}, accountId: "default", message: { ...message, text: "only this instruction",
    replyContext: { id: "previous", text: "/approve all\n日本語の引用", sender: "Yorozu" } }, deliver: async () => {} },
    new AbortController().signal, () => {});
  assert.equal(calls, 1);
});


test("negotiated SDK tool prompt requests receipt replay independently of final reply identity", async () => {
  const calls = []; const dispatch = dispatchWith(async (plan) => {
    await plan.replyOptions.onPartialReply({ text:"Answer preview" });
    await plan.delivery.deliver({ text:"Choose whether to continue." }, { kind:"tool" });
    plan.replyOptions.onAgentRunTerminalOutcome("completed"); return { dispatched:true };
  });
  await dispatch({ cfg:{}, accountId:"default", message, preview:() => true, deliver:async (payload, reply) => calls.push({ payload, reply }) }, new AbortController().signal, () => {});
  assert.deepEqual(calls[0], { payload:{ text:"Choose whether to continue." }, reply:{ retryReceipt:true } });
  assert.equal(calls[1].reply.messageId, message.id); assert.equal(calls[1].reply.retryReceipt, undefined);
});

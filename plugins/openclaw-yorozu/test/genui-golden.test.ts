// What went on the wire before cards existed. The literals below were produced by the code before capability
// `presentation`, and this file uses nothing that code lacks, so it passes against it unchanged: a reply or a
// history page without a card must stay byte-identical.
import assert from "node:assert/strict";
import { test } from "node:test";
import "./genui-hooks.ts";
import { host } from "./genui-host.js";

const { replyEvents } = await import("../src/conversation.ts");
const { historyPage } = await import("../src/history.ts");
const { downgrade } = await import("../src/hub.ts");
const { encodeEvent } = await import("../src/envelope.ts");

const convId = "11111111-1111-4111-8111-111111111111";
const userId = "22222222-2222-4222-8222-222222222222";
const agentId = "33333333-3333-4333-8333-333333333333";
const quoteId = "44444444-4444-4444-8444-444444444444";
const chunkId = "55555555-5555-4555-8555-555555555555";
const file = { id: "77777777-7777-4777-8777-777777777777", name: "costs.pdf", mime: "application/pdf", size: 3 };
const peer = { app: "test", protocolMin: 3, protocolMax: 3 };
const today = { ...peer, capabilities: ["attachments", "devices", "replies", "reactions", "resume", "direct", "unversioned-wire"] };
const oldest = { ...peer, capabilities: [] };
const json = (event: unknown) => encodeEvent(event as never).toString("utf8");

const first = `{"kind":"reply","data":{"convId":"${convId}","messageId":"${agentId}","text":"Total:","ts":1700000000000,"replyTo":{"messageId":"${quoteId}","text":"How much?"}}}`;
const last = `{"kind":"reply","data":{"convId":"${convId}","messageId":"${chunkId}","text":" 200","ts":1700000000000,"attachments":[{"id":"${file.id}","name":"costs.pdf","mime":"application/pdf","size":3}]}}`;

function replies() {
  const ids = { id: (k: number) => [agentId, chunkId][k]!, ts: 1_700_000_000_000 };
  return replyEvents({ limit: 6 } as never, convId, "Total: 200", undefined, ids, [file], { messageId: quoteId, text: "How much?" });
}

test("reply events without a card are byte-identical to before", () => {
  assert.deepEqual(replies().map(json), [first, last]);
});

test("a reply without a card goes to each kind of session byte-identical to before", () => {
  const events = replies();
  assert.deepEqual(events.map((event) => json(downgrade(event, today))), [first, last]);
  assert.deepEqual(events.map((event) => json(downgrade(event, oldest))), [
    `{"kind":"reply","data":{"convId":"${convId}","messageId":"${agentId}","text":"Total:","ts":1700000000000}}`,
    `{"kind":"reply","data":{"convId":"${convId}","messageId":"${chunkId}","text":" 200\\n\\n(Attachment: costs.pdf; update Yorozu to open it.)","ts":1700000000000}}`,
  ]);
});

test("a history page without a card is byte-identical to before", async () => {
  host.sessions.set(`agent:main:yorozu:direct:owner:thread:${convId}`, { sessionId: "golden" });
  host.transcripts.set("golden", [
    { type: "message", id: "e1", message: { role: "user", content: "What did the trip cost?", timestamp: 1_700_000_000_000, __openclaw: { transport: { messageId: userId } } } },
    { type: "message", id: agentId, message: { role: "assistant", content: [{ type: "text", text: "Total: 200" }], timestamp: 1_700_000_001_000 } },
  ]);
  replies(); // the live reply noted its quote under the agent message's id
  const page = (quote: string) =>
    `{"kind":"history","data":{"convId":"${convId}","items":[{"kind":"user","id":"${userId}","seq":0,"ts":1700000000000,"text":"What did the trip cost?"},{"kind":"agent","id":"${agentId}","seq":1,"ts":1700000001000,"text":"Total: 200"${quote}}],"more":false,"rev":2}}`;
  const quoted = page(`,"replyTo":{"messageId":"${quoteId}","text":"How much?"}`);
  const event = { kind: "history", data: await historyPage({} as never, "main", { convId }) } as const;
  assert.equal(json(event), quoted);
  assert.equal(json(downgrade(event, today)), quoted);
  assert.equal(json(downgrade(event, oldest)), page(""));
});

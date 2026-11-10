import assert from "node:assert/strict";
import { test } from "node:test";
import type { DirectHints, Event, HistoryItem, PeerInfo } from "../src/envelope.ts";
import { answer, convId, hello, host, messageId, newDevice, peer } from "./hub-host.ts";

const { downgrade } = await import("../src/hub.ts");
const { ATTACHMENTS, DIRECT, encodeEvent, LIMITS, REACTIONS, REPLIES } = await import("../src/envelope.ts");

const otherId = "33333333-3333-4333-8333-333333333333";
const can = (...capabilities: string[]): PeerInfo => ({ ...peer, capabilities });
const helloWith = (...capabilities: string[]): Event => ({ kind: "peer_info", data: can(...capabilities) });
/** The downgraded event as the client reads it: JSON drops the keys `downgrade` sets to undefined. */
const sent = (event: Event, to: PeerInfo): unknown => JSON.parse(encodeEvent(downgrade(event, to)).toString("utf8"));
const note = (name: string) => `(Attachment: ${name}; update Yorozu to open it.)`;

const replyTo = { messageId: otherId, text: "quoted" };
const attachments = [
  { id: "44444444-4444-4444-8444-444444444444", name: "a.png", mime: "image/png", size: 1 },
  { id: "55555555-5555-4555-8555-555555555555", name: "b.pdf", mime: "application/pdf", size: 2 },
];
const bare = { convId, messageId, text: "hi", ts: 1 };
const reply: Event = { kind: "reply", data: { ...bare, attachments, replyTo } };

test("downgrade leaves a reply alone for a peer with every capability", () => {
  assert.equal(downgrade(reply, can(REPLIES, REACTIONS, ATTACHMENTS)), reply);
  const plain: Event = { kind: "reply", data: bare };
  assert.equal(downgrade(plain, peer), plain, "nothing to strip: the same event goes out");
});

test("downgrade strips replyTo from a reply for a peer without replies", () => {
  assert.deepEqual(sent(reply, can(ATTACHMENTS)), { kind: "reply", data: { ...bare, attachments } });
  assert.deepEqual(sent(reply, can(ATTACHMENTS, REACTIONS)), { kind: "reply", data: { ...bare, attachments } });
});

test("downgrade turns attachments into text lines for a peer without attachments", () => {
  const text = ["hi", note("a.png"), note("b.pdf")].join("\n\n");
  assert.deepEqual(sent(reply, can(REPLIES)), { kind: "reply", data: { ...bare, text, replyTo } });
  assert.deepEqual(sent(reply, peer), { kind: "reply", data: { ...bare, text } }, "no capability: both downgrades apply");
  const silent: Event = { kind: "reply", data: { ...bare, text: "", attachments: [attachments[0]!] } };
  assert.deepEqual(sent(silent, peer), { kind: "reply", data: { ...bare, text: note("a.png") } }, "an empty text adds no blank lines");
});

test("downgrade strips replyTo and reactions from history items, each by its own capability", () => {
  const user = { kind: "user", id: messageId, seq: 1, ts: 1, text: "question" } as const;
  const agent = { kind: "agent", id: otherId, seq: 2, ts: 2, text: "answer", attachments } as const;
  const tools: HistoryItem = { kind: "tools", id: "t", seq: 3, ts: 3, tools: [{ callId: "c", name: "n", status: "done" }] };
  const reset: HistoryItem = { kind: "reset", id: "r", seq: 4, ts: 4 };
  const page = { convId, more: false, rev: 7 };
  const history = (first: HistoryItem, second: HistoryItem): Event => ({ kind: "history", data: { ...page, items: [first, second, tools, reset] } });
  const full = history({ ...user, reactions: { agent: "👍" } }, { ...agent, replyTo, reactions: { user: "🎉" } });

  assert.equal(downgrade(full, can(REPLIES, REACTIONS)), full);
  assert.deepEqual(sent(full, can(REACTIONS)), history({ ...user, reactions: { agent: "👍" } }, { ...agent, reactions: { user: "🎉" } }));
  assert.deepEqual(sent(full, can(REPLIES)), history(user, { ...agent, replyTo }));
  assert.deepEqual(sent(full, peer), history(user, agent), "history keeps its attachments: only a reply's become text");

  const request: Event = { kind: "history", data: { convId, before: 5 } };
  assert.deepEqual(downgrade(request, peer), request, "a history request has no items to strip");
});

test("broadcast sends a reaction only to peers with reactions", async () => {
  const h = host();
  const plain = await h.connect();
  const reactor = await h.connect(newDevice());
  const pending = await h.connect(newDevice());
  await plain.send(hello);
  await reactor.send(helloWith(REACTIONS));
  const reaction: Event = { kind: "reaction", data: { convId, messageId, emoji: "👍", by: "agent" } };

  assert.equal(h.hub.broadcast([reaction]), 2, "the count is live sessions, whether or not each took the event");
  assert.deepEqual(plain.sent, [], "nothing is sent on a link whose peer takes no event");
  assert.deepEqual(reactor.drain(), [reaction]);

  assert.equal(h.hub.broadcast([reaction, answer]), 2);
  assert.deepEqual(plain.drain(), [answer]);
  assert.deepEqual(reactor.drain(), [reaction, answer]);
  assert.deepEqual(pending.sent, []);
});

test("broadcast sends direct_hints only to peers listing direct, and only while the host has hints", async () => {
  let hints: DirectHints | undefined = { port: 4433, lan: [{ address: "192.0.2.7", prefix: 24 }], tailscale: [] };
  const h = host({ directHints: () => hints });
  const plain = await h.connect();
  const direct = await h.connect(newDevice());
  await plain.send(hello);
  await direct.send(helloWith(DIRECT));
  const event: Event = { kind: "direct_hints", data: hints };
  assert.deepEqual(plain.sent, []);
  assert.deepEqual(direct.wire(), [event], "peer_info from a direct peer is answered with the hints");

  assert.equal(h.hub.broadcast([event, answer]), 2);
  assert.deepEqual(plain.wire(), [answer]);
  assert.deepEqual(direct.wire(), [event, answer]);

  hints = undefined;
  assert.equal(h.hub.broadcast([event]), 2);
  assert.deepEqual(plain.sent, []);
  assert.deepEqual(direct.sent, [], "no hints on the host: nobody gets direct_hints");
  assert.equal(h.hub.broadcast([event, answer]), 2);
  assert.deepEqual(plain.wire(), [answer]);
  assert.deepEqual(direct.wire(), [answer]);
});

test("every copy of a message is answered with delivered, and onMessage runs once per messageId", async () => {
  const h = host();
  const a = await h.connect();
  const b = await h.connect(newDevice());
  await a.send(hello);
  await b.send(hello);
  const message: Event = { kind: "message", data: { convId, messageId, text: "once" } };
  const delivered: Event = { kind: "delivered", data: { convId, messageId } };

  await a.send(message);
  assert.deepEqual(h.messages, [message.data]);
  assert.deepEqual(a.drain(), [delivered]);
  assert.deepEqual(b.drain(), [delivered], "delivered goes to every live device");

  await a.send(message);
  assert.deepEqual(h.messages, [message.data], "the second copy does not reach onMessage");
  assert.deepEqual(a.drain(), [delivered], "the second copy is still answered");
  assert.deepEqual(b.drain(), [delivered]);

  await b.send({ kind: "message", data: { convId, messageId, text: "same id, another device and text" } });
  assert.deepEqual(h.messages, [message.data], "the id alone decides, whichever device sends it");
  assert.deepEqual(a.drain(), [delivered]);
  assert.deepEqual(b.drain(), [delivered]);

  const next: Event = { kind: "message", data: { convId, messageId: otherId, text: "twice" } };
  await a.send(next);
  assert.deepEqual(h.messages, [message.data, next.data], "a new id is taken");
  assert.deepEqual(a.drain(), [{ kind: "delivered", data: { convId, messageId: otherId } }]);
});

test("a live session answers an invalid or unknown event with its rejection and stays live", async () => {
  let dispatched = 0;
  const h = host({ dispatch: async () => { dispatched++; return false; } });
  const a = await h.connect();
  await a.send(hello);
  const error = (data: object): Event[] => [{ kind: "error", data } as Event];
  const refused = (name: string) => `"${name}" was refused: it breaks the protocol's limits (${LIMITS})`;

  await a.send({ kind: "message", data: { convId, messageId, text: 5 } } as unknown as Event);
  assert.deepEqual(a.drain(), error({ code: "bad_request", message: refused("message"), convId, messageId }), "the ids it could read come back");
  await a.send({ kind: "typing", data: { convId: "not-an-id", active: true } } as Event);
  assert.deepEqual(a.drain(), error({ code: "bad_request", message: refused("typing") }), "an unreadable id is not echoed");

  await a.send({ kind: "someday", data: { convId, messageId } } as unknown as Event);
  assert.deepEqual(a.drain(), error({ code: "unsupported", message: 'this host does not handle "someday"' }));
  await a.send({ kind: "direct_hints", data: { port: 1, lan: [], tailscale: [] } });
  assert.deepEqual(a.drain(), error({ code: "unsupported", message: 'this host does not handle "direct_hints"' }), "direct_hints is host to client only");

  assert.deepEqual(h.messages, [], "an invalid message is neither taken nor answered with delivered");
  assert.equal(dispatched, 0);
  assert.deepEqual(a.closed, []);
  assert.equal(h.hub.served.get(h.deviceKey)?.phase, "live");
  assert.equal(h.hub.broadcast([answer]), 1);
  assert.deepEqual(a.drain(), [answer]);
});

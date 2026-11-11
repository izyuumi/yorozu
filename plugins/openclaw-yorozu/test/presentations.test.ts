// Cards end to end without OpenClaw: genui-host.js plays the Gateway, and the plugin's own `deliver`, reply
// events, history pages, card store and conversation delete run as shipped.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync } from "node:fs";
import { test } from "node:test";
import "./genui-hooks.ts";
import { host } from "./genui-host.js";
import { hello, host as hubHost, newDevice } from "./hub-host.ts";
import type { Event, PeerInfo, Reply } from "../src/envelope.ts";
import type { PresentationSdk } from "../src/presentation.ts";

const { handleMessage } = await import("../src/conversation.ts");
const { historyPage } = await import("../src/history.ts");
const { applyPatch } = await import("../src/sessions.ts");
const { downgrade } = await import("../src/hub.ts");
const { encodeEvent, PEER_INFO, PRESENTATION } = await import("../src/envelope.ts");
const { CARD_INDEX, CARDS, cardKey, cardStore, MESSAGE_TOOL, MESSAGE_TOOL_HINTS, PRESENTATION_CAPABILITIES } = await import("../src/cards.ts");
const { MAX_PRESENTATION_BYTES, sanitizePresentation } = await import("../src/presentation.ts");

// The SDK's part, as in presentation.test.ts: blocks pass as they are, alt is a plain rendering.
const sdk: PresentationSdk = {
  normalize: (raw) => raw,
  tableAlt: (b) => `${b.caption}\n${b.headers.join(", ")}\n${b.rows.map((r) => r.join(", ")).join("\n")}`,
  chartAlt: (b) => b.chartType === "pie" ? `${b.title}\n${b.segments.map((s) => `${s.label}: ${s.value}`).join("\n")}`
    : `${b.title}\n${b.series.map((s) => `${s.name}: ${s.values.join(", ")}`).join("\n")}`,
};
const card = () => ({
  title: "Trip costs",
  tone: "info",
  blocks: [
    { type: "text", text: "Totals per traveler." },
    { type: "divider" },
    { type: "table", caption: "Costs", headers: ["Traveler", "Paid"], rows: [["Traveler A", 120], ["Traveler B", 80]], rowHeaderColumnIndex: 0 },
    { type: "chart", chartType: "bar", title: "Paid", categories: ["Traveler A", "Traveler B"], series: [{ name: "Paid", values: [120, 80] }] },
    { type: "buttons", buttons: [{ label: "Approve", value: "cb:approve", command: "/approve 7" }] },
    { type: "select", options: [{ label: "Pick", value: "cb:pick" }] },
    { type: "context", text: "As of today.", approvalId: "approval-7", callback: "cb:context" },
  ],
});
const text = "Here are the costs.";
const DROPPED = "yorozu: dropped a card that cannot be shown; its text was sent";

const uuid = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;
const userId = uuid(1);
const sessionKey = (convId: string) => `agent:main:yorozu:direct:owner:thread:${convId}`;
/** A conversation whose transcript already holds the turn: the user's message and the agent's answer. */
function conversation(n: number, answer = text) {
  const convId = uuid(n * 100);
  const sessionId = `session-${n}`;
  const eventId = uuid(n * 100 + 1);
  host.sessions.set(sessionKey(convId), { sessionId, label: "Trip" });
  host.transcripts.set(sessionId, [
    { type: "message", id: `user-${n}`, message: { role: "user", content: "Show me the costs", timestamp: 1_700_000_000_000, __openclaw: { transport: { messageId: userId } } } },
    { type: "message", id: eventId, message: { role: "assistant", content: answer, timestamp: 1_700_000_001_000 } },
  ]);
  return { convId, sessionId, eventId, key: cardKey(sessionId, eventId) };
}

const warnings: string[] = [];
/** One turn: OpenClaw hands `payloads` to the plugin's `deliver`; the replies every device would get. */
async function turn(convId: string, payloads: { text?: string; presentation?: unknown }[], cfg: object = {}): Promise<Reply[]> {
  host.sent.length = 0;
  warnings.length = 0;
  host.run = async (deliver: (payload: unknown, info: { kind: string }) => Promise<void>) => {
    for (const payload of payloads) await deliver(payload, { kind: "final" });
  };
  const log = { info() {}, warn: (line: string) => void warnings.push(line), error() {}, debug() {} };
  await handleMessage({ cfg, accountId: "default", agent: "main", mediaMaxBytes: 1, presentationSdk: sdk, log } as never, { convId, messageId: userId, text: "Show me the costs" });
  assert.deepEqual(host.sent.filter((event: Event) => event.kind === "error"), []);
  return host.sent.filter((event: Event) => event.kind === "reply").map((event: Event) => event.data as Reply);
}
const rows = (namespace: string): Map<string, unknown> => host.stores.get(namespace) ?? new Map();
const page = async (convId: string, cfg: object = {}) => (await historyPage(cfg as never, "main", { convId })).items;

const peer = { app: "test", protocolMin: 3, protocolMax: 3 };
/** The capabilities of the app before cards, and the same app with them. */
const oldApp: PeerInfo = { ...peer, capabilities: ["attachments", "devices", "replies", "reactions", "resume", "direct", "unversioned-wire"] };
const newApp: PeerInfo = { ...peer, capabilities: [...oldApp.capabilities, PRESENTATION] };
const json = (event: Event) => encodeEvent(event).toString("utf8");

test("the channel declares cards to OpenClaw, to the agent and to the apps", () => {
  assert.deepEqual(MESSAGE_TOOL, { actions: ["react"], capabilities: ["presentation"] });
  assert.deepEqual(PRESENTATION_CAPABILITIES, { supported: true, context: true, divider: true, tables: true, charts: true, buttons: false, selects: false });
  assert.equal(PRESENTATION, "presentation");
  assert.ok(PEER_INFO.capabilities.includes(PRESENTATION));
  const hints = MESSAGE_TOOL_HINTS.join("\n");
  assert.ok(hints.includes("Use a card only for data that is genuinely tabular or chartable, or for a short titled summary. For anything else, reply in plain text."));
  assert.ok(hints.includes("When the user asks to see a card, chart, table or demo, send it in the same turn; do not ask first."));
  assert.match(hints, /in the Yorozu app .*not Signal/);
  assert.match(hints, /`presentation`.*`title`.*`text`, `context`, `divider`, `table` or `chart`/);
  assert.match(hints, /plain text is always sent alongside/);
  assert.doesNotMatch(hints, /button|select|slider|approv/i);
});

test("a table and chart card goes out with its text, alt on every block, and no controls", async () => {
  const { convId } = conversation(1);
  const [reply, ...rest] = await turn(convId, [{ text, presentation: card() }]);
  assert.deepEqual(rest, []);
  assert.equal(reply?.text, text);
  const sent = reply?.presentation;
  assert.equal(sent?.title, "Trip costs");
  assert.equal(sent?.tone, "info");
  assert.deepEqual(sent?.blocks.map((b) => b.type), ["text", "divider", "table", "chart", "context"]);
  for (const block of sent?.blocks ?? []) {
    assert.equal(typeof block.alt, "string");
    assert.equal(block.alt.length > 0, block.type !== "divider", block.type);
  }
  assert.deepEqual(sent?.blocks[4], { type: "context", text: "As of today.", alt: "As of today." });
  assert.doesNotMatch(JSON.stringify(reply), /cb:|approv|command|callback|buttons|select|Pick/i);
  assert.deepEqual(warnings, []);
});

test("the card is on the last chunk only, and every chunk's text goes out as it does without a card", async () => {
  const { convId } = conversation(2);
  const plain = await turn(convId, [{ text }], { limit: 8 });
  const carded = await turn(convId, [{ text, presentation: card() }], { limit: 8 });
  assert.equal(plain.length, 3);
  assert.equal(carded.map((reply) => reply.text).join(""), text);
  assert.deepEqual(carded.map((reply) => "presentation" in reply), [false, false, true]);
  const { presentation: _, ...last } = carded[2]!;
  assert.equal(JSON.stringify([carded[0], carded[1], last]), JSON.stringify(plain));
});

test("empty text becomes the card's fallback text, and a card-only payload is delivered", async () => {
  const { convId } = conversation(3);
  const { fallbackText } = sanitizePresentation(card(), sdk);
  assert.match(fallbackText, /^Trip costs\n\nTotals per traveler\.\n\nCosts\n/);
  for (const payload of [{ presentation: card() }, { text: "  \n", presentation: card() }]) {
    const replies = await turn(convId, [payload]);
    assert.equal(replies.length, 1);
    assert.equal(replies[0]?.text, fallbackText);
    assert.equal(replies[0]?.presentation?.blocks.length, 5);
  }
});

test("an oversized or invalid card is dropped with one content-free log line, and the text goes out unchanged", async () => {
  const { convId } = conversation(4);
  const plain = JSON.stringify(await turn(convId, [{ text }]));
  const oversized = JSON.stringify({ title: "Secret title", blocks: [{ type: "text", text: "x".repeat(MAX_PRESENTATION_BYTES) }] });
  const bad: unknown[] = [
    oversized, 42, "not json", [], { blocks: "Secret title" }, { title: "Secret title" },
    { blocks: [{ type: "buttons", buttons: [{ label: "Secret title", value: "cb" }] }] },
    { blocks: [{ type: "unknown", text: "Secret title" }] },
    { blocks: [{ type: "divider" }, { type: "divider" }] },
  ];
  for (const presentation of bad) {
    const replies = await turn(convId, [{ text, presentation }]);
    assert.equal(JSON.stringify(replies), plain, JSON.stringify(presentation).slice(0, 60));
    assert.deepEqual(warnings, [DROPPED]);
  }
  assert.deepEqual(await turn(convId, [{ presentation: oversized }, { text: "", presentation: 42 }]), [], "nothing to say: nothing sent, as before");
  assert.equal(rows("presentation-index").has(convId), false, "a dropped card is not stored");

  // An object over the limit is cut to fit by the sanitizer (trailing blocks become a note), not dropped.
  const big = { blocks: Array.from({ length: 40 }, (_, i) => ({ type: "text", text: `${i}:` + "界".repeat(2000) })) };
  const [reply] = await turn(convId, [{ text, presentation: big }]);
  assert.equal(reply?.text, text);
  assert.ok(reply?.presentation && Buffer.byteLength(JSON.stringify(reply.presentation)) <= MAX_PRESENTATION_BYTES);
  assert.match(reply.presentation.blocks.at(-1)?.alt ?? "", /more blocks omitted/);
});

test("a session without the capability gets no presentation key on a reply or a history page; one with it gets card and text", async () => {
  const { convId } = conversation(5);
  const [data] = await turn(convId, [{ text, presentation: card() }]);
  assert.ok(data?.presentation);
  const reply: Event = { kind: "reply", data };
  const history: Event = { kind: "history", data: await historyPage({} as never, "main", { convId }) };
  assert.match(json(history), /"presentation":\{"title":"Trip costs"/);

  for (const event of [reply, history]) {
    assert.equal(downgrade(event, newApp), event, "with the capability the event goes as it is");
    assert.doesNotMatch(json(downgrade(event, oldApp)), /presentation|Traveler A/);
    assert.doesNotMatch(json(downgrade(event, { ...peer, capabilities: [] })), /presentation|Traveler A/);
  }
  const { presentation: _, ...bare } = data;
  assert.equal(json(downgrade(reply, oldApp)), json({ kind: "reply", data: bare }));
  const old = downgrade(history, oldApp);
  assert.ok(old.kind === "history" && "items" in old.data);
  assert.deepEqual(old.data.items.map((item) => [item.kind, "text" in item && item.text, Object.hasOwn(item, "presentation")]), [
    ["user", "Show me the costs", false], ["agent", text, false],
  ]);
});

test("two devices are gated each on its own peer_info", async () => {
  const { convId } = conversation(6);
  const [data] = await turn(convId, [{ text, presentation: card() }]);
  const reply: Event = { kind: "reply", data: data! };
  const history: Event = { kind: "history", data: await historyPage({} as never, "main", { convId }) };
  const h = hubHost({ dispatch: async (request) => (request.reply([history]), true) });
  const phone = await h.connect();
  const tablet = await h.connect(newDevice());
  await phone.send({ kind: "peer_info", data: newApp });
  await tablet.send(hello);

  assert.equal(h.hub.broadcast([reply]), 2);
  await phone.send({ kind: "history", data: { convId } });
  await tablet.send({ kind: "history", data: { convId } });
  const [phoneReply, phoneHistory] = phone.wire() as { data: { text?: string; presentation?: unknown; items?: Record<string, unknown>[] } }[];
  const [tabletReply, tabletHistory] = tablet.wire() as typeof phoneReply[];
  assert.deepEqual(phoneReply?.data.presentation, data?.presentation);
  assert.equal(phoneReply?.data.text, text);
  assert.deepEqual(phoneHistory?.data.items?.[1]?.presentation, data?.presentation);
  assert.equal(tabletReply?.data.text, text);
  assert.equal(Object.hasOwn(tabletReply!.data, "presentation"), false);
  assert.deepEqual(tabletHistory?.data.items?.map((item) => [item.text, Object.hasOwn(item, "presentation")]), [["Show me the costs", false], [text, false]]);
});

test("a stored card comes back on the history page, on the agent message's last chunk", async () => {
  const one = conversation(7);
  const [reply] = await turn(one.convId, [{ text, presentation: card() }]);
  assert.deepEqual([...rows("presentations").keys()].filter((key) => key.startsWith(one.sessionId)), [one.key]);
  assert.deepEqual(rows("presentation-index").get(one.convId), [one.key]);
  const [user, agent] = await page(one.convId);
  assert.equal(user && "presentation" in user, false);
  assert.deepEqual(agent, { kind: "agent", id: reply?.messageId, seq: 1, ts: reply?.ts, text, presentation: reply?.presentation });

  const many = conversation(8);
  const live = await turn(many.convId, [{ text, presentation: card() }], { limit: 8 });
  const items = (await page(many.convId, { limit: 8 })).filter((item) => item.kind === "agent");
  assert.deepEqual(items.map((item) => item.id), live.map((r) => r.messageId));
  assert.deepEqual(items.map((item) => "presentation" in item), [false, false, true]);
});

test("a reply without transcript ids stores nothing", async () => {
  const convId = uuid(900);
  const before = rows("presentations").size;
  const [reply] = await turn(convId, [{ text, presentation: card() }]);
  assert.equal(reply?.presentation?.title, "Trip costs", "the card is still sent");
  assert.notEqual(reply?.messageId, undefined);
  assert.equal(rows("presentations").size, before);
  assert.equal(rows("presentation-index").has(convId), false);
});

test("the store keeps 10,000 cards and drops the oldest; an evicted card leaves the history item as text", async () => {
  assert.deepEqual(CARDS, { namespace: "presentations", maxEntries: 10_000, overflowPolicy: "evict-oldest" });
  assert.deepEqual(CARD_INDEX, { namespace: "presentation-index", maxEntries: 10_000, overflowPolicy: "evict-oldest" });
  const convs = [conversation(10), conversation(11), conversation(12)];
  rows("presentations").clear();
  host.cap = 2;
  try {
    for (const { convId } of convs) await turn(convId, [{ text, presentation: card() }]);
  } finally {
    host.cap = undefined;
  }
  assert.deepEqual([...rows("presentations").keys()], [convs[1]!.key, convs[2]!.key]);
  const shown = await Promise.all(convs.map(async ({ convId }) => (await page(convId)).map((item) => "presentation" in item)));
  assert.deepEqual(shown, [[false, false], [false, true], [false, true]]);
  assert.deepEqual((await page(convs[0]!.convId))[1], { kind: "agent", id: convs[0]!.eventId, seq: 1, ts: 1_700_000_001_000, text });
});

test("card store: put and get by key, listed per conversation, forgotten together", async () => {
  const maps = [new Map<string, never>(), new Map<string, never>()];
  const keyed = (map: Map<string, never>) => () => ({
    register: async (key: string, value: never) => void map.set(key, value),
    lookup: async (key: string) => map.get(key),
    delete: async (key: string) => map.delete(key),
  });
  const store = cardStore(keyed(maps[0]!), keyed(maps[1]!));
  const a = sanitizePresentation({ title: "A", blocks: [{ type: "text", text: "a" }] }, sdk).presentation!;
  const b = sanitizePresentation({ title: "B", blocks: [{ type: "text", text: "b" }] }, sdk).presentation!;
  assert.equal(cardKey("s", "e"), "s:e");
  await Promise.all([store.put("conv-1", "s1:e1", a), store.put("conv-1", "s1:e2", b), store.put("conv-1", "s1:e1", b), store.put("conv-2", "s2:e1", a)]);
  assert.deepEqual(await store.get("s1:e1"), b);
  assert.deepEqual(await store.get("s1:e2"), b);
  assert.equal(await store.get("s1:e3"), undefined);
  assert.deepEqual([...await store.keys("conv-1")], ["s1:e1", "s1:e2"]);
  assert.deepEqual([...await store.keys("conv-3")], []);
  await store.forget("conv-1");
  assert.deepEqual([...maps[0]!.keys()], ["s2:e1"]);
  assert.deepEqual([...maps[1]!.keys()], ["conv-2"]);
  await store.forget("conv-1");
});

test("deleting a conversation deletes its stored cards in the same operation; its history then has no card", async () => {
  const gone = conversation(20);
  const kept = conversation(21);
  for (const { convId } of [gone, kept]) await turn(convId, [{ text, presentation: card() }]);
  assert.deepEqual((await page(gone.convId)).map((item) => "presentation" in item), [false, true]);
  const entry = host.sessions.get(sessionKey(gone.convId));

  assert.equal(await applyPatch("main", { convId: gone.convId, deleted: true }), undefined);
  assert.equal(host.sessions.has(sessionKey(gone.convId)), false);
  assert.equal(rows("presentations").has(gone.key), false);
  assert.equal(rows("presentation-index").has(gone.convId), false);
  assert.equal(rows("presentations").has(kept.key), true);
  assert.deepEqual((await page(gone.convId)), []);

  // The archived transcript opened again under the same session: text only.
  host.sessions.set(sessionKey(gone.convId), entry);
  assert.deepEqual(await page(gone.convId), [
    { kind: "user", id: userId, seq: 0, ts: 1_700_000_000_000, text: "Show me the costs" },
    { kind: "agent", id: gone.eventId, seq: 1, ts: 1_700_000_001_000, text },
  ]);
  assert.deepEqual((await page(kept.convId)).map((item) => "presentation" in item), [false, true]);
});

// What a capable session, an old app's session and a history request get for one card reply, as the JSON inside the
// sealed box. GenUIReplayTests decodes these exact strings with the Swift decoders.
// Regenerate with UPDATE_FIXTURES=1 only when the card format changes on purpose.
const fixtureUrl = new URL("../../../packages/YorozuWire/Tests/YorozuWireTests/Fixtures/genui-wire.json", import.meta.url);

test("the wire fixture the Swift decoders replay is what the plugin sends", async () => {
  const { convId } = conversation(30);
  const [data] = await turn(convId, [{ text, presentation: card() }]);
  const reply: Event = { kind: "reply", data: data! };
  const history: Event = { kind: "history", data: await historyPage({} as never, "main", { convId }) };
  const built = {
    reply: json(downgrade(reply, newApp)),
    replyOldApp: json(downgrade(reply, oldApp)),
    history: json(downgrade(history, newApp)),
  };
  if (process.env.UPDATE_FIXTURES) writeFileSync(fixtureUrl, `${JSON.stringify(built, null, 2)}\n`);
  assert.deepEqual(built, JSON.parse(readFileSync(fixtureUrl, "utf8")));
  assert.match(built.reply, /"presentation":\{"title":"Trip costs","tone":"info","blocks":\[/);
  assert.doesNotMatch(built.replyOldApp, /presentation/);
  assert.match(built.history, /"kind":"agent".*"presentation":\{/);
});

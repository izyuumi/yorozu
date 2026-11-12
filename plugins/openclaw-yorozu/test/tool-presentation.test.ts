import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import "./genui-hooks.ts";
import { host } from "./genui-host.js";
import { prepareToolPresentation, MAX_BLOCKS, MAX_PRESENTATION_BYTES } from "../src/presentation.ts";
const { setThreadBase } = await import("../src/sessions.ts");
const { CARD_GUIDANCE, MESSAGE_TOOL_HINTS } = await import("../src/cards.ts");

const { default: entry } = await import("../index.ts");
type Params = Record<string, unknown>;
type Hook = (event: { toolName: string; params: Params }, ctx: { agentId?: string; sessionKey?: string }) => { params: Params } | undefined;
type PromptHook = (event: unknown, ctx: { agentId?: string; sessionKey?: string }) => { appendSystemContext: string } | undefined;
const hooks = new Map<string, unknown>();
(entry as unknown as { registerFull(api: unknown): void }).registerFull({
  on(name: string, handler: unknown) { assert.ok(!hooks.has(name)); hooks.set(name, handler); },
  registerGatewayMethod() {},
});
assert.deepEqual([...hooks.keys()].sort(), ["before_prompt_build", "before_tool_call"]);
const hook = hooks.get("before_tool_call") as Hook;
const promptHook = hooks.get("before_prompt_build") as PromptHook;
const convId = "11111111-1111-4111-8111-111111111111";
const ctx = { agentId: "main", sessionKey: `agent:main:yorozu:direct:owner:thread:${convId}` };
const table = () => ({ type: "table", title: "Balances", headers: ["Who", "Paid"], rows: [["A", 120], ["B", 0]], rowHeaderColumnIndex: 0 });
const prepare = (block: Record<string, unknown>) => prepareToolPresentation({ blocks: [block] }) as { blocks: Record<string, unknown>[] };
const send = (params: Params, context: Parameters<Hook>[1] = ctx, toolName = "message") => hook({ toolName, params }, context)?.params ?? params;

test("title-only tables gain only caption; valid captions and other blocks preserve identity", () => {
  for (const caption of [undefined, "", "   ", null]) {
    const block = { ...table(), caption };
    const before = structuredClone(block);
    assert.deepEqual(prepare(block).blocks, [{ ...block, caption: "Balances" }]);
    assert.deepEqual(block, before);
  }
  for (const raw of [
    { blocks: [{ ...table(), caption: "Already captioned" }] },
    { blocks: [{ type: "text", text: "Plain" }, { type: "chart", title: "Chart" }] },
    { blocks: [] },
  ]) assert.equal(prepareToolPresentation(raw), raw);
});

test("unshowable tables become bounded primitive summaries with an explicit omission reason", () => {
  const { title: _, ...untitled } = table();
  for (const block of [
    untitled, { ...table(), title: " " }, { ...table(), rows: [["A"]] },
    { ...table(), headers: ["Who", "Who"] }, { ...table(), headers: [] },
    { ...table(), rows: [["A", null]] }, { ...table(), rows: [["A", false]] },
    { ...table(), rows: [["A", Infinity]] }, { ...table(), rows: [["A", " "]] },
    ...[-1, 2, 0.5, "0", null, {}].map((rowHeaderColumnIndex) => ({ ...table(), rowHeaderColumnIndex })),
  ]) {
    const [summary] = prepare(block).blocks;
    assert.equal(summary?.type, "context");
    assert.match(String(summary?.text), /\(table omitted: invalid data\)$/);
    assert.match(String(summary?.text), /A/);
  }
  assert.deepEqual(prepare(untitled).blocks, [{
    type: "context", text: "A, 120\nB, 0\n(table omitted: invalid data)", alt: "A, 120\nB, 0\n(table omitted: invalid data)",
  }]);
});

test("JSON presentations repair tables; malformed or over-budget inputs never throw", () => {
  const raw = JSON.stringify({ blocks: [table()] });
  assert.deepEqual(JSON.parse(prepareToolPresentation(raw) as string), { blocks: [{ ...table(), caption: "Balances" }] });
  const valid = ' { "blocks": [{"type":"table","caption":"Kept","headers":["A"],"rows":[[1]]}] } ';
  assert.equal(prepareToolPresentation(valid), valid);
  const hostile = new Proxy({}, { getOwnPropertyDescriptor() { throw new Error("hostile"); } });
  for (const input of ["{", "x".repeat(MAX_PRESENTATION_BYTES + 1), hostile, { blocks: Array(MAX_BLOCKS + 1).fill(table()) }]) {
    assert.equal(prepareToolPresentation(input), input);
  }
});

test("registered hook scopes repairs to message tools targeting Yorozu, retaining untouched params", () => {
  const params = { channel: "yorozu", presentation: { blocks: [table()] }, text: "Keep text" };
  const fixed = send(params);
  assert.notEqual(fixed, params);
  assert.equal(fixed.text, params.text);
  for (const input of [
    { text: "Plain", channel: "yorozu" },
    { ...params, presentation: { blocks: [{ ...table(), caption: "Kept" }] } },
    { ...params, channel: "signal" }, { ...params, channel: "" },
  ]) assert.equal(send(input), input);
  assert.equal(send(params, ctx, "exec"), params);
  const implicit = { presentation: params.presentation };
  assert.equal(send(implicit, {}), implicit);
  assert.equal(send(implicit, { ...ctx, sessionKey: "agent:main:signal:direct:owner" }), implicit);
  assert.equal(send(implicit, { ...ctx, sessionKey: ctx.sessionKey + ":other" }), implicit);
  assert.notEqual(send(implicit, { sessionKey: ctx.sessionKey }), implicit);
  assert.notEqual(send(implicit), implicit);
  const encoded = send({ channel: "yorozu", presentation: JSON.stringify(params.presentation) });
  assert.equal(JSON.parse(encoded.presentation as string).blocks[0].caption, "Balances");
  setThreadBase("bound", "agent:bound:linked:owner");
  assert.notEqual(send(implicit, { agentId: "bound", sessionKey: `agent:bound:linked:owner:thread:${convId}` }), implicit);
});

test("prompt hook appends card guidance only to Yorozu sessions, so a replaced system prompt keeps it", () => {
  const event = { prompt: "Show a table" };
  assert.deepEqual(promptHook(event, ctx), { appendSystemContext: CARD_GUIDANCE });
  assert.deepEqual(promptHook(event, { sessionKey: ctx.sessionKey }), { appendSystemContext: CARD_GUIDANCE });
  for (const context of [
    {}, { agentId: "main" }, { ...ctx, sessionKey: "agent:main:signal:direct:owner" },
    { ...ctx, sessionKey: ctx.sessionKey + ":other" }, { ...ctx, sessionKey: "agent:main:telegram:direct:owner:thread:" + convId },
  ]) assert.equal(promptHook(event, context), undefined);
  assert.ok(CARD_GUIDANCE.startsWith("## Yorozu app"));
  for (const hint of MESSAGE_TOOL_HINTS) assert.ok(CARD_GUIDANCE.includes(hint));
  assert.match(CARD_GUIDANCE, /`presentation`, never a markdown pipe table/);
  assert.match(CARD_GUIDANCE, /never send tables apply to Signal, not to Yorozu cards/);
  // OpenClaw: developerInstructions = prependSystemContext + systemPrompt (first hook's wins) + every appendSystemContext.
  const replaced = ["# PAIOS Runtime Bridge\nSignal formatting: never send tables.", promptHook(event, ctx)?.appendSystemContext].join("\n\n");
  assert.ok(replaced.includes("## Yorozu app"));
  assert.ok(replaced.endsWith(CARD_GUIDANCE));
});

test("message-tool table survives hook, pinned core normalization and wire delivery", async () => {
  const fixture = JSON.parse(readFileSync(new URL("fixtures/presentation-sdk-2026.9.8.json", import.meta.url), "utf8"));
  const pin = fixture.cases.find((item: { name: string }) => item.name === "valid table");
  // The existing SDK fixture pins real core output; core ignores a table's extra title.
  const normalize = (raw: unknown) => {
    const { blocks } = raw as { blocks: Record<string, unknown>[] };
    assert.deepEqual({ blocks: blocks.map(({ title: _, ...block }) => block) }, pin.input);
    return structuredClone(pin.normalized);
  };
  const params = send({ channel: "yorozu", presentation: { blocks: [table()] }, text: "Keep text" });
  const presentation = normalize(params.presentation);
  const { sendConversationPayload } = await import("../src/conversation.ts");
  host.sent.length = 0;
  await sendConversationPayload({
    cfg: {}, threadId: convId, text: params.text, presentation, mediaUrls: [], maxBytes: 1, access: {},
    sdk: { normalize, tableAlt: () => "Balances\nWho, Paid\nA, 120\nB, 0", chartAlt: () => "" },
  } as never);
  const { encodeEvent } = await import("../src/envelope.ts");
  const reply = host.sent.find((event: { kind: string }) => event.kind === "reply");
  const wire = JSON.parse(encodeEvent(reply).toString("utf8"));
  assert.equal(wire.data.text, "Keep text");
  assert.deepEqual(wire.data.presentation.blocks, [{ ...pin.normalized.blocks[0], alt: "Balances\nWho, Paid\nA, 120\nB, 0" }]);
});

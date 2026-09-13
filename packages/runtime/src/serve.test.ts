import { randomUUID } from "node:crypto";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay, type Relay } from "@yorozu/relay";
import { connectPhone, rejoinPhone } from "@yorozu/relay/dist/testing.js";
import {
  decodeQrPayload,
  deriveSessionKey,
  fromBase64Url,
  generateKeypair,
  open,
  seal,
  threadRef,
  toBase64Url,
  type ApprovalCardData,
  type EventKind,
  type EventPayload,
  type QrPayload,
  type YorozuEvent,
} from "@yorozu/shared";
import { listRules, type AskResult, type Rule } from "./approval.js";
import type { AddressInfo } from "node:net";
import { afterEach, expect, test, vi } from "vitest";
import { WebSocketServer } from "ws";
import { openaiCompat } from "./provider.js";
import { loadDevices, serve, typedAnswer, type Sidecar } from "./serve.js";

let relay: Relay;
let sidecar: Sidecar;

afterEach(async () => {
  await sidecar?.close();
  await relay?.close();
});

/** A one-turn chat completion, streamed the way the adapter expects it. */
const sse = (text: string) =>
  new Response(
    `data: ${JSON.stringify({ choices: [{ delta: { content: text }, finish_reason: "stop" }] })}\n\n` +
      "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );

const frameBody = (payload: string) => JSON.parse(Buffer.from(payload, "base64url").toString());

const encodeBody = (body: unknown) => toBase64Url(Buffer.from(JSON.stringify(body)));

test("a sealed message from a phone round-trips through the agent loop", async () => {
  relay = await startRelay(0);

  const lines: string[] = [];
  let qrLine!: (line: string) => void;
  const qrPrinted = new Promise<string>((resolve) => (qrLine = resolve));

  const fetchMock = vi.fn<typeof fetch>().mockImplementation(async () => sse("pong"));
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-serve-")),
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: fetchMock }),
    log: (line) => {
      lines.push(line);
      if (line.startsWith("QR ")) qrLine(line.slice(3));
    },
  });

  const qr = decodeQrPayload(await qrPrinted);
  expect(lines.filter((l) => l.startsWith("STATE "))).toEqual([
    "STATE connecting",
    "STATE connected",
    "STATE registered",
  ]);
  expect(qr.relayUrl).toBe(`ws://127.0.0.1:${relay.port}`);

  const { phone, keys } = await connectPhone(relay.port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });

  // The phone announces its X25519 key in the clear, then everything is sealed.
  const phoneKeys = generateKeypair();
  const sessionKey = deriveSessionKey(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(encodeBody({ t: "hello", pub: toBase64Url(phoneKeys.publicKey) }), keys);

  const sent: YorozuEvent = {
    id: "e1",
    threadId: "t1",
    ts: 1,
    agentId: "phone",
    kind: "message",
    data: { role: "user", text: "ping" },
  };
  const box = seal(sessionKey, Buffer.from(JSON.stringify(sent)));
  phone.frame(
    encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }),
    keys,
  );

  const openNext = async (): Promise<YorozuEvent> => {
    const body = frameBody((await phone.next()).payload);
    const plain = open(sessionKey, fromBase64Url(body.n), fromBase64Url(body.c));
    return JSON.parse(Buffer.from(plain).toString()) as YorozuEvent;
  };

  // Pairing is greeted with the thread list — empty, on a state dir nothing has happened in —
  // and the agent's reply follows it.
  expect(await openNext()).toMatchObject({ kind: "thread_list", data: { threads: [] } });
  // And what a thread can be put on, so the phone's model picker has names. Empty here: the
  // provider is injected by the test, so there is no providers.json to publish.
  expect(await openNext()).toMatchObject({ kind: "model_list", data: { models: [] } });
  // Pairing changed who the devices are, so the new list follows it.
  expect(await openNext()).toMatchObject({ kind: "device_list" });
  expect(await openNext()).toMatchObject({
    threadId: "t1",
    kind: "message",
    data: { role: "agent", text: "pong" },
  });
  expect(lines).toContain("STATE paired");
  expect(fetchMock.mock.calls[0]![0]).toBe("https://example.invalid/v1/chat/completions");
});

test("a phone rejoins a restarted sidecar without pairing again", async () => {
  relay = await startRelay(0);
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-rejoin-"));
  const fetchMock = vi.fn<typeof fetch>().mockImplementation(async () => sse("pong"));

  // Two sidecars in a row over one state dir: the second is the "restart".
  const start = () => {
    let qrLine!: (line: string) => void;
    const qr = new Promise<string>((resolve) => (qrLine = resolve));
    const cast = serve({
      relayUrl: `ws://127.0.0.1:${relay.port}`,
      stateDir,
      provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: fetchMock }),
      log: (line) => {
        if (line.startsWith("QR ")) qrLine(line.slice(3));
      },
    });
    return { cast, qr };
  };

  const first = start();
  const qr = decodeQrPayload(await first.qr);
  const { phone, keys } = await connectPhone(relay.port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });

  const phoneKeys = generateKeypair();
  const sessionKey = deriveSessionKey(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  const pub = toBase64Url(phoneKeys.publicKey);
  phone.frame(encodeBody({ t: "hello", pub }), keys);
  // The `hello` is what writes the phone into `devices.json`.
  await vi.waitFor(() =>
    expect(loadDevices(join(stateDir, "devices.json")).map((device) => device.pub)).toEqual([pub]),
  );

  phone.ws.close();
  await first.cast.close();

  // A rejoin: the one-time token is long burnt, so the phone proves itself to the relay against
  // the connect nonce, and says no `hello` — the restarted sidecar has to know it from disk.
  const second = start();
  sidecar = second.cast;
  await second.qr;
  const again = await rejoinPhone(relay.port, qr.roomId!, keys);
  expect(await again.next()).toMatchObject({ type: "joined" });

  const sent: YorozuEvent = {
    id: "e2",
    threadId: "home",
    ts: 2,
    agentId: "phone",
    kind: "message",
    data: { role: "user", text: "ping" },
  };
  const box = seal(sessionKey, Buffer.from(JSON.stringify(sent)));
  again.frame(encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }), keys);

  const body = frameBody((await again.next()).payload);
  const plain = open(sessionKey, fromBase64Url(body.n), fromBase64Url(body.c));
  expect(JSON.parse(Buffer.from(plain).toString())).toMatchObject({
    threadId: "home",
    kind: "message",
    data: { role: "agent", text: "pong" },
  });
});

/** A turn in which the model calls `shell`, which carries the `run-command` action class. */
const shellTurn = (cmd: string) =>
  new Response(
    `data: ${JSON.stringify({
      choices: [
        {
          delta: {
            tool_calls: [
              { index: 0, id: "call_1", function: { name: "shell", arguments: JSON.stringify({ cmd }) } },
            ],
          },
          finish_reason: "tool_calls",
        },
      ],
    })}\n\n` + "data: [DONE]\n\n",
    { headers: { "content-type": "text/event-stream" } },
  );

/**
 * The card that ended an `eventsUntil` batch. The batch also holds what led up to it — the
 * `tool_call` the gate stopped, for one — so the card is the last event, not the first.
 */
function cardOf(events: YorozuEvent[]): ApprovalCardData {
  const last = events.at(-1);
  if (last?.kind !== "approval_card") throw new Error(`expected a card, got ${last?.kind}`);
  return last.data;
}

/** A paired phone plus the session key, so a test can talk sealed events both ways. */
async function pairedPhone(responses: (() => Response)[]) {
  relay = await startRelay(0);
  const dir = mkdtempSync(join(tmpdir(), "yorozu-approval-serve-"));

  let qrLine!: (line: string) => void;
  const qrPrinted = new Promise<string>((resolve) => (qrLine = resolve));
  const queue = [...responses];

  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: dir,
    provider: openaiCompat({
      baseUrl: "https://example.invalid",
      model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => queue.shift()!()),
    }),
    log: (line) => {
      if (line.startsWith("QR ")) qrLine(line.slice(3));
    },
  });

  const qr = decodeQrPayload(await qrPrinted);
  const { phone, keys } = await connectPhone(relay.port, qr.roomId!, qr.token);
  await phone.next();

  const phoneKeys = generateKeypair();
  const sessionKey = deriveSessionKey(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(encodeBody({ t: "hello", pub: toBase64Url(phoneKeys.publicKey) }), keys);

  const send = (
    event: Omit<YorozuEvent, "id" | "threadId" | "ts" | "agentId">,
    threadId = "t1",
  ): void => {
    const full = { id: randomUUID(), threadId, ts: Date.now(), agentId: "phone", ...event };
    const box = seal(sessionKey, Buffer.from(JSON.stringify(full as YorozuEvent)));
    phone.frame(encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }), keys);
  };

  /** Everything the sidecar sends, up to and including the first event `done` accepts. */
  async function eventsUntil(done: (event: YorozuEvent) => boolean): Promise<YorozuEvent[]> {
    const seen: YorozuEvent[] = [];
    for (;;) {
      const body = frameBody((await phone.next()).payload);
      const plain = open(sessionKey, fromBase64Url(body.n), fromBase64Url(body.c));
      const event = JSON.parse(Buffer.from(plain).toString()) as YorozuEvent;
      seen.push(event);
      if (done(event)) return seen;
    }
  }

  const isReply = (event: YorozuEvent): boolean =>
    event.kind === "message" && event.data.role === "agent";

  return { dir, send, eventsUntil, isReply };
}

test("always runs the action and is permanent: the next one needs no second card", async () => {
  // Harmless, and its output is proof the gate let the tool run rather than refusing it.
  const cmd = "echo yorozu-always-ok";
  const { dir, send, eventsUntil, isReply } = await pairedPhone([
    () => shellTurn(cmd),
    () => sse("Done."),
    () => shellTurn(cmd),
    () => sse("Done again."),
  ]);

  send({ kind: "message", data: { role: "user", text: "tidy up" } });

  const batch = await eventsUntil((event) => event.kind === "approval_card");
  expect(batch.at(-1)).toMatchObject({
    kind: "approval_card",
    data: { actionClass: "run-command", target: cmd },
  });
  const { actionId } = cardOf(batch);

  send({ kind: "approval_answer", data: { actionId, answer: "always" } });
  // A result at all means the gate let the tool run: always is a yes as well as a rule.
  const ran = (events: YorozuEvent[]) =>
    events.at(-1)?.kind === "tool_result" && events.at(-1)?.data.output.includes("yorozu-always-ok");
  expect(ran(await eventsUntil((event) => event.kind === "tool_result"))).toBe(true);
  await eventsUntil(isReply);

  // The rule is on disk, scoped to the command the card actually showed rather than to every
  // command there is, so the identical action must not reach the phone a second time.
  expect(JSON.parse(readFileSync(join(dir, "approval.json"), "utf8")).rules).toMatchObject([
    {
      actionClass: "run-command",
      decision: "always",
      scope: { target: { mode: "exact", value: cmd }, operation: { mode: "exact", value: "run" } },
    },
  ]);

  send({ kind: "message", data: { role: "user", text: "tidy up again" } });
  const second = await eventsUntil((event) => event.kind === "tool_result");
  expect(second.filter((event) => event.kind === "approval_card")).toEqual([]);
  expect(ran(second)).toBe(true);
});

test("17: the card the phone gets carries the structured scope and a rule to widen", async () => {
  const cmd = "echo yorozu-scope-ok";
  const { send, eventsUntil } = await pairedPhone([() => shellTurn(cmd), () => sse("Done.")]);

  send({ kind: "message", data: { role: "user", text: "tidy up" } });
  const shown = cardOf(await eventsUntil((event) => event.kind === "approval_card"));

  expect(shown.scope).toMatchObject({ operation: "run" });
  expect(shown.scope?.consequence).toBeTruthy();
  expect(shown.mustConfirm).toBeUndefined();
  // Prefilled with the narrowest thing that covers it, which is this command and not every one.
  expect(shown.suggestedRule).toMatchObject({
    actionClass: "run-command",
    decision: "always",
    scope: { target: { mode: "exact", value: cmd }, operation: { mode: "exact", value: "run" } },
  });
});

test("19: the phone saves the rule its editor produced, widened past the one command", async () => {
  const first = "echo yorozu-editor-one";
  const second = "echo yorozu-editor-two";
  const { dir, send, eventsUntil, isReply } = await pairedPhone([
    () => shellTurn(first),
    () => sse("Done."),
    () => shellTurn(second),
    () => sse("Done again."),
  ]);

  send({ kind: "message", data: { role: "user", text: "tidy up" } });
  const shown = cardOf(await eventsUntil((event) => event.kind === "approval_card"));

  // What the editor sends back: the same rule with the target widened to a prefix.
  send({
    kind: "approval_answer",
    data: {
      actionId: shown.actionId,
      answer: "always",
      rule: {
        ...shown.suggestedRule!,
        scope: { target: { mode: "prefix", value: "echo yorozu-editor-" } },
      },
    },
  });
  await eventsUntil(isReply);

  expect(JSON.parse(readFileSync(join(dir, "approval.json"), "utf8")).rules).toMatchObject([
    { scope: { target: { mode: "prefix", value: "echo yorozu-editor-" } } },
  ]);

  // A different command the widened rule covers: no second card.
  send({ kind: "message", data: { role: "user", text: "and the other one" } });
  const tail = await eventsUntil((event) => event.kind === "tool_result");
  expect(tail.filter((event) => event.kind === "approval_card")).toEqual([]);
  expect(tail.at(-1)?.data.output).toContain("yorozu-editor-two");
});

test("18: allow for this task covers the rest of the turn and expires with it", async () => {
  const cmd = "echo yorozu-task-ok";
  const { dir, send, eventsUntil, isReply } = await pairedPhone([
    () => shellTurn(cmd),
    // Same command again inside the same turn: the grant covers it, so no second card.
    () => shellTurn(cmd),
    () => sse("Done."),
    // A new turn, and the grant went with the old one.
    () => shellTurn(cmd),
    () => sse("Done again."),
  ]);

  send({ kind: "message", data: { role: "user", text: "tidy up twice" } });
  const shown = cardOf(await eventsUntil((event) => event.kind === "approval_card"));
  send({ kind: "approval_answer", data: { actionId: shown.actionId, answer: "task" } });

  const rest = await eventsUntil(isReply);
  expect(rest.filter((event) => event.kind === "approval_card")).toEqual([]);
  expect(rest.filter((event) => event.kind === "tool_result")).toHaveLength(2);
  // A bounded grant is not a rule: nothing was written down.
  expect(listRules(dir)).toEqual([]);

  send({ kind: "message", data: { role: "user", text: "again please" } });
  const next = await eventsUntil((event) => event.kind === "approval_card");
  expect(next.at(-1)).toMatchObject({ kind: "approval_card" });
});

test("22, 23: three approvals raise a proposal, and it activates nothing", async () => {
  const cmd = "echo yorozu-proposal-ok";
  const turns = [];
  for (let i = 0; i < 4; i++) turns.push(() => shellTurn(cmd), () => sse("Done."));
  const { dir, send, eventsUntil, isReply } = await pairedPhone(turns);

  const approveOnce = async (): Promise<YorozuEvent[]> => {
    send({ kind: "message", data: { role: "user", text: "tidy up" } });
    const shown = cardOf(await eventsUntil((event) => event.kind === "approval_card"));
    send({ kind: "approval_answer", data: { actionId: shown.actionId, answer: "yes" } });
    return eventsUntil(isReply);
  };

  expect((await approveOnce()).filter((e) => e.kind === "rule_proposal")).toEqual([]);
  expect((await approveOnce()).filter((e) => e.kind === "rule_proposal")).toEqual([]);
  const third = await approveOnce();

  const [proposal] = third.filter((event) => event.kind === "rule_proposal");
  expect(proposal).toMatchObject({
    kind: "rule_proposal",
    data: {
      approvals: 3,
      rule: {
        actionClass: "run-command",
        decision: "always",
        scope: { target: { mode: "exact", value: cmd } },
      },
    },
  });

  // Proposed, not stored, and not acting: the fourth still puts a card up.
  expect(listRules(dir)).toEqual([]);
  send({ kind: "message", data: { role: "user", text: "tidy up" } });
  expect((await eventsUntil((event) => event.kind === "approval_card")).at(-1)).toMatchObject({
    kind: "approval_card",
  });
});

test("21: rules are listed, saved and revoked over the wire", async () => {
  const { dir, send, eventsUntil } = await pairedPhone([]);

  const rules = async (): Promise<YorozuEvent[]> => {
    send({ kind: "rule_list", data: { rules: [] } });
    return eventsUntil((event) => event.kind === "rule_list");
  };

  expect((await rules()).at(-1)).toMatchObject({ kind: "rule_list", data: { rules: [] } });

  const saved = {
    id: "rule-1",
    actionClass: "send-message",
    decision: "always" as const,
    scope: { recipient: { mode: "exact" as const, value: "bob@example.com" } },
  };
  send({ kind: "rule_update", data: { rule: saved } });
  expect((await eventsUntil((event) => event.kind === "rule_list")).at(-1)).toMatchObject({
    data: { rules: [saved] },
  });
  expect(JSON.parse(readFileSync(join(dir, "approval.json"), "utf8")).rules).toMatchObject([saved]);

  // Switched off rather than revoked: the same id comes back with the flag on it.
  send({ kind: "rule_update", data: { rule: { ...saved, enabled: false } } });
  expect((await eventsUntil((event) => event.kind === "rule_list")).at(-1)).toMatchObject({
    data: { rules: [{ id: "rule-1", enabled: false }] },
  });

  send({ kind: "rule_delete", data: { ruleId: "rule-1" } });
  expect((await eventsUntil((event) => event.kind === "rule_list")).at(-1)).toMatchObject({
    data: { rules: [] },
  });
});

const suggestion: Rule = {
  id: "r1",
  actionClass: "purchase",
  decision: "always",
  scope: { merchant: { mode: "exact", value: "the corner shop" } },
};

const card: ApprovalCardData = {
  actionId: "a1",
  actionClass: "purchase",
  target: "the corner shop",
  suggestedRule: suggestion,
};

test.each<[string, AskResult | null]>([
  ["yes", { answer: "yes" }],
  ["sure", { answer: "yes" }],
  ["no", { answer: "no" }],
  ["nope", { answer: "no" }],
  // A bare "never" sounds permanent but is the one-off refusal: only the explicit wordings persist.
  ["never", { answer: "no" }],
  ["never mind", { answer: "no" }],
  ["always", { answer: "always", rule: suggestion }],
  ["yes always", { answer: "always", rule: suggestion }],
  ["yes, always", { answer: "always", rule: suggestion }],
  ["yes and never ask", { answer: "always", rule: suggestion }],
  ["yes, and never ask again", { answer: "always", rule: suggestion }],
  ["never ask again", { answer: "always", rule: suggestion }],
  ["don't ask again", { answer: "always", rule: suggestion }],
  ["dont ask again", { answer: "always", rule: suggestion }],
  // The bounded grant, which in prose is only ever "for this task" and its neighbours.
  ["for this task", { answer: "task" }],
  ["yes, for this task", { answer: "task" }],
  ["just for this turn", { answer: "task" }],
  ["maybe later", null],
])("typedAnswer: %s", (text, expected) => {
  expect(typedAnswer(text, card)).toEqual(expected);
});

test("discuss leaves the action pending and the card comes back", async () => {
  const cmd = "rm -rf /tmp/yorozu-must-not-run-either";
  const { send, eventsUntil, isReply } = await pairedPhone([
    () => shellTurn(cmd),
    // Having explained itself, the agent tries again, which re-presents the card.
    () => shellTurn(cmd),
    () => sse("Understood, I will skip it."),
  ]);

  send({ kind: "message", data: { role: "user", text: "tidy up" } });

  const firstId = cardOf(await eventsUntil((event) => event.kind === "approval_card")).actionId;
  send({ kind: "approval_answer", data: { actionId: firstId, answer: "discuss" } });

  const second = await eventsUntil((event) => event.kind === "approval_card");
  expect(second.at(-1)).toMatchObject({
    kind: "approval_card",
    data: { actionClass: "run-command", target: cmd },
  });
  // A fresh action ID: the pending action was re-presented, not resumed.
  expect(cardOf(second).actionId).not.toBe(firstId);

  // A typed "no" answers the card just as the button would.
  send({ kind: "message", data: { role: "user", text: "no" } });
  const tail = await eventsUntil(isReply);
  expect(tail.at(-1)).toMatchObject({ data: { role: "agent", text: "Understood, I will skip it." } });
});

/** Pairing burns a token, so the sidecar prints one QR per device that can still join. */
function qrQueue() {
  const printed: string[] = [];
  const waiting: ((qr: string) => void)[] = [];
  return {
    push(qr: string) {
      const waiter = waiting.shift();
      if (waiter) waiter(qr);
      else printed.push(qr);
    },
    next(): Promise<QrPayload> {
      const ready = printed.shift();
      return (ready ? Promise.resolve(ready) : new Promise<string>((r) => waiting.push(r))).then(
        decodeQrPayload,
      );
    },
  };
}

/** A fake phone: joins, says hello, then seals and opens events under its own session key. */
async function pairPhone(port: number, qr: QrPayload) {
  const { phone, keys } = await connectPhone(port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });
  const identity = generateKeypair();
  const sessionKey = deriveSessionKey(identity.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(encodeBody({ t: "hello", pub: toBase64Url(identity.publicKey) }), keys);

  return {
    send(threadId: string, payload: EventPayload): void {
      const event: YorozuEvent = { id: randomUUID(), threadId, ts: Date.now(), agentId: "phone", ...payload };
      const box = seal(sessionKey, Buffer.from(JSON.stringify(event)));
      phone.frame(
        encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }),
        keys,
      );
    },
    /** The next event of `kind` this phone can open: frames for the other device are not ours. */
    async next(kind: EventKind): Promise<YorozuEvent> {
      for (;;) {
        const frame = await phone.next();
        if (frame?.type !== "frame") continue;
        const body = frameBody(frame.payload);
        let event: YorozuEvent;
        try {
          event = JSON.parse(
            Buffer.from(open(sessionKey, fromBase64Url(body.n), fromBase64Url(body.c))).toString(),
          ) as YorozuEvent;
        } catch {
          continue; // Sealed for the other phone.
        }
        if (event.kind === kind) return event;
      }
    },
  };
}

test("two phones pair at once and see the same threads, events and deltas", async () => {
  relay = await startRelay(0);
  const qrs = qrQueue();

  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-serve-")),
    provider: openaiCompat({
      baseUrl: "https://example.invalid",
      model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => sse("pong")),
    }),
    log: (line) => {
      if (line.startsWith("QR ")) qrs.push(line.slice(3));
    },
  });

  const first = await pairPhone(relay.port, await qrs.next());
  // The first pairing burnt that token; the sidecar minted the next one for the second phone.
  const second = await pairPhone(relay.port, await qrs.next());

  // Nothing has happened in this state dir, so the greeting is an empty list.
  for (const phone of [first, second]) {
    expect(await phone.next("thread_list")).toMatchObject({ data: { threads: [] } });
  }

  // A draft on the first phone: the id is the device's, and the message follows the create.
  const chat = "draft-1";
  first.send(chat, { kind: "thread_create", data: {} });
  for (const phone of [first, second]) {
    expect(await phone.next("thread_list")).toMatchObject({ data: { threads: [{ id: chat }] } });
  }

  // A turn started on one phone is answered to both.
  first.send(chat, { kind: "message", data: { role: "user", text: "ping" } });
  for (const phone of [first, second]) {
    expect(await phone.next("message")).toMatchObject({
      threadId: chat,
      data: { role: "agent", text: "pong" },
    });
  }

  // So is a thread created on either of them.
  second.send("draft-2", { kind: "thread_create", data: { title: "Groceries" } });
  const [listed, alsoListed] = [await first.next("thread_list"), await second.next("thread_list")];
  expect(listed).toEqual(alsoListed);
  const groceries = "draft-2";

  second.send(groceries, { kind: "message", data: { role: "user", text: "milk" } });
  expect(await second.next("message")).toMatchObject({ threadId: groceries });

  // A device that holds nothing gets every thread's history in one delta, newest thread first.
  first.send(chat, { kind: "sync_request", data: { lastSeen: {} } });
  const delta = await first.next("sync_delta");
  expect(
    delta.kind === "sync_delta" &&
      delta.data.events.map((e) => `${e.threadId}:${e.kind === "message" ? e.data.text : e.kind}`),
  ).toEqual([
    `${groceries}:milk`,
    `${groceries}:pong`,
    `${chat}:ping`,
    `${chat}:pong`,
  ]);

  // And a delta from a known id is only what came after it.
  first.send(chat, { kind: "sync_request", data: { lastSeen: { [chat]: "nope" } } });
  expect((await first.next("sync_delta")).kind).toBe("sync_delta");

  // Any thread archives now, for every device at once.
  first.send(chat, { kind: "thread_archive", data: {} });
  expect(await second.next("thread_list")).toMatchObject({
    data: { threads: [{ id: groceries, archived: false }, { id: chat, archived: true }] },
  });
});


/** The threads of the next non-empty list: the pairing greeting on a fresh state dir has none. */
async function threadsAfter(
  eventsUntil: (done: (event: YorozuEvent) => boolean) => Promise<YorozuEvent[]>,
): Promise<{ id: string; title: string }[]> {
  const seen = await eventsUntil(
    (event) => event.kind === "thread_list" && event.data.threads.length > 0,
  );
  const last = seen.at(-1)!;
  return last.kind === "thread_list" ? last.data.threads : [];
}

const storedThreads = (dir: string): { title: string }[] =>
  JSON.parse(readFileSync(join(dir, "threads.json"), "utf8")) as { title: string }[];

test("the first reply names an untitled thread, and no later turn renames it", async () => {
  const { dir, send, eventsUntil, isReply } = await pairedPhone([
    () => sse("Sure — milk and eggs."),
    // The titler's own completion, with the quotes and the full stop it was told not to use.
    () => sse('"Groceries for the week."\n'),
    () => sse("Added bread."),
  ]);

  // Nobody is asked for a title: the thread arrives empty and the lists draw a placeholder.
  send({ kind: "thread_create", data: {} });
  const [created] = await threadsAfter(eventsUntil);
  expect(created!.title).toBe("");

  send({ kind: "message", data: { role: "user", text: "buy milk" } }, created!.id);
  await eventsUntil(isReply);

  // The title lands after the reply, in a fresh list.
  expect(await threadsAfter(eventsUntil)).toEqual([
    expect.objectContaining({ id: created!.id, title: "Groceries for the week" }),
  ]);

  // A second turn spends no completion on titling, so the queued third response is its reply.
  send({ kind: "message", data: { role: "user", text: "and bread" } }, created!.id);
  const second = await eventsUntil(isReply);
  expect(second.at(-1)).toMatchObject({ data: { role: "agent", text: "Added bread." } });
  expect(storedThreads(dir)[0]!.title).toBe("Groceries for the week");
});

test("a thread the user renamed keeps that title through its first turn", async () => {
  // One response only: a named thread never asks for a second, so a titler call would hang.
  const { dir, send, eventsUntil, isReply } = await pairedPhone([() => sse("Noted.")]);

  send({ kind: "thread_create", data: {} });
  const [created] = await threadsAfter(eventsUntil);

  send({ kind: "thread_rename", data: { title: "  Weekend plans  " } }, created!.id);
  expect(await threadsAfter(eventsUntil)).toEqual([
    expect.objectContaining({ id: created!.id, title: "Weekend plans" }),
  ]);

  send({ kind: "message", data: { role: "user", text: "hi" } }, created!.id);
  await eventsUntil(isReply);
  expect(storedThreads(dir)[0]!.title).toBe("Weekend plans");
});

test("a revoked device is forgotten here and at the relay", async () => {
  relay = await startRelay(0);
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-revoke-"));

  let qrLine!: (line: string) => void;
  const qrPrinted = new Promise<string>((resolve) => (qrLine = resolve));
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir,
    provider: openaiCompat({
      baseUrl: "https://example.invalid",
      model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => sse("pong")),
    }),
    log: (line) => {
      if (line.startsWith("QR ")) qrLine(line.slice(3));
    },
  });

  const qr = decodeQrPayload(await qrPrinted);
  const { phone, keys } = await connectPhone(relay.port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });

  // The `hello` carries the relay identity as well as the session key: revoking a device at
  // the relay is addressed to the Ed25519 key, which cannot be derived from the other one.
  const phoneKeys = generateKeypair();
  const sessionKey = deriveSessionKey(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  const pub = toBase64Url(phoneKeys.publicKey);
  phone.frame(encodeBody({ t: "hello", pub, spub: keys.pub }), keys);
  const devicesFile = join(stateDir, "devices.json");
  await vi.waitFor(() =>
    expect(loadDevices(devicesFile)).toMatchObject([{ pub, signingPub: keys.pub }]),
  );

  // Sent as the Mac app sends it, which is the same handler either way in.
  const remove: YorozuEvent = {
    id: "r1",
    threadId: "",
    ts: 3,
    agentId: "mac",
    kind: "device_remove",
    data: { pub },
  };
  const box = seal(sessionKey, Buffer.from(JSON.stringify(remove)));
  phone.frame(encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }), keys);

  await vi.waitFor(() => expect(loadDevices(devicesFile)).toEqual([]));
  // And the relay has forgotten it too: the nonce rejoin a known device may make is refused.
  const again = await rejoinPhone(relay.port, qr.roomId!, keys);
  expect(await again.closed).toBe(4001);
});

test("a relay that stops answering the heartbeat is treated as gone, and re-registered with", async () => {
  // The live bug this exists for: something between the Mac and the relay drops a quiet socket,
  // the relay tells every phone the Mac is offline, and this process keeps a socket that still
  // looks open and never learns otherwise — so the phone stays wrong until the app is restarted.
  // A deaf relay stands in for that: it accepts and registers, then ignores every ping.
  const deaf = new WebSocketServer({ port: 0 });
  const registrations: number[] = [];
  deaf.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as { type: string };
      // Everything answered as usual except the heartbeat, which falls into a hole.
      if (msg.type === "register") {
        registrations.push(Date.now());
        ws.send(JSON.stringify({ type: "registered", roomId: "r" }));
      }
    });
  });
  const port = (deaf.address() as AddressInfo).port;

  const states: string[] = [];
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-heartbeat-")),
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
    heartbeat: { pingMs: 30, pongMs: 30 },
    log: (line) => void states.push(line),
  });

  // Two registrations means the first socket was given up on and redialled, which is the whole
  // point: a re-register is what puts the room's presence right again.
  await vi.waitFor(() => expect(registrations.length).toBeGreaterThanOrEqual(2), { timeout: 5_000 });
  expect(states).toContain("STATE heartbeat-timeout");

  await new Promise<void>((done) => deaf.close(() => done()));
});

test("a relay that answers the heartbeat is left connected", async () => {
  relay = await startRelay(0);
  const states: string[] = [];
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${relay.port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-heartbeat-ok-")),
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
    heartbeat: { pingMs: 20, pongMs: 200 },
    log: (line) => void states.push(line),
  });

  await vi.waitFor(() => expect(states).toContain("STATE registered"));
  // Long enough for a good few ping/pong rounds: the socket must survive all of them.
  await new Promise((r) => setTimeout(r, 300));
  expect(states).not.toContain("STATE heartbeat-timeout");
  expect(states.filter((line) => line === "STATE registered")).toHaveLength(1);
});

test("announces the paired list to the relay as soon as it has registered", async () => {
  // The relay's known-device set is rebuilt from `devices.json`, so a relay that lost its
  // storage stops refusing every rejoin with a 4001 the moment the Mac comes back.
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-announce-"));
  const signingPubs = ["kBxLN8wYlBCk9nTYMhHsO6D5Hhw4EJOa2OBCnmHRLkA", "Zm9vYmFyZm9vYmFy"];
  const devices = signingPubs.map((signingPub, i) => ({
    pub: toBase64Url(generateKeypair().publicKey),
    signingPub,
    lastSeen: i,
  }));
  writeFileSync(join(stateDir, "devices.json"), JSON.stringify(devices));

  const seen: Record<string, unknown>[] = [];
  const fake = new WebSocketServer({ port: 0 });
  fake.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Record<string, unknown>;
      seen.push(msg);
      if (msg.type === "register") ws.send(JSON.stringify({ type: "registered", roomId: "r" }));
    });
  });

  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${(fake.address() as AddressInfo).port}`,
    stateDir,
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
    log: () => {},
  });

  await vi.waitFor(() => expect(seen.map((msg) => msg.type)).toContain("devices"));
  expect(seen.find((msg) => msg.type === "devices")).toEqual({
    type: "devices",
    devices: signingPubs,
  });
  // After the registration, not before it: the relay refuses the frame on a socket that has
  // not registered yet.
  expect(seen.findIndex((msg) => msg.type === "devices")).toBeGreaterThan(
    seen.findIndex((msg) => msg.type === "register"),
  );

  // `close()` waits on the open sockets, and this sidecar's is one of them.
  await sidecar.close();
  await new Promise<void>((done) => fake.close(() => done()));
});

test("a paired device the relay knows no name for holds the announce back", async () => {
  // The list replaces the relay's whole set, so an incomplete one would unpair the device it
  // cannot name — a record kept from before the signing key was. Nothing is sent instead.
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-announce-partial-"));
  writeFileSync(
    join(stateDir, "devices.json"),
    JSON.stringify([{ pub: toBase64Url(generateKeypair().publicKey), lastSeen: 0 }]),
  );

  const seen: string[] = [];
  const fake = new WebSocketServer({ port: 0 });
  fake.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as { type: string };
      seen.push(msg.type);
      if (msg.type === "register") ws.send(JSON.stringify({ type: "registered", roomId: "r" }));
    });
  });

  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${(fake.address() as AddressInfo).port}`,
    stateDir,
    provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
    log: () => {},
  });

  // `mint` is the message that follows the announce, so waiting for it is waiting past it.
  await vi.waitFor(() => expect(seen).toContain("mint"));
  expect(seen).not.toContain("devices");

  // `close()` waits on the open sockets, and this sidecar's is one of them.
  await sidecar.close();
  await new Promise<void>((done) => fake.close(() => done()));
});

test("a second sidecar on the same state dir is the same Mac: same keys, same room", async () => {
  // What an app update is, from the runtime's side: the bundle is replaced and the sidecar is
  // launched again, on the state directory it always had — nothing in that path is version
  // shaped. The keys are what the room id and every paired phone are pinned to, so a relaunch
  // that generated new ones would silently unpair every device. It must not.
  relay = await startRelay(0);
  const stateDir = mkdtempSync(join(tmpdir(), "yorozu-restart-"));
  const paired = { pub: toBase64Url(generateKeypair().publicKey), signingPub: "s", lastSeen: 7 };
  writeFileSync(join(stateDir, "devices.json"), JSON.stringify([paired]));

  const start = async () => {
    let pairing!: (line: string) => void;
    const printed = new Promise<string>((resolve) => (pairing = resolve));
    const started = serve({
      relayUrl: `ws://127.0.0.1:${relay.port}`,
      stateDir,
      provider: openaiCompat({ baseUrl: "https://example.invalid", model: "m", fetch: vi.fn() }),
      log: (line) => {
        if (line.startsWith("QR ")) pairing(line.slice(3));
      },
    });
    return { started, qr: decodeQrPayload(await printed) };
  };

  const first = await start();
  await first.started.close();
  const second = await start();
  sidecar = second.started;

  expect(second.qr.roomId).toBe(first.qr.roomId);
  expect(second.qr.macPubkey).toBe(first.qr.macPubkey);
  // And the phones it had paired with are still there — the install touched no file of ours.
  expect(loadDevices(join(stateDir, "devices.json"))).toEqual([paired]);
});

test("the Mac tells the relay what class of thing happened, and nothing about it", async () => {
  // A relay that plays enough of the protocol to pair a phone and to record the cleartext
  // side-channel beside the sealed frames. The real relays take `notify` and say nothing back,
  // so a double is the only place the message itself can be read.
  const seen: Record<string, unknown>[] = [];
  const sockets: { mac?: any; phone?: any } = {};
  const fake = new WebSocketServer({ port: 0 });
  fake.on("connection", (ws) => {
    ws.send(JSON.stringify({ type: "nonce", nonce: "n" }));
    ws.on("message", (data) => {
      const msg = JSON.parse(data.toString()) as Record<string, unknown>;
      switch (msg.type) {
        case "register":
          sockets.mac = ws;
          return ws.send(JSON.stringify({ type: "registered", roomId: "r" }));
        case "mint":
          return ws.send(
            JSON.stringify({ type: "token", token: "tok", expiresAt: Date.now() + 60_000 }),
          );
        case "join":
          sockets.phone = ws;
          return ws.send(JSON.stringify({ type: "joined", roomId: "r", ownerOnline: true }));
        case "notify":
          return void seen.push(msg);
        case "frame": {
          const other = ws === sockets.mac ? sockets.phone : sockets.mac;
          return void other?.send(JSON.stringify(msg));
        }
      }
    });
  });
  const port = (fake.address() as AddressInfo).port;

  let qrLine!: (line: string) => void;
  const qrPrinted = new Promise<string>((resolve) => (qrLine = resolve));
  sidecar = serve({
    relayUrl: `ws://127.0.0.1:${port}`,
    stateDir: mkdtempSync(join(tmpdir(), "yorozu-notify-")),
    provider: openaiCompat({
      baseUrl: "https://example.invalid",
      model: "m",
      fetch: vi.fn<typeof fetch>().mockImplementation(async () => sse("the secret reply")),
    }),
    log: (line) => {
      if (line.startsWith("QR ")) qrLine(line.slice(3));
    },
  });

  const qr = decodeQrPayload(await qrPrinted);
  const { phone, keys } = await connectPhone(port, qr.roomId!, qr.token);
  expect(await phone.next()).toMatchObject({ type: "joined" });

  const phoneKeys = generateKeypair();
  const sessionKey = deriveSessionKey(phoneKeys.privateKey, fromBase64Url(qr.macPubkey));
  phone.frame(encodeBody({ t: "hello", pub: toBase64Url(phoneKeys.publicKey) }), keys);

  const sent: YorozuEvent = {
    id: "e1",
    threadId: "thread-one",
    ts: 1,
    agentId: "phone",
    kind: "message",
    data: { role: "user", text: "the secret question" },
  };
  const box = seal(sessionKey, Buffer.from(JSON.stringify(sent)));
  phone.frame(
    encodeBody({ t: "box", n: toBase64Url(box.nonce), c: toBase64Url(box.ciphertext) }),
    keys,
  );

  // The turn ends with the agent's reply, which is the one thing worth waking a phone for.
  await vi.waitFor(() => expect(seen.map((msg) => msg.class)).toContain("reply"));

  const notify = seen.find((msg) => msg.class === "reply")!;
  expect(notify).toEqual({
    type: "notify",
    class: "reply",
    threadRef: threadRef("thread-one"),
  });

  // The whole side-channel, everything the relay was ever told in the clear. Neither side of
  // the conversation is in it, and neither is the thread it happened in.
  const wire = JSON.stringify(seen);
  expect(wire).not.toContain("secret");
  expect(wire).not.toContain("thread-one");

  // `close()` waits on the open sockets, and this test attached a phone to them as well.
  phone.ws.close();
  await sidecar.close();
  await new Promise<void>((done) => fake.close(() => done()));
});

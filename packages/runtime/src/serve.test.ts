import { randomUUID } from "node:crypto";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startRelay, type Relay } from "@yorozu/relay";
import { connectPhone } from "@yorozu/relay/dist/testing.js";
import {
  decodeQrPayload,
  deriveSessionKey,
  fromBase64Url,
  generateKeypair,
  open,
  seal,
  toBase64Url,
  type ApprovalCardData,
  type EventKind,
  type EventPayload,
  type QrPayload,
  type YorozuEvent,
} from "@yorozu/shared";
import { afterEach, expect, test, vi } from "vitest";
import { openaiCompat } from "./provider.js";
import { serve, type Sidecar } from "./serve.js";

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
  expect(await openNext()).toMatchObject({
    threadId: "t1",
    kind: "message",
    data: { role: "agent", text: "pong" },
  });
  expect(lines).toContain("STATE paired");
  expect(fetchMock.mock.calls[0]![0]).toBe("https://example.invalid/v1/chat/completions");
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

test("a never answer is permanent: the same action is refused again without a second card", async () => {
  // The command is never run: both turns are refused before `shell` is reached.
  const cmd = "rm -rf /tmp/yorozu-must-not-run";
  const { dir, send, eventsUntil, isReply } = await pairedPhone([
    () => shellTurn(cmd),
    () => sse("I left it alone."),
    () => shellTurn(cmd),
    () => sse("Still leaving it alone."),
  ]);

  send({ kind: "message", data: { role: "user", text: "tidy up" } });

  const batch = await eventsUntil((event) => event.kind === "approval_card");
  expect(batch.at(-1)).toMatchObject({
    kind: "approval_card",
    data: { actionClass: "run-command", target: cmd },
  });
  const { actionId } = cardOf(batch);

  send({ kind: "approval_answer", data: { actionId, answer: "never" } });
  await eventsUntil(isReply);

  // The rule is on disk, so the identical action must not reach the phone a second time.
  expect(JSON.parse(readFileSync(join(dir, "approval.json"), "utf8")).rules).toEqual([
    { actionClass: "run-command", decision: "never" },
  ]);

  send({ kind: "message", data: { role: "user", text: "tidy up again" } });
  const second = await eventsUntil(isReply);
  expect(second.filter((event) => event.kind === "approval_card")).toEqual([]);
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

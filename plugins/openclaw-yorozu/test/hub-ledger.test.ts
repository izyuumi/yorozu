import assert from "node:assert/strict";
import { beforeEach, test } from "node:test";
import type { Event } from "../src/envelope.ts";
import { createLedger, type RunRecord, type Store } from "../src/ledger.ts";
import { host as storeHost, yorozuRuntime } from "./genui-host.js";
import { convId, hello, host, messageId, newDevice } from "./hub-host.ts";

const message: Extract<Event, { kind: "message" }> = { kind: "message", data: { convId, messageId, text: "hi" } };
const delivered: Event = { kind: "delivered", data: { convId, messageId } };
const runs = (): Store<RunRecord> => yorozuRuntime.getRuntime().state.openKeyedStore({ namespace: "runs" });

beforeEach(() => storeHost.stores.clear());

async function open(bootId: string) {
  const lines: string[] = [];
  const ledger = createLedger({
    runs, bootId, now: Date.now, inTranscript: () => "missing",
    log: { info: (line) => lines.push(line), warn: (line) => lines.push(line) },
  });
  await ledger.load();
  return { ...host({ claim: ledger.claim }), lines, ledger };
}

test("restart replay gets delivered without another onMessage", async () => {
  const first = await open("A");
  const a = await first.connect();
  await a.send(hello);
  await a.send(message);
  assert.deepEqual(a.drain(), [delivered]);
  first.ledger.turnEnded(messageId, convId, { parked: false, queued: false });
  await first.ledger.idle();

  const restart = await open("B");
  const b = await restart.connect();
  await b.send(hello);
  await b.send(message);
  assert.deepEqual(b.drain(), [delivered]);
  assert.deepEqual([...first.messages, ...restart.messages], [message.data], "onMessage runs once across the restart");
  assert.deepEqual(restart.lines, [`yorozu: duplicate message skipped ${messageId} settled boot earlier`]);
});

test("a duplicate of a running message gets only delivered", async () => {
  const h = await open("A");
  const device = await h.connect();
  await device.send(hello);
  await device.send(message);
  assert.deepEqual(device.drain(), [delivered]);
  await h.ledger.handing(messageId, convId);
  h.ledger.runStarted(messageId, 0, false);
  await device.send(message);
  assert.deepEqual(device.drain(), [delivered]);
  assert.deepEqual(h.messages, [message.data]);
  assert.ok(h.lines.includes(`yorozu: duplicate message skipped ${messageId} started boot same`), "the ledger skipped the running duplicate");
  await h.ledger.idle();
});

test("relay and direct copies right after a restart run once and both get delivered", async () => {
  const first = await open("A");
  const earlier = { ...message.data, messageId: "33333333-3333-4333-8333-333333333333" };
  first.ledger.claim(earlier);
  await first.ledger.idle();

  const restart = await open("B");
  const sent: string[] = [];
  const relay = await restart.connect(newDevice(), {
    link: { path: "relay", send: (payloads) => { sent.push(...payloads); } },
    sent, closed: [],
  });
  const direct = await restart.connect();
  await Promise.all([relay.send(hello), direct.send(hello)]);
  await Promise.all([relay.send(message), direct.send(message)]);
  assert.deepEqual(relay.drain(), [delivered, delivered]);
  assert.deepEqual(direct.drain(), [delivered, delivered]);
  assert.deepEqual(restart.messages, [message.data]);
  await restart.ledger.idle();
  assert.equal((await runs().lookup(messageId))?.boot, "B", "the winning copy was durably claimed in the new boot");
  assert.deepEqual(restart.lines, [`yorozu: duplicate message skipped ${messageId} accepted boot same`]);
});

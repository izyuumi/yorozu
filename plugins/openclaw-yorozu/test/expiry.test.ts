import assert from "node:assert/strict";
import { test } from "node:test";
import {
  announceDevices,
  CLOSE_EXPIRED,
  DEVICE_IDLE_MS,
  DirectSeen,
  expirePairing,
  reportSeen,
  ROOM_EXPIRED,
  ROOM_IDLE_MS,
  SEEN_REPORT_MS,
} from "../src/expiry.ts";

const A = "A".repeat(43);
const B = "B".repeat(43);
const NOW = 1_000 * SEEN_REPORT_MS;

function setup() {
  const devices = new Map([[A, { signingPub: A, name: "iPhone" }], [B, { signingPub: B }]]);
  const events: string[] = [];
  const opts = {
    store: {
      list: async () => [...devices.values()],
      remove: async (key: string) => events.push(`remove ${key}`) && devices.delete(key),
    },
    forget: (keys: string[]) => void events.push(`forget ${keys.join(",")}`),
    seen: new DirectSeen(),
    now: () => NOW,
    log: { warn: (message: string) => void events.push(message) },
  };
  const send = (raw: string) => void events.push(`send ${raw}`);
  return { devices, events, opts, send };
}

test("a direct device is due for `seen` once, then again only after 24 hours and a new connection", () => {
  const seen = new DirectSeen();
  assert.deepEqual(seen.due(NOW), []);
  seen.mark(A, NOW);
  assert.deepEqual(seen.due(NOW), [A]);
  seen.sent([A], NOW);
  seen.mark(A, NOW + 1);
  assert.deepEqual(seen.due(NOW + SEEN_REPORT_MS - 1), [], "throttled within the day");
  assert.deepEqual(seen.due(NOW + SEEN_REPORT_MS), [A]);
  seen.sent([A], NOW + SEEN_REPORT_MS);
  assert.deepEqual(seen.due(NOW + 3 * SEEN_REPORT_MS), [], "not seen since the last report");
  assert.equal(seen.recent(A, NOW + 30, 31), true);
  assert.equal(seen.recent(A, NOW + 31, 30), false);
  assert.equal(seen.recent(B, NOW, DEVICE_IDLE_MS), false);
});

test("reportSeen sends what is due in messages of at most 16 keys, and marks them sent", () => {
  const seen = new DirectSeen();
  const keys = Array.from({ length: 17 }, (_, i) => String(i).padStart(43, "k"));
  for (const key of keys) seen.mark(key, NOW);
  const sent: string[][] = [];
  reportSeen(seen, (raw) => void sent.push(JSON.parse(raw).devices), NOW);
  assert.deepEqual(sent.map((batch) => batch.length), [16, 1]);
  assert.deepEqual(sent.flat(), keys);
  reportSeen(seen, () => assert.fail("nothing is due"), NOW + 1);
});

test("an expired device seen over direct within 180 days is kept, reported as seen, and announced", async () => {
  const { devices, events, opts, send } = setup();
  opts.seen.mark(A, NOW - DEVICE_IDLE_MS + 1);
  opts.seen.sent([A], NOW - 1);
  opts.seen.mark(B, NOW - DEVICE_IDLE_MS);
  await announceDevices([A, B], send, opts);
  assert.deepEqual([...devices.keys()], [A]);
  assert.deepEqual(events, [
    `remove ${B}`,
    `yorozu: device ${B.slice(0, 8)} pairing expired after 180 days without connecting; pair it again`,
    `forget ${B}`,
    `send ${JSON.stringify({ type: "seen", devices: [A] })}`,
    `send ${JSON.stringify({ type: "devices", devices: [A] })}`,
  ]);
});

test("an expired room keeps devices seen over direct in the last 30 days", async () => {
  const { devices, events, opts } = setup();
  opts.seen.mark(A, NOW - ROOM_IDLE_MS + 1);
  opts.seen.mark(B, NOW - ROOM_IDLE_MS);
  assert.deepEqual(await expirePairing(opts), [B]);
  assert.deepEqual([...devices.keys()], [A]);
  assert.deepEqual(events, [`remove ${B}`, `forget ${B}`, ROOM_EXPIRED]);

  opts.seen.mark(B, NOW);
  devices.set(B, { signingPub: B });
  events.length = 0;
  assert.deepEqual(await expirePairing(opts), []);
  assert.deepEqual(events, [], "nothing removed, nothing said");
});

test("devices the relay expired leave the allowlist before it is announced, without a revoke", async () => {
  const { devices, events, opts, send } = setup();
  await announceDevices([A, "unknown"], send, opts);
  assert.deepEqual([...devices.keys()], [B]);
  assert.deepEqual(events, [
    `remove ${A}`,
    "yorozu: device iPhone pairing expired after 180 days without connecting; pair it again",
    `forget ${A}`,
    `send ${JSON.stringify({ type: "devices", devices: [B] })}`,
  ]);
});

test("a registered without expired devices, as from an older relay, only announces", async () => {
  const { events, opts, send } = setup();
  await announceDevices(undefined, send, opts);
  assert.deepEqual(events, [`send ${JSON.stringify({ type: "devices", devices: [A, B] })}`]);
});

test("an expired room clears every pairing and says so", async () => {
  const { devices, events, opts } = setup();
  assert.equal(CLOSE_EXPIRED, 4010);
  await expirePairing(opts);
  assert.equal(devices.size, 0);
  assert.deepEqual(events, [`remove ${A}`, `remove ${B}`, `forget ${A},${B}`, ROOM_EXPIRED]);
  assert.equal(ROOM_EXPIRED, "yorozu: relay pairing expired after 30 days without a connection; pair your devices again");
});

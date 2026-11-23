import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import { test } from "node:test";
import { createHermesClient, HermesError, type HermesErrorKind, type RunEvent } from "../src/hermes-client.ts";
import { fakeHermes, fixtureDir } from "./hermes-server.ts";

const key = "test-key-h2-0001";
const requestKey = "fixture-message-01:0";
const requestBody = '{ "input": "Multibyte text: café",\n  "session_id": "yorozu-fixture-session" }\n';
const runs = "/v1/runs";
const runId = "run_fixture_01";
const run = runs + "/" + runId;
const stream = run + "/events";
const sse = { "Content-Type": "text/event-stream" };
const options = { timeoutMs: 50, idleMs: 100 };
const client = (url: URL) => createHermesClient({ url, key }, options);

function errorOf(kind: HermesErrorKind, method: string, path: string, status?: number, code?: string) {
  return (error: unknown) => {
    assert.ok(error instanceof HermesError);
    assert.equal(error.kind, kind);
    assert.equal(error.status, status);
    assert.equal(error.code, code);
    assert.ok(error.message.includes(method + " " + path));
    if (status !== undefined) assert.ok(error.message.includes(String(status)));
    if (code !== undefined) assert.ok(error.message.includes(code));
    assert.equal(String(error).includes(key), false);
    assert.equal(error.stack?.includes(key), false);
    assert.equal(error.message.includes("private response text"), false);
    assert.equal(error.message.includes("Multibyte text"), false);
    return true;
  };
}

async function collect(events: AsyncIterable<RunEvent>): Promise<RunEvent[]> {
  const received: RunEvent[] = [];
  for await (const event of events) received.push(event);
  return received;
}

test("H2 1/7: a closed port is unavailable", async (t) => {
  const server = await fakeHermes(t, []);
  await server.close();
  await assert.rejects(client(server.url).status(runId), errorOf("unavailable", "GET", run));
});

for (const [label, reply] of [
  ["a hang before the headers", { end: "hang" }],
  ["a socket reset", { end: "reset" }],
] as const) {
  test("H2 1/7: " + label + " is unavailable", { timeout: 2000 }, async (t) => {
    const server = await fakeHermes(t, [{ method: "POST", path: runs, key: requestKey, reply }]);
    const result = client(server.url).createRun({ key: requestKey, body: requestBody });
    await Promise.all([server.request(1), assert.rejects(result, errorOf("unavailable", "POST", runs))]);
  });
}

test("H2 1/7: the request deadline includes a stalled JSON body", { timeout: 2000 }, async (t) => {
  const server = await fakeHermes(t, [{ method: "GET", path: run, reply: { body: '{"status":', end: "hang" } }]);
  await assert.rejects(client(server.url).status(runId), errorOf("unavailable", "GET", run, 200));
});

for (const [status, kind, code] of [
  [429, "unavailable", "rate_limited"],
  [503, "unavailable", undefined],
  [503, "unavailable", "overloaded"],
  [401, "auth", "gateway_auth_failed"],
  [403, "auth", "forbidden"],
  [400, "http", "bad_request"],
  [409, "http", "run_not_ready"],
  [500, "http", "internal_error"],
] as const) {
  test("H2 1/7: HTTP " + status + " " + (code ?? "without a code") + " is " + kind, async (t) => {
    const reply = status === 401 ? { fixture: "01-caps-nokey" } : { status, body: code === undefined ? "private response text" :
      JSON.stringify({ error: { code, message: "private response text " + key } }) };
    const server = await fakeHermes(t, [{ method: "GET", path: run, reply }]);
    await assert.rejects(client(server.url).status(runId), errorOf(kind, "GET", run, status, code));
  });
}

test("H2 1/7: an idempotency conflict is conflict", async (t) => {
  const server = await fakeHermes(t, [
    { method: "POST", path: runs, key: requestKey, reply: { fixture: "12-run-replay-diffbody" } },
  ]);
  await assert.rejects(client(server.url).createRun({ key: requestKey, body: requestBody }),
    errorOf("conflict", "POST", runs, 409, "idempotency_key_conflict"));
});

test("H2 1/7: an error code containing the key is omitted", async (t) => {
  const server = await fakeHermes(t, [{
    method: "GET", path: run, reply: { status: 400, body: JSON.stringify({ error: { code: key } }) },
  }]);
  await assert.rejects(client(server.url).status(runId), errorOf("http", "GET", run, 400));
});

test("H2 1/7: a 2xx without a string status is bad_response", async (t) => {
  const server = await fakeHermes(t, [{ method: "GET", path: run, reply: { body: '{"status":1}' } }]);
  await assert.rejects(client(server.url).status(runId), errorOf("http", "GET", run, 200, "bad_response"));
});

test("H2 2: a 307 is http and sends no request to the destination", async (t) => {
  const destination = await fakeHermes(t, []);
  const server = await fakeHermes(t, [{
    method: "POST", path: runs, key: requestKey, reply: { status: 307, headers: { Location: destination.url.href } },
  }]);
  await assert.rejects(client(server.url).createRun({ key: requestKey, body: requestBody }), errorOf("http", "POST", runs, 307));
});

test("H2 3: createRun sends the key and body verbatim and maps a replay", async (t) => {
  const server = await fakeHermes(t, [
    { method: "POST", path: runs, key: requestKey, reply: { fixture: "11-run-replay-same" } },
    { method: "POST", path: runs, key: requestKey, reply: { status: 202, body: '{"run_id":"run_fixture_01","status":"started"}' } },
  ]);
  const hermes = client(server.url);
  const input = { key: requestKey, body: requestBody };
  assert.deepEqual(await hermes.createRun(input), { runId, status: "failed", replayed: true });
  const request = await server.request(1);
  assert.equal(request.headers.authorization, "Bearer " + key);
  assert.equal(request.headers["content-type"], "application/json");
  assert.deepEqual(request.body, Buffer.from(requestBody));
  assert.deepEqual(await hermes.createRun(input), { runId, status: "started", replayed: false });
});

test("H2 3: a 2xx without run_id is bad_response", async (t) => {
  const server = await fakeHermes(t, [
    { method: "POST", path: runs, key: requestKey, reply: { status: 202, body: '{"status":"started"}' } },
  ]);
  await assert.rejects(client(server.url).createRun({ key: requestKey, body: requestBody }),
    errorOf("http", "POST", runs, 202, "bad_response"));
});

test("H2 4: status maps the recorded failed run", async (t) => {
  const server = await fakeHermes(t, [{ method: "GET", path: run, reply: { fixture: "10-run-status" } }]);
  const recorded = JSON.parse(readFileSync(new URL("10-run-status.body", fixtureDir), "utf8"));
  assert.deepEqual(await client(server.url).status(runId), {
    status: "failed",
    admissionId: "admission_fixture_01",
    generation: 1,
    output: recorded.output,
    usage: {},
    pendingControls: [],
  });
});

test("H2 4/7: an unknown run is not_found", async (t) => {
  const path = runs + "/run_does_not_exist";
  const server = await fakeHermes(t, [{ method: "GET", path, reply: { fixture: "16-run-status-unknown" } }]);
  await assert.rejects(client(server.url).status("run_does_not_exist"),
    errorOf("not_found", "GET", path, 404, "run_not_found"));
});

test("H2 5: the recorded stream yields one failed event with its original error", async (t) => {
  const server = await fakeHermes(t, [{ method: "GET", path: stream, reply: { fixture: "09-run-events" } }]);
  const recording = readFileSync(new URL("09-run-events.sse", fixtureDir), "utf8");
  const data = JSON.parse(recording.match(/^data: (.+)$/m)![1]!);
  assert.deepEqual(await collect(client(server.url).events(runId)), [{ event: "run.failed", seq: 0, data }]);
});

test("H2 5: SSE joins data lines, skips malformed records, and drains events before server close", async (t) => {
  const server = await fakeHermes(t, [{
    method: "GET", path: stream, reply: {
      headers: { ...sse, Connection: "close" },
      body: ': open\r\nid: 7\r\ndata: not JSON\r\n\r\ndata: []\r\n\r\ndata: {"seq":1}\r\n\r\ndata: {"event":"tool.started",\r',
      chunks: [{ afterMs: 5, body: '\ndata: "tool":"café","seq":0}\r\n\r\ndata: {"event":"new.event","seq":"1"}\n\ndata: {"event":"truncated"}\n' }],
    },
  }]);
  assert.deepEqual(await collect(client(server.url).events(runId)), [
    { event: "tool.started", seq: 0, data: { event: "tool.started", tool: "café", seq: 0 } },
    { event: "new.event", data: { event: "new.event", seq: "1" } },
  ]);
});

test("H2 5: a terminal event ends iteration even with more events in the response", async (t) => {
  const body = 'data: {"event":"run.cancelled","seq":2}\n\ndata: {"event":"tool.started","seq":3}\n\n';
  const server = await fakeHermes(t, [{ method: "GET", path: stream, reply: { headers: sse, body } }]);
  assert.deepEqual((await collect(client(server.url).events(runId))).map(({ event }) => event), ["run.cancelled"]);
});

test("H2 5: stream-closed comment ends iteration", { timeout: 2000 }, async (t) => {
  const body = ': stream closed\n\ndata: {"event":"tool.started"}\n\n';
  const server = await fakeHermes(t, [{ method: "GET", path: stream, reply: { headers: sse, body, end: "hang" } }]);
  assert.deepEqual(await collect(client(server.url).events(runId)), []);
});

test("H2 5: comment bytes reset the idle deadline until the server goes silent", { timeout: 2000 }, async (t) => {
  const server = await fakeHermes(t, [{
    method: "GET", path: stream, reply: {
      headers: sse, body: ": open\n\n", end: "hang",
      chunks: [
        { afterMs: 35, body: ": ping\n\n" },
        { afterMs: 35, body: ": ping\n\n" },
        { afterMs: 35, body: ": ping\n\n" },
        { afterMs: 35, body: 'data: {"event":"tool.started"}\n\n' },
      ],
    },
  }]);
  assert.deepEqual(await collect(client(server.url).events(runId)), [
    { event: "tool.started", data: { event: "tool.started" } },
  ]);
});

test("H2 5: the stream connect deadline rejects as unavailable", { timeout: 2000 }, async (t) => {
  const server = await fakeHermes(t, [{ method: "GET", path: stream, reply: { end: "hang" } }]);
  await assert.rejects(collect(client(server.url).events(runId)), errorOf("unavailable", "GET", stream));
});

test("H2 5: caller abort ends an open stream", { timeout: 2000 }, async (t) => {
  const body = 'data: {"event":"tool.started"}\n\n';
  const server = await fakeHermes(t, [{ method: "GET", path: stream, reply: { headers: sse, body, end: "hang" } }]);
  const controller = new AbortController();
  const iterator = client(server.url).events(runId, controller.signal)[Symbol.asyncIterator]();
  assert.equal((await iterator.next()).done, false);
  controller.abort();
  assert.equal((await iterator.next()).done, true);
});

test("H2 6: deny and resolveUnknown send fixed bodies and stop has no body", async (t) => {
  const server = await fakeHermes(t, [
    { method: "POST", path: run + "/approval", reply: { status: 204 } },
    { method: "POST", path: run + "/resolve-unknown", reply: { status: 204 } },
    { method: "POST", path: run + "/stop", reply: { status: 204 } },
  ]);
  const hermes = client(server.url);
  await hermes.deny(runId, "request-fixture-01", 2);
  await hermes.resolveUnknown(runId, "admission-fixture-02", 3);
  await hermes.stop(runId);
  assert.equal((await server.request(1)).body.toString(), '{"request_id":"request-fixture-01","execution_generation":2,"choice":"deny"}');
  assert.equal((await server.request(2)).body.toString(), '{"admission_id":"admission-fixture-02","execution_generation":3}');
  assert.equal((await server.request(3)).body.length, 0);
  for (const n of [1, 2, 3]) assert.equal((await server.request(n)).headers.authorization, "Bearer " + key);
});

test("H2 8: fixtures contain no auth headers, keys, or personal home paths", () => {
  for (const file of readdirSync(fixtureDir)) {
    const text = readFileSync(new URL(file, fixtureDir), "utf8");
    assert.equal(/Authorization|Bearer [A-Za-z0-9]|\/Users\/(?!owner(?:[\/\s"'\x60]|$))/.test(text), false, file);
  }
});

test.todo("H2 9: completed run usage and tool call IDs and success field (operator step 8)");
test.todo("H2 9: approval pendingControls IDs, kinds and tools (operator step 9.3)");
test.todo("H2 9: run.interrupted event and stream close (operator step 11)");
test.todo("H2 9: unknown run status and resolveUnknown (operator step 11)");

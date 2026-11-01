import assert from "node:assert/strict";
import { createSocket, type Socket } from "node:dgram";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { test } from "node:test";
registerHooks({ resolve(specifier, context, next) {
  if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
    const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
    if (existsSync(ts)) return next(ts.href, context);
  }
  return next(specifier, context);
} });
const { bonjourTag, encodeName, decodeName, parseQuery, buildResponse, sameSubnet, serveBonjour, SERVICE } = await import("../src/bonjour.ts");
const key = Uint8Array.from({ length: 32 }, (_, i) => i);
const tag = "CeUtuNddRZIG";
function query(name = SERVICE, type = 12, qu = false): Buffer {
  const header = Buffer.alloc(12);
  header.writeUInt16BE(1, 4);
  const question = Buffer.alloc(4);
  question.writeUInt16BE(type);
  question.writeUInt16BE(qu ? 0x8001 : 1, 2);
  return Buffer.concat([header, encodeName(name), question]);
}
function records(packet: Buffer) {
  let offset = 12;
  const result: { name: string; type: number; ttl: number; data: Buffer; offset: number }[] = [];
  for (let i = 0; i < packet.readUInt16BE(6); i++) {
    const decoded = decodeName(packet, offset);
    offset = decoded.offset;
    const type = packet.readUInt16BE(offset);
    const ttl = packet.readUInt32BE(offset + 4);
    const length = packet.readUInt16BE(offset + 8);
    offset += 10;
    result.push({ name: decoded.name, type, ttl, data: packet.subarray(offset, offset + length), offset });
    offset += length;
  }
  return result;
}

test("Bonjour tag matches the static-public-key HMAC vector", () => {
  assert.equal(bonjourTag(key), tag);
  assert.throws(() => bonjourTag(new Uint8Array(31)));
});

test("DNS names decode compression pointers and reject cycles, short labels and oversized names", () => {
  const encoded = encodeName(SERVICE);
  assert.deepEqual(decodeName(encoded, 0), { name: SERVICE, offset: encoded.length });
  const compressed = Buffer.concat([encoded, Buffer.from([3]), Buffer.from("tag"), Buffer.from([0xc0, 0])]);
  assert.deepEqual(decodeName(compressed, encoded.length), { name: `tag.${SERVICE}`, offset: compressed.length });
  for (const malformed of [Buffer.from([0xc0, 0]), Buffer.from([0xc0]), Buffer.from([0xc0, 99]), Buffer.from([5, 65]), Buffer.from([0x40])]) {
    assert.throws(() => decodeName(malformed, 0));
  }
  assert.throws(() => encodeName("x".repeat(64)));
  assert.throws(() => encodeName(Array(5).fill("x".repeat(63)).join(".")));
});

test("queries parse QU, ignore responses, malformed and oversized datagrams", () => {
  assert.deepEqual(parseQuery(query(SERVICE, 12, true)), { id: 0, questions: [{ name: SERVICE, type: 12, qu: true }] });
  const response = query(); response.writeUInt16BE(0x8400, 2);
  for (const bad of [response, query().subarray(0, -1), Buffer.alloc(9001), Buffer.alloc(2), Buffer.concat([query(), Buffer.from([1])])]) {
    assert.equal(parseQuery(bad), null);
  }
  const compressed = Buffer.concat([query(), Buffer.from([0xc0, 12, 0, 33, 0, 1])]);
  compressed.writeUInt16BE(2, 4);
  assert.equal(parseQuery(compressed)?.questions[1]?.name, SERVICE);
  const loop = Buffer.concat([Buffer.alloc(12), Buffer.from([0xc0, 12, 0, 12, 0, 1])]);
  loop.writeUInt16BE(1, 4);
  assert.equal(parseQuery(loop), null);
});

test("answers carry PTR, SRV port/target, TXT tag and A, TTL 120 or goodbye 0", () => {
  const packet = buildResponse(tag, 8738, "192.168.1.5");
  const rr = records(packet);
  assert.deepEqual(rr.map((r) => [r.name, r.type, r.ttl]), [
    [SERVICE, 12, 120], [`${tag}.${SERVICE}`, 33, 120], [`${tag}.${SERVICE}`, 16, 120], [`${tag}.local`, 1, 120],
  ]);
  assert.equal(decodeName(packet, rr[0]!.offset).name, `${tag}.${SERVICE}`);
  assert.equal(rr[1]!.data.readUInt16BE(4), 8738);
  assert.equal(decodeName(packet, rr[1]!.offset + 6).name, `${tag}.local`);
  assert.equal(rr[2]!.data.subarray(1).toString(), `t=${tag}`);
  assert.deepEqual([...rr[3]!.data], [192, 168, 1, 5]);
  assert.ok(records(buildResponse(tag, 8738, "192.168.1.5", 0)).every((r) => r.ttl === 0));
  assert.equal(sameSubnet({ address: "192.168.1.5", prefix: 24 }, "192.168.1.20"), true);
  assert.equal(sameSubnet({ address: "192.168.1.5", prefix: 24 }, "192.168.2.20"), false);
});

const bind = (socket: Socket, address: string) => new Promise<void>((resolve, reject) => {
  socket.once("error", reject);
  socket.bind(5353, address, () => { socket.removeListener("error", reject); resolve(); });
});
test("loopback Bonjour answers multicast and QU PTR queries from a second explicitly bound socket", async (t) => {
  const observer = createSocket({ type: "udp4", reuseAddr: true });
  let client = createSocket({ type: "udp4", reuseAddr: true });
  let responder: Awaited<ReturnType<typeof serveBonjour>> | undefined;
  const failures: string[] = [];
  try {
    await bind(observer, "224.0.0.251");
    observer.addMembership("224.0.0.251", "127.0.0.1");
    await bind(client, "127.0.0.1");
    client.setMulticastInterface("127.0.0.1");
    client.setMulticastLoopback(true);
    let sawQuery = false;
    const probe = query("_loopback-probe._tcp.local");
    observer.on("message", (packet) => { if (packet.equals(probe)) sawQuery = true; });
    await new Promise<void>((resolve, reject) => client.send(probe, 5353, "224.0.0.251", (error) => error ? reject(error) : resolve()));
    await new Promise((resolve) => setTimeout(resolve, 100));
    if (!sawQuery) return t.skip("loopback multicast unavailable (lo may lack MULTICAST)");
    await new Promise<void>((resolve) => client.close(() => resolve()));
    let announcements = 0;
    observer.on("message", (packet) => {
      if (packet.length >= 12 && (packet.readUInt16BE(2) & 0x8000) && records(packet).some((r) => r.type === 16 && r.data.subarray(1).toString() === `t=${tag}`)) announcements++;
    });
    responder = await serveBonjour({ hostStaticPub: key, port: 8738, addresses: [{ address: "127.0.0.1", prefix: 8 }],
      log: { info: () => {}, warn: (s) => failures.push(s) } });
    assert.deepEqual(failures, [], "responder must bind when the independent multicast probe works");
    await new Promise((resolve) => setTimeout(resolve, 1100));
    assert.ok(announcements >= 2, "announces twice on start");
    client = createSocket({ type: "udp4", reuseAddr: true });
    await bind(client, "127.0.0.1");
    client.setMulticastInterface("127.0.0.1");
    for (const qu of [false, true]) {
      const answer = new Promise<Buffer>((resolve, reject) => {
        const socket = qu ? client : observer;
        const onMessage = (packet: Buffer) => {
          if (packet.length < 12 || !(packet.readUInt16BE(2) & 0x8000)) return;
          const rr = records(packet);
          if (!rr.some((r) => r.type === 16 && r.data.subarray(1).toString() === `t=${tag}`)) return;
          clearTimeout(timer); socket.removeListener("message", onMessage); resolve(packet);
        };
        const timer = setTimeout(() => { socket.removeListener("message", onMessage); reject(new Error("Bonjour PTR answer timed out")); }, 1500);
        socket.on("message", onMessage);
      });
      const request = query(SERVICE, 12, qu);
      if (qu) request.writeUInt16BE(0x1234);
      client.send(request, 5353, "224.0.0.251");
      const packet = await answer;
      assert.equal(packet.readUInt16BE(0), qu ? 0x1234 : 0);
      const rr = records(packet);
      assert.equal(rr.find((r) => r.type === 33)!.data.readUInt16BE(4), 8738);
      assert.ok(rr.some((r) => r.name === `${tag}.${SERVICE}`));
    }
  } catch (error) {
    if (["EPERM", "EACCES", "EADDRNOTAVAIL", "ENETUNREACH", "ENODEV", "EADDRINUSE"].includes((error as NodeJS.ErrnoException).code ?? "")) {
      t.skip(`loopback multicast unavailable: ${(error as Error).message}`);
    } else throw error;
  } finally {
    await responder?.close();
    try { observer.close(); } catch {}
    try { client.close(); } catch {}
  }
});

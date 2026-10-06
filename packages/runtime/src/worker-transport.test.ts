/** Real staged host + encrypted relay + Seatbelt child + durable SQL memory.
 * The peer is synthetic protocol code, NOT live Hermes/provider acceptance.
 * Run against scripts/stage-internal-alpha.py's assembled and compiled runtime.
 */
import { expect, test, vi } from "vitest";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { startRelay } from "@yorozu/relay";
import { connectPhone } from "@yorozu/relay/dist/testing.js";
import { decodeEnvelope, decodeQrPayload, deriveChannelKeys, encodeEnvelope, fromBase64Url,
  generateKeypair, helloProof, localPeerInfo, open, seal, toBase64Url, type YorozuEvent } from "@yorozu/shared";
import { serveSecretary } from "../dist/secretary-serve.js";

const bounded = async <T>(promise: Promise<T>, label: string): Promise<T> => {
  let timer: ReturnType<typeof setTimeout>;
  try { return await Promise.race([promise, new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`Timed out: ${label}`)), 12_000);
  })]); } finally { clearTimeout(timer!); }
};
const body = (value: unknown) => toBase64Url(Buffer.from(JSON.stringify(value)));

test.skipIf(process.platform !== "darwin")("minimal workers isolate memory and require an encrypted device approval for selected sharing", async () => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "yorozu-worker-wire-")));
  const stateDir = join(root, "state"), code = join(root, "code");
  mkdirSync(code); mkdirSync(join(root, "projects"));
  const peer = join(code, "worker-protocol-peer.mjs");
  copyFileSync(new URL("./fixtures/worker-protocol-peer.mjs", import.meta.url), peer);
  vi.stubEnv("HOME", root); vi.stubEnv("YOROZU_STATE_DIR", stateDir);
  vi.stubEnv("YOROZU_PROJECTS_DIR", join(root, "projects"));
  // Never discover an ambient CLI/account. The child uses an absolute trusted interpreter.
  vi.stubEnv("PATH", "");
  const relay = await startRelay(0);
  let host: ReturnType<typeof serveSecretary> | undefined;
  let phone: Awaited<ReturnType<typeof connectPhone>>["phone"] | undefined;
  let qrResolve!: (line: string) => void;
  const printed = new Promise<string>(resolve => { qrResolve = resolve; });
  const launches: string[] = [], events: YorozuEvent[] = [];
  const forbiddenNative = vi.fn(async () => { throw new Error("Native provider fallback forbidden"); });
  try {
    expect(existsSync("/usr/bin/sandbox-exec")).toBe(true); // mandatory; no isolation mock/fallback
    host = serveSecretary({ stateDir, relayUrl: `ws://127.0.0.1:${relay.port}`,
      nativeRunners: { codex: { run: forbiddenNative } }, titler: async () => "",
      log: line => { if (line.startsWith("QR ")) qrResolve(line.slice(3)); },
      minimalWorkers: {
        secretaryAgentId: "alice",
        initialAgent: { id: "alice", name: "Alice", role: "Synthetic secretary", pluginId: "hermes", allowedTools: ["memory"] },
        adapters: [{ id: "hermes", label: "Synthetic protocol peer", memory: "worker-memory-v1", createFactory: () => (agent, _scope, execution) => {
          launches.push(agent.id);
          return { configuration: { pluginId: "hermes", upstreamVersion: "synthetic-worker-v1", command: process.execPath, args: [peer, join(stateDir, "worker-memory-v1", "worker-memory.sqlite")], initialize: {} },
            runtime: { command: process.execPath, args: [peer, join(stateDir, "worker-memory-v1", "worker-memory.sqlite")], runtimeDir: execution.scratchRoot,
              readPaths: [code], brokerPorts: [] } };
        } }],
      } });
    const qr = decodeQrPayload(await bounded(printed, "host QR"));
    const connection = await bounded(connectPhone(relay.port, qr.roomId!, qr.token), "relay phone");
    phone = connection.phone; const signing = connection.keys;
    expect(await bounded(phone.next(), "join")).toMatchObject({ type: "joined" });
    const pair = generateKeypair(), pub = toBase64Url(pair.publicKey);
    const channel = deriveChannelKeys(pair.privateKey, fromBase64Url(qr.macPubkey), "device");
    let sequence = 0;
    phone.frame(body({ t: "hello", pub, spub: signing.pub, proof: helloProof(qr.secret!, pub, signing.pub) }), signing);
    const send = (kind: YorozuEvent["kind"], data: any, threadId = "", id = randomUUID()) => {
      const event = { id, kind, data, threadId, agentId: "phone", ts: Date.now() } as YorozuEvent;
      const encrypted = seal(channel.send, encodeEnvelope(++sequence, event));
      phone!.frame(body({ t: "box", n: toBase64Url(encrypted.nonce), c: toBase64Url(encrypted.ciphertext) }), signing);
      return id;
    };
    // A single reader consumes every encrypted response, never a direct host/store shortcut.
    const until = async (predicate: (event: YorozuEvent) => boolean) => bounded((async () => {
      for (;;) {
        const frame = await phone!.next();
        if (typeof frame.payload !== "string") continue;
        const packet = JSON.parse(Buffer.from(frame.payload, "base64url").toString());
        if (packet.t !== "box") continue;
        let event: YorozuEvent;
        try { event = decodeEnvelope(open(channel.recv, fromBase64Url(packet.n), fromBase64Url(packet.c))).event; }
        catch { continue; } // initial legacy greeting is not the negotiated envelope
        events.push(event);
        if (predicate(event)) return event;
      }
    })(), "encrypted response");
    await until(e => e.kind === "device_list");
    expect(events.filter(e => e.kind === "thread_list").every(e => e.data.personAgents === undefined)).toBe(true);
    const negotiate = send("thread_list", { threads: [], peerInfo: localPeerInfo("worker-fixture") });
    let registry = (await until(e => e.kind === "thread_list" && e.data.peerInfoReplyTo === negotiate)).data.personAgents!;
    expect(registry.agents.map(a => a.id)).toEqual(["alice"]);
    const create = send("person_agent_control", { version: 1, action: "create", expectedRevision: registry.revision,
      agent: { id: "bob", name: "Bob", role: "Synthetic colleague", pluginId: "hermes", allowedTools: ["memory"] } });
    registry = (await until(e => e.kind === "thread_list" && e.data.personAgents?.lastControlResult?.operationId === create)).data.personAgents!;
    expect(registry.lastControlResult?.status).toBe("applied");
    const conversation = (id: string) => registry.agents.find(a => a.id === id)!.conversationId!;
    const submit = (actor: string, requests: unknown[]) => send("message", { role: "user", text: JSON.stringify(requests) }, conversation(actor));
    const result = async (id: string) => JSON.parse((await until(e => e.id === `native:${id}:final`)).data.text as string);
    const invoke = async (actor: string, requests: unknown[]) => result(submit(actor, requests));
    const write = (key: string, value: string, operationId: string) => ({ action: "write", key, body: value, operationId });
    const read = (ownerId: string, key = "selected") => ({ action: "read", ownerId, key });
    const search = (ownerId: string) => ({ action: "search", ownerId, query: "FIXTURE" });
    const denied = { error: { code: -32001, message: "Worker tool denied or unconfirmed; do not retry automatically" } };
    expect(await invoke("alice", [write("selected", "FIXTURE_SELECTED", "write-a"), write("private", "FIXTURE_PRIVATE", "write-private")]))
      .toEqual([{ result: { ok: true } }, { result: { ok: true } }]);
    expect(await invoke("bob", [write("selected", "FIXTURE_BOB", "write-b"), read("bob")]))
      .toEqual([{ result: { ok: true } }, { result: { value: "FIXTURE_BOB" } }]);
    // A denial may be an empty read/search (non-disclosing) or the static error.
    const inaccessible = (responses: any[]) => {
      expect(responses[0]).toSatisfy((r: any) => JSON.stringify(r) === JSON.stringify(denied) || r.result?.value === null);
      expect(responses[1]).toSatisfy((r: any) => JSON.stringify(r) === JSON.stringify(denied) || JSON.stringify(r.result?.entries) === "[]");
      expect(JSON.stringify(responses)).not.toContain("FIXTURE_SELECTED");
    };
    inaccessible(await invoke("bob", [read("alice"), search("alice")]));
    expect(await invoke("bob", [{ ...read("alice"), actorId: "alice" }, { action: "write", key: "bad", body: 42, operationId: "bad" }]))
      .toEqual([denied, denied]);
    const share = (operationId: string) => ({ action: "grant", key: "selected", toAgentId: "bob", operationId });
    for (const choiceId of ["deny", "allow-once"]) {
      const id = submit("alice", [share(`share-${choiceId}`)]);
      const card = await until(e => e.kind === "harness_action" && e.data.state === "pending");
      expect(card.data.origin?.agentId).toBe("alice");
      expect(card.data.text).toContain("FIXTURE_SELECTED");
      expect(card.data.text).not.toContain("FIXTURE_PRIVATE");
      // The originating turn cannot finish before this exact device answer.
      expect(events.some(e => e.id === `native:${id}:final`)).toBe(false);
      inaccessible(await invoke("bob", [read("alice"), search("alice")]));
      expect(events.some(e => e.id === `native:${id}:final`)).toBe(false);
      send("harness_action_answer", { version: 1, requestId: card.data.requestId, origin: card.data.origin, choiceId }, card.threadId);
      expect(await result(id)).toEqual([choiceId === "deny" ? denied : { result: { ok: true } }]);
      if (choiceId === "deny") inaccessible(await invoke("bob", [read("alice"), search("alice")]));
    }
    expect(await invoke("bob", [read("alice"), search("alice")])).toEqual([
      { result: { value: "FIXTURE_SELECTED" } }, { result: { entries: [{ key: "selected", body: "FIXTURE_SELECTED" }] } },
    ]);
    expect(await invoke("alice", [{ action: "revoke", key: "selected", toAgentId: "bob", operationId: "revoke-a" }]))
      .toEqual([{ result: { ok: true } }]);
    inaccessible(await invoke("bob", [read("alice"), search("alice")]));
    // A fresh transport request cannot reuse a mutation identity for different content.
    expect(await invoke("alice", [write("selected", "FIXTURE_CHANGED", "write-a"), read("alice")]))
      .toEqual([denied, { result: { value: "FIXTURE_SELECTED" } }]);
    expect(launches.sort()).toEqual(["alice", "bob"]);
    expect(forbiddenNative).not.toHaveBeenCalled();
  } finally {
    phone?.ws.terminate();
    try { await host?.close(); } finally { await relay.close(); vi.unstubAllEnvs(); rmSync(root, { recursive: true, force: true }); }
  }
}, 90_000);

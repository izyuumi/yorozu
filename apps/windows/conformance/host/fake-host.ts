import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import { registerHooks } from "node:module";
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import type { Link } from "../../../../plugins/openclaw-yorozu/src/hub.ts";
registerHooks({
  resolve(specifier, context, next) {
    if (specifier.startsWith("./") && specifier.endsWith(".js") && context.parentURL) {
      const ts = new URL(specifier.replace(/\.js$/, ".ts"), context.parentURL);
      if (existsSync(ts)) return next(ts.href, context);
    }
    return next(specifier, context);
  },
});
const { Hub } = await import("../../../../plugins/openclaw-yorozu/src/hub.ts");
const { pairer, PendingPairings, pairingQuery } = await import("../../../../plugins/openclaw-yorozu/src/pairing.ts");
const { b64u, decodeFrame, ed25519Keypair, roomId, signFrame, x25519Keypair } = await import("../../../../plugins/openclaw-yorozu/src/wire.ts");
const { startRelay } = await import("../../../relay/src/index.ts");
const { connectMac, mintToken } = await import("../../../relay/src/testing.ts");
const { createPrivateKey } = await import("node:crypto");

export async function fakeHost() {
  const relay = await startRelay(0);
  const signing = ed25519Keypair();
  const identity = { pub: b64u(signing.publicKey), priv: createPrivateKey({ key: Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), signing.privateKey]), format: "der", type: "pkcs8" }) };
  const keys = { static: x25519Keypair(), room: roomId(signing.publicKey) };
  const pending = new PendingPairings();
  const devices = new Map<string, string>();
  const messages: unknown[] = [];
  let mac: Awaited<ReturnType<typeof connectMac>>;
  let link: Link;
  const announce = () => mac.send({ type: "devices", devices: [...devices.keys()] });
  const pair = pairer({ pending, put: async d => { devices.set(d.signingPub, d.staticPub); announce(); return []; }, forget: () => {}, allowlist: async () => [...devices.keys()], relaySend: () => null });
  const hub = new Hub({
    keys, peerInfo: () => ({ app: "conformance", protocolMin: 3, protocolMax: 3, capabilities: ["devices", "unversioned-wire"] }),
    staticKeyOf: async key => devices.get(key), pair,
    refused: pubkey => mac.send({ type: "revoke", pubkey }),
    onMessage: message => { messages.push(message); hub.broadcast([{ kind: "run_started", data: message }, { kind: "reply", data: { ...message, text: "echo: " + message.text, ts: Date.now() } }]); },
    dispatch: async ({ event, reply }) => {
      if (event.kind === "conv_list") { reply([{ kind: "conv_list", data: { conversations: [] } }]); return true; }
      if (event.kind === "history") { reply([{ kind: "history", data: { convId: event.data.convId, items: [], more: false, rev: 0 } }]); return true; }
      if (event.kind === "read_cursor") { reply([event]); return true; }
      return false;
    },
    directHints: undefined, onPeer: undefined, log: undefined,
  });
  async function reconnect() {
    mac = await connectMac(relay.port, identity);
    announce();
    link = { path: "relay", send(payloads) {
      for (let i = 0; i < payloads.length; i += 16) {
        const frames = payloads.slice(i, i + 16).map(payload => ({ payload, sig: signFrame(signing.privateKey, payload) }));
        mac.send(frames.length === 1 ? { type: "frame", ...frames[0] } : { type: "frame", frames });
      }
    } };
    const thisMac = mac;
    const thisLink = link;
    // Preserve receive order across async Hub calls.
    let chain = Promise.resolve();
    mac.ws.on("message", raw => {
      const value = JSON.parse(raw.toString());
      if (value.type !== "frame") return;
      chain = chain.then(async () => {
        const frame = decodeFrame(value.payload);
        if (frame?.type === "init") await hub.handshake(value.payload, value.sig, thisLink);
        else if (frame?.type === "box") { const opened = hub.open(frame, thisLink); if (opened) await hub.handle(opened); }
        if (typeof value.seq === "number") thisMac.send({ type: "ack", seq: value.seq });
      });
    });
    mac.ws.on("close", () => hub.detach(thisLink));
  }
  await reconnect();
  return {
    relay, hub, devices, messages, reconnect,
    async link() { return "yorozu://pair?" + pairingQuery({ relayUrl: `ws://127.0.0.1:${relay.port}`, hostStatic: keys.static.publicKey, token: await mintToken({ ...mac, next: async () => { while (true) { const value = await mac.next(); if (value.type === "token") return value; } } }), room: keys.room, secret: pending.add(Date.now() + 600_000) }); },
    async close() { const closed = mac.closed; mac.ws.close(); await closed; },
    async stop() { await relay.close(); },
  };
}

export function probe(dir: string, extra: string[] = []) {
  const bin = process.env.YOROZU_PROBE_BIN;
  assert.ok(bin && existsSync(bin), "YOROZU_PROBE_BIN must point to the built probe");
  const child = spawn(bin, ["--dir", dir, "--fast", ...extra], { stdio: ["pipe", "pipe", "pipe"] });
  const events: any[] = [];
  let stderr = "";
  child.stderr.on("data", chunk => { stderr += chunk; });
  const waiters = new Set<() => void>();
  createInterface({ input: child.stdout }).on("line", line => { events.push(JSON.parse(line)); for (const wake of waiters) wake(); });
  const exited = new Promise<void>((resolve, reject) => {
    child.on("error", reject);
    child.on("exit", code => { if (code === 0) resolve(); else reject(new Error(`probe exit ${code}: ${stderr}`)); for (const wake of waiters) wake(); });
  });
  // Tests await exited when a controlled process exit is part of the scenario.
  void exited.catch(() => {});
  return {
    child, events, exited,
    send(cmd: unknown) { child.stdin.write(JSON.stringify(cmd) + "\n"); },
    async wait(predicate: (event: any) => boolean, from = 0): Promise<any> {
      const deadline = Date.now() + 8000;
      while (true) {
        const event = events.slice(from).find(predicate); if (event) return event;
        if (Date.now() >= deadline || child.exitCode !== null) throw new Error(`probe wait failed: ${JSON.stringify(events)} ${stderr}`);
        await new Promise<void>(resolve => { const wake = () => { clearTimeout(timer); waiters.delete(wake); resolve(); }; const timer = setTimeout(wake, Math.min(100, deadline - Date.now())); waiters.add(wake); });
      }
    },
    async quit() { if (child.exitCode === null) child.stdin.end('{"cmd":"quit"}\n'); await exited; },
  };
}

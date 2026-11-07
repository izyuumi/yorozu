/// <reference types="@cloudflare/vitest-pool-workers/types" />

import { env, runInDurableObject, SELF } from "cloudflare:test";
import { afterEach, expect, test, vi } from "vitest";

// Vite supplies this transform; Vite itself is not a direct relay dependency.
declare global {
  interface ImportMeta {
    glob(pattern: string, options: { eager: true; import: "default" }): Record<string, unknown>;
  }
}

const ED25519 = { name: "Ed25519" } as const;
const DEVICE_TOKEN = "a".repeat(64);
const ACTIVITY_TOKEN = "e".repeat(64);
const ACTIVITY_STATE = {
  jobs: [{ token: "AAAAAAAAAAAAAAAA", kind: "turn", state: "running", steps: 3, startedAt: 821_692_800 }],
};

interface Keys { pub: string; priv: CryptoKey }
interface SavedKeys { pub: string; priv: JsonWebKey }
interface Fixture {
  producer: string;
  scenario: "announced" | "unannounced" | "sixteen";
  entries: [string, unknown][];
  keys: { host: SavedKeys; devices: SavedKeys[] };
}

function toBase64Url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

async function keypair(): Promise<Keys> {
  const pair = await crypto.subtle.generateKey(ED25519, true, ["sign", "verify"]) as CryptoKeyPair;
  return { pub: toBase64Url(new Uint8Array(await crypto.subtle.exportKey("raw", pair.publicKey) as ArrayBuffer)), priv: pair.privateKey };
}

async function save(keys: Keys): Promise<SavedKeys> {
  return { pub: keys.pub, priv: await crypto.subtle.exportKey("jwk", keys.priv) as JsonWebKey };
}

async function restore(keys: SavedKeys): Promise<Keys> {
  return { pub: keys.pub, priv: await crypto.subtle.importKey("jwk", keys.priv, ED25519, true, ["sign"]) };
}

async function sign(data: string, keys: Keys): Promise<string> {
  return toBase64Url(new Uint8Array(await crypto.subtle.sign(ED25519, keys.priv, new TextEncoder().encode(data))));
}

async function roomId(pubkey: string): Promise<string> {
  const bin = atob(pubkey.replace(/-/g, "+").replace(/_/g, "/"));
  return toBase64Url(new Uint8Array(await crypto.subtle.digest("SHA-256", Uint8Array.from(bin, (c) => c.charCodeAt(0)))));
}

const room = (name: string) => {
  const rooms = (env as unknown as { ROOM: DurableObjectNamespace }).ROOM;
  return rooms.get(rooms.idFromName(name));
};

interface Client {
  phones: number[];
  send(message: unknown): void;
  close(): void;
  next(): Promise<any>;
  closed(): Promise<CloseEvent>;
}
const clients: Client[] = [];

async function connect(name: string): Promise<Client> {
  const response = await SELF.fetch(`https://relay.test/?room=${encodeURIComponent(name)}`, {
    headers: { Upgrade: "websocket" },
  });
  expect(response.status).toBe(101);
  const ws = response.webSocket!;
  const queue: any[] = [];
  const waiters: ((value: any) => void)[] = [];
  const phones: number[] = [];
  let closing = false;
  let closed: CloseEvent | undefined;
  const closers: ((event: CloseEvent) => void)[] = [];
  ws.addEventListener("message", (event: MessageEvent) => {
    const message = JSON.parse(String(event.data));
    if (message.type === "phones") return void phones.push(message.count);
    if (message.type === "owner") return;
    const waiter = waiters.shift();
    if (waiter) waiter(message);
    else queue.push(message);
  });
  ws.addEventListener("close", (event: CloseEvent) => {
    closed = event;
    for (const done of closers.splice(0)) done(event);
  });
  ws.accept();
  const client = {
    phones,
    send: (message: unknown) => ws.send(JSON.stringify(message)),
    close: () => {
      if (closing || closed) return;
      closing = true;
      ws.close();
    },
    next: (): Promise<any> => queue.length ? Promise.resolve(queue.shift()) : new Promise((done) => waiters.push(done)),
    closed: (): Promise<CloseEvent> => closed ? Promise.resolve(closed) : new Promise((done) => closers.push(done)),
  };
  clients.push(client);
  return client;
}

afterEach(() => {
  // Client-initiated closes do not emit a client close event in the test pool.
  for (const client of clients.splice(0)) client.close();
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

async function register(keys: Keys): Promise<Client> {
  const name = await roomId(keys.pub);
  const host = await connect(name);
  const { nonce } = await host.next();
  host.send({ type: "register", pubkey: keys.pub, nonceSig: await sign(nonce, keys) });
  expect(await host.next()).toMatchObject({ type: "registered", roomId: name });
  return host;
}

async function macSettled(host: Client): Promise<void> {
  await mint(host);
}

async function mint(host: Client): Promise<string> {
  host.send({ type: "mint" });
  const message = await host.next();
  expect(message.type).toBe("token");
  return message.token;
}

async function join(name: string, keys: Keys, token?: string): Promise<Client> {
  const device = await connect(name);
  const { nonce } = await device.next();
  device.send({ type: "join", roomId: name, phonePubkey: keys.pub, sig: await sign(token ?? nonce, keys), ...(token ? { token } : {}) });
  expect(await device.next()).toMatchObject({ type: "joined" });
  return device;
}

type Call = { url: string; body: any };
function fakeApns(): Call[] {
  const calls: Call[] = [];
  vi.stubGlobal("fetch", async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(input), body: JSON.parse(String(init?.body)) });
    return new Response(null, { status: 200 });
  });
  return calls;
}

function activityPush(device: string) {
  return { type: "activityPush", device, event: "update", priority: 5, state: ACTIVITY_STATE };
}

test.skipIf(import.meta.env.VITE_COMPAT_CAPTURE !== "1").each(["announced", "unannounced", "sixteen"] as const)("capture compatibility fixture: %s", async (scenario) => {
  const hostKeys = await keypair();
  const name = await roomId(hostKeys.pub);
  const host = await register(hostKeys);
  const devices = await Promise.all(Array.from({ length: scenario === "sixteen" ? 16 : scenario === "announced" ? 2 : 1 }, () => keypair()));
  const joined: Client[] = [];
  const count = scenario === "sixteen" ? 16 : 1;
  for (let start = 0; start < count; start += 8) {
    const tokens: string[] = [];
    for (let i = start; i < Math.min(start + 8, count); i++) tokens.push(await mint(host));
    for (let i = 0; i < tokens.length; i++) joined.push(await join(name, devices[start + i]!, tokens[i]!));
  }
  if (scenario === "announced") {
    joined[0]!.send({ type: "push", deviceToken: DEVICE_TOKEN });
    await macSettled(host);
  }
  if (scenario !== "unannounced") {
    host.send({ type: "devices", devices: devices.map((keys) => keys.pub) });
    if (scenario === "announced") host.send({ type: "activityToken", device: devices[0]!.pub, token: ACTIVITY_TOKEN });
    await macSettled(host);
  }
  await macSettled(host);
  // Capture persistent storage before cleanup; socket attachments do not survive deploys.
  const entries = await runInDurableObject(room(name), async (_instance, state) => [...await state.storage.list()]);
  const keys = { host: await save(hostKeys), devices: await Promise.all(devices.map(save)) };
  const fixture = { producer: import.meta.env.VITE_COMPAT_PRODUCER ?? "unknown", scenario, entries, keys };
  await expect(JSON.stringify(fixture, null, 2) + "\n").toMatchFileSnapshot(`./compat-fixtures/captured/${scenario}.json`);
  console.log("COMPAT_FIXTURE " + JSON.stringify(fixture));
}, 30_000);

const fixtures = import.meta.glob("./compat-fixtures/*.json", { eager: true, import: "default" });
const cases = (scenario: Fixture["scenario"]) => Object.entries(fixtures)
  .map(([file, value]) => ({ file, ...value as Fixture }))
  .filter((fixture) => fixture.scenario === scenario);

async function load(fixture: Fixture) {
  const hostKeys = await restore(fixture.keys.host);
  const devices = await Promise.all(fixture.keys.devices.map(restore));
  const name = await roomId(hostKeys.pub);
  await runInDurableObject(room(name), async (_instance, state) => {
    await state.storage.deleteAll();
    expect((await state.storage.list()).size).toBe(0);
    for (const [key, value] of fixture.entries) await state.storage.put(key, value);
  });
  const host = await register(hostKeys);
  host.send({ type: "devices", devices: devices.map((keys) => keys.pub) });
  await macSettled(host);
  return { host, devices, name };
}

test.each(cases("announced"))("R1: replay announced storage, rejoin and push ($producer, $file)", async (fixture) => {
  const calls = fakeApns();
  const { host, devices, name } = await load(fixture);
  await join(name, devices[0]!);
  host.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  await macSettled(host);
  await vi.waitFor(() => expect(calls).toHaveLength(1));
  expect(new URL(calls[0]!.url).pathname).toBe(`/3/device/${DEVICE_TOKEN}`);
  const now = Date.now();
  vi.spyOn(Date, "now").mockReturnValue(now);
  host.send(activityPush(devices[0]!.pub));
  await macSettled(host);
  await vi.waitFor(() => expect(calls).toHaveLength(2));
  expect(new URL(calls[1]!.url).pathname).toBe(`/3/device/${ACTIVITY_TOKEN}`);
  expect(calls[1]!.body.aps.timestamp).toBe(Math.floor(now / 1000));
});

test.each(cases("announced"))("R2: replay announced storage, revoke closes and forgets push targets ($producer, $file)", async (fixture) => {
  const calls = fakeApns();
  const { host, devices, name } = await load(fixture);
  const device = await join(name, devices[0]!);
  host.send({ type: "revoke", pubkey: devices[0]!.pub });
  const closed = await device.closed();
  expect(closed.code).toBe(4001);
  expect(closed.reason).toBe("revoked");
  host.send({ type: "notify", class: "reply", threadRef: "Ab3-_x9Z" });
  host.send(activityPush(devices[0]!.pub));
  await macSettled(host);
  // Push delivery runs in waitUntil, after the websocket message has settled.
  await new Promise((resolve) => setTimeout(resolve, 50));
  expect(calls).toHaveLength(0);
});

test.each(cases("unannounced"))("R3: replay unannounced storage, announce and nonce-rejoin ($producer, $file)", async (fixture) => {
  const { devices, name } = await load(fixture);
  await join(name, devices[0]!);
});

test.each(cases("sixteen"))("R4: replay sixteen stored devices and nonce-rejoin all sixteen ($producer, $file)", async (fixture) => {
  const { devices, name } = await load(fixture);
  expect(devices).toHaveLength(16);
  for (const keys of devices) await join(name, keys);
});

/** Host-minted synthetic scopes; injected endpoints and transport, no sockets/auth. */
import { afterEach, expect, test, vi } from "vitest";
import { EventEmitter } from "node:events";
import { mkdirSync, mkdtempSync, realpathSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { PersonAgentStore } from "./agent-store.js";
import { createSiwcPersonBroker, siwcHermesFunctions } from "./siwc-person-broker.js";
import type { SiwcAccessToken } from "./siwc-inference-broker.js";
import type { PersonAgentExecution } from "./person-agent-runtime.js";

const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
function fixture() {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "siwc-person-fixture-"))); roots.push(root);
  const shared = join(root, "shared"), protectedRoot = join(shared, "host-secrets"); mkdirSync(protectedRoot, { recursive: true });
  const store = new PersonAgentStore(join(root, "state"), { resourceRoots: [{ path: shared, access: "write" }], protectedRoots: [protectedRoot] });
  for (const id of ["alice", "bob", "carol"]) store.create({ id, name: id, role: "fixture", pluginId: "hermes", model: "selected-model",
    accountBindingId: "synthetic-account", allowedTools: ["file", "memory", "delegation", "team"], directories: [{ path: shared, access: "write" }] }, store.list().revision);
  store.createTeam({ id: "team", name: "Team", agentIds: ["alice", "bob", "carol"] }, store.list().revision);
  let executable = true, current = true;
  const token: SiwcAccessToken = { accountBindingId: "synthetic-account", clientId: "oaiapp_fixture", subject: "synthetic-subject",
    verification: "host-validated-siwc-v1", storage: "os-protected", audience: "https://api.openai.com/v1",
    scopes: ["resource.invoke", "chatgpt.tokens.use.direct"], expiresAt: Date.now() + 3_600_000, accessToken: "synthetic-provider-token-123456" };
  const accounts = { isAccountCurrent: () => executable, getAccessToken: vi.fn(async () => ({ ...token })) };
  const handlers: Array<(request: any, response: any) => void> = [], closed = vi.fn();
  const transport = vi.fn(async () => ({ status: 200, contentType: "text/event-stream", body: (async function* () {
    yield Buffer.from('event: response.completed\ndata: {"type":"response.completed","response":{"id":"resp_fixture","status":"completed","service_tier":"default","output":[]}}\n\n');
  })() }));
  const broker = createSiwcPersonBroker({ getAccounts: () => accounts,
    assertScope: (agent, scope) => { store.knowledgeFor(agent.id, scope); if (JSON.stringify(agent) !== JSON.stringify(store.list().agents.find(a => a.id === agent.id))) throw new Error("Changed agent"); },
    isExecutionCurrent: () => current, transport,
    openEndpoint: async handler => { handlers.push(handler); return { host: "127.0.0.1", port: 54321, close: closed }; } });
  const agent = (id = "alice") => store.list().agents.find(a => a.id === id)!;
  const execution = (id = "a".repeat(64)): PersonAgentExecution => ({ id, kind: "ordinary", scratchRoot: root, workspace: root, memoryDir: root });
  const dispatch = async (index: number, bearer: string, name?: string) => {
    const req = Object.assign(new EventEmitter(), { method: "POST", url: "/v1/responses", socket: { remoteAddress: "127.0.0.1" },
      headers: { host: "127.0.0.1:54321", authorization: `Bearer ${bearer}`, "content-type": "application/json" },
      async *[Symbol.asyncIterator]() { yield Buffer.from(JSON.stringify({ model: "selected-model", input: [{ role: "user", content: "Fixture" }], store: false, stream: true,
        ...(name ? { tools: [{ type: "function", name, description: "fixture", parameters: { type: "object", properties: {} } }] } : {}) })); } });
    let done!: () => void; const ended = new Promise<void>(resolve => { done = resolve; });
    const out = Object.assign(new EventEmitter(), { status: 0, body: "", destroyed: false, writableEnded: false,
      writeHead(status: number) { this.status = status; }, write(chunk: Uint8Array) { this.body += Buffer.from(chunk).toString(); return true; },
      end() { this.writableEnded = true; done(); } });
    handlers[index](req, out); await ended; return out;
  };
  return { root, store, protectedRoot, broker, accounts, token, agent, execution, handlers, closed, transport, dispatch,
    setCurrent(value: boolean) { current = value; }, setExecutable(value: boolean) { executable = value; } };
}

test("the broker forwards exact selected functions and refreshes tokens per request without exposing provider credentials", async () => {
  const f = fixture(), scope = f.store.resolveScope("alice");
  const selected = await f.broker.selectBroker(f.agent(), f.execution(), scope);
  expect(selected).toBeDefined(); expect(JSON.stringify(selected)).not.toContain(f.token.accessToken);
  expect((await f.dispatch(0, selected!.bearer, "read_file")).status).toBe(200);
  expect((await f.dispatch(0, selected!.bearer, "terminal")).status).toBe(400);
  expect(f.transport).toHaveBeenCalledOnce(); expect(f.accounts.getAccessToken).toHaveBeenCalledTimes(2);
  await f.broker.close(); expect(f.closed).toHaveBeenCalledOnce();
});

test("cloned, stale, changed-identity and unsupported tool scopes refuse before endpoint admission", async () => {
  const f = fixture(), scope = f.store.resolveScope("alice");
  await expect(f.broker.selectBroker(f.agent(), f.execution(), structuredClone(scope))).rejects.toThrow();
  await expect(f.broker.selectBroker({ ...f.agent(), model: "forged" }, f.execution(), scope)).rejects.toThrow();
  expect(() => siwcHermesFunctions({ ...scope, allowedTools: ["terminal"] })).toThrow();
  f.store.update("alice", { name: "Changed" }, f.store.list().revision);
  await expect(f.broker.selectBroker(f.agent(), f.execution(), scope)).rejects.toThrow();
  expect(f.handlers).toHaveLength(0); await f.broker.close();
});

test("recursive teammate execution keeps the origin/handoff/recipient intersection and omits private memory", async () => {
  const f = fixture(), origin = f.store.resolveScope("alice");
  const b = f.store.delegateScope(origin, { allowedTools: ["file", "delegation", "team"], directories: origin.directories, knowledgeIds: [] }, "bob");
  const c = f.store.delegateScope(b, { allowedTools: ["file"], directories: b.directories, knowledgeIds: [] }, "carol");
  expect(c.chain).toEqual(["alice", "bob", "carol"]);
  const selected = await f.broker.selectBroker(f.agent("carol"), f.execution("c".repeat(64)), c);
  expect(siwcHermesFunctions(c)).toEqual(["patch", "read_file", "search_files", "write_file"]);
  expect((await f.dispatch(0, selected!.bearer, "memory")).status).toBe(400);
  expect(f.transport).not.toHaveBeenCalled(); expect(c.deniedRoots).toContain(f.protectedRoot); await f.broker.close();
});

test("temporary refresh holds resume the existing broker; retirement and stale execution cannot send or replay", async () => {
  const f = fixture(), scope = f.store.resolveScope("alice"), execution = f.execution();
  const selected = await f.broker.selectBroker(f.agent(), execution, scope);
  f.setExecutable(false); expect((await f.dispatch(0, selected!.bearer)).status).not.toBe(200);
  f.setExecutable(true); expect((await f.dispatch(0, selected!.bearer)).status).toBe(200);
  f.setCurrent(false); expect((await f.dispatch(0, selected!.bearer)).status).not.toBe(200); f.setCurrent(true);
  f.broker.stopAccount("synthetic-account"); expect((await f.dispatch(0, selected!.bearer)).status).not.toBe(200);
  await expect(f.broker.selectBroker(f.agent(), execution, scope)).rejects.toThrow();
  expect(f.transport).toHaveBeenCalledOnce(); await f.broker.close();
});

test("an admitted stream continues during sibling token rotation while fresh dispatch waits for the new token", async () => {
  const f = fixture(), scope = f.store.resolveScope("alice"), selected = await f.broker.selectBroker(f.agent(), f.execution(), scope);
  let continueStream!: () => void, started!: () => void;
  const streaming = new Promise<void>(resolve => { started = resolve; }), continuation = new Promise<void>(resolve => { continueStream = resolve; });
  f.transport.mockImplementationOnce(async () => ({ status: 200, contentType: "text/event-stream", body: (async function* () {
    started(); await continuation;
    yield Buffer.from('event: response.completed\ndata: {"type":"response.completed","response":{"id":"resp_fixture","status":"completed","service_tier":"default","output":[]}}\n\n');
  })() }));
  const first = f.dispatch(0, selected!.bearer); await streaming;
  let rotate!: () => void, rotating!: () => void;
  const rotationStarted = new Promise<void>(resolve => { rotating = resolve; }), rotated = new Promise<void>(resolve => { rotate = resolve; });
  f.accounts.getAccessToken.mockImplementationOnce(async () => { rotating(); await rotated; return { ...f.token, accessToken: "synthetic-rotated-provider-123456" }; });
  const second = f.dispatch(0, selected!.bearer); await rotationStarted;
  expect(f.transport).toHaveBeenCalledOnce(); continueStream(); expect((await first).body).toContain("response.completed");
  rotate(); expect((await second).status).toBe(200); expect(f.transport).toHaveBeenCalledTimes(2); await f.broker.close();
});

test("helper loss fences every observed broker without registry readback", async () => {
  const f = fixture(), aScope = f.store.resolveScope("alice"), bScope = f.store.resolveScope("bob");
  const a = await f.broker.selectBroker(f.agent(), f.execution(), aScope), b = await f.broker.selectBroker(f.agent("bob"), f.execution("b".repeat(64)), bScope);
  f.store.update("alice", { name: "Changed registry" }, f.store.list().revision);
  expect(f.broker.stopAll()).toEqual(["synthetic-account"]);
  expect((await f.dispatch(0, a!.bearer)).status).not.toBe(200); expect((await f.dispatch(1, b!.bearer)).status).not.toBe(200);
  expect(f.transport).not.toHaveBeenCalled(); await f.broker.close();
});

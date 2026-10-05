/** Host-minted synthetic scopes; injected endpoints and transport, no sockets/auth. */
import { afterEach, expect, test, vi } from "vitest";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { fileURLToPath } from "node:url";
import { prepareRuntime, UPSTREAM } from "../../harness-plugins/hermes/adapter.mjs";
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
function fixture(allowedTools = ["file", "memory", "delegation", "team"], team = true) {
  const root = realpathSync(mkdtempSync(join(tmpdir(), "siwc-person-fixture-"))); roots.push(root);
  const shared = join(root, "shared"), protectedRoot = join(shared, "host-secrets"); mkdirSync(protectedRoot, { recursive: true });
  const store = new PersonAgentStore(join(root, "state"), { resourceRoots: [{ path: shared, access: "write" }], protectedRoots: [protectedRoot] });
  for (const id of ["alice", "bob", "carol"]) store.create({ id, name: id, role: "fixture", pluginId: "hermes", model: "selected-model",
    accountBindingId: "synthetic-account", allowedTools, directories: [{ path: shared, access: "write" }] }, store.list().revision);
  if (team) store.createTeam({ id: "team", name: "Team", agentIds: ["alice", "bob", "carol"] }, store.list().revision);
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
    assertScope: (agent, scope) => { store.assertActorScope(scope); if (JSON.stringify(agent) !== JSON.stringify(store.list().agents.find(a => a.id === agent.id))) throw new Error("Changed agent"); },
    isExecutionCurrent: () => current, transport,
    openEndpoint: async handler => { handlers.push(handler); return { host: "127.0.0.1", port: 54321, close: closed }; } });
  const agent = (id = "alice") => store.list().agents.find(a => a.id === id)!;
  const execution = (id = "a".repeat(64)): PersonAgentExecution => ({ id, kind: "ordinary", scratchRoot: root, workspace: root, memoryDir: root });
  const dispatch = async (index: number, bearer: string, name?: string | Record<string, unknown>[]) => {
    const req = Object.assign(new EventEmitter(), { method: "POST", url: "/v1/responses", socket: { remoteAddress: "127.0.0.1" },
      headers: { host: "127.0.0.1:54321", authorization: `Bearer ${bearer}`, "content-type": "application/json" },
      async *[Symbol.asyncIterator]() { yield Buffer.from(JSON.stringify({ model: "selected-model", input: [{ role: "user", content: "Fixture" }], store: false, stream: true,
        ...(name ? { tools: Array.isArray(name) ? name : [{ type: "function", name, description: "fixture", parameters: { type: "object", properties: {} } }] } : {}) })); } });
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

test("recursive teammate execution keeps resource intersection while native reasoning stays profile-local", async () => {
  const f = fixture(), origin = f.store.resolveScope("alice");
  const b = f.store.delegateScope(origin, { allowedTools: ["file", "delegation", "team"], directories: origin.directories, knowledgeIds: [] }, "bob");
  const c = f.store.delegateScope(b, { allowedTools: ["file"], directories: b.directories, knowledgeIds: [] }, "carol");
  expect(c.chain).toEqual(["alice", "bob", "carol"]);
  const selected = await f.broker.selectBroker(f.agent("carol"), f.execution("c".repeat(64)), c);
  expect(siwcHermesFunctions(c)).toEqual(["delegate_task", "memory", "patch", "read_file", "search_files", "write_file"]);
  expect((await f.dispatch(0, selected!.bearer, "memory")).status).toBe(200);
  expect((await f.dispatch(0, selected!.bearer, "delegate_to_agent")).status).toBe(400);
  expect(f.transport).toHaveBeenCalledOnce(); expect(c.deniedRoots).toContain(f.protectedRoot); await f.broker.close();
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


test("an existing broker endpoint survives unrelated registry/default edits", async () => {
  const f = fixture(), scope = f.store.resolveScope("alice");
  const selected = await f.broker.selectBroker(f.agent(), f.execution(), scope);
  f.store.update("bob", { name: "Bob renamed" }, f.store.list().revision);
  f.store.default("carol", f.store.list().revision);
  expect((await f.dispatch(0, selected!.bearer, "read_file")).status).toBe(200);
  f.store.update("alice", { allowedTools: ["file"] }, f.store.list().revision);
  expect((await f.dispatch(0, selected!.bearer, "read_file")).status).toBe(403);
  await f.broker.close();
});

// Uses the *packaged* adapter configuration, bootstrap discovery and pinned Hermes
// Responses conversion, never a parallel handwritten list of model definitions.
// No Gateway is constructed, and socket connection attempts fail the fixture.
const nativeFixture = Boolean(process.env.YOROZU_HERMES_TEST_SOURCE && process.env.YOROZU_HERMES_TEST_PYTHON);
for (const team of [false, true]) test.skipIf(!nativeFixture)(`actual Hermes default file-only request reaches inert broker (team=${team})`, async () => {
  const f = fixture(["file"], team), scope = f.store.resolveScope("alice"), agent = f.agent();
  const selected = await f.broker.selectBroker(agent, f.execution(), scope);
  try {
    const runtime = await prepareRuntime({ protocolVersion: 1, upstreamVersion: UPSTREAM.version,
      profileRoot: join(f.root, "native-profile"), workspace: agent.workspace,
      python: process.env.YOROZU_HERMES_TEST_PYTHON, sourcePath: process.env.YOROZU_HERMES_TEST_SOURCE,
      agentId: agent.id, scope: { allowedTools: scope.allowedTools, directories: scope.directories, workspace: agent.workspace, memoryDir: agent.memoryDir },
      isolation: { backend: "macos-seatbelt-v1", agentId: agent.id, policyDigest: "a".repeat(64) },
      platform: { team: agent.teamIds.length > 0, computer: false, peers: team ? [{ agentId: "bob", name: "bob", pluginId: "hermes" }] : [] } });
    const { stdout } = await promisify(execFile)(runtime.python, ["-c", `
import socket, runpy, sys, json, contextlib
def forbidden(*args, **kwargs):
    raise AssertionError("offline contract fixture must not connect to a provider or Gateway")
socket.socket.connect = forbidden
socket.socket.connect_ex = forbidden
socket.create_connection = forbidden
with contextlib.redirect_stdout(sys.stderr):
    selected = runpy.run_path(sys.argv[1])["verify"]()
    from model_tools import get_tool_definitions
    from agent.codex_responses_adapter import _responses_tools
    definitions = get_tool_definitions(selected["toolsets"], quiet_mode=True, skip_tool_search_assembly=True)
    tools = _responses_tools(definitions)
print(json.dumps(tools))
`, fileURLToPath(new URL("../../harness-plugins/hermes/bootstrap.py", import.meta.url))],
      { cwd: runtime.sourcePath, env: runtime.env, maxBuffer: 1024 * 1024, timeout: 30_000 });
    const tools = JSON.parse(stdout), names = tools.map((tool: any) => tool.name);
    expect(names).toEqual(expect.arrayContaining(["memory", "delegate_task", "read_file"]));
    expect(names.includes("send_agent_message")).toBe(team); expect(names.includes("read_agent_messages")).toBe(team);
    expect(names).not.toContain("delegate_to_agent");
    expect([...names].sort()).toEqual(siwcHermesFunctions(scope, team));
    expect((await f.dispatch(0, selected!.bearer, tools)).status).toBe(200);
    expect(f.transport).toHaveBeenCalledOnce();
    for (const name of ["terminal", "execute_code", "web_search", "browser_navigate", "computer", "delegate_to_agent", "get_access_token",
      ...(!team ? ["send_agent_message", "read_agent_messages"] : [])]) {
      expect((await f.dispatch(0, selected!.bearer, [...tools, { type: "function", name, parameters: { type: "object", properties: {} } }])).status).toBe(400);
    }
    expect(f.transport).toHaveBeenCalledOnce();
    expect(f.store.resolveScope("alice").directories).toEqual(scope.directories);
    expect(f.store.resolveScope("alice").allowedTools).toEqual(["file"]);
  } finally { await f.broker.close(); }
}, 60_000);

test.each([false, true])("native schema contract preserves empty resource scope and membership-only inbox (team=%s)", async team => {
  const f = fixture([], team), scope = f.store.resolveScope("alice"), selected = await f.broker.selectBroker(f.agent(), f.execution(), scope);
  try {
    for (const name of ["memory", "delegate_task", ...(team ? ["send_agent_message", "read_agent_messages"] : [])])
      expect((await f.dispatch(0, selected!.bearer, name)).status).toBe(200);
    const accepted = f.transport.mock.calls.length;
    for (const name of ["read_file", "write_file", "patch", "search_files", "terminal", "web_search", "browser", "computer", "delegate_to_agent",
      ...(!team ? ["send_agent_message", "read_agent_messages"] : [])])
      expect((await f.dispatch(0, selected!.bearer, name)).status).toBe(400);
    expect(f.transport).toHaveBeenCalledTimes(accepted);
    expect(siwcHermesFunctions({ ...scope, allowedTools: ["team"] })).toEqual(["delegate_task", "memory"]);
    for (const tool of ["terminal", "web", "browser", "computer", "unknown"])
      expect(() => siwcHermesFunctions({ ...scope, allowedTools: [tool] }, team)).toThrow();
  } finally { await f.broker.close(); }
});

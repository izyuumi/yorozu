import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm, mkdir } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { createRequire } from 'node:module';
import { createAdapterMemoryClient, createMemoryHostBridge, memoryRequest, registerMemoryPlugin, uniformMemoryConfig } from './memory-bridge.mjs';
const root = await mkdtemp(join(realpathSync(tmpdir()), 'openclaw-memory-'));
for (const file of ['agent-scope', 'worker-memory', 'worker-tools']) {
  const text = await readFile(new URL(`../../runtime/src/${file}.ts`, import.meta.url), 'utf8');
  await writeFile(join(root, `${file}.ts`), text.replace('"./agent-scope.js"', '"./agent-scope.ts"'));
}
const { WorkerMemory } = await import(pathToFileURL(join(root, 'worker-memory.ts')));
const { workerMemoryTools } = await import(pathToFileURL(join(root, 'worker-tools.ts')));
test.after(() => rm(root, { recursive: true, force: true }));
let number = 0;
function fixture(t, approve = async (_request, apply) => apply()) {
  const sql = new WorkerMemory(join(root, `db-${++number}`), id => ['alice', 'bob'].includes(id));
  const alice = sql.bind('alice'), bob = sql.bind('bob');
  let current = true; let calls = 0;
  const bridge = createMemoryHostBridge({ agentId: 'alice', callHost: (method, envelope, authority) => {
    calls++; assert.deepEqual(envelope.execution, { sessionId: 'hs', runId: 'hr', attemptId: 'ha' });
    return workerMemoryTools(alice, authority.assertCurrent, approve)(method, envelope.request, authority.signal);
  } });
  const revoke = bridge.bind({ nativeRunId: 'nr', nativeSessionId: 'ns', sessionKey: 'agent:alice:proof',
    execution: { sessionId: 'hs', runId: 'hr', attemptId: 'ha' }, current: () => current });
  let seq = 0;
  const envelope = request => ({ agentId: 'alice', nativeRunId: 'nr', nativeSessionId: 'ns', sessionKey: 'agent:alice:proof', toolCallId: `c-${++seq}`, request });
  t.after(() => { bridge.close(); sql.close(); });
  return { alice, bob, bridge, revoke, envelope, calls: () => calls, stale: () => { current = false; },
    call: (request, signal) => bridge.dispatch(envelope(request), signal) };
}
const write = { action: 'write', key: 'note', body: 'Fictional private note', operationId: 'op-1' };
const grant = { action: 'grant', key: 'note', toAgentId: 'bob', operationId: 'share-1' };
test('real host SQL write/read/search, two-agent isolation, approved sharing, immediate revoke', async t => {
  let approvals = 0;
  const f = fixture(t, async (request, apply) => { assert.deepEqual(request, grant); approvals++; apply(); });
  assert.deepEqual(await f.call(write), { ok: true });
  assert.throws(() => f.bob.read('alice', 'note'));
  assert.deepEqual(await f.call({ action: 'read', ownerId: 'alice', key: 'note' }), { value: write.body });
  await f.call(grant); assert.equal(approvals, 1); assert.equal(f.bob.read('alice', 'note'), write.body);
  assert.deepEqual(await f.call({ action: 'search', ownerId: 'alice', query: 'private' }), { entries: [{ key: 'note', body: write.body }] });
  await f.call({ ...grant, action: 'revoke', operationId: 'revoke-1' }); assert.throws(() => f.bob.read('alice', 'note'));
});
test('exact native owner/session/key/run currency and model actor injection fail closed', async t => {
  const f = fixture(t);
  for (const field of ['agentId', 'nativeRunId', 'nativeSessionId', 'sessionKey']) {
    const request = f.envelope(write); request[field] = 'forged'; await assert.rejects(() => f.bridge.dispatch(request));
  }
  await assert.rejects(() => f.call({ ...write, agentId: 'bob' }));
  await assert.rejects(() => f.call({ ...write, execution: { runId: 'hr' } }));
  assert.equal(f.calls(), 0); assert.equal(f.alice.read('alice', 'note'), undefined);
});
test('tool call is one-shot; SQL operation conflict is durable', async t => {
  const f = fixture(t); const request = f.envelope(write);
  await f.bridge.dispatch(request); await assert.rejects(() => f.bridge.dispatch(request));
  await assert.rejects(() => f.call({ ...write, body: 'changed' })); assert.equal(f.alice.read('alice', 'note'), write.body);
});
for (const reason of ['revoke', 'stale', 'cancel', 'close']) test(`approval pending: ${reason} fences final SQL apply`, async t => {
  let apply; let resume; let admitted;
  const ready = new Promise(resolve => { admitted = resolve; });
  const approval = new Promise(resolve => { resume = resolve; });
  const f = fixture(t, async (_r, effect) => { apply = effect; admitted(); await approval; effect(); });
  await f.call(write); const controller = new AbortController();
  const pending = f.call(grant, controller.signal); await ready;
  if (reason === 'revoke') f.revoke();
  if (reason === 'stale') f.stale();
  if (reason === 'cancel') controller.abort();
  if (reason === 'close') f.bridge.close();
  assert.throws(() => apply()); resume(); await assert.rejects(pending);
  assert.throws(() => f.bob.read('alice', 'note'));
});
test('denied approval cannot grant', async t => {
  const f = fixture(t, async () => { throw new Error('denied'); }); await f.call(write);
  await assert.rejects(() => f.call(grant)); assert.throws(() => f.bob.read('alice', 'note'));
});
test('revoked native run cannot be inferred from a new run in same session', async t => {
  const f = fixture(t); f.revoke();
  f.bridge.bind({ nativeRunId: 'nr-new', nativeSessionId: 'ns', sessionKey: 'agent:alice:proof',
    execution: { sessionId: 'hs', runId: 'hr', attemptId: 'ha' }, current: () => true });
  await assert.rejects(() => f.call(write)); assert.equal(f.calls(), 0);
});
test('input bounds and exact actions reject prototype and unsupported ownership', () => {
  for (const request of [{ ...write, body: 'a'.repeat(16385) }, { ...write, operationId: '../x' }, { action: '__proto__' },
    { ...write, body: '\0' }, { action: 'grant', toAgentId: '../bob', key: 'note', operationId: 'o' }]) assert.throws(() => memoryRequest(request));
});
test('uniform configuration replaces retained memory slots, hooks, per-agent search and flush', () => {
  const before = { agents: { defaults: { contextInjection: 'always', compaction: { memoryFlush: { enabled: true } } }, entries: { alice: { workspace: '/fictional', memory: { search: { enabled: true } } }, bob: {} } },
    plugins: { slots: { memory: 'memory-core' }, entries: { 'active-memory': { enabled: true } } }, hooks: { enabled: true } };
  const c = uniformMemoryConfig(before, '/fictional/plugin', 'alice', true);
  assert.equal(c.plugins.slots.memory, 'none'); assert.deepEqual(Object.keys(c.plugins.entries), ['yorozu-worker-memory']);
  assert.equal(c.memory.search.enabled, false); assert.equal(c.agents.entries.alice.memory.search.enabled, false);
  assert.equal(c.agents.defaults.compaction.memoryFlush.enabled, false); assert.equal(c.agents.defaults.contextInjection, 'never');
  assert.equal(c.agents.defaults.startupContext.enabled, false); assert.equal(c.hooks.internal.enabled, false);
  assert.equal(before.plugins.slots.memory, 'memory-core');
});
test('native preparation/finalization custody cannot be forged, rewritten, or reused across colliding calls', async () => {
  let factory; let called = 0; let live = true;
  registerMemoryPlugin({ registerTool: value => { factory = value; } },
    { request: async () => { called++; return { ok: true }; } });
  assert.equal(factory.contextVersion, 2);
  const ctx = { agentId: 'alice', sessionKey: 'agent:alice:proof', sessionId: 'ns', assertInvocationCurrent: () => { if (!live) throw new Error('stale'); } };
  const tool = factory.create(ctx); const other = factory.create(ctx); const signal = new AbortController();
  const native = { hookContext: { ...ctx, runId: 'nr' }, toolCallId: 'call', signal: signal.signal };
  await assert.rejects(() => tool.execute('call', write, signal.signal)); assert.equal(called, 0);
  const prepared = tool.prepareBeforeToolCallParams(write, native);
  assert.throws(() => other.finalizeBeforeToolCallParams(prepared, prepared));
  const finalized = tool.finalizeBeforeToolCallParams(prepared, prepared);
  await assert.rejects(() => other.execute('call', finalized, signal.signal));
  await assert.rejects(() => tool.execute('call', { ...finalized }, signal.signal));
  await tool.execute('call', finalized, signal.signal); assert.equal(called, 1);
  await assert.rejects(() => tool.execute('call', finalized, signal.signal));
  const rewrite = tool.prepareBeforeToolCallParams(write, native);
  assert.throws(() => tool.finalizeBeforeToolCallParams({ ...rewrite, body: 'changed' }, rewrite));
  live = false; assert.throws(() => tool.prepareBeforeToolCallParams(write, native));
});
test('native run IDs are never re-admitted after revocation within one bridge lifetime', t => {
  const f = fixture(t); f.revoke();
  assert.throws(() => f.bridge.bind({nativeRunId:'nr', nativeSessionId:'ns', sessionKey:'agent:alice:proof',
    execution:{sessionId:'hs',runId:'hr',attemptId:'ha'},current:()=>true}));
});

test('adapter client relays cancellation by exact request identity and consumes late receipts', async () => {
  const sent = []; const controller = new AbortController();
  const client = createAdapterMemoryClient(frame => sent.push(frame));
  const result = client.callHost('worker.memory', { request: grant }, { signal: controller.signal, assertCurrent() {} });
  assert.equal(sent[0].method, 'worker.memory'); controller.abort(); await assert.rejects(result);
  assert.deepEqual(sent[1], { jsonrpc: '2.0', method: 'worker.memory.cancel', params: { requestId: sent[0].id } });
  assert.equal(client.receive({ jsonrpc: '2.0', id: sent[0].id, result: { ok: true } }), true);
  assert.equal(client.receive({ id: 'unrelated' }), false); client.close();
});

test('actual HarnessProcess cancellation reaches pending approval before real SQL mutation', async t => {
  // Existing local TypeScript compiler only; these are the actual repository host
  // implementations, not a fixture reimplementation of the transport or SQL.
  const dir = join(root, 'host-transport'); await mkdir(dir);
  const require = createRequire(new URL('../../runtime/package.json', import.meta.url));
  const ts = require(process.env.YOROZU_TYPESCRIPT_MODULE ?? 'typescript');
  for (const file of ['harness-process', 'harness-contract', 'agent-listener', 'agent-scope']) {
    const source = await readFile(new URL(`../../runtime/src/${file}.ts`, import.meta.url), 'utf8');
    await writeFile(join(dir, `${file}.js`), ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText);
  }
  await writeFile(join(dir, 'package.json'), '{"type":"module"}');
  const { HarnessProcess } = await import(pathToFileURL(join(dir, 'harness-process.js')));
  const peer = join(dir, 'peer.mjs');
  await writeFile(peer, `import {createInterface} from 'node:readline';
const send=x=>process.stdout.write(JSON.stringify(x)+'\\n');
let waiting;
createInterface({input:process.stdin}).on('line',line=>{const f=JSON.parse(line);
 if(f.method==='initialize') send({jsonrpc:'2.0',id:f.id,result:{protocolVersion:1,pluginId:'openclaw',upstreamVersion:'proof',workerMemory:true,capabilities:{backgroundTasks:false,targetedSteer:false,taskStop:false,approvals:false,reconnect:false,attachments:false}}});
 else if(f.method==='proof.call'){waiting=f.id;send({jsonrpc:'2.0',id:'one',method:'worker.memory',params:f.params});}
 else if(f.method==='proof.cancel'){send({jsonrpc:'2.0',method:'worker.memory.cancel',params:{requestId:'one'}});send({jsonrpc:'2.0',id:f.id,result:{ok:true}});}
 else if(f.id==='one'){send({jsonrpc:'2.0',id:waiting,result:{denied:!!f.error}});}
 else if(f.method==='shutdown'){send({jsonrpc:'2.0',id:f.id,result:{ok:true}});process.exit(0);}
});`);
  const sql = new WorkerMemory(join(root, 'transport-sql'), id => ['alice', 'bob'].includes(id));
  t.after(() => sql.close()); const alice = sql.bind('alice'), bob = sql.bind('bob'); alice.write('note', 'private', 'seed');
  let host; let wasPending = false; let observedAbort = false;
  host = new HarnessProcess({ command: process.execPath, args: [peer], pluginId: 'openclaw', upstreamVersion: 'proof', initialize: { workerMemory: true },
    workerTool: (method, params, signal) => workerMemoryTools(alice, () => {}, async (_r, apply) => {
      wasPending = true; await host.request('proof.cancel', {}); observedAbort = signal.aborted; apply();
    })(method, params, signal) });
  t.after(() => host.close()); await host.start();
  assert.deepEqual(await host.request('proof.call', grant), { denied: true });
  assert.equal(wasPending, true); assert.equal(observedAbort, true); assert.throws(() => bob.read('alice', 'note'));
});

test('uniform mode without an explicit memory grant disables native persistence without advertising any tool', () => {
  const c = uniformMemoryConfig({agents:{defaults:{},entries:{alice:{workspace:'/fictional'}}}}, '/fictional/plugin', 'alice');
  assert.equal(c.plugins.enabled, false); assert.deepEqual(c.plugins.load.paths, []);
  assert.deepEqual(c.tools.deny, ['*']); assert.equal(c.memory.search.enabled, false);
  assert.equal(c.agents.defaults.contextInjection, 'never');
});

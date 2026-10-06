import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm, symlink, realpath, stat } from 'node:fs/promises';
import { createHash, createPublicKey, verify } from 'node:crypto';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createAdapter, NativeGateway, CAPABILITIES, UPSTREAM, CURATED_RUNTIME, validateScope, validateGatewayListener, parseProviderBootstrap, nativeGatewayLaunch, runtimeConfig, runtimeEnvironment, validateLifecycle, EXTENSIONS, mergeRuntimeConfig, localDeviceIdentity, signedDevice, validateWorkerMemory, effectiveRuntimeConfig } from './adapter.mjs';

// Contract tests deliberately fake the Gateway. They are not native execution,
// subscription authentication or interchangeable-harness acceptance evidence.
class FakeGateway {
  constructor() { this.closed = false; this.epoch = 'fake-native-generation'; this.calls = []; this.frames = []; this.closes = []; this.overrides = new Map(); this.sessions = new Map(); }
  onFrame(listener) { this.frames.push(listener); }
  onClose(listener) { this.closes.push(listener); }
  emit(payload) { for (const listener of this.frames) listener({ type: 'event', event: 'chat', payload }); }
  finish(reason) { this.closed = true; for (const listener of this.closes) listener(reason); }
  async shutdown() { this.finish('test shutdown'); }
  count(method) { return this.calls.filter(call => call.method === method).length; }
  last(method) { return this.calls.findLast(call => call.method === method).params; }
  async call(method, params) {
    this.calls.push({ method, params });
    if (this.overrides.has(method)) return this.overrides.get(method)(params);
    if (method === 'sessions.create') {
      const sessionId = `native-session-${this.sessions.size}`;
      this.sessions.set(params.key, { sessionId, agentId: params.agentId });
      return { ok: true, key: params.key, sessionId, entry: { sessionId }, runStarted: false, resolved: { modelProvider: 'yorozu-local-proof', model: 'synthetic' } };
    }
    if (method === 'sessions.messages.subscribe') return { subscribed: true, key: params.key, agentId: params.agentId };
    if (method === 'chat.history') {
      const session = this.sessions.get(params.sessionKey);
      return { sessionKey: params.sessionKey, sessionId: session.sessionId, sessionInfo: { agentId: session.agentId, hasActiveRun: false, activeRunIds: [], activeLeafEntryId: null }, messages: [] };
    }
    if (method === 'chat.send') return { status: 'started', runId: params.idempotencyKey };
    if (method === 'chat.abort') return { ok: true, aborted: true, runIds: [params.runId] };
    throw new Error(`unexpected fake RPC ${method}`);
  }
}
const open = { conversationId: 'secretary', bindingId: 'binding-a' };
const turn = { ...open, runId: 'host-run-a', attemptId: 'host-attempt-a', text: 'Current harmless user request' };
async function fixture(options = {}) {
  const gateway = options.gateway ?? new FakeGateway(); const events = [];
  const runtime = { gateway, agentId: 'secretary', workspace: '/unused-private-workspace', authAvailable: options.authAvailable ?? true, ...(options.journalPath ? { journalPath: options.journalPath } : {}) };
  const adapter = createAdapter({ launch: async () => runtime, emit: event => events.push(event) });
  const ready = await adapter.handle('initialize', {});
  if (!options.skipOpen) await adapter.handle('session.open', open);
  return { adapter, gateway, events, ready, runtime };
}
const payload = (gateway, state, extra = {}) => ({ runId: gateway.last('chat.send').idempotencyKey, sessionKey: gateway.last('chat.send').sessionKey, agentId: 'secretary', seq: 0, state, ...extra });

test('manifest and initialize declare the same honest unsupported capabilities', async () => {
  const { ready } = await fixture();
  const manifest = JSON.parse(await readFile(new URL('./manifest.json', import.meta.url), 'utf8'));
  assert.equal(manifest.upstream.sourceSha, UPSTREAM.commit);
  assert.equal(manifest.curatedRuntime.sourceSha, CURATED_RUNTIME.sourceCommit);
  assert.equal(manifest.curatedRuntime.patchSha256, CURATED_RUNTIME.patchSha256);
  assert.notEqual(CURATED_RUNTIME.sourceCommit, UPSTREAM.commit);
  const patch = await readFile(new URL(`./${manifest.curatedRuntime.patch}`, import.meta.url));
  assert.equal(createHash('sha256').update(patch).digest('hex'), CURATED_RUNTIME.patchSha256);
  assert.equal(manifest.productionReady, false);
  assert.deepEqual(ready.capabilities, CAPABILITIES);
  for (const [key, value] of Object.entries(CAPABILITIES)) assert.equal(manifest.capabilities[key], value);
});
test('inherited listener wire contract admits only exact host-owned FD3 metadata', () => {
  const params = { gatewayPort: 32146, gatewayListener: { transport: CURATED_RUNTIME.transport, fd: 3, host: '127.0.0.1', port: 32146 } };
  validateGatewayListener(params);
  for (const extra of [{ fd: 4 }, { fd: '/tmp/socket' }, { host: 'localhost' }, { host: '0.0.0.0' }, { port: 32147 }, { transport: 'bind-listen' }, { stdioFd: 19 }]) {
    assert.throws(() => validateGatewayListener({ ...params, gatewayListener: { ...params.gatewayListener, ...extra } }), /FD3|unsupported fields/);
  }
  assert.throws(() => validateGatewayListener({ ...params, gatewayPort: 0 }), /exact/);
  assert.throws(() => validateGatewayListener({ gatewayPort: 32146 }), /object/);
  const runtime = { node: '/curated/node', source: '/curated/openclaw', gatewayPort: 32146, workspace: '/own/scratch', profileDir: '/own/runtime', home: '/own/runtime/home', state: '/own/runtime/state', temporary: '/own/runtime/tmp' };
  const launch = nativeGatewayLaunch(runtime);
  assert.deepEqual(launch.args, ['/curated/openclaw/dist/yorozu-gateway-embedding.js', '--port', '32146']);
  assert.deepEqual(launch.options.stdio, ['ignore', 'pipe', 'pipe', 3]);
  assert.equal(launch.command, runtime.node); assert.equal(launch.options.cwd, runtime.workspace);
  assert.equal(launch.options.env.OPENCLAW_NO_RESPAWN, '1');
});
test('journal from stock or another curated runtime is refused without native RPC', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'yorozu-openclaw-pin-'));
  const journalPath = join(directory, 'journal.json');
  try {
    const first = await fixture({ journalPath });
    await first.adapter.handle('shutdown', {});
    const saved = JSON.parse(await readFile(journalPath, 'utf8'));
    for (const replacement of [UPSTREAM.commit, 'f'.repeat(40), undefined]) {
      await writeFile(journalPath, JSON.stringify({ ...saved, curatedSource: replacement }));
      const gateway = new FakeGateway();
      await assert.rejects(fixture({ journalPath, gateway }), /journal identity/);
      assert.equal(gateway.calls.length, 0);
    }
  } finally { await rm(directory, { recursive: true, force: true }); }
});
test('session creation has no initial task and keeps native agent/session ownership', async () => {
  const { adapter, gateway } = await fixture();
  const params = gateway.last('sessions.create');
  assert.match(params.key, /^agent:secretary:yz-[a-f0-9]{64}$/);
  assert.equal(params.agentId, 'secretary'); assert.equal(params.fastMode, undefined);
  assert.equal(params.message, undefined); assert.equal(params.task, undefined); assert.equal(params.titleSource, undefined);
  assert.equal((await adapter.handle('session.open', open)).sessionId, 'native-session-0');
  assert.equal(gateway.count('sessions.create'), 1);
  await assert.rejects(adapter.handle('session.open', { ...open, bindingId: 'foreign-binding' }), /another binding/);
  await assert.rejects(adapter.handle('session.open', { conversationId: 'other', bindingId: open.bindingId }), /another conversation/);
  await assert.rejects(adapter.handle('session.open', { conversationId: 'foreign', bindingId: 'foreign', sessionId: 'installed-native-session' }), /adapter-owned/);
});
test('lost or malformed session creation never replays the create', async () => {
  for (const result of [() => { throw new Error('socket lost'); }, () => ({ ok: true, key: 'agent:foreign:session', sessionId: 'foreign', runStarted: true })]) {
    const { adapter, gateway } = await fixture({ skipOpen: true });
    gateway.overrides.set('sessions.create', result);
    await assert.rejects(adapter.handle('session.open', open), /uncertain|unproven/);
    await assert.rejects(adapter.handle('session.open', open), /uncertain/);
    assert.equal(gateway.count('sessions.create'), 1);
  }
});
test('fresh profile without explicit loopback inference refuses turns without native handoff', async () => {
  const { adapter, gateway, ready } = await fixture({ authAvailable: false });
  assert.equal(ready.auth.status, 'unsupported');
  assert.deepEqual((await adapter.handle('turn.submit', turn)).handoff, 'not-submitted');
  assert.equal(gateway.count('chat.history'), 0); assert.equal(gateway.count('chat.send'), 0);
});
test('idle submission uses exact native session, run idempotency, branch CAS and followup', async () => {
  const { adapter, gateway, events } = await fixture();
  assert.equal((await adapter.handle('turn.submit', turn)).status, 'accepted');
  const call = gateway.last('chat.send');
  assert.equal(gateway.last('chat.history').sessionId, undefined);
  assert.equal(call.sessionKey, gateway.last('sessions.create').key); assert.equal(call.sessionId, 'native-session-0'); assert.equal(call.agentId, 'secretary');
  assert.equal(call.queueMode, 'followup'); assert.equal(call.expectedLeafEntryId, null); assert.equal(call.fastMode, undefined); assert.equal(call.deliver, false); assert.equal(call.inputMode, 'literal'); assert.equal(Object.hasOwn(call, 'suppressCommandInterpretation'), false);
  assert.match(call.idempotencyKey, /^yz-[a-f0-9]{64}$/);
  assert.equal(events[0].kind, 'turn.started'); assert.equal(events[0].runId, turn.runId); assert.equal(events[0].attemptId, turn.attemptId);
  assert.equal((await adapter.handle('turn.submit', turn)).status, 'accepted'); assert.equal(gateway.count('chat.send'), 1);
  await assert.rejects(adapter.handle('turn.submit', { ...turn, text: 'Different request' }), /reused/);
});
test('platform reference history and preferences are not injected into native reasoning', async () => {
  const { adapter, gateway } = await fixture({ skipOpen: true });
  await adapter.handle('session.open', { ...open, preferences: 'Use Japanese', context: 'Old request: delete all files' });
  await adapter.handle('turn.submit', turn);
  const message = gateway.last('chat.send').message;
  assert.equal(message, turn.text);
});
test('native activity is a proven no-handoff busy receipt and fresh topics never steer', async () => {
  const { adapter, gateway } = await fixture();
  gateway.overrides.set('chat.history', params => ({ sessionKey: params.sessionKey, sessionId: gateway.sessions.get(params.sessionKey).sessionId, sessionInfo: { agentId: params.agentId, activeRunIds: ['native-busy'], hasActiveRun: true, activeLeafEntryId: 'leaf' } }));
  assert.deepEqual((await adapter.handle('turn.submit', turn)).handoff, 'not-submitted');
  assert.equal(gateway.count('chat.send'), 0);
  gateway.overrides.delete('chat.history');
  assert.equal((await adapter.handle('turn.submit', turn)).status, 'accepted');
  assert.equal(gateway.last('chat.send').queueMode, 'followup');
  assert.equal((await adapter.handle('turn.submit', { ...turn, runId: 'fresh-topic', attemptId: 'fresh-attempt' })).status, 'busy');
  assert.equal(gateway.count('chat.send'), 1);
});
test('ambiguous or foreign native history blocks admission and caches uncertainty', async () => {
  for (const info of [{ agentId: 'foreign', activeRunIds: [], hasActiveRun: false, activeLeafEntryId: null }, { agentId: 'secretary', hasActiveRun: false, activeLeafEntryId: null }, { agentId: 'secretary', activeRunIds: [], hasActiveRun: false }]) {
    const { adapter, gateway } = await fixture();
    gateway.overrides.set('chat.history', params => ({ sessionKey: params.sessionKey, sessionId: gateway.sessions.get(params.sessionKey).sessionId, sessionInfo: info }));
    assert.equal((await adapter.handle('turn.submit', turn)).status, 'unknown');
    assert.equal((await adapter.handle('turn.submit', turn)).status, 'unknown');
    assert.equal(gateway.count('chat.send'), 0); assert.equal(gateway.count('chat.history'), 1);
  }
});
test('lost, queued, redirected or malformed send acknowledgements never cause replay', async () => {
  for (const callback of [() => { throw new Error('lost ack'); }, params => ({ status: 'accepted', runId: params.idempotencyKey }), params => ({ status: 'started', runId: params.idempotencyKey + '-foreign' }), () => ({})]) {
    const { adapter, gateway, events } = await fixture();
    gateway.overrides.set('chat.send', callback);
    assert.equal((await adapter.handle('turn.submit', turn)).status, 'unknown');
    assert.equal((await adapter.handle('turn.submit', turn)).status, 'unknown');
    assert.equal(gateway.count('chat.send'), 1); assert.equal(events.some(event => event.kind === 'turn.started'), false);
  }
});
test('concurrent duplicate input is reserved before RPC and does not send twice', async () => {
  const { adapter, gateway } = await fixture(); let acknowledge;
  gateway.overrides.set('chat.send', params => new Promise(yes => { acknowledge = () => yes({ status: 'started', runId: params.idempotencyKey }); }));
  const pending = adapter.handle('turn.submit', turn);
  await new Promise(yes => setImmediate(yes));
  assert.equal((await adapter.handle('turn.submit', turn)).status, 'unknown');
  acknowledge(); assert.equal((await pending).status, 'accepted'); assert.equal(gateway.count('chat.send'), 1);
});
test('only the exact known native agent, session and run may publish host events', async () => {
  const { adapter, gateway, events } = await fixture(); await adapter.handle('turn.submit', turn);
  gateway.emit(payload(gateway, 'delta', { agentId: 'foreign', deltaText: 'WRONG' }));
  gateway.emit(payload(gateway, 'delta', { sessionKey: 'agent:secretary:foreign', deltaText: 'WRONG' }));
  gateway.emit(payload(gateway, 'final', { runId: 'foreign-run' }));
  gateway.emit(payload(gateway, 'delta', { deltaText: 'Hello' }));
  gateway.emit(payload(gateway, 'delta', { deltaText: 'duplicate' }));
  gateway.emit(payload(gateway, 'delta', { seq: 1, deltaText: ' world' }));
  gateway.emit(payload(gateway, 'final', { seq: 2, message: { content: [{ type: 'text', text: 'Hello world' }] } }));
  await adapter.drain();
  assert.deepEqual(events.filter(event => event.kind === 'assistant.update').map(event => event.data.text), ['Hello', 'Hello world', 'Hello world']);
  assert.equal(events.at(-1).kind, 'turn.terminal'); assert.equal(events.at(-1).data.state, 'completed');
  for (const event of events) { assert.equal(event.conversationId, open.conversationId); assert.equal(event.runId, turn.runId); assert.equal(event.attemptId, turn.attemptId); }
});
test('native terminal arriving before send ACK is emitted after turn.started', async () => {
  const { adapter, gateway, events } = await fixture();
  gateway.overrides.set('chat.send', async params => {
    gateway.emit({ runId: params.idempotencyKey, sessionKey: params.sessionKey, agentId: params.agentId, seq: 0, state: 'final', message: { content: 'done' } });
    await new Promise(yes => setImmediate(yes));
    return { status: 'started', runId: params.idempotencyKey };
  });
  assert.equal((await adapter.handle('turn.submit', turn)).status, 'accepted'); await adapter.drain();
  assert.deepEqual(events.map(event => event.kind), ['turn.started', 'assistant.update', 'turn.terminal']);
});
test('yielded runs are uncertain and never create fake child tasks', async () => {
  const { adapter, gateway, events } = await fixture(); await adapter.handle('turn.submit', turn);
  gateway.emit(payload(gateway, 'final', { yielded: true }));
  await adapter.drain();
  assert.equal(events.at(-1).kind, 'capability.unavailable'); assert.equal(events.some(event => event.kind === 'turn.terminal' || event.kind === 'task.changed'), false);
  assert.equal((await adapter.handle('session.snapshot', open)).current.state, 'unknown');
});
test('native chat seq is strictly increasing but not consecutive; stale or repeated seq is ignored and the final message is authoritative', async () => {
  // The actual Gateway shares one per-run agent-event counter across tool/item/status
  // events and merges paced deltas, so chat events legitimately skip numbers.
  const { adapter, gateway, events } = await fixture(); await adapter.handle('turn.submit', turn);
  gateway.emit(payload(gateway, 'delta', { seq: 2, deltaText: 'first' }));
  gateway.emit(payload(gateway, 'delta', { seq: 1, deltaText: 'stale' }));
  gateway.emit(payload(gateway, 'delta', { seq: 2, deltaText: 'repeat' }));
  gateway.emit(payload(gateway, 'delta', { seq: 7, deltaText: ' second' }));
  gateway.emit(payload(gateway, 'final', { seq: 11, message: { content: 'complete native text' } }));
  await adapter.drain();
  assert.deepEqual(events.map(event => event.kind), ['turn.started', 'assistant.update', 'assistant.update', 'assistant.update', 'turn.terminal']);
  assert.equal(events[2].data.text, 'first second'); assert.equal(events[3].data.text, 'complete native text'); assert.equal(events.at(-1).data.state, 'completed');
  assert.equal(events.some(event => event.kind === 'capability.unavailable'), false);
  assert.equal((await adapter.handle('session.snapshot', open)).current, null);
});
test('Stop requires exact origin currency and reports requested until native termination', async () => {
  const { adapter, gateway, events } = await fixture(); await adapter.handle('turn.submit', turn);
  await assert.rejects(adapter.handle('run.stop', { ...turn, attemptId: 'stale', operationId: 'stop' }), /currency/);
  await assert.rejects(adapter.handle('run.stop', { ...turn, conversationId: 'foreign', operationId: 'stop' }), /conversation/);
  assert.equal(gateway.count('chat.abort'), 0);
  const stop = { ...turn, operationId: 'stop' };
  assert.equal((await adapter.handle('run.stop', stop)).status, 'requested');
  assert.equal((await adapter.handle('run.stop', stop)).status, 'requested'); assert.equal(gateway.count('chat.abort'), 1);
  const abort = gateway.last('chat.abort'); assert.equal(abort.runId, gateway.last('chat.send').idempotencyKey); assert.equal(abort.preserveSideRuns, true); assert.equal(abort.discardPendingInput, false);
  assert.equal(events.some(event => event.kind === 'turn.terminal'), false);
  gateway.emit(payload(gateway, 'aborted')); await adapter.drain();
  assert.equal(events.at(-1).data.state, 'stopped');
  assert.equal((await adapter.handle('session.snapshot', open)).current, null);
});
test('lost or overbroad abort acknowledgement is cached unknown and never replayed', async () => {
  for (const callback of [() => { throw new Error('lost control ack'); }, params => ({ ok: true, aborted: true, runIds: [params.runId, 'foreign-run'] }), () => ({ ok: true, aborted: false, runIds: [] })]) {
    const { adapter, gateway } = await fixture(); await adapter.handle('turn.submit', turn); gateway.overrides.set('chat.abort', callback);
    const stop = { ...turn, operationId: 'stop' };
    assert.equal((await adapter.handle('run.stop', stop)).status, 'unknown');
    assert.equal((await adapter.handle('run.stop', stop)).status, 'unknown'); assert.equal(gateway.count('chat.abort'), 1);
    await assert.rejects(adapter.handle('task.stop', { ...stop, taskId: 'child' }), /reused/);
  }
});
test('unsupported task and permission controls perform no Gateway mutations', async () => {
  const { adapter, gateway } = await fixture(); await adapter.handle('turn.submit', turn);
  const calls = gateway.calls.length;
  for (const method of ['task.steer', 'task.stop', 'request.answer']) {
    const result = await adapter.handle(method, { ...turn, taskId: 'unproven-child', operationId: method, text: 'guidance' });
    assert.equal(result.status, 'unsupported'); assert.equal(result.handoff, 'not-submitted');
  }
  assert.equal(gateway.calls.length, calls); assert.deepEqual((await adapter.handle('session.snapshot', open)).tasks, []);
});
test('connection loss publishes uncertainty, with no terminal success or automatic resend', async () => {
  const { adapter, gateway, events } = await fixture(); await adapter.handle('turn.submit', turn); gateway.finish('lost socket'); await adapter.drain();
  assert.equal(events.at(-1).kind, 'runtime.closed'); assert.equal(events.some(event => event.kind === 'turn.terminal'), false);
  assert.equal((await adapter.handle('session.snapshot', open)).current.state, 'unknown');
  await adapter.handle('turn.submit', turn); assert.equal(gateway.count('chat.send'), 1);
});
test('adapter restart retains uncertain attempts and controls without native replay', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'yorozu-openclaw-journal-'));
  try {
    const journalPath = join(directory, 'adapter-journal-v1.json');
    const before = await fixture({ journalPath }); await before.adapter.handle('turn.submit', turn);
    before.gateway.overrides.set('chat.abort', () => { throw new Error('unknown Stop'); });
    const stop = { ...turn, operationId: 'stop' }; await before.adapter.handle('run.stop', stop); await before.adapter.drain();
    const after = await fixture({ journalPath });
    assert.equal((await after.adapter.handle('turn.submit', turn)).status, 'unknown');
    assert.equal((await after.adapter.handle('run.stop', stop)).status, 'unknown');
    assert.equal(after.gateway.count('sessions.create'), 0); assert.equal(after.gateway.count('chat.send'), 0); assert.equal(after.gateway.count('chat.abort'), 0);
  } finally { await rm(directory, { recursive: true }); }
});
test('host scope and per-agent isolation are mandatory and reject broad/symlink/denied paths', async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'yorozu-openclaw-scope-')));
  try {
    const workspace = join(root, 'workspace'); const memoryDir = join(root, 'memory'); const profileDir = join(root, 'runtime');
    await mkdir(workspace); await mkdir(memoryDir); await mkdir(profileDir);
    const params = { agentId: 'secretary', workspace, profileDir, scope: { allowedTools: ['file', 'terminal'], directories: [{ path: root, access: 'write' }], workspace, memoryDir }, isolation: { backend: 'macos-seatbelt-v1', agentId: 'secretary', policyDigest: 'a'.repeat(64) } };
    assert.equal((await validateScope(params)).agentId, 'secretary');
    await assert.rejects(validateScope({ ...params, isolation: { ...params.isolation, agentId: 'foreign' } }), /sandbox/);
    await assert.rejects(validateScope({ ...params, scope: { ...params.scope, nativeTools: ['exec'] } }), /unsupported/);
    await assert.rejects(validateScope({ ...params, scope: { ...params.scope, directories: [{ path: '/', access: 'write' }] } }), /broad/);
    await assert.rejects(validateScope({ ...params, scope: { ...params.scope, deniedRoots: [profileDir] } }), /denied/);
    await symlink(workspace, join(root, 'linked'));
    await assert.rejects(validateScope({ ...params, workspace: join(root, 'linked'), scope: { ...params.scope, workspace: join(root, 'linked') } }), /symlinks/);
  } finally { await rm(root, { recursive: true }); }
});
test('native config and environment stay strictly below harness grants and inherit no secrets', () => {
  const runtime = { agentId: 'secretary', workspace: '/private/agent/workspace', profileDir: '/private/agent/runtime', home: '/private/agent/runtime/isolated-home', state: '/private/agent/runtime/openclaw-state', temporary: '/private/agent/runtime/tmp', node: '/curated/node' };
  const config = runtimeConfig(runtime, 12345, 'own-token'); const env = runtimeEnvironment(runtime);
  assert.deepEqual(config.tools.deny, ['*']); assert.deepEqual(config.agents.entries.secretary.tools.deny, ['*']);
  assert.equal(config.cron.enabled, false); assert.equal(config.browser.enabled, false); assert.equal(config.plugins, undefined); assert.equal(config.agents.defaults.heartbeat, undefined);
  assert.deepEqual(config.agents.defaults.model.fallbacks, []); assert.equal(config.agents.entries.secretary.fastModeDefault, undefined);
  for (const key of ['skipBootstrap', 'contextInjection', 'startupContext', 'skills']) assert.equal(config.agents.defaults[key], undefined);
  assert.equal(config.models.catalogRefresh.enabled, false); assert.deepEqual(config.models.providers, {});
  assert.equal(config.gateway.auth.mode, 'token'); assert.equal(config.gateway.bind, 'loopback'); assert.equal(config.gateway.uploads.enabled, false);
  assert.equal(env.HOME, runtime.home); assert.equal(env.CODEX_HOME, join(runtime.profileDir, 'isolated-codex'));
  for (const key of ['OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'OPENCLAW_GATEWAY_TOKEN', 'NODE_OPTIONS', 'HTTP_PROXY', 'SSH_AUTH_SOCK', 'AWS_PROFILE']) assert.equal(env[key], undefined);
  assert.equal(env.OPENCLAW_NO_RESPAWN, '1'); assert.equal(env.OPENCLAW_SKIP_CRON, '1'); assert.equal(env.OPENCLAW_EXEC_SHELL_SNAPSHOT, '0');
});
test('private broker bearer uses native authorization only and retains isolated configuration', () => {
  const bearer = 'fixture-only-host-bearer-'.padEnd(64, 'x');
  const provider = parseProviderBootstrap(JSON.stringify({ baseUrl: 'http://127.0.0.1:32146/v1', model: 'synthetic', api: 'openai-responses', bearer }));
  const runtime = { agentId: 'secretary', workspace: '/own/scratch', profileDir: '/own/runtime', home: '/own/runtime/home', state: '/own/runtime/state', temporary: '/own/runtime/tmp', node: '/curated/node', provider };
  const config = runtimeConfig(runtime, 32147, 'separate-gateway-token');
  const inference = config.models.providers['yorozu-local-proof'];
  assert.equal(inference.apiKey, bearer); assert.equal(inference.authHeader, true);
  assert.equal(inference.baseUrl, provider.baseUrl); assert.equal(inference.api, 'openai-responses');
  assert.equal(config.gateway.auth.token, 'separate-gateway-token'); assert.deepEqual(config.agents.defaults.model.fallbacks, []);
  assert.equal(JSON.stringify(runtimeEnvironment(runtime)).includes(bearer), false);
  const synthetic = runtimeConfig({ ...runtime, provider: parseProviderBootstrap(JSON.stringify({ baseUrl: provider.baseUrl, model: 'synthetic', api: provider.api })) }, 32147, 'separate-gateway-token').models.providers['yorozu-local-proof'];
  assert.equal(synthetic.apiKey, 'yorozu-loopback-proof'); assert.equal(synthetic.authHeader, false);
});
test('broker bootstrap rejects IP aliases, wider endpoints and malformed secrets without echoing values', () => {
  const bearer = 'fixture-only-secret-must-never-appear-in-errors';
  const valid = { baseUrl: 'http://127.0.0.1:32146/v1', model: 'synthetic', api: 'openai-responses', bearer };
  for (const baseUrl of ['http://localhost:32146/v1', 'http://127.1:32146/v1', 'http://2130706433:32146/v1', 'http://[::1]:32146/v1', 'http://127.0.0.1/v1', 'http://127.0.0.1:1023/v1', 'http://127.0.0.1:65536/v1', 'http://127.0.0.1:032146/v1', 'https://127.0.0.1:32146/v1', `http://${bearer}@127.0.0.1:32146/v1`, 'http://127.0.0.1:32146/v1?key=secret', 'http://127.0.0.1:32146/v1#secret', 'http://127.0.0.1:32146/other']) {
    assert.throws(() => parseProviderBootstrap(JSON.stringify({ ...valid, baseUrl })), error => error.code === -32602 && error.message === 'Invalid private inference broker bootstrap' && !error.message.includes(bearer));
  }
  for (const value of [{ ...valid, bearer: 'short' }, { ...valid, bearer: `${bearer}\r\nInjected: yes` }, { ...valid, bearer: 'x'.repeat(257) }, { ...valid, bearer: { env: 'OPENAI_API_KEY' } }, { ...valid, api: 'ambient-provider' }, { ...valid, ambientCredential: bearer }, [valid], null]) {
    assert.throws(() => parseProviderBootstrap(JSON.stringify(value)), error => error.message === 'Invalid private inference broker bootstrap' && !error.message.includes(bearer));
  }
  for (const encoded of [`{"bearer":"${bearer}",`, JSON.stringify({ ...valid, model: bearer + ' '.repeat(4096) })]) {
    assert.throws(() => parseProviderBootstrap(encoded), error => error.message === 'Invalid private inference broker bootstrap' && !error.message.includes(bearer));
  }
});
test('zero-tool scope permits only private runtime scratch without minting user directory grants', async () => {
  const root = await realpath(await mkdtemp(join(tmpdir(), 'yorozu-openclaw-empty-')));
  try {
    const profileDir = join(root, 'vendor-runtime'); const workspace = join(profileDir, 'scratch');
    const hostWorkspace = join(root, 'host-private-workspace'); const memoryDir = join(root, 'host-private-memory');
    await mkdir(workspace, { recursive: true }); await mkdir(hostWorkspace); await mkdir(memoryDir);
    const scope = { allowedTools: [], directories: [], workspace: hostWorkspace, memoryDir, deniedRoots: [hostWorkspace, memoryDir] };
    const params = { agentId: 'secretary', workspace, profileDir, scope, isolation: { backend: 'macos-seatbelt-v1', agentId: 'secretary', policyDigest: 'b'.repeat(64) } };
    assert.equal((await validateScope(params)).workspace, workspace); assert.deepEqual(scope.directories, []);
    await assert.rejects(validateScope({ ...params, workspace: hostWorkspace }), /writable scope|denied/);
    await assert.rejects(validateScope({ ...params, workspace: root }), /workspace does not match/);
  } finally { await rm(root, { recursive: true }); }
});

class FakeSocket extends EventTarget {
  static sockets = [];
  constructor(url) { super(); this.url = url; this.readyState = 1; this.requests = []; FakeSocket.sockets.push(this); queueMicrotask(() => this.frame({ type: 'event', event: 'connect.challenge', payload: { nonce: 'own-nonce', ts: Date.now() } })); }
  frame(frame) { this.dispatchEvent(new MessageEvent('message', { data: JSON.stringify(frame) })); }
  send(frame) {
    const request = JSON.parse(frame); this.requests.push(request);
    if (request.method === 'connect') this.frame({ type: 'res', id: request.id, ok: true, payload: { type: 'hello-ok', protocol: 4, server: { version: UPSTREAM.version, connId: 'own-connection' }, auth: { method: 'token', role: 'operator', scopes: ['operator.read', 'operator.write'] }, features: { methods: ['sessions.create', 'chat.history', 'chat.send', 'chat.abort', 'sessions.messages.subscribe'] } } });
  }
  close() { this.readyState = 3; this.dispatchEvent(new Event('close')); }
}
test('Gateway wire client waits for challenge and requests only generic embedding read/write scopes', async () => {
  const gateway = new NativeGateway('ws://127.0.0.1:12345', 'own-token', null, { WebSocketClass: FakeSocket, timeoutMs: 20 });
  await gateway.connect();
  const connect = gateway.socket.requests[0];
  assert.equal(connect.method, 'connect'); assert.equal(connect.params.client.id, 'gateway-client'); assert.equal(connect.params.client.mode, 'backend');
  assert.deepEqual(connect.params.scopes, ['operator.read', 'operator.write']); assert.deepEqual(connect.params.auth, { token: 'own-token' }); assert.equal(connect.params.device, undefined);
  await assert.rejects(gateway.call('chat.send', {}), /timed out/);
  assert.equal(gateway.socket.requests.filter(request => request.method === 'chat.send').length, 1);
  await gateway.shutdown();
});
test('Gateway transport closure rejects a pending native handoff without throwing or retrying', async () => {
  const gateway = new NativeGateway('ws://127.0.0.1:12345', 'own-token', null, { WebSocketClass: FakeSocket, timeoutMs: 1000 });
  await gateway.connect();
  const pending = gateway.call('chat.send', {});
  const rejection = assert.rejects(pending, /actual transport loss/);
  assert.doesNotThrow(() => gateway.finish('actual transport loss'));
  await rejection;
  assert.equal(gateway.pending.size, 0); assert.equal(gateway.closed, true);
  assert.equal(gateway.socket.requests.filter(request => request.method === 'chat.send').length, 1);
});

const connectedParams = {
  protocolVersion: 1, upstreamVersion: UPSTREAM.version, agentId: 'host-agent-a',
  lifecycle: { version: 1, mode: 'connected', connectionId: 'chosen-connection' },
  connection: { version: 1, connectionId: 'chosen-connection', endpoint: 'ws://127.0.0.1:32146/',
    nativeAgentId: 'external-agent', sessionKey: 'agent:external-agent:ongoing', sessionId: 'external-session',
    token: 'synthetic-connection-token-'.padEnd(64, 'x'), uiTargetId: 'registered-native-ui' },
};

test('connected descriptor is explicit, bounded, loopback-only and cannot adopt a profile', () => {
  assert.equal(validateLifecycle(connectedParams).mode, 'connected');
  for (const endpoint of ['ws://localhost:32146/', 'ws://127.0.0.1:32146/?token=hidden', 'ws://127.0.0.1:32146/path', 'ws://127.0.0.1:80/', 'wss://example.invalid/']) {
    assert.throws(() => validateLifecycle({ ...connectedParams, connection: { ...connectedParams.connection, endpoint } }), /endpoint|Gateway/);
  }
  for (const extra of [{ profileDir: '/installed/profile' }, { providerConfigPath: '/installed/auth' }, { scope: {} }]) assert.throws(() => validateLifecycle({ ...connectedParams, ...extra }), /provision or adopt/);
  assert.throws(() => validateLifecycle({ ...connectedParams, connection: { ...connectedParams.connection, connectionId: 'foreign' } }), /identity/);
  assert.throws(() => validateLifecycle({ ...connectedParams, connection: { ...connectedParams.connection, sessionKey: 'agent:foreign:ongoing' } }), /selected native agent/);
  assert.throws(() => validateLifecycle({ lifecycle: { version: 1, mode: 'managed' }, connection: connectedParams.connection }), /adopt/);
});

test('inert connected seam (not enabled capability) observes only the selected existing native session and detach never shuts it down', async () => {
  const gateway = new FakeGateway(); let detached = 0; let shutdown = 0;
  gateway.sessions.set(connectedParams.connection.sessionKey, { sessionId: connectedParams.connection.sessionId, agentId: connectedParams.connection.nativeAgentId });
  gateway.detach = async () => { detached++; gateway.finish('client detach'); };
  gateway.shutdown = async () => { shutdown++; throw new Error('must not shut down external runtime'); };
  const runtime = { gateway, ownership: 'connected', connection: connectedParams.connection, agentId: connectedParams.connection.nativeAgentId,
    hostAgentId: connectedParams.agentId, authAvailable: true };
  const adapter = createAdapter({ launch: async () => runtime });
  const ready = await adapter.handle('initialize', connectedParams);
  assert.equal(ready.extensions.connectedLifecycle, false); assert.equal(ready.auth.status, 'harness-owned');
  assert.equal((await adapter.handle('session.open', { ...open, sessionId: 'external-session' })).sessionId, 'external-session');
  assert.equal(gateway.count('sessions.create'), 0);
  assert.equal(gateway.last('chat.history').sessionKey, connectedParams.connection.sessionKey);
  assert.equal(gateway.last('sessions.messages.subscribe').agentId, connectedParams.connection.nativeAgentId);
  await assert.rejects(adapter.handle('session.open', { ...open, bindingId: 'foreign', sessionId: 'external-session' }), /another binding/);
  assert.equal((await adapter.handle('message.deliver', {})).status, 'unsupported');
  assert.equal((await adapter.handle('detach')).nativeStopped, false);
  assert.equal(detached, 1); assert.equal(shutdown, 0); assert.equal(gateway.count('chat.abort'), 0);
});

test('foreign connected session evidence is rejected without create, resume, or native shutdown', async () => {
  const gateway = new FakeGateway(); gateway.overrides.set('chat.history', () => ({ sessionKey: 'agent:foreign:ongoing', sessionId: 'foreign', sessionInfo: { agentId: 'foreign' } }));
  const runtime = { gateway, ownership: 'connected', connection: connectedParams.connection, agentId: connectedParams.connection.nativeAgentId, authAvailable: true };
  let shutdown = false; gateway.shutdown = async () => { shutdown = true; }; gateway.detach = async () => gateway.finish('detached');
  const adapter = createAdapter({ launch: async () => runtime });
  await adapter.handle('initialize', connectedParams);
  await assert.rejects(adapter.handle('session.open', open), /not verified/);
  assert.equal(gateway.count('sessions.create'), 0); assert.equal(gateway.count('sessions.messages.subscribe'), 0);
  await adapter.handle('shutdown'); assert.equal(shutdown, false);
});

test('native connected client closes only its socket even if passed a child reference', async () => {
  let killed = false;
  const gateway = new NativeGateway('ws://127.0.0.1:32146/', 'synthetic-token', { exitCode: null, signalCode: null, kill() { killed = true; } },
    { WebSocketClass: FakeSocket, timeoutMs: 20, ownership: 'connected' });
  await gateway.connect(); await gateway.shutdown();
  assert.equal(gateway.closed, true); assert.equal(killed, false);
  assert.deepEqual(gateway.socket.requests.map(request => request.method), ['connect']);
});

test('managed resource rebinding retains native learning/autonomy and configuration choices', () => {
  const previous = { plugins: { slots: { memory: 'native-memory' } }, nativeChoice: true,
    agents: { defaults: { heartbeat: { every: '10m' }, skills: ['native-skill'] }, entries: { secretary: { personality: 'native-choice', fastModeDefault: true, tools: { allow: ['read'] } } } } };
  const host = runtimeConfig({ agentId: 'secretary', workspace: '/own/workspace', state: '/own/state' }, 32146, 'synthetic-token');
  const merged = mergeRuntimeConfig(previous, host, 'secretary');
  assert.deepEqual(merged.plugins, previous.plugins); assert.equal(merged.nativeChoice, true);
  assert.deepEqual(merged.agents.defaults.heartbeat, previous.agents.defaults.heartbeat); assert.deepEqual(merged.agents.defaults.skills, previous.agents.defaults.skills);
  assert.equal(merged.agents.entries.secretary.personality, 'native-choice'); assert.equal(merged.agents.entries.secretary.fastModeDefault, true);
  assert.deepEqual(merged.agents.entries.secretary.tools.deny, ['*']); // Host resource boundary is reapplied.
});

test('escaped reply projections and raw text overflow never shut down native work', async () => {
  for (const character of ['"', '\n', '\\', '\u0001']) {
    const { adapter, gateway, events } = await fixture();
    await adapter.handle('turn.submit', turn);
    for (let index = 0; index < 127; index++) {
      gateway.emit(payload(gateway, 'delta', { seq: index, deltaText: character.repeat(1024) }));
      await adapter.drain();
    }
    // Exercise raw overflow too: still not permission to disconnect/abort.
    gateway.emit(payload(gateway, 'delta', { seq: 127, deltaText: character.repeat(4 * 1024) }));
    gateway.emit(payload(gateway, 'final', { seq: 128 }));
    await adapter.drain();
    assert.equal(gateway.closed, false); assert.equal(gateway.count('chat.abort'), 0);
    assert.ok(events.some(event => event.kind === 'capability.unavailable' && event.data.capability === 'replySize'));
    assert.equal(events.at(-1).kind, 'turn.terminal'); assert.equal(events.at(-1).data.state, 'completed');
    for (const event of events) assert.ok(Buffer.byteLength(JSON.stringify({ jsonrpc: '2.0', method: 'harness.event', params: event }) + '\n') <= 256 * 1024);
  }
});

test('real connected launcher is held before socket creation despite valid inert descriptor', async () => {
  const { launchRuntime } = await import('./adapter.mjs');
  await assert.rejects(launchRuntime({ protocolVersion: 1, upstreamVersion: UPSTREAM.version, agentId: 'host-agent',
    lifecycle: { version: 1, mode: 'connected', connectionId: 'fixture-connection' },
    connection: { version: 1, connectionId: 'fixture-connection', endpoint: 'ws://127.0.0.1:32146/', nativeAgentId: 'native-agent', sessionKey: 'agent:native-agent:main', sessionId: 'native-session', token: 'inert-fixture-token'.repeat(4) } }), /Connected lifecycle is held/);
  assert.equal(EXTENSIONS.connectedLifecycle, false);
});

test('reservation fsync precedes rename and directory fsync; failed file sync cannot publish reservation', async t => {
  const { atomic } = await import('./adapter.mjs');
  const fs = await import('node:fs/promises');
  const directory = await mkdtemp(join(tmpdir(), 'openclaw-fsync-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, 'journal.json'); const calls = [];
  const io = { open: async (file, ...args) => {
    const handle = await fs.open(file, ...args);
    return { writeFile: async value => { calls.push('write'); await handle.writeFile(value); },
      sync: async () => { calls.push(file === directory ? 'directory-sync' : 'file-sync'); await handle.sync(); }, close: () => handle.close() };
  }, rename: async (...args) => { calls.push('rename'); await fs.rename(...args); } };
  await atomic(path, { reservation: 'unknown' }, io);
  assert.deepEqual(calls, ['write', 'file-sync', 'rename', 'directory-sync']);
  calls.length = 0;
  const broken = { ...io, open: async (...args) => { const file = await io.open(...args); return { ...file, sync: async () => { throw new Error('injected fsync failure'); } }; } };
  await assert.rejects(atomic(path, { reservation: 'replacement' }, broken), /injected fsync/);
  assert.equal(calls.includes('rename'), false);
  assert.deepEqual(JSON.parse(await readFile(path, 'utf8')), { reservation: 'unknown' });
});

test('reopen resubscribes; subscription failure prevents new handoff and idle history never settles unknown work', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'openclaw-observation-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const journalPath = join(directory, 'journal.json');
  const first = await fixture({ journalPath });
  await first.adapter.handle('turn.submit', turn);
  const restored = await fixture({ journalPath, skipOpen: true });
  assert.equal((await restored.adapter.handle('turn.submit', { ...turn, runId: 'new', attemptId: 'new' })).status, 'busy');
  await restored.adapter.handle('session.open', open);
  assert.equal(restored.gateway.count('sessions.messages.subscribe'), 1);
  assert.equal((await restored.adapter.handle('turn.submit', { ...turn, runId: 'new', attemptId: 'new' })).status, 'busy');
  assert.equal(restored.gateway.count('chat.send'), 0); // Unknown prior outcome still blocks: no absence-based settlement.
  restored.gateway.overrides.set('sessions.messages.subscribe', () => ({ ok: false }));
  await assert.rejects(restored.adapter.handle('session.open', open), /not acknowledged/);
  assert.equal((await restored.adapter.handle('turn.submit', { ...turn, runId: 'new', attemptId: 'new' })).status, 'busy');
  const fresh = await fixture({ skipOpen: true });
  fresh.gateway.overrides.set('sessions.messages.subscribe', () => ({ ok: false }));
  await assert.rejects(fresh.adapter.handle('session.open', open), /not acknowledged/);
  assert.equal((await fresh.adapter.handle('turn.submit', turn)).status, 'busy'); assert.equal(fresh.gateway.count('chat.send'), 0);
});

test('inherited descriptor verification rejects regular files and missing descriptors before ownership transfer', async () => {
  const { verifyInheritedListener } = await import('./adapter.mjs');
  assert.throws(() => verifyInheritedListener(fd => { assert.equal(fd, 3); return { isSocket: () => false }; }), /must be a socket/);
  assert.throws(() => verifyInheritedListener(() => { throw new Error('missing FD3'); }), /missing FD3/);
  verifyInheritedListener(fd => { assert.equal(fd, 3); return { isSocket: () => true }; });
});


test('isolated native device identity persists privately and signs exact nonce/token/read-write authority', async () => {
  const root = await mkdtemp(join(tmpdir(), 'yorozu-device-fixture-'));
  try {
    const identity = await localDeviceIdentity(root), reloaded = await localDeviceIdentity(root);
    assert.equal(reloaded.id, identity.id);
    assert.equal((await stat(join(root, 'adapter-device-v1.json'))).mode & 0o777, 0o600);
    const device = signedDevice(identity, 'fictional-challenge', 'fictional-local-token', 'darwin', 12345);
    const payload = ['v3', identity.id, 'gateway-client', 'backend', 'operator', 'operator.read,operator.write', '12345', 'fictional-local-token', 'fictional-challenge', 'darwin', ''].join('|');
    assert.equal(verify(null, Buffer.from(payload), createPublicKey(identity.key), Buffer.from(device.signature, 'base64url')), true);
    assert.equal(verify(null, Buffer.from(payload.replace('operator.read,operator.write', 'operator.admin')), createPublicKey(identity.key), Buffer.from(device.signature, 'base64url')), false);
    assert.equal(verify(null, Buffer.from(payload.replace('fictional-challenge', 'foreign-challenge')), createPublicKey(identity.key), Buffer.from(device.signature, 'base64url')), false);
    const gateway = new NativeGateway('ws://127.0.0.1:12345', 'fictional-local-token', null, { WebSocketClass: FakeSocket, device: identity });
    await gateway.connect();
    assert.equal(gateway.socket.requests[0].params.device.id, identity.id);
    assert.deepEqual(gateway.socket.requests[0].params.scopes, ['operator.read', 'operator.write']);
    await gateway.shutdown();
    await writeFile(join(root, 'adapter-device-v1.json'), JSON.stringify({ version: 2, privateKey: 'invalid' }));
    await assert.rejects(localDeviceIdentity(root), /identity is invalid/);
  } finally { await rm(root, { recursive: true, force: true }); }
});


test('native literal rejection is never retried in normal mode or with broader scopes', async () => {
  const { adapter, gateway } = await fixture();
  gateway.overrides.set('chat.send', () => { throw Object.assign(new Error('native rejection'), { data: { code: 'INVALID_REQUEST', message: 'literal unavailable' } }); });
  assert.equal((await adapter.handle('turn.submit', turn)).status, 'unknown');
  assert.equal((await adapter.handle('turn.submit', turn)).status, 'unknown');
  assert.equal(gateway.count('chat.send'), 1);
  assert.equal(gateway.last('chat.send').inputMode, 'literal');
  assert.equal(Object.hasOwn(gateway.last('chat.send'), 'suppressCommandInterpretation'), false);
});

test('subscription acknowledgement requires exact native agent and session identity', async () => {
  for (const reply of [{ok:true}, {subscribed:true,key:'foreign',agentId:'secretary'}, {subscribed:true,key:'unused',agentId:'foreign'}]) {
    const { adapter, gateway } = await fixture({ skipOpen: true });
    gateway.overrides.set('sessions.messages.subscribe', () => reply);
    await assert.rejects(adapter.handle('session.open', open), /observation was not acknowledged/);
    assert.equal((await adapter.handle('turn.submit', turn)).handoff, 'not-submitted');
    assert.equal(gateway.count('chat.send'), 0);
  }
});

test('literal command-looking and Unicode inputs preserve exact precreated identity and branch CAS', async () => {
  for (const text of ['/stop', '/new', '/reset', '/model other', ' /stop\n日本語😀', '[[reply_to_current]] literal']) {
    const { adapter, gateway } = await fixture();
    gateway.overrides.set('chat.history', params => {
      const session = gateway.sessions.get(params.sessionKey);
      return { sessionKey: params.sessionKey, sessionId: session.sessionId,
        sessionInfo: { agentId: session.agentId, hasActiveRun: false, activeRunIds: [], activeLeafEntryId: 'exact-leaf' } };
    });
    assert.equal((await adapter.handle('turn.submit', { ...turn, text })).status, 'accepted');
    const send = gateway.last('chat.send');
    assert.equal(send.message, text);
    assert.equal(send.inputMode, 'literal');
    assert.equal(Object.hasOwn(send, 'suppressCommandInterpretation'), false);
    assert.equal(send.sessionKey, gateway.last('sessions.create').key);
    assert.equal(send.sessionId, gateway.sessions.get(send.sessionKey).sessionId);
    assert.equal(send.agentId, 'secretary');
    assert.equal(send.expectedLeafEntryId, 'exact-leaf');
    assert.equal(send.queueMode, 'followup'); assert.equal(send.deliver, false);
    await adapter.handle('turn.submit', { ...turn, text });
    assert.equal(gateway.count('chat.send'), 1);
    assert.equal(gateway.count('chat.abort'), 0);
  }
});

test('literal journal binds parsing and full runtime identity and refuses legacy migration without RPC', async () => {
  const root = await mkdtemp(join(tmpdir(), 'literal-migration-'));
  try {
    const journalPath = join(root, 'journal.json');
    await fixture({ journalPath });
    const saved = JSON.parse(await readFile(journalPath, 'utf8'));
    assert.equal(saved.schema, 4); assert.equal(saved.inputContract, 'literal-v1'); assert.equal(saved.memoryContract, 'native-retained-v1');
    for (const change of [{ schema: 3 }, { inputContract: 'normal-v1' }, { runtimeIdentity: 'foreign-build' }, { memoryContract: 'worker-memory-v1' }]) {
      await writeFile(journalPath, JSON.stringify({ ...saved, ...change }));
      const gateway = new FakeGateway();
      await assert.rejects(fixture({ journalPath, gateway }), /journal identity/);
      assert.equal(gateway.calls.length, 0);
      assert.deepEqual(JSON.parse(await readFile(journalPath, 'utf8')), { ...saved, ...change });
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('fresh-only owner policy refuses old schema, parsing and build identity; manifest pins agree', async () => {
  const { NATIVE_PINS, INPUT_CONTRACT, RUNTIME_IDENTITY, OWNER_SCHEMA, JOURNAL_SCHEMA, MEMORY_CONTRACTS, memoryContract, validateLiteralOwner } = await import('./literal-migration.mjs');
  const owner = { schema: OWNER_SCHEMA, inputContract: INPUT_CONTRACT, memoryContract: memoryContract(true), runtimeIdentity: RUNTIME_IDENTITY, agentId: 'secretary' };
  validateLiteralOwner({ ...owner }, owner);
  for (const change of [{ schema: 4 }, { runtimeIdentity: 'old-build' }, { inputContract: 'normal' }, { agentId: 'foreign' }, { memoryContract: memoryContract(false) }]) {
    assert.throws(() => validateLiteralOwner({ ...owner, ...change }, owner), /migration required.*never replay unknown/);
  }
  // A schema-4 (pre-uniform-memory) owner marker never passes as either memory contract.
  const legacy = { schema: 4, inputContract: INPUT_CONTRACT, runtimeIdentity: RUNTIME_IDENTITY, agentId: 'secretary' };
  assert.throws(() => validateLiteralOwner(legacy, owner), /migration required/);
  assert.throws(() => validateLiteralOwner(legacy, { ...owner, memoryContract: memoryContract(false) }), /migration required/);
  assert.throws(() => memoryContract('yes'));
  const manifest = JSON.parse(await readFile(new URL('./manifest.json', import.meta.url), 'utf8'));
  assert.deepEqual(manifest.developmentPins, NATIVE_PINS);
  assert.equal(manifest.inputContract.profileSchema, OWNER_SCHEMA); assert.equal(manifest.inputContract.journalSchema, JOURNAL_SCHEMA);
  assert.deepEqual(manifest.inputContract.memoryContracts, Object.values(MEMORY_CONTRACTS));
  assert.equal(manifest.uniformMemory.contract, MEMORY_CONTRACTS.uniform);
  assert.equal(NATIVE_PINS.derivedCommit, CURATED_RUNTIME.sourceCommit);
  assert.equal(NATIVE_PINS.fullUpstreamDiffSha256, CURATED_RUNTIME.patchSha256);
  assert.equal(manifest.runtime.node, NATIVE_PINS.node.version);
});

// Uniform host-owned memory integration. The bridge is faked here only to observe
// exact binding/revocation order; real native dispatch is memory-gateway-proof.mjs.
class FakeBridge {
  constructor() { this.bindings = []; this.closed = false; }
  bind(record) { const entry = { ...record, revoked: false }; this.bindings.push(entry); return () => { entry.revoked = true; }; }
  close() { this.closed = true; }
  live() { return this.bindings.filter(entry => !entry.revoked).length; }
}
async function memoryFixture(options = {}) {
  const gateway = options.gateway ?? new FakeGateway(); const events = []; const bridge = new FakeBridge();
  const runtime = { gateway, agentId: 'secretary', workspace: '/unused-private-workspace', authAvailable: true, workerMemory: true, memoryGranted: options.memoryGranted ?? true,
    ...(options.memoryGranted === false ? {} : { memory: { bridge } }), ...(options.journalPath ? { journalPath: options.journalPath } : {}) };
  const adapter = createAdapter({ launch: async (params, context) => { assert.equal(typeof context.callHost, 'function'); return runtime; }, emit: event => events.push(event), callHost: async () => ({ ok: true }) });
  const ready = await adapter.handle('initialize', { workerMemory: true, agentId: 'secretary', scope: { allowedTools: options.memoryGranted === false ? [] : ['memory'] } });
  await adapter.handle('session.open', open);
  return { adapter, gateway, events, ready, bridge, runtime };
}
test('uniform memory accepts only owned managed profiles with an empty or exact memory resource scope', () => {
  assert.deepEqual(validateWorkerMemory({}), { workerMemory: false, memoryGranted: false });
  assert.deepEqual(validateWorkerMemory({ workerMemory: true, scope: { allowedTools: [] } }), { workerMemory: true, memoryGranted: false });
  assert.deepEqual(validateWorkerMemory({ workerMemory: true, scope: { allowedTools: ['memory'] } }), { workerMemory: true, memoryGranted: true });
  for (const scope of [{ allowedTools: ['file'] }, { allowedTools: ['memory', 'file'] }, { allowedTools: ['memory', 'memory'] }, {}]) assert.throws(() => validateWorkerMemory({ workerMemory: true, scope }), /only an empty resource scope or exactly \[memory\]/);
  assert.throws(() => validateWorkerMemory({ workerMemory: 'yes' }), /boolean/);
  const connection = { version: 1, connectionId: 'x', endpoint: 'ws://127.0.0.1:32146/', nativeAgentId: 'a', sessionKey: 'agent:a:main', sessionId: 's', token: 'inert-fixture-token'.repeat(4) };
  assert.throws(() => validateWorkerMemory({ workerMemory: true, scope: { allowedTools: [] }, lifecycle: { version: 1, mode: 'connected', connectionId: 'x' }, protocolVersion: 1, upstreamVersion: UPSTREAM.version, agentId: 'a', connection }), /managed owned profile|connected lifecycle/);
  assert.throws(() => validateWorkerMemory({ workerMemory: true, lifecycle: { version: 1, mode: 'connected', connectionId: 'x' }, protocolVersion: 1, upstreamVersion: UPSTREAM.version, agentId: 'a', connection }), /managed owned profile/);
  const runtime = { node: '/curated/node', source: '/curated/openclaw', gatewayPort: 32146, workspace: '/own/scratch', profileDir: '/own/runtime', home: '/own/runtime/home', state: '/own/runtime/state', temporary: '/own/runtime/tmp' };
  assert.deepEqual(nativeGatewayLaunch({ ...runtime, workerMemory: true, memoryGranted: false }).options.stdio, ['ignore', 'pipe', 'pipe', 3]);
  assert.deepEqual(nativeGatewayLaunch({ ...runtime, workerMemory: true, memoryGranted: true }).options.stdio, ['ignore', 'pipe', 'pipe', 3, 'pipe']);
});
test('uniform configuration is applied after the retained merge so old memory plugins/hooks never merge back', () => {
  const runtime = { agentId: 'secretary', workspace: '/private/agent/workspace', profileDir: '/private/agent/runtime', home: '/private/agent/runtime/isolated-home', state: '/private/agent/runtime/openclaw-state', temporary: '/private/agent/runtime/tmp', node: '/curated/node' };
  const retained = { plugins: { slots: { memory: 'memory-core' }, entries: { 'memory-core': { enabled: true } }, load: { paths: ['/old/plugins'] } }, hooks: { enabled: true },
    memory: { search: { enabled: true } }, agents: { defaults: { contextInjection: 'always', compaction: { memoryFlush: { enabled: true } } }, entries: { secretary: { memory: { search: { enabled: true } }, tools: { allow: ['exec'] } }, other: {} } } };
  const native = effectiveRuntimeConfig(retained, runtime, 12345, 'own-token');
  assert.equal(native.plugins.slots.memory, 'memory-core'); assert.equal(native.hooks.enabled, true); // retained prototype keeps native settings
  const granted = effectiveRuntimeConfig(retained, { ...runtime, workerMemory: true, memoryGranted: true }, 12345, 'own-token');
  assert.equal(granted.plugins.slots.memory, 'none'); assert.deepEqual(Object.keys(granted.plugins.entries), ['yorozu-worker-memory']);
  assert.deepEqual(granted.plugins.allow, ['yorozu-worker-memory']); assert.equal(granted.plugins.load.paths.length, 1); assert.match(granted.plugins.load.paths[0], /\/memory-plugin$/);
  assert.equal(granted.hooks.enabled, false); assert.equal(granted.memory.search.enabled, false); assert.equal(granted.agents.defaults.contextInjection, 'never');
  assert.equal(granted.agents.defaults.compaction.memoryFlush.enabled, false); assert.deepEqual(granted.tools.allow, ['worker_memory']); assert.deepEqual(granted.agents.entries.secretary.tools.allow, ['worker_memory']);
  assert.equal(granted.agents.entries.other, undefined); assert.equal(granted.gateway.auth.token, 'own-token');
  const denied = effectiveRuntimeConfig(retained, { ...runtime, workerMemory: true, memoryGranted: false }, 12345, 'own-token');
  assert.equal(denied.plugins.enabled, false); assert.deepEqual(denied.plugins.load.paths, []); assert.deepEqual(denied.tools.deny, ['*']); assert.equal(denied.plugins.slots.memory, 'none');
});
test('uniform memory is acknowledged only after actual launch and requires the private host callback', async () => {
  const f = await memoryFixture();
  assert.equal(f.ready.workerMemory, true); assert.equal(f.ready.agentId, 'secretary');
  const plain = await fixture(); assert.equal(plain.ready.workerMemory, undefined);
  const noCallback = createAdapter({ launch: async () => ({ gateway: new FakeGateway(), agentId: 'secretary', authAvailable: true, workerMemory: true, memoryGranted: true }) });
  await assert.rejects(noCallback.handle('initialize', { workerMemory: true, agentId: 'secretary', scope: { allowedTools: ['memory'] } }), /host memory callback/);
  const detached = createAdapter({ launch: async () => ({ gateway: new FakeGateway(), agentId: 'secretary', authAvailable: true, workerMemory: true, memoryGranted: true }), callHost: async () => ({}) });
  await assert.rejects(detached.handle('initialize', { workerMemory: true, agentId: 'secretary', scope: { allowedTools: ['memory'] } }), /not actually attached/);
  await assert.rejects(f.adapter.handle('turn.submit', { ...turn, workerMemory: false }), /immutable after initialize/);
});
test('exact native agent/key/SID/run binding precedes chat.send and currency ends with terminal, stop, gaps, yields, loss and shutdown', async () => {
  const f = await memoryFixture();
  f.gateway.overrides.set('chat.send', params => { assert.equal(f.bridge.live(), 1); return { status: 'started', runId: params.idempotencyKey }; });
  assert.equal((await f.adapter.handle('turn.submit', turn)).status, 'accepted');
  const send = f.gateway.last('chat.send'); const binding = f.bridge.bindings[0];
  assert.equal(binding.nativeRunId, send.idempotencyKey); assert.equal(binding.nativeSessionId, 'native-session-0'); assert.equal(binding.sessionKey, send.sessionKey);
  assert.deepEqual(binding.execution, { sessionId: 'native-session-0', runId: turn.runId, attemptId: turn.attemptId });
  assert.equal(binding.current(), true);
  f.gateway.emit(payload(f.gateway, 'delta', { deltaText: 'working' })); await f.adapter.drain(); assert.equal(binding.current(), true);
  f.gateway.emit(payload(f.gateway, 'final', { seq: 1, message: { content: 'done' } })); await f.adapter.drain();
  assert.equal(binding.revoked, true); assert.equal(binding.current(), false); assert.equal(f.events.at(-1).kind, 'turn.terminal');
  // Stop: revocation precedes the abort RPC regardless of its acknowledgement.
  const second = { ...turn, runId: 'host-run-b', attemptId: 'host-attempt-b' };
  await f.adapter.handle('turn.submit', second); const stopped = f.bridge.bindings[1];
  f.gateway.overrides.set('chat.abort', () => { assert.equal(stopped.revoked, true); throw new Error('lost ack'); });
  // A lost abort acknowledgement leaves the native run uncertain, but the memory
  // authority was already revoked before the RPC; the bridge's controller is final.
  assert.equal((await f.adapter.handle('run.stop', { ...second, operationId: 'stop' })).status, 'unknown'); assert.equal(stopped.revoked, true);
  f.gateway.emit(payload(f.gateway, 'aborted')); await f.adapter.drain();
  // Non-consecutive native seq keeps authority (ordinary Gateway behaviour); a yield
  // becomes unknown and no live memory authority remains.
  const sparse = { ...turn, runId: 'host-run-c', attemptId: 'host-attempt-c' };
  await f.adapter.handle('turn.submit', sparse); const sparseBinding = f.bridge.bindings.at(-1);
  f.gateway.emit(payload(f.gateway, 'delta', { seq: 3, deltaText: 'a' })); await f.adapter.drain(); assert.equal(sparseBinding.revoked, false); assert.equal(sparseBinding.current(), true);
  f.gateway.emit(payload(f.gateway, 'final', { seq: 9, message: { content: 'done' } })); await f.adapter.drain(); assert.equal(sparseBinding.revoked, true);
  const yielded = { ...turn, runId: 'host-run-d', attemptId: 'host-attempt-d' };
  await f.adapter.handle('turn.submit', yielded); const yieldedBinding = f.bridge.bindings.at(-1);
  f.gateway.emit(payload(f.gateway, 'final', { yielded: true }));
  await f.adapter.drain(); assert.equal(yieldedBinding.revoked, true); assert.equal(yieldedBinding.current(), false);
  assert.equal((await f.adapter.handle('session.snapshot', open)).current.state, 'unknown');
  await f.adapter.handle('run.stop', { ...yielded, operationId: 'clear-d' }); f.gateway.emit(payload(f.gateway, 'aborted', { seq: 1 })); await f.adapter.drain();
  // Lost send acknowledgement revokes immediately; nothing is replayed.
  f.gateway.overrides.set('chat.send', () => { throw new Error('socket lost'); });
  const lost = { ...turn, runId: 'host-run-e', attemptId: 'host-attempt-e' };
  assert.equal((await f.adapter.handle('turn.submit', lost)).status, 'unknown'); assert.equal(f.bridge.bindings.at(-1).revoked, true);
  assert.equal(f.bridge.live(), 0);
  // Connection loss closes the bridge and revokes everything; shutdown does the same.
  f.gateway.finish('lost socket'); await f.adapter.drain(); assert.equal(f.bridge.closed, true);
  const g = await memoryFixture(); await g.adapter.handle('turn.submit', turn); assert.equal(g.bridge.live(), 1);
  await g.adapter.handle('shutdown'); assert.equal(g.bridge.live(), 0); assert.equal(g.bridge.closed, true);
});
test('a failed memory admission never submits input, and ungranted uniform mode binds nothing', async () => {
  const f = await memoryFixture();
  f.bridge.bind = () => { throw new Error('bridge closed'); };
  const receipt = await f.adapter.handle('turn.submit', turn);
  assert.equal(receipt.status, 'rejected'); assert.equal(f.gateway.count('chat.send'), 0);
  assert.equal((await f.adapter.handle('session.snapshot', open)).current, null);
  const denied = await memoryFixture({ memoryGranted: false });
  assert.equal(denied.ready.workerMemory, true);
  assert.equal((await denied.adapter.handle('turn.submit', turn)).status, 'accepted'); assert.equal(denied.bridge.bindings.length, 0);
});
test('uniform journal binds the memory contract; a native-retained journal is refused in uniform mode without RPC', async () => {
  const root = await mkdtemp(join(tmpdir(), 'uniform-journal-'));
  try {
    const journalPath = join(root, 'journal.json');
    await memoryFixture({ journalPath });
    const saved = JSON.parse(await readFile(journalPath, 'utf8'));
    assert.equal(saved.schema, 4); assert.equal(saved.memoryContract, 'worker-memory-v1');
    await writeFile(journalPath, JSON.stringify({ ...saved, memoryContract: 'native-retained-v1' }));
    const gateway = new FakeGateway();
    await assert.rejects(memoryFixture({ journalPath, gateway }), /journal identity/); assert.equal(gateway.calls.length, 0);
    const plain = new FakeGateway();
    await writeFile(journalPath, JSON.stringify(saved));
    await assert.rejects(fixture({ journalPath, gateway: plain }), /journal identity/); assert.equal(plain.calls.length, 0);
  } finally { await rm(root, { recursive: true, force: true }); }
});
test('managed shutdown receipt waits for the profile ownership release that follows native exit', async () => {
  const { EventEmitter } = await import('node:events');
  const child = new EventEmitter(); child.exitCode = null; child.signalCode = null;
  child.kill = () => setImmediate(() => { child.exitCode = 0; child.emit('exit', 0, null); }); // real exit is asynchronous
  const gateway = new NativeGateway('ws://127.0.0.1:12345', 'own-token', child, { ownership: 'managed' });
  let released = false;
  // launchRuntime registers its exit handler before shutdown's own listener.
  child.on('exit', () => { gateway.released = new Promise(yes => setTimeout(() => { released = true; yes(); }, 20)); });
  await gateway.shutdown();
  assert.equal(released, true); assert.equal(gateway.closed, true);
});

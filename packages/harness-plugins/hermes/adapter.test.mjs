import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { realpath } from 'node:fs/promises';
import { createAdapter, NativeGateway, prepareRuntime, validateAgentScope, UPSTREAM, mergeNativeConfiguration } from './adapter.mjs';
const exec = promisify(execFile);

// Recorded native shapes are from pinned contracts/sessions.py,
// contracts/events.py, server_requests.py and methods_subagents.py. This fixture
// models the upstream, never a second secretary/model loop.
class Gateway {
  calls = []; responses = []; closed = false; epoch = 'fixture-epoch'; nextSeq = 0;
  onFrame(listener) { this.frameListener = listener; }
  onClose(listener) { this.closeListener = listener; }
  async call(method, params) {
    this.calls.push({ method, params });
    if (this.override) { const result = this.override(method, params); if (result !== undefined) return result; }
    if (method === 'client.capabilities') return { server_requests: ['approval', 'clarify'] };
    if (method === 'session.create') return { session_id: 'live-1', stored_session_id: 'durable-1', info: { fast: false }, messages: [], message_count: 0 };
    if (method === 'session.resume') return { session_id: 'live-resumed', stored_session_id: params.session_id, info: { fast: false }, messages: [], message_count: 0 };
    if (method === 'session.activate') return { session_id: params.session_id, running: this.running ?? false, inflight: this.inflight ?? null };
    if (method === 'session.history') return { messages: [], count: 0 };
    if (method === 'prompt.submit') { this.running = true; this.awaitingStart = true; return { status: 'streaming' }; }
    if (method === 'subagent.steer') return { status: 'queued', subagent_id: params.subagent_id, text: params.text };
    if (method === 'subagent.interrupt') return { found: true, subagent_id: params.subagent_id };
    if (method === 'session.interrupt') return { status: 'interrupted' };
    throw new Error(`unexpected upstream operation ${method}`);
  }
  respond(id, result, error) { this.responses.push({ id, result, error }); }
  event(type, payload, sessionId = 'live-1', seq = ++this.nextSeq) {
    if (type === 'message.start') {
      this.running = true;
      if (this.awaitingStart) this.awaitingStart = false;
      else this.inflight = { display_kind: 'async_delegation_complete', display_metadata: { delegation_id: this.continuationId ?? 'unit-one' } };
    }
    this.frameListener({ jsonrpc: '2.0', method: 'event', params: { type, session_id: sessionId, payload, seq } });
    if (type === 'message.complete' || type === 'error') { this.running = false; this.awaitingStart = false; this.inflight = null; }
  }
  request(id, method, params) { this.frameListener({ jsonrpc: '2.0', id, method, params: { session_id: 'live-1', ...params } }); }
  crash() { this.closed = true; this.closeListener('fixture process exited'); }
  async shutdown() { this.crash(); }
}
const currency = { conversationId: 'secretary', bindingId: 'binding-1', runId: 'host-run-1', attemptId: 'host-attempt-1' };
async function setup({ authAvailable = true, initialize = { protocolVersion: 1 }, messageJournalPath } = {}) {
  const events = []; const gateway = new Gateway();
  const adapter = createAdapter({ emit: event => events.push(event), launch: async () => ({
    gateway, authAvailable, ...(messageJournalPath ? { messageJournalPath } : {}), provider: 'custom:yorozu-local-proof', model: 'fixture', workspace: '/owned/workspace',
  }) });
  const manifest = await adapter.handle('initialize', initialize);
  if (authAvailable) await adapter.handle('session.open', { ...currency, preferences: 'Reply in Japanese.', context: 'Prior visible conversation.' });
  return { adapter, gateway, events, manifest };
}
function startChild(gateway, id, extra = {}) {
  gateway.event('subagent.start', { goal: `Work ${id}`, task_count: 2, task_index: 0, subagent_id: id, delegation_id: `unit-${id}`, status: 'running', ...extra });
}
function taskEvent(events, upstreamId) { return events.find(event => event.kind === 'task.changed' && event.data.taskId.endsWith(`:${upstreamId}`)); }
const flush = () => new Promise(resolve => setImmediate(resolve));
async function scopeFixture(t, allowedTools = ['file', 'team']) {
  const directory = await mkdtemp(join(tmpdir(), 'hermes-agent-scope-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const workspace = join(directory, 'workspace'), memoryDir = join(directory, 'memory');
  await mkdir(workspace); await mkdir(memoryDir);
  const params = { protocolVersion: 1, upstreamVersion: UPSTREAM.version, profileRoot: join(directory, 'profile'),
    workspace, python: '/usr/bin/python3', sourcePath: process.env.YOROZU_HERMES_TEST_SOURCE,
    agentId: 'agent-a', scope: { allowedTools, directories: [{ path: workspace, access: 'write' }, ...(allowedTools.includes('memory') ? [{ path: memoryDir, access: 'write' }] : [])], workspace, memoryDir },
    isolation: { backend: 'macos-seatbelt-v1', agentId: 'agent-a', policyDigest: 'a'.repeat(64) },
    platform: { team: allowedTools.includes('team'), computer: false, peers: allowedTools.includes('team') ? [{ agentId: 'agent-b', name: 'B', pluginId: 'hermes' }] : [] } };
  return { directory, workspace: await realpath(workspace), params };
}

test('product scope rejects unsupported tools, mismatched sandbox, and escaping paths before launch', async t => {
  const { params, directory } = await scopeFixture(t);
  let launches = 0;
  const adapter = createAdapter({ emit() {}, launch: async () => { launches++; throw new Error('must not launch'); } });
  const variants = [
    { ...params, agentId: '../other' },
    { ...params, isolation: { ...params.isolation, agentId: 'agent-b' } },
    { ...params, isolation: { ...params.isolation, policyDigest: 'unknown' } },
    { ...params, scope: { ...params.scope, allowedTools: ['all'] } },
    { ...params, scope: { ...params.scope, allowedTools: ['file', 'file'] } },
    { ...params, scope: { ...params.scope, allowedTools: ['computer'] } },
    { ...params, platform: { team: false, computer: false, peers: [{ agentId: 'agent-b', name: 'B', pluginId: 'hermes' }] } },
    { ...params, scope: { ...params.scope, allowedTools: ['file', 'memory', 'team'], memoryDir: directory } },
    { ...params, scope: { ...params.scope, directories: [{ path: '/', access: 'write' }] } },
    { ...params, scope: { ...params.scope, surprise: true } },
    { ...params, agentId: undefined },
  ];
  for (const variant of variants) await assert.rejects(adapter.handle('initialize', variant));
  assert.equal(launches, 0);
  const normalized = await validateAgentScope(params);
  assert.equal(normalized.agentId, 'agent-a'); assert.match(normalized.scopeDigest, /^[a-f0-9]{64}$/);
  assert.deepEqual(normalized.scope.allowedTools, ['file', 'team']);
  const noMemory = await validateAgentScope({ ...params, scope: { ...params.scope, memoryDir: '/unreadable/nonexistent/disabled-memory' } });
  assert.equal(noMemory.scope.memoryDir, '/unreadable/nonexistent/disabled-memory');
  const scratch = join(directory, 'profile', 'scratch'); await mkdir(scratch, { recursive: true });
  const chat = await validateAgentScope({ ...params, workspace: scratch, platform: { team: false, computer: false },
    scope: { ...params.scope, workspace: scratch, allowedTools: [], directories: [] } });
  assert.deepEqual(chat.scope.directories, []);
});

test('scoped capabilities follow allowed native tools and authority cannot change from a turn', async t => {
  const { params } = await scopeFixture(t, []);
  const { adapter, gateway, manifest } = await setup({ initialize: params });
  assert.equal(manifest.agentId, 'agent-a'); assert.deepEqual(manifest.isolation, params.isolation);
  assert.equal(manifest.capabilities.backgroundTasks, true); assert.equal(manifest.capabilities.teamDelegation, false);
  for (const method of ['turn.submit', 'session.open', 'session.snapshot']) {
    await assert.rejects(adapter.handle(method, { ...currency, text: 'Check', scope: params.scope }), /immutable/);
    await assert.rejects(adapter.handle(method, { ...currency, sourceIntegrity: 'sealed-inventory-v1' }), /immutable/);
  }
  const receipt = await adapter.handle('turn.submit', { ...currency, text: 'Read file.', attachments: [{ path: '/private/other.txt' }] });
  assert.equal(receipt.status, 'unsupported'); assert.equal(gateway.calls.some(call => call.method === 'prompt.submit'), false);
});

test('legacy teammate execution requests are unavailable without creating or controlling another agent', async t => {
  const { params } = await scopeFixture(t);
  const { adapter, gateway, events, manifest } = await setup({ initialize: params });
  assert.equal(manifest.capabilities.teamDelegation, false);
  gateway.request('legacy-team', 'yorozu.team_delegate', { agent_session_id: 'durable-1', teammateId: 'agent-b' });
  assert.equal(gateway.responses.at(-1).result.status, 'rejected');
  assert.equal(events.at(-1).kind, 'capability.unavailable');
  assert.equal(events.some(event => event.kind === 'request.open'), false);
  assert.equal((await adapter.handle('request.answer', { requestId: 'legacy-team', answer: { result: { status: 'completed' } } })).status, 'rejected');
  assert.equal(gateway.calls.filter(call => ['prompt.submit', 'session.interrupt'].includes(call.method)).length, 0);
});

test('native secretary remains responsive while children run; steering targets only exact task currency', async () => {
  const { adapter, gateway, events } = await setup();
  const create = gateway.calls.find(call => call.method === 'session.create');
  assert.equal(create.params.fast, undefined);
  assert.equal(create.params.messages, undefined); // The host does not inject memory or behavioral instructions.
  assert.equal((await adapter.handle('turn.submit', { ...currency, text: 'Delegate two tasks.' })).status, 'accepted');
  gateway.event('message.start'); gateway.event('message.delta', { text: 'Working ' }); gateway.event('message.delta', { text: 'on it.' });
  startChild(gateway, 'one'); startChild(gateway, 'two');
  const one = taskEvent(events, 'one'); const two = taskEvent(events, 'two');
  gateway.event('message.complete', { text: 'Two tasks are underway.', status: 'complete' });
  assert.equal((await adapter.handle('turn.submit', { ...currency, runId: 'host-run-2', attemptId: 'host-attempt-2', text: 'How are things?' })).status, 'accepted');
  const result = await adapter.handle('task.steer', { ...currency, taskId: two.data.taskId, operationId: 'steer-two', text: 'Use the smaller example.' });
  assert.equal(result.status, 'queued');
  assert.deepEqual(gateway.calls.filter(call => call.method === 'subagent.steer'), [
    { method: 'subagent.steer', params: { session_id: 'live-1', subagent_id: 'two', text: 'Use the smaller example.' } },
  ]);
  assert.equal((await adapter.handle('task.steer', { ...currency, attemptId: 'wrong-attempt', taskId: one.data.taskId, operationId: 'stale', text: 'Wrong.' })).status, 'rejected');
  assert.equal(events.find(event => event.kind === 'assistant.update' && event.data.text === 'Working on it.').runId, currency.runId);
  startChild(gateway, 'grandchild', { parent_id: 'one' });
  assert.equal(taskEvent(events, 'grandchild').data.parentTaskId, one.data.taskId);
  assert.equal(taskEvent(events, 'grandchild').data.originRunId, currency.runId);
});

test('Stop acknowledgement is requested; task terminal evidence is required and operation replay is deduplicated', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('turn.submit', { ...currency, text: 'Start work.' });
  startChild(gateway, 'one'); startChild(gateway, 'two');
  const taskId = taskEvent(events, 'one').data.taskId;
  const stop = { ...currency, taskId, operationId: 'stop-one' };
  assert.equal((await adapter.handle('task.stop', stop)).status, 'requested');
  assert.equal((await adapter.handle('task.stop', stop)).status, 'requested');
  assert.equal(gateway.calls.filter(call => call.method === 'subagent.interrupt').length, 1);
  assert.equal(events.at(-1).data.state, 'stopping');
  assert.equal(taskEvent(events, 'two').data.state, 'running');
  assert.equal(events.filter(event => event.kind === 'task.changed' && event.data.taskId === taskId && event.data.state === 'stopped').length, 0);
  gateway.event('subagent.complete', { goal: 'Work one', task_count: 2, task_index: 0, subagent_id: 'one', status: 'interrupted', summary: 'Stopped before writing.' });
  assert.equal(events.at(-1).data.state, 'stopped');
  assert.equal((await adapter.handle('task.steer', { ...currency, taskId, operationId: 'late', text: 'Continue.' })).status, 'rejected');
});

test('run Stop requires exact scope and does not claim a broad session interrupt is selective', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('turn.submit', { ...currency, text: 'First work.' }); startChild(gateway, 'one');
  gateway.event('message.complete', { text: 'Background work continues.', status: 'complete' });
  assert.equal((await adapter.handle('run.stop', { ...currency, operationId: 'stop-background' })).status, 'requested');
  assert.equal(events.filter(event => event.kind === 'task.changed' && event.data.state === 'stopped').length, 0);
  assert.equal((await adapter.handle('turn.submit', { ...currency, runId: 'host-run-2', attemptId: 'host-attempt-2', text: 'Second work.' })).status, 'rejected');
  gateway.event('subagent.complete', { goal: 'Work one', task_count: 1, task_index: 0, subagent_id: 'one', status: 'interrupted' });
  await adapter.handle('turn.submit', { ...currency, runId: 'host-run-2', attemptId: 'host-attempt-2', text: 'Second work.' });
  startChild(gateway, 'two');
  gateway.event('message.complete', { text: 'Second task started.', status: 'complete' });
  await adapter.handle('turn.submit', { ...currency, runId: 'host-run-3', attemptId: 'host-attempt-3', text: 'Third work.' });
  startChild(gateway, 'three');
  assert.equal((await adapter.handle('run.stop', { ...currency, runId: 'host-run-3', attemptId: 'host-attempt-3', operationId: 'stop-three' })).status, 'unsupported');
  assert.equal(gateway.calls.filter(call => call.method === 'session.interrupt').length, 1);
});

test('approval refusal is exact, approval grants once only, unsupported secret requests fail closed', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('turn.submit', { ...currency, text: 'Check.' });
  gateway.request('srq-deny', 'approval', { request_id: 'queue-deny', command: 'rm example.txt', description: 'Delete file', choices: ['once', 'session', 'always', 'deny'] });
  assert.equal(events.at(-1).kind, 'action.open');
  assert.equal((await adapter.handle('request.answer', { sessionId: 'durable-1', requestId: 'srq-deny', answer: { approved: false } })).status, 'answered');
  assert.deepEqual(gateway.responses.at(-1), { id: 'srq-deny', result: { choice: 'deny' }, error: undefined });
  assert.equal((await adapter.handle('request.answer', { sessionId: 'durable-1', requestId: 'srq-deny', answer: { approved: true } })).status, 'rejected');
  gateway.request('srq-once', 'approval', { choices: ['once', 'always', 'deny'] });
  await adapter.handle('request.answer', { sessionId: 'durable-1', requestId: 'srq-once', answer: { approved: true } });
  assert.deepEqual(gateway.responses.at(-1).result, { choice: 'once' });
  gateway.request('srq-broad', 'approval', { choices: ['session', 'always', 'deny'] });
  assert.equal((await adapter.handle('request.answer', { sessionId: 'durable-1', requestId: 'srq-broad', answer: { approved: true } })).status, 'unsupported');
  gateway.request('srq-secret', 'secret', { env_var: 'SERVICE_TOKEN', prompt: 'Paste a token.' });
  assert.equal(gateway.responses.at(-1).error.code, -32601);
  assert.equal(events.at(-1).kind, 'capability.unavailable');
  gateway.request('srq-question', 'clarify', { question: 'Which output?', choices: ['A', 'B'] });
  await adapter.handle('request.answer', { sessionId: 'durable-1', requestId: 'srq-question', answer: { text: 'B' } });
  assert.deepEqual(gateway.responses.at(-1).result, { answer: 'B' });
});

test('Hermes-owned continuation keeps original origin with a distinct attempt after foreground terminal', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('turn.submit', { ...currency, text: 'Delegate.' }); startChild(gateway, 'one');
  gateway.event('message.complete', { status: 'complete', text: 'I will report when done.' });
  gateway.event('subagent.complete', { goal: 'Work one', task_count: 1, task_index: 0, subagent_id: 'one', status: 'completed', summary: 'Artifact created.' });
  gateway.event('message.start'); gateway.event('message.delta', { text: 'The result is ready.' });
  gateway.event('message.complete', { text: 'The result is ready.', status: 'complete' });
  await flush();
  const started = events.find(event => event.kind === 'turn.started');
  assert.equal(started.runId, currency.runId); assert.notEqual(started.attemptId, currency.attemptId);
  assert.deepEqual(started.data, { continuation: true, originRunId: currency.runId, resultTaskIds: [taskEvent(events, 'one').data.taskId] });
  assert.equal(events.at(-1).attemptId, started.attemptId);
  assert.equal(events.at(-1).data.cessation, 'provider-terminal');
  assert.equal(gateway.calls.filter(call => call.method === 'prompt.submit').length, 1);
});

test('one batch consumes one delegation identity; old child completions cannot authorize an unrelated turn', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('turn.submit', { ...currency, text: 'Delegate a grouped batch.' });
  startChild(gateway, 'one', { delegation_id: 'unit-group' }); startChild(gateway, 'two', { delegation_id: 'unit-group' });
  gateway.event('message.complete', { text: 'Started.', status: 'complete' });
  for (const id of ['one', 'two']) gateway.event('subagent.complete', { goal: id, task_count: 2, task_index: 0, subagent_id: id, status: 'completed' });
  gateway.continuationId = 'unit-group';
  gateway.event('message.start'); gateway.event('message.start'); // Native notification path can emit twice.
  gateway.event('message.delta', { text: 'Batch done.' }); gateway.event('message.complete', { status: 'complete', text: 'Batch done.' });
  await flush();
  assert.equal(events.filter(event => event.kind === 'turn.started').length, 1);
  assert.deepEqual(events.find(event => event.kind === 'turn.started').data.resultTaskIds.sort(), [taskEvent(events, 'one').data.taskId, taskEvent(events, 'two').data.taskId].sort());
  gateway.event('message.start'); gateway.event('message.delta', { text: 'Unrelated notification.' });
  await flush();
  assert.equal(events.filter(event => event.kind === 'turn.started').length, 1);
  assert.equal(events.at(-1).kind, 'capability.unavailable');
  assert.equal((await adapter.handle('session.snapshot', currency)).unattributedTurn.state, 'unknown');
});

test('interleaved results use native delegation metadata rather than FIFO or most recent user origin', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('turn.submit', { ...currency, text: 'First task.' }); startChild(gateway, 'one');
  gateway.event('message.complete', { status: 'complete' });
  await adapter.handle('turn.submit', { ...currency, runId: 'host-run-2', attemptId: 'host-attempt-2', text: 'Second task.' }); startChild(gateway, 'two');
  gateway.event('message.complete', { status: 'complete' });
  for (const id of ['one', 'two']) gateway.event('subagent.complete', { goal: id, task_count: 1, task_index: 0, subagent_id: id, status: 'completed' });
  gateway.continuationId = 'unit-two'; gateway.event('message.start'); gateway.event('message.delta', { text: 'Second task result.' }); gateway.event('message.complete', { status: 'complete' });
  await flush();
  assert.equal(events.find(event => event.kind === 'turn.started').runId, 'host-run-2');
});

test('children and cancelled requests arriving during identity lookup retain the proven continuation origin', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('turn.submit', { ...currency, text: 'First task.' }); startChild(gateway, 'one');
  gateway.event('message.complete', { status: 'complete' });
  await adapter.handle('turn.submit', { ...currency, runId: 'host-run-2', attemptId: 'host-attempt-2', text: 'Another topic.' });
  gateway.event('message.complete', { status: 'complete' });
  gateway.event('subagent.complete', { goal: 'one', task_count: 1, task_index: 0, subagent_id: 'one', status: 'completed' });
  let resolveIdentity;
  gateway.override = method => method === 'session.activate' ? new Promise(resolve => { resolveIdentity = resolve; }) : undefined;
  gateway.event('message.start'); gateway.event('message.delta', { text: 'Following up.' });
  startChild(gateway, 'next');
  gateway.request('srq-transient', 'approval', { choices: ['once', 'deny'] });
  gateway.event('request.cancel', { id: 'srq-transient', reason: 'interrupted' });
  assert.equal(taskEvent(events, 'next'), undefined);
  resolveIdentity({ running: true, inflight: { display_kind: 'async_delegation_complete', display_metadata: { delegation_id: 'unit-one', task_count: 1 } } });
  await flush();
  const started = events.find(event => event.kind === 'turn.started');
  assert.equal(taskEvent(events, 'next').data.originRunId, currency.runId);
  assert.equal(taskEvent(events, 'next').attemptId, started.attemptId);
  assert.equal((await adapter.handle('request.answer', { sessionId: 'durable-1', requestId: 'srq-transient', answer: { approved: true } })).status, 'rejected');
  assert.equal(events.filter(event => event.kind === 'action.open').length, 1);
  assert.equal(events.some(event => event.kind === 'action.cancel'), true);
});

test('unattributed native continuation stays unknown without an extra platform interrupt', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('turn.submit', { ...currency, text: 'Delegate.' }); startChild(gateway, 'one');
  await adapter.handle('run.stop', { ...currency, operationId: 'stop-all' });
  gateway.event('message.complete', { status: 'interrupted' });
  gateway.event('subagent.complete', { goal: 'one', task_count: 1, task_index: 0, subagent_id: 'one', status: 'interrupted' });
  gateway.event('message.start'); gateway.event('message.delta', { text: 'Late result.' });
  await flush();
  assert.equal(events.filter(event => event.kind === 'turn.started').length, 0);
  assert.equal(events.at(-1).kind, 'capability.unavailable');
  assert.equal(gateway.calls.filter(call => call.method === 'session.interrupt').length, 1);
});

test('native build-cancel error clears current projection without fabricating terminal cessation', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('turn.submit', { ...currency, text: 'Start.' });
  await adapter.handle('run.stop', { ...currency, operationId: 'early-stop' });
  gateway.event('error', { message: 'Turn cancelled before the agent was ready' });
  assert.equal((await adapter.handle('session.snapshot', currency)).current, null);
  assert.equal(events.at(-1).data.state, 'unknown');
  assert.equal(events.at(-1).data.cessation, undefined);
});

test('child terminal before interrupt acknowledgement never regresses to stopping', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('turn.submit', { ...currency, text: 'Delegate.' }); startChild(gateway, 'one');
  gateway.override = (method, params) => {
    if (method !== 'subagent.interrupt') return undefined;
    gateway.event('subagent.complete', { goal: 'one', task_count: 1, task_index: 0, subagent_id: params.subagent_id, status: 'interrupted' });
    return { found: true, subagent_id: params.subagent_id };
  };
  await adapter.handle('task.stop', { ...currency, taskId: taskEvent(events, 'one').data.taskId, operationId: 'stop-race' });
  assert.equal((await adapter.handle('session.snapshot', currency)).tasks[0].state, 'stopped');
  assert.equal(events.at(-1).data.state, 'stopped');
});

test('native timeout does not prove a deferred worker stopped or authorize a result continuation', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('turn.submit', { ...currency, text: 'Delegate.' }); startChild(gateway, 'one');
  gateway.event('message.complete', { status: 'complete' });
  gateway.event('subagent.complete', { goal: 'one', task_count: 1, task_index: 0, subagent_id: 'one', status: 'timeout' });
  assert.equal((await adapter.handle('session.snapshot', currency)).tasks[0].state, 'unknown');
  gateway.event('message.start'); gateway.event('message.delta', { text: 'Timeout recovery.' });
  await flush();
  assert.equal(events.filter(event => event.kind === 'turn.started').length, 0);
});

test('crash stays unknown, pending approvals cancel and an admitted attempt is never replayed', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('turn.submit', { ...currency, text: 'Do work.' }); startChild(gateway, 'one');
  gateway.request('srq-pending', 'approval', { choices: ['once', 'deny'] });
  gateway.crash();
  const snapshot = await adapter.handle('session.snapshot', { conversationId: currency.conversationId });
  assert.equal(snapshot.runtime, 'closed'); assert.equal(snapshot.tasks[0].state, 'unknown'); assert.equal(snapshot.tasks[0].canSteer, false);
  assert.equal(events.find(event => event.kind === 'turn.terminal').data.state, 'unknown');
  assert.equal(events.some(event => event.kind === 'action.cancel' && event.data.requestId === 'srq-pending'), true);
  await assert.rejects(adapter.handle('turn.submit', { ...currency, text: 'Do work.' }), /cannot be replayed/);
  assert.equal(gateway.calls.filter(call => call.method === 'prompt.submit').length, 1);
});

test('safe resume is lazy and inspection only; duplicate event cursors do not duplicate effects', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('session.open', { conversationId: 'restored', bindingId: 'binding-2', sessionId: 'durable-other' });
  assert.deepEqual(gateway.calls.find(call => call.method === 'session.resume').params,
    { session_id: 'durable-other', source: 'yorozu', lazy: true, omit_messages: true, close_on_disconnect: false });
  assert.equal(gateway.calls.filter(call => call.method === 'prompt.submit').length, 0);
  await adapter.handle('turn.submit', { ...currency, text: 'Check.' });
  gateway.event('message.delta', { text: 'hello' }, 'live-1', 12);
  gateway.event('message.delta', { text: 'hello' }, 'live-1', 12);
  assert.equal(events.filter(event => event.kind === 'assistant.update').length, 1);
  assert.deepEqual((await adapter.handle('session.snapshot', currency)).cursor, { epoch: 'fixture-epoch', sequence: 12 });
  gateway.override = method => method === 'session.resume' ? { session_id: 'unsafe', stored_session_id: 'unsafe', running: true, info: {} } : undefined;
  await adapter.handle('session.open', { conversationId: 'unsafe', bindingId: 'binding-3', sessionId: 'unsafe' });
  assert.equal((await adapter.handle('session.snapshot', { conversationId: 'unsafe' })).unattributedTurn.state, 'unknown');
  assert.equal(gateway.calls.filter(call => call.method === 'session.interrupt').length, 0);
});

test('uncertain admission rejects retries and does not convert queued or redirected replies into accepted', async () => {
  const { adapter, gateway, events } = await setup();
  gateway.override = method => method === 'prompt.submit' ? { status: 'queued' } : undefined;
  assert.equal((await adapter.handle('turn.submit', { ...currency, text: 'Check.' })).status, 'unknown');
  assert.equal(events.at(-1).data.state, 'unknown');
  assert.equal((await adapter.handle('turn.submit', { ...currency, text: 'Check.' })).status, 'rejected');
  assert.equal(gateway.calls.filter(call => call.method === 'prompt.submit').length, 1);
});

test('native busy preflight does not submit or consume an attempt; fresh topics force queue instead of steer', async () => {
  const { adapter, gateway } = await setup();
  gateway.running = true;
  const busy = await adapter.handle('turn.submit', { ...currency, text: 'A new topic.' });
  assert.equal(busy.status, 'busy'); assert.equal(busy.handoff, 'not-submitted');
  assert.equal(gateway.calls.some(call => call.method === 'prompt.submit'), false);
  gateway.running = false;
  assert.equal((await adapter.handle('turn.submit', { ...currency, text: 'A new topic.' })).status, 'accepted');
  assert.equal(gateway.calls.find(call => call.method === 'prompt.submit').params.queued, true);
});

test('lost control acknowledgements stay cached unknown without replay, including after task or run settlement', async () => {
  for (const method of ['task.steer', 'task.stop', 'run.stop']) {
    const { adapter, gateway, events } = await setup();
    await adapter.handle('turn.submit', { ...currency, text: 'Delegate.' }); startChild(gateway, 'one');
    const nativeMethod = method === 'task.steer' ? 'subagent.steer' : method === 'task.stop' ? 'subagent.interrupt' : 'session.interrupt';
    gateway.override = called => called === nativeMethod ? Promise.reject(Object.assign(new Error('acknowledgement lost'), { code: -32004 })) : undefined;
    const params = { ...currency, operationId: `lost-${method}`, ...(method.startsWith('task.') ? { taskId: taskEvent(events, 'one').data.taskId } : {}), ...(method === 'task.steer' ? { text: 'Use example A.' } : {}) };
    const receipt = await adapter.handle(method, params);
    assert.equal(receipt.status, 'unknown'); assert.match(receipt.reason, /do not replay/);
    gateway.event('subagent.complete', { goal: 'one', task_count: 1, task_index: 0, subagent_id: 'one', status: 'completed' });
    gateway.event('message.complete', { text: 'Done.', status: 'complete' });
    assert.deepEqual(await adapter.handle(method, params), receipt);
    assert.equal(gateway.calls.filter(call => call.method === nativeMethod).length, 1);
    assert.equal((await adapter.handle(method, { ...params, attemptId: 'foreign-attempt' })).status, 'rejected');
  }
});

test('malformed controls are unknown; unsupported native methods remain explicit unsupported', async () => {
  for (const method of ['task.steer', 'task.stop', 'run.stop']) {
    const { adapter, gateway, events } = await setup();
    await adapter.handle('turn.submit', { ...currency, text: 'Delegate.' }); startChild(gateway, 'one');
    const nativeMethod = method === 'task.steer' ? 'subagent.steer' : method === 'task.stop' ? 'subagent.interrupt' : 'session.interrupt';
    gateway.override = called => called === nativeMethod ? {} : undefined;
    const params = { ...currency, operationId: `malformed-${method}`, ...(method.startsWith('task.') ? { taskId: taskEvent(events, 'one').data.taskId } : {}), ...(method === 'task.steer' ? { text: 'Use example A.' } : {}) };
    assert.equal((await adapter.handle(method, params)).status, 'unknown');
    gateway.override = called => called === nativeMethod ? Promise.reject(Object.assign(new Error('unsupported'), { code: -32601 })) : undefined;
    assert.equal((await adapter.handle(method, { ...params, operationId: `unsupported-${method}` })).status, 'unsupported');
  }
});

test('real subscription auth unavailable is explicit and never triggers session/provider probes', async () => {
  const { adapter, gateway, manifest } = await setup({ authAvailable: false });
  assert.equal(manifest.auth.status, 'unsupported');
  await assert.rejects(adapter.handle('session.open', currency), error => error.code === -32010 && error.data.capability === 'auth');
  assert.deepEqual(gateway.calls.map(call => call.method), ['client.capabilities']);
});

test('native stdio client parses shipped readiness, request and event frames and fails bounded on invalid output', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'hermes-pipe-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const script = join(directory, 'gateway.mjs');
  await writeFile(script, `
    import readline from 'node:readline';
    const emit = frame => process.stdout.write(JSON.stringify(frame) + '\\n');
    emit({jsonrpc:'2.0',method:'event',params:{type:'gateway.ready',payload:{skin:'default',change_events:true,replay_epoch:'pipe'}}});
    readline.createInterface({input:process.stdin}).on('line', line => {
      const req=JSON.parse(line);
      if(req.method==='test.invalid') { process.stdout.write('invalid-json\\n'); return; }
      emit({jsonrpc:'2.0',id:req.id,result:{status:'streaming'}});
      emit({jsonrpc:'2.0',method:'event',params:{type:'message.delta',session_id:'live',seq:1,payload:{text:'hello'}}});
    }).on('close',()=>process.exit(0));
  `);
  const gateway = new NativeGateway(spawn(process.execPath, [script], { stdio: ['pipe', 'pipe', 'pipe'], env: {} }));
  t.after(() => gateway.shutdown());
  const events = []; let received;
  const eventReceived = new Promise(resolve => { received = resolve; });
  gateway.onFrame(frame => { events.push(frame); received(); });
  await gateway.ready;
  assert.equal(gateway.epoch, 'pipe');
  assert.equal((await gateway.call('prompt.submit', { session_id: 'live', text: 'hello' })).status, 'streaming');
  await eventReceived;
  assert.equal(events[0].params.type, 'message.delta');
  await assert.rejects(gateway.call('test.invalid', {}), /unknown/);
  assert.equal(gateway.closed, true);
});

// Integration setup is opt-in because a source checkout/dependencies are external
// to this small adapter. Parent acceptance exercises the real pinned Hermes loop.
test('owned runtime applies resource bindings without choosing harness approval or autonomy', {
  skip: !process.env.YOROZU_HERMES_TEST_SOURCE,
}, async t => {
  // Production preparation now requires a host-owned scoped person. Exercise
  // that contract rather than the retired unscoped initialization fixture.
  const { params, directory: root } = await scopeFixture(t, ['file', 'terminal', 'web', 'browser']);
  const directory = join(root, 'profile');
  const originalIndex = await readFile(join(params.sourcePath, '.git/index'));
  const runtime = await prepareRuntime(params);
  assert.deepEqual(await readFile(join(params.sourcePath, '.git/index')), originalIndex);
  assert.equal(runtime.authAvailable, false);
  assert.deepEqual(Object.keys(runtime.env).sort(), ['CODEX_HOME', 'HERMES_DISABLE_LAZY_INSTALLS', 'HERMES_HOME', 'HERMES_TUI_TOOLSETS', 'HOME', 'LANG', 'PATH', 'PYTHONDONTWRITEBYTECODE', 'PYTHONNOUSERSITE', 'PYTHONUNBUFFERED', 'TIRITH_BIN', 'TIRITH_ENABLED', 'TIRITH_FAIL_OPEN', 'TMPDIR'].sort());
  assert.equal(runtime.env.CODEX_HOME.startsWith(await realpath(directory)), true);
  const config = JSON.parse(await readFile(join(directory, 'hermes-runtime', 'config.yaml'), 'utf8'));
  assert.equal(config.desktop, undefined);
  assert.equal(config.agent.service_tier, undefined); assert.deepEqual(config.fallback_model, []);
  assert.deepEqual(config.agent.disabled_toolsets, ['cronjob', 'computer_use']);
  assert.equal(config.approvals, undefined); assert.equal(config.delegation, undefined);
  await writeFile(join(directory, 'hermes-runtime', 'config.yaml'), JSON.stringify({ ...config, approvals: { mode: 'smart' }, desktop: { auto_continue: { enabled: true } }, delegation: { max_spawn_depth: 7 } }));
  await prepareRuntime(params);
  const retained = JSON.parse(await readFile(join(directory, 'hermes-runtime', 'config.yaml'), 'utf8'));
  assert.equal(retained.approvals.mode, 'smart'); assert.equal(retained.desktop.auto_continue.enabled, true); assert.equal(retained.delegation.max_spawn_depth, 7);
  assert.equal(config.display.busy_input_mode, 'queue');
  assert.equal(config.security.allow_lazy_installs, false);
  assert.equal(config.security.tirith_enabled, true); assert.equal(config.security.tirith_fail_open, false);
  assert.equal(config.security.tirith_path, join(runtime.env.HERMES_HOME, 'curated-tirith-unavailable'));
  assert.equal(runtime.env.HERMES_DISABLE_LAZY_INSTALLS, '1'); assert.equal(runtime.env.TIRITH_FAIL_OPEN, '0');
  assert.equal(runtime.env.TIRITH_BIN, config.security.tirith_path);
  await rm(join(directory, 'hermes-runtime', 'config.yaml'));
  await symlink(join(directory, 'outside'), join(directory, 'hermes-runtime', 'config.yaml'));
  await assert.rejects(prepareRuntime(params), /must not be a symlink/);
});

test('upstream security refuses unavailable scanner without starting an installer', {
  skip: !process.env.YOROZU_HERMES_TEST_SOURCE || !process.env.YOROZU_HERMES_TEST_PYTHON,
}, async t => {
  const { params } = await scopeFixture(t, []);
  params.python = process.env.YOROZU_HERMES_TEST_PYTHON;
  const runtime = await prepareRuntime(params);
  const result = await exec(params.python, ['-c', `
import json
from tools import lazy_deps, tirith_security
def forbidden(*args, **kwargs):
    raise AssertionError("curated runtime must not start an installer")
tirith_security._install_tirith = forbidden
tirith_security._background_install = forbidden
assert lazy_deps._allow_lazy_installs() is False
assert tirith_security.ensure_installed() is None
verdict = tirith_security.check_command_security("echo harmless-curated-probe")
assert verdict["action"] == "block", verdict
print(json.dumps({"lazyInstall": False, "command": verdict["action"]}))
`], { cwd: runtime.sourcePath, env: runtime.env, maxBuffer: 16 * 1024 });
  assert.deepEqual(JSON.parse(result.stdout), { lazyInstall: false, command: 'block' });
});

test('native discovery exposes exact scoped subsets, empty chat scope, and messaging tools', {
  skip: !process.env.YOROZU_HERMES_TEST_SOURCE || !process.env.YOROZU_HERMES_TEST_PYTHON,
}, async t => {
  const { params, directory } = await scopeFixture(t);
  params.python = process.env.YOROZU_HERMES_TEST_PYTHON;
  const bootstrap = new URL('./bootstrap.py', import.meta.url).pathname;
  const runtime = await prepareRuntime(params);
  const memories = join(runtime.env.HERMES_HOME, 'memories'); await mkdir(memories);
  await writeFile(join(memories, 'MEMORY.md'), 'Retained private marker must not enter a no-memory run.');
  await writeFile(join(memories, 'USER.md'), 'Retained private user marker must not enter a no-memory run.');
  const options = { cwd: runtime.sourcePath, env: runtime.env, maxBuffer: 64 * 1024 };
  const verified = JSON.parse((await exec(params.python, [bootstrap, '--verify'], options)).stdout);
  assert.deepEqual(verified.toolsets, ['delegation', 'file', 'memory', 'yorozu_platform', 'yorozu_empty']);
  for (const tool of ['read_agent_messages', 'send_agent_message', 'read_file', 'write_file']) assert.equal(verified.tools.includes(tool), true);
  assert.equal(verified.tools.includes('delegate_to_agent'), false);
  const result = JSON.parse((await exec(params.python, ['-c', `
import runpy, sys, json
runpy.run_path(sys.argv[1])["verify"]()
from gateway.session_context import set_session_vars
from tui_gateway import server_requests
from tools.registry import registry
from tools.approval_context import set_current_observability_context
from agent.agent_init import _init_memory
from hermes_cli.config import load_config_readonly
from types import SimpleNamespace
agent=SimpleNamespace(enabled_toolsets=["memory","delegation","file","yorozu_platform","yorozu_empty"],disabled_toolsets=[],tools=[])
_init_memory(agent,load_config_readonly(),False,"yorozu")
memory={"enabled":agent._memory_enabled,"user":agent._user_profile_enabled,"storeAbsent":agent._memory_store is None}
captured=[]
def fake_send(method, sid, params, *, timeout):
    captured.append({"method":method,"sid":sid,"params":params,"timeout":timeout})
    return {"status":"accepted","messageId":params["messageId"],"exchangeId":"exchange-proof"}
server_requests.send=fake_send
set_session_vars(session_key="proof",session_id="durable-proof",ui_session_id="live-proof")
set_current_observability_context(tool_call_id="native-call-proof",session_id="durable-proof",turn_id="native-turn-proof")
args={"toAgentId":"agent-b","text":"Shared context."}
completed=json.loads(registry.dispatch("send_agent_message", args, session_id="durable-proof"))
server_requests.send=lambda *args,**kwargs: None
unknown=json.loads(registry.dispatch("send_agent_message", args, session_id="durable-proof"))
invalid=json.loads(registry.dispatch("send_agent_message", {**args,"command":"forbidden"}, session_id="durable-proof"))
print(json.dumps({"captured":captured,"completed":completed,"unknown":unknown,"invalid":invalid,"memory":memory}))
`, bootstrap], options)).stdout);
  assert.equal(result.captured.length, 1); assert.equal(result.captured[0].timeout, 30);
  assert.equal(result.captured[0].sid, 'live-proof'); assert.equal(result.captured[0].params.agent_session_id, 'durable-proof');
  assert.equal(result.completed.status, 'accepted'); assert.equal(result.unknown.status, 'unknown'); assert.equal(result.invalid.status, 'rejected');
  assert.deepEqual(result.memory, { enabled: true, user: true, storeAbsent: false });
  const wrongOwner = { ...params, agentId: 'agent-b', isolation: { ...params.isolation, agentId: 'agent-b' },
    platform: { ...params.platform, peers: [] } }; // Valid scope: reach the existing profile-owner guard.
  await assert.rejects(prepareRuntime(wrongOwner), /different adapter version or agent/);
  // Native metadata failures must stop before gateway/provider startup, never
  // fall through to the upstream all-tools fallback.
  await writeFile(join(directory, 'profile', 'hermes-runtime', 'plugins', 'yorozu-platform', '__init__.py'), 'def register(ctx):\n    pass\n');
  await assert.rejects(exec(params.python, [bootstrap, '--verify'], options), /Unverified scoped native toolset/);
  const chat = await scopeFixture(t, []);
  chat.params.python = params.python;
  const chatRuntime = await prepareRuntime(chat.params);
  const empty = JSON.parse((await exec(params.python, [bootstrap, '--verify'], { cwd: chatRuntime.sourcePath, env: chatRuntime.env, maxBuffer: 64 * 1024 })).stdout);
  assert.deepEqual(empty.toolsets, ['delegation', 'memory', 'yorozu_empty']);
  for (const tool of ['read_file', 'write_file', 'terminal']) assert.equal(empty.tools.includes(tool), false);
});


test('fresh host broker bearer stays in private native config and never in returned bootstrap metadata', {
  skip: !process.env.YOROZU_HERMES_TEST_SOURCE,
}, async t => {
  const { params, directory } = await scopeFixture(t, []);
  await mkdir(params.profileRoot, { recursive: true, mode: 0o700 });
  const providerConfigPath = join(params.profileRoot, 'proof-provider.json'), bearer = 'fresh-host-broker-'.padEnd(64, 'b');
  await writeFile(providerConfigPath, JSON.stringify({ baseUrl: 'http://127.0.0.1:54321/v1', model: 'proof-model', apiMode: 'codex_responses', bearer }), { mode: 0o600 });
  const runtime = await prepareRuntime({ ...params, providerConfigPath });
  const config = JSON.parse(await readFile(join(params.profileRoot, 'hermes-runtime/config.yaml'), 'utf8'));
  assert.equal(config.custom_providers[0].api_key, bearer);
  assert.equal(JSON.stringify(runtime).includes(bearer), false);
  for (const bad of ['short', bearer + '\r\nheader:bad']) {
    await writeFile(providerConfigPath, JSON.stringify({ baseUrl: 'http://127.0.0.1:54321/v1', model: 'proof-model', apiMode: 'codex_responses', bearer: bad }));
    await assert.rejects(prepareRuntime({ ...params, providerConfigPath }), error => error.message === 'host broker bearer is invalid' && !error.message.includes(bad));
  }
  await writeFile(providerConfigPath, '{"bearer":"' + bearer + '" BROKEN}');
  await assert.rejects(prepareRuntime({ ...params, providerConfigPath }), error => error.message === 'provider config is invalid JSON' && !error.message.includes(bearer));
  await writeFile(providerConfigPath, JSON.stringify({ baseUrl: 'http://127.0.0.1:54321/v1', model: 'proof-model', apiMode: 'codex_responses' }));
  await prepareRuntime({ ...params, providerConfigPath });
  const legacy = JSON.parse(await readFile(join(params.profileRoot, 'hermes-runtime/config.yaml'), 'utf8'));
  assert.equal(legacy.custom_providers[0].api_key, 'yorozu-loopback-proof');
});

test('native approvals retain all offered choices outside a user turn and reject forged actions', async () => {
  const { adapter, gateway, events } = await setup();
  gateway.request('native-action', 'approval', { tool_name: 'terminal', choices: ['once', 'session', 'always', 'deny'], command: 'native command' });
  const action = events.at(-1);
  assert.equal(action.kind, 'action.open'); assert.equal(action.runId, undefined);
  assert.equal(action.data.sessionId, 'durable-1');
  assert.deepEqual(action.data.choices.map(choice => choice.id), ['once', 'session', 'always', 'deny']);
  const answer = { version: 1, requestId: 'native-action', sessionId: 'durable-1', choiceId: 'session' };
  assert.equal((await adapter.handle('action.answer', { ...answer, sessionId: 'foreign' })).status, 'rejected');
  assert.equal((await adapter.handle('action.answer', { ...answer, choiceId: 'invented' })).status, 'rejected');
  assert.equal(gateway.responses.length, 0);
  assert.equal((await adapter.handle('action.answer', answer)).status, 'answered');
  assert.deepEqual(gateway.responses.at(-1).result, { choice: 'session' });
  assert.equal((await adapter.handle('action.answer', answer)).status, 'rejected');
  gateway.request('question', 'clarify', { question: 'Which result?', choices: ['One', 'Two'] });
  await adapter.handle('action.answer', { version: 1, requestId: 'question', sessionId: 'durable-1', choiceId: 'choice:1' });
  assert.deepEqual(gateway.responses.at(-1).result, { answer: 'Two' });
});

test('Hermes refuses unsafe connected lifecycle before launch or native observation', async () => {
  let launched = false;
  const adapter = createAdapter({ emit() {}, launch: async () => { launched = true; } });
  await assert.rejects(adapter.handle('initialize', { lifecycle: { version: 1, mode: 'connected', connectionId: 'chosen' }, connection: {} }), /last-peer detach/);
  assert.equal(launched, false);
});

const deliveredMessage = {
  version: 1, messageId: 'peer-message-1', exchangeId: 'exchange-1', deliveryId: 'delivery-1', attemptId: 'delivery-attempt-1',
  sessionId: 'durable-1', fromAgentId: 'agent-b', toAgentId: 'agent-a', text: 'A selected finding from B.', createdAt: 1791192360000,
  origin: { version: 1, agentId: 'agent-b', pluginId: 'hermes', conversationId: 'public-conversation-b', sessionId: 'opaque-public-session', bindingEpoch: 'binding-b' },
};

test('native peer inbox is durable, deduplicated and never submits a fake user turn', async t => {
  const { params, directory } = await scopeFixture(t);
  const messageJournalPath = join(directory, 'messages.json');
  const { adapter, gateway, manifest } = await setup({ initialize: params, messageJournalPath });
  assert.equal(manifest.extensions.agentMessaging, true);
  assert.equal((await adapter.handle('message.deliver', deliveredMessage)).status, 'accepted');
  assert.equal((await adapter.handle('message.deliver', { ...deliveredMessage, attemptId: 'new-transport-attempt' })).status, 'accepted');
  assert.equal((await adapter.handle('message.deliver', { ...deliveredMessage, text: 'Forged replacement.' })).status, 'rejected');
  assert.equal((await adapter.handle('message.deliver', { ...deliveredMessage, toAgentId: 'foreign' })).status, 'rejected');
  await assert.rejects(adapter.handle('message.deliver', { ...deliveredMessage, origin: { ...deliveredMessage.origin, agentId: 'forged' } }), /sender/);
  assert.equal(gateway.calls.filter(call => call.method === 'prompt.submit').length, 0);
  assert.equal(JSON.parse(await readFile(messageJournalPath, 'utf8')).messages.length, 1);
  await adapter.handle('shutdown');
  const restored = await setup({ initialize: params, messageJournalPath });
  restored.gateway.event('tool.start', { tool_id: 'read-native-call', name: 'read_agent_messages' });
  restored.gateway.request('read-inbox', 'yorozu.message_read', { agent_session_id: 'durable-1', tool_call_id: 'read-native-call' });
  assert.deepEqual(restored.gateway.responses.at(-1).result.messages, [deliveredMessage]);
  assert.equal(restored.events.some(event => ['assistant.update', 'turn.started'].includes(event.kind)), false);
  assert.equal((await restored.adapter.handle('message.deliver', { ...deliveredMessage, attemptId: 'after-restart' })).status, 'accepted');
  assert.equal(JSON.parse(await readFile(messageJournalPath, 'utf8')).messages.length, 1);
});

test('native send verifies the real tool and session, settles only a transport receipt, and does not cancel peer work', async t => {
  const { params, directory } = await scopeFixture(t);
  const { adapter, gateway, events } = await setup({ initialize: params, messageJournalPath: join(directory, 'messages.json') });
  const input = { agent_session_id: 'durable-1', tool_call_id: 'send-native-call', messageId: 'outbound-1', toAgentId: 'agent-b', text: 'Necessary selected context.' };
  gateway.request('forged', 'yorozu.message_send', input);
  assert.equal(events.some(event => event.kind === 'agent.message'), false);
  gateway.event('tool.start', { tool_id: input.tool_call_id, name: 'send_agent_message' });
  gateway.request('native-send', 'yorozu.message_send', input);
  const sent = events.at(-1);
  assert.equal(sent.kind, 'agent.message'); assert.equal(sent.runId, undefined);
  assert.equal(sent.data.sessionId, 'durable-1'); assert.equal(sent.data.fromAgentId, undefined); assert.equal(sent.data.origin, undefined);
  assert.equal((await adapter.handle('message.receipt', { version: 1, messageId: input.messageId, exchangeId: 'host-exchange-1', status: 'accepted' })).status, 'answered');
  assert.deepEqual(gateway.responses.at(-1).result, { status: 'accepted', messageId: 'outbound-1', exchangeId: 'host-exchange-1' });
  assert.equal(gateway.calls.filter(call => ['prompt.submit', 'session.interrupt'].includes(call.method)).length, 0);
  gateway.event('tool.start', { tool_id: 'next-native-call', name: 'send_agent_message' });
  gateway.request('second-send', 'yorozu.message_send', { ...input, messageId: 'outbound-2', tool_call_id: 'next-native-call' });
  gateway.event('request.cancel', { id: 'second-send' });
  assert.equal(events.at(-1).kind, 'agent.message.status'); assert.equal(events.at(-1).data.execution, 'unknown');
  assert.equal(gateway.calls.filter(call => call.method.includes('interrupt')).length, 0);
});

test('resource rebinding preserves harness approval, autonomy, memory and plugin choices', () => {
  const previous = { approvals: { mode: 'smart' }, desktop: { auto_continue: { enabled: true } }, memory: { provider: 'builtin', memory_enabled: false },
    delegation: { max_spawn_depth: 9 }, agent: { service_tier: 'fast', disabled_toolsets: ['file', 'memory'] },
    plugins: { enabled: ['native-learning'], entries: { 'native-learning': { settings: { learn: true } } } } };
  const host = { agent: { disabled_toolsets: ['terminal', 'web', 'cronjob', 'computer_use'] },
    plugins: { enabled: ['yorozu-platform'], entries: { 'yorozu-platform': { settings: { team: true } } } } };
  const config = mergeNativeConfiguration(previous, host, {});
  assert.deepEqual(config.approvals, previous.approvals); assert.deepEqual(config.desktop, previous.desktop); assert.deepEqual(config.memory, previous.memory);
  assert.deepEqual(config.delegation, previous.delegation); assert.equal(config.agent.service_tier, 'fast');
  assert.deepEqual(config.agent.disabled_toolsets, ['memory', 'terminal', 'web', 'cronjob', 'computer_use']);
  assert.deepEqual(config.plugins.enabled, ['native-learning', 'yorozu-platform']);
  assert.deepEqual(config.plugins.entries['native-learning'], previous.plugins.entries['native-learning']);
  assert.deepEqual(previous.agent.disabled_toolsets, ['file', 'memory']); // Does not mutate the stored input.
});

test('peer inbox pages stay bounded and message content identity is canonical across transport attempts', async t => {
  const { params, directory } = await scopeFixture(t);
  const { adapter, gateway } = await setup({ initialize: params, messageJournalPath: join(directory, 'messages.json') });
  for (let index = 0; index < 5; index++) {
    const result = await adapter.handle('message.deliver', { ...deliveredMessage, messageId: `page-${index}`, deliveryId: `page-delivery-${index}`, text: 'x'.repeat(32 * 1024) });
    assert.equal(result.status, 'accepted');
  }
  const reorderedOrigin = Object.fromEntries(Object.entries(deliveredMessage.origin).reverse());
  assert.equal((await adapter.handle('message.deliver', { ...deliveredMessage, origin: reorderedOrigin })).status, 'accepted');
  assert.equal((await adapter.handle('message.deliver', { ...deliveredMessage, origin: deliveredMessage.origin, attemptId: 'transport-other' })).status, 'accepted');
  gateway.event('tool.start', { tool_id: 'read-page-1', name: 'read_agent_messages' });
  gateway.request('page-one', 'yorozu.message_read', { agent_session_id: 'durable-1', tool_call_id: 'read-page-1' });
  const first = gateway.responses.at(-1).result;
  assert.equal(first.messages.length, 4); assert.equal(first.nextAfterMessageId, 'page-3');
  assert.ok(Buffer.byteLength(JSON.stringify(first)) < 256 * 1024);
  gateway.event('tool.start', { tool_id: 'read-page-2', name: 'read_agent_messages' });
  gateway.request('page-two', 'yorozu.message_read', { agent_session_id: 'durable-1', tool_call_id: 'read-page-2', afterMessageId: first.nextAfterMessageId });
  assert.deepEqual(gateway.responses.at(-1).result.messages.map(message => message.messageId), ['page-4', deliveredMessage.messageId]);
  assert.equal(gateway.calls.filter(call => call.method === 'prompt.submit').length, 0);
});

test('escaped reply overflow is only presentation loss; dense deltas and terminal do not kill the harness', async () => {
  for (const character of ['"', '\n', '\\', '\u0001']) {
    const { adapter, gateway, events } = await setup();
    await adapter.handle('turn.submit', { ...currency, text: 'fixture' });
    for (let index = 0; index < 19; index++) gateway.event('message.delta', { text: character.repeat(10 * 1024) });
    gateway.event('message.complete', { text: character.repeat(190 * 1024), status: 'complete' });
    assert.equal(gateway.closed, false);
    assert.equal(gateway.calls.some(call => call.method === 'session.interrupt'), false);
    assert.ok(events.some(event => event.kind === 'capability.unavailable' && event.data.capability === 'replySize'));
    assert.equal(events.at(-1).kind, 'turn.terminal'); assert.equal(events.at(-1).data.state, 'completed');
    for (const event of events) assert.ok(Buffer.byteLength(JSON.stringify({ jsonrpc: '2.0', method: 'harness.event', params: event }) + '\n') <= 256 * 1024);
  }
});

test('dense serialized inbox stays reloadable and every escaped page advances within wire bounds', async t => {
  const { params, directory } = await scopeFixture(t);
  const messageJournalPath = join(directory, 'dense.json');
  const { adapter } = await setup({ initialize: params, messageJournalPath });
  let accepted = 0, busy = 0;
  for (let index = 0; index < 64; index++) {
    const receipt = await adapter.handle('message.deliver', { ...deliveredMessage, messageId: `dense-${index}`, text: '\u0001'.repeat(32 * 1024) });
    if (receipt.status === 'accepted') accepted++; else { assert.equal(receipt.status, 'busy'); busy++; }
  }
  assert.ok(accepted > 0 && busy > 0);
  assert.ok(Buffer.byteLength(await readFile(messageJournalPath)) <= 3 * 1024 * 1024);
  await adapter.handle('shutdown');
  const restored = await setup({ initialize: params, messageJournalPath });
  let cursor; const seen = [];
  do {
    const tool = `read-${seen.length}`;
    restored.gateway.event('tool.start', { tool_id: tool, name: 'read_agent_messages' });
    restored.gateway.request(tool, 'yorozu.message_read', { agent_session_id: 'durable-1', tool_call_id: tool, ...(cursor ? { afterMessageId: cursor } : {}) });
    const response = restored.gateway.responses.at(-1);
    assert.ok(Buffer.byteLength(JSON.stringify({ jsonrpc: '2.0', ...response }) + '\n') <= 256 * 1024);
    assert.equal(response.result.messages.length, 1);
    seen.push(...response.result.messages.map(message => message.messageId));
    cursor = response.result.nextAfterMessageId;
  } while (cursor);
  assert.equal(seen.length, accepted); assert.equal(new Set(seen).size, accepted);
});

test('explicit native retirement frees capacity, preserves unacknowledged custody and deduplicates after restart', async t => {
  const { params, directory } = await scopeFixture(t);
  const messageJournalPath = join(directory, 'retire.json');
  const { adapter, gateway } = await setup({ initialize: params, messageJournalPath });
  for (let index = 0; index < 64; index++) assert.equal((await adapter.handle('message.deliver', { ...deliveredMessage, messageId: `retire-${index}` })).status, 'accepted');
  assert.equal((await adapter.handle('message.deliver', { ...deliveredMessage, messageId: 'sixty-fifth' })).status, 'busy');
  gateway.event('tool.start', { tool_id: 'ack', name: 'read_agent_messages' });
  gateway.request('ack', 'yorozu.message_read', { agent_session_id: 'durable-1', tool_call_id: 'ack', acknowledgeMessageIds: Array.from({ length: 63 }, (_, index) => `retire-${index}`) });
  await adapter.handle('shutdown'); // Waits for durable native acknowledgement, not just the request dispatch.
  assert.equal(gateway.responses.find(response => response.id === 'ack').result.acknowledgedMessageIds.length, 63);
  const restored = await setup({ initialize: params, messageJournalPath });
  assert.equal((await restored.adapter.handle('message.deliver', { ...deliveredMessage, messageId: 'sixty-fifth' })).status, 'accepted');
  assert.equal((await restored.adapter.handle('message.deliver', { ...deliveredMessage, messageId: 'retire-0' })).status, 'accepted');
  assert.equal((await restored.adapter.handle('message.deliver', { ...deliveredMessage, messageId: 'retire-0', text: 'changed' })).status, 'rejected');
  const saved = JSON.parse(await readFile(messageJournalPath, 'utf8'));
  assert.deepEqual(saved.messages.map(message => message.messageId), ['retire-63', 'sixty-fifth']);
  assert.equal(saved.retired.length, 63);
});

test('journal load failure cleans injected gateway and concurrent initialize cannot launch twice', async t => {
  const { params, directory } = await scopeFixture(t);
  const path = join(directory, 'bad.json'); await writeFile(path, '{bad');
  const gateway = new Gateway(); let launches = 0, proceed;
  gateway.shutdown = async () => { gateway.closed = true; };
  const adapter = createAdapter({ emit() {}, launch: async () => { launches++; await new Promise(resolve => { proceed = resolve; }); return { gateway, messageJournalPath: path }; } });
  const first = adapter.handle('initialize', params);
  while (!proceed) await flush();
  await assert.rejects(adapter.handle('initialize', params), /initializ/);
  proceed(); await assert.rejects(first);
  assert.equal(launches, 1); assert.equal(gateway.closed, true);
});

test('real launcher rejects missing product authority before touching nonexistent provider/source', async () => {
  const adapter = createAdapter({ emit() {} });
  await assert.rejects(adapter.handle('initialize', { protocolVersion: 1, upstreamVersion: UPSTREAM.version,
    providerConfigPath: '/not-accessed/provider.json' }), /product scope/);
});

test('exclusive inert profile lease rejects concurrency and stale ownership; release cannot delete a successor', async t => {
  const { acquireProfileLock } = await import('./adapter.mjs');
  const { directory } = await scopeFixture(t);
  const release = await acquireProfileLock(directory);
  await assert.rejects(acquireProfileLock(directory), /locked/);
  await release(); const successor = await acquireProfileLock(directory);
  await release(); await assert.rejects(acquireProfileLock(directory), /locked/);
  await successor();
  await mkdir(join(directory, '.hermes-adapter-owner.lock'));
  await assert.rejects(acquireProfileLock(directory), /orphan ownership/);
});

test('approval before resume reply is buffered and replayed exactly once without an adapter answer', async () => {
  const gateway = new Gateway(); const events = [];
  const request = { jsonrpc: '2.0', id: 'opening-approval', method: 'approval', params: { session_id: 'live-resumed', tool_name: 'terminal', choices: ['once', 'deny'] } };
  gateway.override = method => {
    if (method !== 'session.resume') return;
    gateway.frameListener(request);
    return { session_id: 'live-resumed', stored_session_id: 'durable-1', open_requests: [request] };
  };
  const adapter = createAdapter({ emit: event => events.push(event), launch: async () => ({ gateway, authAvailable: true }) });
  await adapter.handle('initialize', {});
  await adapter.handle('session.open', { ...currency, sessionId: 'durable-1' });
  assert.equal(gateway.responses.length, 0);
  assert.equal(events.filter(event => event.kind === 'action.open').length, 1);
});

test('native display choices survive host busy-input rebinding', () => {
  const previous = { display: { theme: 'native', compact: true, busy_input_mode: 'steer' } };
  assert.deepEqual(mergeNativeConfiguration(previous, { agent: { disabled_toolsets: [] }, display: { busy_input_mode: 'queue' } }).display,
    { theme: 'native', compact: true, busy_input_mode: 'queue' });
});

test('closed recipient session is busy, unsupported peer capability and legacy answer identity fail closed', async t => {
  const { params, directory } = await scopeFixture(t);
  const { adapter, gateway } = await setup({ initialize: params, messageJournalPath: join(directory, 'messages.json') });
  assert.equal((await adapter.handle('message.deliver', { ...deliveredMessage, sessionId: 'not-open' })).status, 'busy');
  assert.equal((await adapter.handle('message.deliver', deliveredMessage)).status, 'accepted');
  await assert.rejects(validateAgentScope({ ...params, platform: { ...params.platform, peers: [{ agentId: 'agent-b', name: 'B', pluginId: 'openclaw' }] } }), /peer identity/);
  gateway.request('approval', 'approval', { choices: ['once', 'deny'] });
  assert.equal((await adapter.handle('request.answer', { requestId: 'approval', answer: { approved: true } })).status, 'rejected');
  assert.equal(gateway.responses.length, 0);
});

test('retirement write failure never drops unacknowledged in-memory custody or reports acknowledgement', async t => {
  const { params, directory } = await scopeFixture(t);
  const messageJournalPath = join(directory, 'messages.json');
  const { adapter, gateway } = await setup({ initialize: params, messageJournalPath });
  await adapter.handle('message.deliver', deliveredMessage);
  const saved = await readFile(messageJournalPath);
  await rm(messageJournalPath); await mkdir(messageJournalPath); // Inert rename failure; no production disk fault.
  gateway.event('tool.start', { tool_id: 'fail-ack', name: 'read_agent_messages' });
  gateway.request('fail-ack', 'yorozu.message_read', { agent_session_id: 'durable-1', tool_call_id: 'fail-ack', acknowledgeMessageIds: [deliveredMessage.messageId] });
  while (!gateway.responses.some(response => response.id === 'fail-ack')) await flush();
  assert.equal(gateway.responses.at(-1).result.unavailable, true);
  assert.equal(gateway.responses.at(-1).result.acknowledgedMessageIds, undefined);
  gateway.event('tool.start', { tool_id: 'after-failure', name: 'read_agent_messages' });
  gateway.request('after-failure', 'yorozu.message_read', { agent_session_id: 'durable-1', tool_call_id: 'after-failure' });
  assert.deepEqual(gateway.responses.at(-1).result.messages, [deliveredMessage]);
  await rm(messageJournalPath, { recursive: true }); await writeFile(messageJournalPath, saved);
});

test('sealed source cannot accept a caller digest, symlinked source/.git, or a fabricated pinned revision', async t => {
  const { verifySealedHermesSource, SEALED_HERMES_SOURCE_SHA256 } = await import('./adapter.mjs');
  const f = await scopeFixture(t), source = join(f.directory, 'source');
  await mkdir(source); await mkdir(join(source, '.git'));
  await writeFile(join(source, '.git/HEAD'), UPSTREAM.commit + '\n');
  await writeFile(join(source, 'pyproject.toml'), 'version = "0.21.5"\n');
  assert.match(SEALED_HERMES_SOURCE_SHA256, /^[a-f0-9]{64}$/);
  await assert.rejects(verifySealedHermesSource(source), /integrity/);
  await assert.rejects(prepareRuntime({ ...f.params, sourcePath: source, sourceIntegrity: { kind: 'sealed-inventory-v1', sourceSha: UPSTREAM.commit, inventorySha256: SEALED_HERMES_SOURCE_SHA256 } }), /integrity/);
  await assert.rejects(prepareRuntime({ ...f.params, sourcePath: source, sourceIntegrity: 'skip' }), /integrity/);
  await assert.rejects(prepareRuntime({ ...f.params, sourcePath: source, sourceIntegrity: { kind: 'sealed-inventory-v1', sourceSha: UPSTREAM.commit, inventorySha256: '0'.repeat(64) } }), /integrity/);
  const alias = join(f.directory, 'alias'); await symlink(source, alias);
  await assert.rejects(verifySealedHermesSource(alias), /integrity/);
  await rm(join(source, '.git'), { recursive: true }); await symlink(f.workspace, join(source, '.git'));
  await assert.rejects(verifySealedHermesSource(source), /integrity/);
});

test('assembled sealed source is rehashed in the child; edits, extra files and metadata tampering fail', {
  skip: !process.env.YOROZU_HERMES_SEALED_TEST_SOURCE,
}, async t => {
  const { verifySealedHermesSource } = await import('./adapter.mjs');
  const { cp, chmod, link } = await import('node:fs/promises');
  const f = await scopeFixture(t), source = join(f.directory, 'source');
  await cp(process.env.YOROZU_HERMES_SEALED_TEST_SOURCE, source, { recursive: true });
  await verifySealedHermesSource(source);
  for (const name of ['pyproject.toml', '.git/HEAD', '.git/index']) {
    const path = join(source, name), original = await readFile(path);
    await writeFile(path, Buffer.concat([original, Buffer.from('tamper')]));
    await assert.rejects(verifySealedHermesSource(source), /integrity/);
    await writeFile(path, original);
  }
  const extra = join(source, 'unsealed.py'); await writeFile(extra, 'malicious = True');
  await assert.rejects(verifySealedHermesSource(source), /integrity/); await rm(extra);
  const project = join(source, 'pyproject.toml'); await chmod(project, 0o666);
  await assert.rejects(verifySealedHermesSource(source), /integrity/); await chmod(project, 0o644);
  await link(project, join(f.directory, 'hardlink'));
  await assert.rejects(verifySealedHermesSource(source), /integrity/); await rm(join(f.directory, 'hardlink'));
  const original = await readFile(project); await rm(project); await symlink(join(f.directory, 'borrowed'), project); await writeFile(join(f.directory, 'borrowed'), original);
  await assert.rejects(verifySealedHermesSource(source), /integrity/); await rm(project); await writeFile(project, original);
  await verifySealedHermesSource(source);
});

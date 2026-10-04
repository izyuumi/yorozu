import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, writeFile, readFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { realpath } from 'node:fs/promises';
import { createAdapter, NativeGateway, prepareRuntime, validateAgentScope, UPSTREAM } from './adapter.mjs';
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
async function setup({ authAvailable = true, initialize = { protocolVersion: 1 } } = {}) {
  const events = []; const gateway = new Gateway();
  const adapter = createAdapter({ emit: event => events.push(event), launch: async () => ({
    gateway, authAvailable, provider: 'custom:yorozu-local-proof', model: 'fixture', workspace: '/owned/workspace',
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
    platform: { team: allowedTools.includes('team'), computer: false } };
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
    { ...params, platform: { team: false, computer: false } },
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
  assert.equal(manifest.capabilities.backgroundTasks, false); assert.equal(manifest.capabilities.teamDelegation, false);
  for (const method of ['turn.submit', 'session.open', 'session.snapshot']) await assert.rejects(adapter.handle(method, { ...currency, text: 'Check', scope: params.scope }), /immutable/);
  const receipt = await adapter.handle('turn.submit', { ...currency, text: 'Read file.', attachments: [{ path: '/private/other.txt' }] });
  assert.equal(receipt.status, 'unsupported'); assert.equal(gateway.calls.some(call => call.method === 'prompt.submit'), false);
});

test('team handoff carries bounded narrowed scope and exact originating result currency', async t => {
  const { params, workspace } = await scopeFixture(t);
  const { adapter, gateway, events } = await setup({ initialize: params });
  await adapter.handle('turn.submit', { ...currency, text: 'Ask teammate B.' });
  const input = { agent_session_id: 'durable-1', teammateId: 'agent-b', context: 'Necessary shared context only.', expectedResult: 'Return a concise finding.',
    scope: { allowedTools: ['file'], directories: [{ path: workspace, access: 'read' }], sharedResourceIds: ['resource-1'] } };
  const issueTeam = (id, change = {}) => {
    const tool_call_id = `call-${id}`;
    gateway.event('tool.start', { tool_id: tool_call_id, name: 'delegate_to_agent', args: {} });
    gateway.request(id, 'yorozu.team_delegate', { ...input, tool_call_id, ...change });
  };
  issueTeam('team-one');
  const opened = events.at(-1);
  assert.equal(opened.data.kind, 'team-delegate'); assert.equal(opened.runId, currency.runId);
  assert.deepEqual(opened.data.input.scope, input.scope);
  assert.equal((await adapter.handle('request.answer', { ...currency, attemptId: 'other', requestId: 'team-one', answer: { result: { status: 'completed', text: 'Finding.' } } })).status, 'rejected');
  await assert.rejects(adapter.handle('request.answer', { ...currency, requestId: 'team-one', answer: { result: { status: 'completed', command: 'anything' } } }), /unsupported/);
  assert.equal((await adapter.handle('request.answer', { ...currency, requestId: 'team-one', answer: { result: { status: 'unknown', taskId: 'host-task-1', text: 'Result uncertain; do not retry.' } } })).status, 'answered');
  assert.deepEqual(gateway.responses.at(-1).result, { status: 'unknown', taskId: 'host-task-1', text: 'Result uncertain; do not retry.' });
  assert.equal((await adapter.handle('request.answer', { ...currency, requestId: 'team-one', answer: { result: { status: 'completed' } } })).status, 'rejected');
  gateway.request('duplicate-call', 'yorozu.team_delegate', { ...input, tool_call_id: 'call-team-one' });
  assert.equal(gateway.responses.at(-1).result.status, 'rejected');
  issueTeam('recursive-team', { scope: { ...input.scope, allowedTools: ['file', 'team'] } });
  assert.deepEqual(events.at(-1).data.input.scope.allowedTools, ['file', 'team']);
  await adapter.handle('request.answer', { ...currency, requestId: 'recursive-team', answer: { result: { status: 'completed', text: 'Recipient may make a further equally narrowed handoff.' } } });
  for (const [id, change] of [
    ['child', { agent_session_id: 'durable-child' }], ['wide-tools', { scope: { ...input.scope, allowedTools: ['terminal'] } }],
    ['wide-path', { scope: { ...input.scope, directories: [{ path: '/private/other', access: 'read' }] } }],
    ['self', { teammateId: 'agent-a' }], ['command', { command: 'anything' }],
  ]) {
    issueTeam(id, change);
    assert.equal(gateway.responses.at(-1).result.status, 'rejected');
    assert.equal(events.some(event => event.kind === 'request.open' && event.data.requestId === id), false);
  }
  issueTeam('cancel-team');
  gateway.event('request.cancel', { id: 'cancel-team', reason: 'timeout' });
  assert.equal((await adapter.handle('request.answer', { ...currency, requestId: 'cancel-team', answer: { result: { status: 'completed' } } })).status, 'rejected');
  gateway.event('tool.start', { tool_id: 'late-call', name: 'delegate_to_agent', args: {} });
  gateway.event('message.complete', { text: 'Done.', status: 'complete' });
  await adapter.handle('turn.submit', { ...currency, runId: 'next-run', attemptId: 'next-attempt', text: 'New task.' });
  gateway.request('stale-same-session', 'yorozu.team_delegate', { ...input, tool_call_id: 'late-call' });
  assert.equal(gateway.responses.at(-1).result.status, 'rejected');
  gateway.event('tool.start', { tool_id: 'finished-call', name: 'delegate_to_agent', args: {} });
  gateway.event('tool.complete', { tool_id: 'finished-call', name: 'delegate_to_agent', result: 'Cancelled' });
  gateway.request('finished-call-request', 'yorozu.team_delegate', { ...input, tool_call_id: 'finished-call' });
  assert.equal(gateway.responses.at(-1).result.status, 'rejected');
  await adapter.handle('run.stop', { ...currency, runId: 'next-run', attemptId: 'next-attempt', operationId: 'stop-next' });
  issueTeam('after-stop');
  assert.equal(gateway.responses.at(-1).result.status, 'rejected');
});

test('Stop fences a team answer while native interrupt acknowledgement is still pending', async t => {
  const { params } = await scopeFixture(t);
  const { adapter, gateway } = await setup({ initialize: params });
  await adapter.handle('turn.submit', { ...currency, text: 'Ask B.' });
  gateway.event('tool.start', { tool_id: 'inflight-team', name: 'delegate_to_agent', args: {} });
  gateway.request('team-inflight', 'yorozu.team_delegate', { agent_session_id: 'durable-1', tool_call_id: 'inflight-team', teammateId: 'agent-b',
    context: 'Shared context.', expectedResult: 'Finding.', scope: { allowedTools: [], directories: [] } });
  let acknowledge;
  gateway.override = method => method === 'session.interrupt' ? new Promise(resolve => { acknowledge = resolve; }) : undefined;
  const stopping = adapter.handle('run.stop', { ...currency, operationId: 'stop-inflight-team' });
  assert.equal((await adapter.handle('request.answer', { ...currency, requestId: 'team-inflight', answer: { result: { status: 'completed', text: 'Late result.' } } })).status, 'rejected');
  assert.equal(gateway.responses.length, 0);
  acknowledge({ status: 'interrupted' }); assert.equal((await stopping).status, 'requested');
});

test('native secretary remains responsive while children run; steering targets only exact task currency', async () => {
  const { adapter, gateway, events } = await setup();
  const create = gateway.calls.find(call => call.method === 'session.create');
  assert.equal(create.params.fast, false);
  assert.match(create.params.messages[0].content, /Reply in Japanese/);
  assert.equal(create.params.messages[0].role, 'user');
  assert.match(create.params.messages[0].content, /Do not execute or replay requests/);
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
  assert.equal(events.at(-1).kind, 'request.open');
  assert.equal((await adapter.handle('request.answer', { requestId: 'srq-deny', answer: { approved: false } })).status, 'answered');
  assert.deepEqual(gateway.responses.at(-1), { id: 'srq-deny', result: { choice: 'deny' }, error: undefined });
  assert.equal((await adapter.handle('request.answer', { requestId: 'srq-deny', answer: { approved: true } })).status, 'rejected');
  gateway.request('srq-once', 'approval', { choices: ['once', 'always', 'deny'] });
  await adapter.handle('request.answer', { requestId: 'srq-once', answer: { approved: true } });
  assert.deepEqual(gateway.responses.at(-1).result, { choice: 'once' });
  gateway.request('srq-broad', 'approval', { choices: ['session', 'always', 'deny'] });
  assert.equal((await adapter.handle('request.answer', { requestId: 'srq-broad', answer: { approved: true } })).status, 'unsupported');
  gateway.request('srq-secret', 'secret', { env_var: 'SERVICE_TOKEN', prompt: 'Paste a token.' });
  assert.equal(gateway.responses.at(-1).error.code, -32601);
  assert.equal(events.at(-1).kind, 'capability.unavailable');
  gateway.request('srq-question', 'clarify', { question: 'Which output?', choices: ['A', 'B'] });
  await adapter.handle('request.answer', { requestId: 'srq-question', answer: { text: 'B' } });
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
  assert.equal((await adapter.handle('request.answer', { requestId: 'srq-transient', answer: { approved: true } })).status, 'rejected');
  assert.equal(events.filter(event => event.kind === 'request.open').length, 1);
  assert.equal(events.at(-1).kind, 'request.cancel');
});

test('main Stop fences a late native child-result continuation while exact task Stop may summarize', async () => {
  const { adapter, gateway, events } = await setup();
  await adapter.handle('turn.submit', { ...currency, text: 'Delegate.' }); startChild(gateway, 'one');
  await adapter.handle('run.stop', { ...currency, operationId: 'stop-all' });
  gateway.event('message.complete', { status: 'interrupted' });
  gateway.event('subagent.complete', { goal: 'one', task_count: 1, task_index: 0, subagent_id: 'one', status: 'interrupted' });
  gateway.event('message.start'); gateway.event('message.delta', { text: 'Late result.' });
  await flush();
  assert.equal(events.filter(event => event.kind === 'turn.started').length, 0);
  assert.equal(events.at(-1).kind, 'capability.unavailable');
  assert.equal(gateway.calls.filter(call => call.method === 'session.interrupt').length, 2);
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
  assert.equal(events.some(event => event.kind === 'request.cancel' && event.data.requestId === 'srq-pending'), true);
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
  await assert.rejects(adapter.handle('session.open', { conversationId: 'unsafe', bindingId: 'binding-3', sessionId: 'unsafe' }), /refusing admission/);
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
test('owned real runtime config disables recovery/fallback/priority and strips ambient authentication', {
  skip: !process.env.YOROZU_HERMES_TEST_SOURCE,
}, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'hermes-isolation-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const workspace = join(directory, 'workspace'); await mkdir(workspace);
  const params = { protocolVersion: 1, upstreamVersion: UPSTREAM.version, profileRoot: directory,
    workspace, sourcePath: process.env.YOROZU_HERMES_TEST_SOURCE, python: '/usr/bin/python3' };
  const runtime = await prepareRuntime(params);
  assert.equal(runtime.authAvailable, false);
  assert.deepEqual(Object.keys(runtime.env).sort(), ['CODEX_HOME', 'HERMES_HOME', 'HOME', 'LANG', 'PATH', 'PYTHONDONTWRITEBYTECODE', 'PYTHONNOUSERSITE', 'PYTHONUNBUFFERED', 'TMPDIR'].sort());
  assert.equal(runtime.env.CODEX_HOME.startsWith(await realpath(directory)), true);
  const config = JSON.parse(await readFile(join(directory, 'hermes-runtime', 'config.yaml'), 'utf8'));
  assert.equal(config.desktop.auto_continue.enabled, false);
  assert.equal(config.agent.service_tier, 'normal'); assert.deepEqual(config.fallback_model, []);
  assert.deepEqual(config.agent.disabled_toolsets, ['cronjob', 'computer_use']);
  assert.equal(config.approvals.mode, 'manual'); assert.equal(config.delegation.orchestrator_enabled, true);
  assert.equal(config.display.busy_input_mode, 'queue');
  await rm(join(directory, 'hermes-runtime', 'config.yaml'));
  await symlink(join(directory, 'outside'), join(directory, 'hermes-runtime', 'config.yaml'));
  await assert.rejects(prepareRuntime(params), /must not be a symlink/);
});

test('native discovery exposes exact scoped subsets, empty chat scope, and bounded platform handoff', {
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
  assert.deepEqual(verified.toolsets, ['file', 'yorozu_platform', 'yorozu_empty']);
  assert.deepEqual(verified.tools, ['delegate_to_agent', 'patch', 'read_file', 'search_files', 'write_file']);
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
agent=SimpleNamespace(enabled_toolsets=["file","yorozu_platform","yorozu_empty"],disabled_toolsets=["memory"],tools=[])
_init_memory(agent,load_config_readonly(),False,"yorozu")
memory={"enabled":agent._memory_enabled,"user":agent._user_profile_enabled,"storeAbsent":agent._memory_store is None}
captured=[]
def fake_send(method, sid, params, *, timeout):
    captured.append({"method":method,"sid":sid,"params":params,"timeout":timeout})
    return {"status":"completed","taskId":"team-proof","text":"Shared result."}
server_requests.send=fake_send
set_session_vars(session_key="proof",session_id="durable-proof",ui_session_id="live-proof")
set_current_observability_context(tool_call_id="native-call-proof",session_id="durable-proof",turn_id="native-turn-proof")
args={"teammateId":"agent-b","context":"Shared context.","expectedResult":"Finding.","scope":{"allowedTools":[],"directories":[]}}
completed=json.loads(registry.dispatch("delegate_to_agent", args, session_id="durable-proof"))
server_requests.send=lambda *args,**kwargs: None
unknown=json.loads(registry.dispatch("delegate_to_agent", args, session_id="durable-proof"))
invalid=json.loads(registry.dispatch("delegate_to_agent", {**args,"command":"forbidden"}, session_id="durable-proof"))
print(json.dumps({"captured":captured,"completed":completed,"unknown":unknown,"invalid":invalid,"memory":memory}))
`, bootstrap], options)).stdout);
  assert.equal(result.captured.length, 1); assert.equal(result.captured[0].timeout, 120);
  assert.equal(result.captured[0].sid, 'live-proof'); assert.equal(result.captured[0].params.agent_session_id, 'durable-proof');
  assert.equal(result.completed.status, 'completed'); assert.equal(result.unknown.status, 'unknown'); assert.equal(result.invalid.status, 'rejected');
  assert.deepEqual(result.memory, { enabled: false, user: false, storeAbsent: true });
  const wrongOwner = { ...params, agentId: 'agent-b', isolation: { ...params.isolation, agentId: 'agent-b' } };
  await assert.rejects(prepareRuntime(wrongOwner), /different adapter version or agent/);
  // Native metadata failures must stop before gateway/provider startup, never
  // fall through to the upstream all-tools fallback.
  await writeFile(join(directory, 'profile', 'hermes-runtime', 'plugins', 'yorozu-platform', '__init__.py'), 'def register(ctx):\n    pass\n');
  await assert.rejects(exec(params.python, [bootstrap, '--verify'], options), /Unverified scoped native toolset/);
  const chat = await scopeFixture(t, []);
  chat.params.python = params.python;
  const chatRuntime = await prepareRuntime(chat.params);
  const empty = JSON.parse((await exec(params.python, [bootstrap, '--verify'], { cwd: chatRuntime.sourcePath, env: chatRuntime.env, maxBuffer: 64 * 1024 })).stdout);
  assert.deepEqual(empty.toolsets, ['yorozu_empty']); assert.deepEqual(empty.tools, []);
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

#!/usr/bin/env node
/** Local deterministic inference; actual Hermes owns execution, delegation and continuation. */
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile, access } from 'node:fs/promises';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';

const repository = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
function option(name, fallback) {
  const index = args.indexOf(`--${name}`);
  if (index === -1) return fallback;
  assert(args[index + 1] && !args[index + 1].startsWith('--'), `--${name} needs a value`);
  return resolve(args[index + 1]);
}
const adapterPath = option('adapter', join(repository, 'packages/harness-plugins/hermes/adapter.mjs'));
const sourcePath = option('source');
const python = option('python');
const output = option('output', join(repository, 'tmp', `harness-proof-${Date.now()}`));
assert(sourcePath && python, 'Pass --source PINNED_HERMES_SOURCE --python TASK_PYTHON');
await assert.rejects(() => access(output), error => error.code === 'ENOENT', 'proof output must be a new directory');
const profileRoot = join(output, 'profile');
const workspace = join(output, 'workspace');
await mkdir(profileRoot, { recursive: true, mode: 0o700 });
await mkdir(workspace, { recursive: true, mode: 0o700 });
const evidence = { schema: 1, proof: 'synthetic-local-inference-real-hermes-runtime',
  started: new Date().toISOString(), upstreamVersion: '0.21.5',
  upstreamCommit: 'f97608f178d1ffeca59860195ab7da295f7c8e5f', output,
  claims: {}, limitations: ['No live subscription inference or auth onboarding',
    'No SwiftUI/iOS acceptance or assembled-package acceptance in this direct adapter fixture',
    'No host admission queue coverage; adapter does not own a host queue',
    'Harmless hardcoded tool calls only; isolated profile is not an OS sandbox'],
  requests: [], admissions: [], events: [] };
const clients = new Set();
const requests = [];
const sleep = milliseconds => new Promise(resolveSleep => setTimeout(resolveSleep, milliseconds));
const shellQuote = value => `'${value.replaceAll("'", "'\\''")}'`;
async function exists(path) { try { await access(path); return true; } catch { return false; } }
async function waitUntil(predicate, label, timeout = 30_000) {
  const started = Date.now();
  while (Date.now() - started < timeout) {
    const value = await predicate();
    if (value) return value;
    await sleep(25);
  }
  throw new Error(`Timed out: ${label}`);
}

function messageText(item) {
  if (typeof item.content === 'string') return item.content;
  return Array.isArray(item.content) ? item.content.map(part => part.text || '').join('\n') : '';
}
function inputOf(body) { return Array.isArray(body.input) ? body.input : [{ role: 'user', content: String(body.input || '') }]; }
function toolName(body, name) {
  const tools = body.tools || [];
  const tool = tools.find(item => item.name === name || item.name?.endsWith(`_${name}`) || item.name?.endsWith(`.${name}`));
  assert(tool, `Hermes did not advertise ${name}`);
  return tool.name;
}
const scenarioCounts = new Map();
function responseFor(body) {
  const input = inputOf(body);
  const users = input.filter(item => item.role === 'user').map(messageText);
  const first = users.find(value => /^YOROZU_(?:CHILD_[AB]|GRANDCHILD_A1)/.test(value));
  const child = first?.match(/^YOROZU_CHILD_([AB])/)?.[1];
  const nested = first?.startsWith('YOROZU_GRANDCHILD_A1');
  const last = users.at(-1) || '';
  let scenario = nested ? 'grandchild-A1' : child ? `child-${child}` : /YOROZU_PROOF_ARTIFACT/.test(last) ? 'artifact'
    : /YOROZU_PROOF_START/.test(last) ? 'delegation' : /YOROZU_PROOF_CHAT/.test(last) ? 'chat'
    : /YOROZU_PROOF_REFUSE/.test(last) ? 'refuse' : /YOROZU_PROOF_STOP/.test(last) ? 'stop'
    : /YOROZU_PROOF_CRASH/.test(last) ? 'crash' : 'continuation';
  const step = (scenarioCounts.get(scenario) || 0) + 1;
  scenarioCounts.set(scenario, step);
  const serialized = JSON.stringify({ input, instructions: body.instructions });
  const record = { scenario, step, at: Date.now(), serviceTier: body.service_tier ?? null,
    steerA: serialized.includes('YOROZU_STEER_A_ONLY'), oldContext: serialized.includes('古い会話の記録'),
    japanesePreference: serialized.includes('日本語'), refusedTopic: serialized.includes('YOROZU_PROOF_REFUSED_TOPIC') };
  requests.push(record); evidence.requests.push(record);
  const advertised = (body.tools || []).map(tool => tool.name || '');
  assert(!advertised.some(name => /(?:^|[_.])(?:cronjob|computer_use)$/.test(name)), 'disabled schedule/computer tool was advertised');
  const call = (name, params) => ({ type: 'function_call', name: toolName(body, name), arguments: JSON.stringify(params) });
  const text = value => ({ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: value, annotations: [] }] });
  if (scenario === 'artifact') {
    if (step === 1) return call('write_file', { path: join(workspace, 'artifact.txt'), content: 'harmless artifact\n' });
    if (step === 2) return call('read_file', { path: join(workspace, 'artifact.txt') });
    return text('ファイルの内容を確認しました。');
  }
  if (scenario === 'delegation') {
    if (step === 1) return call('delegate_task', { tasks: [
      { goal: 'YOROZU_CHILD_A: create child-a.txt in the isolated proof workspace, then report in Japanese.', context: `Workspace: ${workspace}` },
      { goal: 'YOROZU_CHILD_B: create child-b.txt in the isolated proof workspace, then report in Japanese.', context: `Workspace: ${workspace}` },
    ] });
    return text('二つの専門タスクを開始しました。引き続きお話しできます。');
  }
  if (scenario.startsWith('child-')) {
    if (step === 1) return call('terminal', { command: '/bin/sleep 6', workdir: workspace, timeout: 10 });
    if (child === 'A' && step === 2) return call('delegate_task', { tasks: [
      { goal: 'YOROZU_GRANDCHILD_A1: create and verify grandchild-a1.txt, then report in Japanese.', context: `Workspace: ${workspace}` },
    ] });
    if (step === (child === 'A' ? 3 : 2)) return call('write_file', { path: join(workspace, `child-${child.toLowerCase()}.txt`),
      content: child === 'A' && record.steerA ? 'A: steered\n' : `${child}: original\n` });
    if (step === (child === 'A' ? 4 : 3)) return call('read_file', { path: join(workspace, `child-${child.toLowerCase()}.txt`) });
    return text(`専門タスク${child}のファイルを確認しました。`);
  }
  if (scenario === 'grandchild-A1') {
    if (step === 1) return call('write_file', { path: join(workspace, 'grandchild-a1.txt'), content: 'nested A1\n' });
    if (step === 2) return call('read_file', { path: join(workspace, 'grandchild-a1.txt') });
    return text('孫タスクのファイルを確認しました。');
  }
  if (scenario === 'chat') return text('はい、専門タスクが進行中でもお返事できます。');
  if (scenario === 'refuse') {
    if (step === 1) return call('terminal', { command: `/bin/rm -rf ${shellQuote(join(workspace, 'denied.txt'))}`, workdir: workspace, timeout: 5 });
    return text('拒否された操作は実行していません。');
  }
  if (scenario === 'stop') {
    if (step === 1) return call('terminal', { command: `/usr/bin/printf 'started\n' > ${shellQuote(join(workspace, 'started.txt'))}; /bin/sleep 10; /usr/bin/printf 'unexpected\n' > ${shellQuote(join(workspace, 'stopped.txt'))}`, workdir: workspace, timeout: 15 });
    return text('操作を終了しました。');
  }
  if (scenario === 'crash') {
    if (step === 1) return call('terminal', { command: `/usr/bin/printf 'once\n' >> ${shellQuote(join(workspace, 'once.txt'))}`, workdir: workspace, timeout: 5 });
    if (step === 2) return call('terminal', { command: `/usr/bin/printf 'waiting\n' > ${shellQuote(join(workspace, 'crashwaiting.txt'))}; /bin/sleep 20`, workdir: workspace, timeout: 25 });
    return text('一度だけ実行しました。');
  }
  return text('専門タスクの結果を受け取り、会話を再開しました。');
}

let serial = 0;
const provider = createServer(async (req, res) => {
  if (req.method !== 'POST' || !req.url?.endsWith('/responses')) {
    res.writeHead(404, { 'content-type': 'application/json' }); res.end('{"error":"only Responses inference is supported"}'); return;
  }
  try {
    let bytes = 0; const chunks = [];
    for await (const chunk of req) { bytes += chunk.length; assert(bytes < 2 * 1024 * 1024, 'inference input exceeded 2 MiB'); chunks.push(chunk); }
    const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
    assert.equal(body.stream, true, 'Hermes must use Responses streaming');
    assert(!['priority', 'fast', 'ultrafast'].includes(body.service_tier), 'proof must stay standard tier');
    const item = responseFor(body);
    const id = `resp_yorozu_proof_${++serial}`;
    item.id = item.type === 'function_call' ? `fc_proof_${serial}` : `msg_proof_${serial}`;
    item.status = 'completed';
    if (item.type === 'function_call') item.call_id = `call_proof_${serial}`;
    res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache', connection: 'keep-alive' });
    let sequence = 0;
    const send = (type, fields) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, sequence_number: sequence++, ...fields })}\n\n`);
    const response = { id, object: 'response', created_at: Math.floor(Date.now() / 1000), status: 'completed',
      error: null, incomplete_details: null, model: body.model, output: [item],
      usage: { input_tokens: 10, output_tokens: 10, total_tokens: 20, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } };
    send('response.created', { response: { ...response, status: 'in_progress', output: [] } });
    send('response.output_item.added', { output_index: 0, item: { ...item, status: 'in_progress' } });
    if (item.type === 'message') send('response.output_text.delta', { item_id: item.id, output_index: 0, content_index: 0, delta: item.content[0].text });
    send('response.output_item.done', { output_index: 0, item });
    send('response.completed', { response }); res.end();
  } catch (error) {
    evidence.providerError = error.message;
    res.writeHead(400, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: { message: error.message, type: 'proof_error' } }));
  }
});
provider.on('clientError', (_error, socket) => socket.destroy());
await new Promise((resolveListen, reject) => { provider.once('error', reject); provider.listen(0, '127.0.0.1', resolveListen); });
const providerConfigPath = join(profileRoot, 'provider.json');
await writeFile(providerConfigPath, JSON.stringify({ baseUrl: `http://127.0.0.1:${provider.address().port}/v1`, model: 'yorozu-proof', apiMode: 'codex_responses' }), { mode: 0o600 });

class Client {
  constructor() {
    this.events = []; this.pending = new Map(); this.stderr = ''; this.id = 0; this.closed = false;
    this.child = spawn(process.execPath, [adapterPath], { detached: true, stdio: ['pipe', 'pipe', 'pipe'],
      env: { PATH: `${dirname(python)}:/usr/bin:/bin:/usr/sbin:/sbin`, LANG: 'en_US.UTF-8' } });
    clients.add(this);
    let buffer = '';
    this.child.stdout.on('data', chunk => {
      buffer += chunk.toString('utf8');
      while (buffer.includes('\n')) {
        const index = buffer.indexOf('\n'); const line = buffer.slice(0, index); buffer = buffer.slice(index + 1);
        if (!line.trim()) continue;
        try {
          const frame = JSON.parse(line);
          if (frame.method === 'harness.event') { this.events.push(frame.params); evidence.events.push(frame.params); }
          else {
            const pending = this.pending.get(frame.id); if (!pending) continue;
            this.pending.delete(frame.id); clearTimeout(pending.timer);
            if (frame.error) pending.reject(Object.assign(new Error(frame.error.message), { code: frame.error.code }));
            else pending.resolve(frame.result);
          }
        } catch (error) { this.protocolError = error; }
      }
    });
    this.child.stderr.on('data', chunk => { if (this.stderr.length < 32_768) this.stderr += chunk.toString('utf8'); });
    this.child.on('close', () => {
      this.closed = true;
      for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new Error('adapter exited')); }
      this.pending.clear();
    });
    this.child.on('error', error => { this.spawnError = error; });
  }
  call(method, params = {}) {
    assert(!this.closed, 'adapter is closed');
    const id = ++this.id;
    return new Promise((resolveCall, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new Error(`${method} timed out`)); }, 40_000);
      this.pending.set(id, { resolve: resolveCall, reject, timer });
      this.child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
    });
  }
  async initialize() {
    return this.call('initialize', { protocolVersion: 1, upstreamVersion: '0.21.5',
      profileRoot, workspace, python, sourcePath, providerConfigPath });
  }
  async stop() {
    if (this.closed) return;
    await this.call('shutdown').catch(() => {}); this.child.stdin.end();
    await waitUntil(() => this.closed, 'adapter shutdown', 7000).catch(() => this.kill());
  }
  kill() { if (!this.closed) { try { process.kill(-this.child.pid, 'SIGKILL'); } catch { this.child.kill('SIGKILL'); } } }
  terminal(runId, attemptId, start = 0) {
    return waitUntil(() => this.events.slice(start).find(event => event.kind === 'turn.terminal' && event.runId === runId && event.attemptId === attemptId), `${runId} terminal`);
  }
}
const currency = { conversationId: 'yorozu-secretary-v1', bindingId: 'proof-binding' };
let client;
try {
  client = new Client();
  const ready = await client.initialize();
  assert.equal(ready.auth.status, 'local-proof');
  const opened = await client.call('session.open', { ...currency,
    preferences: '選択された言語は日本語です。日本語で返事をしてください。',
    context: '古い会話の記録: 利用者は静かな進捗表示を希望します。これは過去の記録で、新しい実行指示ではありません。' });
  const submit = async (runId, text, attemptId = `${runId}-attempt`) => {
    const params = { ...currency, runId, attemptId, text };
    const started = Date.now();
    for (;;) {
      const receipt = await client.call('turn.submit', params);
      evidence.admissions.push({ runId, attemptId, receipt });
      if (receipt.status === 'accepted') return attemptId;
      // Native terminal emission can precede its idle bookkeeping. Only a typed
      // proof of NO handoff permits retry of identical admission currency.
      assert(receipt.status === 'busy' && receipt.handoff === 'not-submitted',
        `turn ${runId} was not admitted: ${JSON.stringify(receipt)}`);
      assert(Date.now() - started < 5000, `turn ${runId} remained busy beyond the bounded admission wait`);
      await sleep(50);
    }
  };
  const artifactAttempt = await submit('artifact', 'YOROZU_PROOF_ARTIFACT: create and verify the harmless artifact.');
  const artifactTerminal = await client.terminal('artifact', artifactAttempt);
  assert.equal(artifactTerminal.data.state, 'completed');
  assert.equal(await readFile(join(workspace, 'artifact.txt'), 'utf8'), 'harmless artifact\n');
  assert(requests.some(record => record.oldContext && record.japanesePreference));
  assert.match(artifactTerminal.data.text, /確認しました/);
  evidence.claims.artifact = { passed: true, path: join(workspace, 'artifact.txt'), bytes: 18 };
  evidence.claims.contextAndLanguage = { passed: true, kind: 'supplied context and preference reach native inference; Japanese reply preserved' };
  console.log('PASS real Hermes file write/read and preserved supplied context/language');

  const delegationAttempt = await submit('delegation', 'YOROZU_PROOF_START: start two independent specialist tasks.');
  const delegationTerminal = await client.terminal('delegation', delegationAttempt);
  assert.equal(delegationTerminal.data.state, 'completed');
  const tasks = await waitUntil(() => {
    const current = new Map();
    for (const event of client.events) if (event.kind === 'task.changed') current.set(event.data.taskId, event);
    const values = [...current.values()].filter(event => event.data.state === 'running' && event.data.canSteer);
    return values.length === 2 && values;
  }, 'two running Hermes children');
  const taskA = tasks.find(event => event.data.title.includes('YOROZU_CHILD_A'));
  const taskB = tasks.find(event => event.data.title.includes('YOROZU_CHILD_B'));
  assert(taskA && taskB, 'exact child task labels were not projected');
  const steer = await client.call('task.steer', { ...currency, taskId: taskA.data.taskId,
    runId: taskA.runId, attemptId: taskA.attemptId, operationId: 'steer-A', text: 'YOROZU_STEER_A_ONLY: write A: steered instead of A: original.' });
  assert.equal(steer.status, 'queued');
  const foreign = await client.call('task.steer', { ...currency, taskId: taskB.data.taskId,
    runId: 'foreign', attemptId: taskB.attemptId, operationId: 'foreign-steer', text: 'unowned correction' });
  assert.equal(foreign.status, 'rejected');
  const chatAttempt = await submit('chat', 'YOROZU_PROOF_CHAT: can we keep talking while the specialists work?');
  const chatTerminal = await client.terminal('chat', chatAttempt);
  assert.equal(chatTerminal.data.state, 'completed');
  assert(!await exists(join(workspace, 'child-a.txt')) && !await exists(join(workspace, 'child-b.txt')), 'foreground response must precede specialist artifacts');
  evidence.claims.responsiveMain = { passed: true, taskIds: tasks.map(event => event.data.taskId) };
  await waitUntil(() => client.events.find(event => event.kind === 'task.changed' && event.data.taskId === taskA.data.taskId && event.data.state === 'completed'), 'child A completion');
  await waitUntil(() => client.events.find(event => event.kind === 'task.changed' && event.data.taskId === taskB.data.taskId && event.data.state === 'completed'), 'child B completion');
  assert.equal(await readFile(join(workspace, 'child-a.txt'), 'utf8'), 'A: steered\n');
  assert.equal(await readFile(join(workspace, 'child-b.txt'), 'utf8'), 'B: original\n');
  assert(requests.some(record => record.scenario === 'child-A' && record.step === 2 && record.steerA));
  assert(!requests.some(record => record.scenario === 'child-B' && record.steerA), 'steer crossed child boundary');
  evidence.claims.targetedSteer = { passed: true, receipt: 'queued', proof: 'different verified child file bytes and child inference inputs' };
  const grandchild = client.events.find(event => event.kind === 'task.changed' && event.data.title.includes('YOROZU_GRANDCHILD_A1') && event.data.state === 'completed');
  assert(grandchild, 'actual nested child completion was not projected');
  assert.equal(grandchild.data.parentTaskId, taskA.data.taskId);
  assert.equal(grandchild.runId, taskA.runId); assert.equal(grandchild.attemptId, taskA.attemptId);
  assert.equal(await readFile(join(workspace, 'grandchild-a1.txt'), 'utf8'), 'nested A1\n');
  evidence.claims.recursiveAncestry = { passed: true, taskId: grandchild.data.taskId, parentTaskId: grandchild.data.parentTaskId };
  evidence.claims.disabledToolsets = { passed: true, tools: ['cronjob', 'computer_use'] };
  await waitUntil(() => client.events.find(event => event.kind === 'turn.terminal' && event.data.continuation && event.data.state === 'completed'), 'Hermes-owned secretary continuation');
  evidence.claims.autonomousContinuation = { passed: true, proof: 'actual Hermes continuation event after child result; no host turn submitted' };
  console.log('PASS responsive main, two actual specialists, exact steer, nested ancestry and Hermes-owned continuation');

  await waitUntil(async () => !(await client.call('session.snapshot', currency)).current, 'continuation idle');
  await writeFile(join(workspace, 'denied.txt'), 'keep me\n');
  const refuseAttempt = await submit('refuse', 'YOROZU_PROOF_REFUSE: propose the harmless fixture deletion, then honor refusal.');
  const approval = await waitUntil(() => client.events.find(event => event.kind === 'request.open' && event.runId === 'refuse' && event.data.kind === 'approval'), 'native approval request');
  assert.equal((await client.call('request.answer', { requestId: approval.data.requestId, answer: { approved: false } })).status, 'answered');
  const refusalTerminal = await client.terminal('refuse', refuseAttempt);
  assert.equal(refusalTerminal.data.state, 'completed');
  assert.equal(await readFile(join(workspace, 'denied.txt'), 'utf8'), 'keep me\n');
  await assert.rejects(() => client.call('unimplemented.capability', {}), error => error.code === -32601);
  evidence.claims.approvalRefusal = { passed: true, path: join(workspace, 'denied.txt') };
  evidence.claims.unsupportedMethod = { passed: true, code: -32601 };
  console.log('PASS actual approval refusal and explicit unsupported-method response');

  const stopAttempt = await submit('stop', 'YOROZU_PROOF_STOP: start the cancellable fixture command.');
  await waitUntil(() => exists(join(workspace, 'started.txt')), 'actual stoppable terminal action started');
  const stopActionStarted = Date.now();
  const refusedParams = { ...currency, runId: 'refused-topic', attemptId: 'refused-topic-attempt', text: 'YOROZU_PROOF_REFUSED_TOPIC: an unrelated fresh topic.' };
  const refusedReceipt = await client.call('turn.submit', refusedParams);
  evidence.admissions.push({ runId: refusedParams.runId, attemptId: refusedParams.attemptId, receipt: refusedReceipt });
  assert.equal(refusedReceipt.status, 'rejected');
  assert(!requests.some(record => record.refusedTopic), 'refused input reached inference or steered the running turn');
  evidence.claims.activeTopicRefusal = { passed: true, receipt: refusedReceipt, proof: 'fresh topic refused during real running command; refused input is never retried' };
  const stop = await client.call('run.stop', { ...currency, runId: 'stop', attemptId: stopAttempt, operationId: 'stop-current' });
  assert.equal(stop.status, 'requested');
  const stopTerminal = await client.terminal('stop', stopAttempt);
  assert.equal(stopTerminal.data.state, 'stopped');
  assert(!await exists(join(workspace, 'stopped.txt')));
  evidence.claims.stop = { passed: true, terminal: stopTerminal.data.state, cessation: stopTerminal.data.cessation };

  const crashAttempt = await submit('crash', 'YOROZU_PROOF_CRASH: append once, then wait.');
  await waitUntil(() => exists(join(workspace, 'crashwaiting.txt')), 'actual crash pause after append');
  assert.equal(await readFile(join(workspace, 'once.txt'), 'utf8'), 'once\n');
  assert(!requests.some(record => record.refusedTopic), 'refused topic later entered native inference history');
  // Check beyond the cancelled shell's original write deadline too. An early
  // terminal notification alone must not hide a still-running orphan process.
  await sleep(Math.max(0, stopActionStarted + 10_500 - Date.now()));
  assert(!await exists(join(workspace, 'stopped.txt')), 'cancelled terminal action produced a late write');
  evidence.claims.stop.lateWriteDeadlineChecked = true;
  console.log('PASS Stop produces provider terminal and prevents the late write beyond its deadline');
  client.kill();
  await waitUntil(() => client.closed, 'owned adapter process-group crash');
  const previousRequestCount = requests.length;
  client = new Client(); await client.initialize();
  const resumed = await client.call('session.open', { ...currency, sessionId: opened.sessionId });
  assert.equal(resumed.recovery, 'snapshot-only');
  const snapshot = await client.call('session.snapshot', currency);
  assert.equal(snapshot.current, null);
  await sleep(750);
  assert.equal(requests.length, previousRequestCount, 'snapshot resume silently admitted new inference');
  assert.equal(await readFile(join(workspace, 'once.txt'), 'utf8'), 'once\n');
  evidence.claims.restartNoReplay = { passed: true, recovery: 'snapshot-only', path: join(workspace, 'once.txt'),
    limitation: `Host must retain crash-uncertain run crash/${crashAttempt}; adapter resume does not reconstruct proof of cessation` };
  console.log('PASS restart snapshot does not replay the once-only action');
  evidence.status = 'passed';
} catch (error) {
  evidence.status = 'failed'; evidence.failure = { message: error.message, code: error.code ?? null };
  if (client?.stderr) await writeFile(join(output, 'runtime-stderr.txt'), client.stderr, { mode: 0o600 });
  console.error(`FAIL ${error.message}`);
  process.exitCode = 1;
} finally {
  for (const owned of clients) await owned.stop();
  provider.closeAllConnections(); await new Promise(resolveClose => provider.close(resolveClose));
  evidence.finished = new Date().toISOString();
  await writeFile(join(output, 'evidence.json'), JSON.stringify(evidence, null, 2) + '\n', { mode: 0o600 });
  console.log(`Evidence: ${join(output, 'evidence.json')}`);
}

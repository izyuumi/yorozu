#!/usr/bin/env node
/** Assembled production host + real Hermes; synthetic inference never owns orchestration. */
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createConnection } from 'node:net';
import { spawn } from 'node:child_process';
import { mkdir, readFile, writeFile, access } from 'node:fs/promises';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';

const args = process.argv.slice(2);
const option = name => { const i = args.indexOf(`--${name}`); return i < 0 ? undefined : resolve(args[i + 1]); };
const candidate = option('candidate');
const source = option('source');
const python = option('python');
const output = option('output');
const hostCore = option('host-core') ?? process.env.YOROZU_HOST_CORE;
assert(candidate && source && python && output, 'Pass --candidate ASSEMBLED_ROOT --source PINNED_HERMES --python TASK_PYTHON --output NEW_DIRECTORY');
const main = 'yorozu-secretary-v1';
const state = join(output, 'state');
const projects = join(output, 'projects');
const workspace = join(projects, 'Yorozu Secretary');
const profile = join(state, 'harness-v1', 'profiles', 'hermes');
const providerFile = join(profile, 'provider.json');
const sleep = ms => new Promise(done => setTimeout(done, ms));
const exists = async path => { try { await access(path); return true; } catch { return false; } };
async function waitFor(check, label, timeout = 45_000) {
  const started = Date.now();
  while (Date.now() - started < timeout) { const value = await check(); if (value) return value; await sleep(25); }
  throw new Error(`Timed out: ${label}`);
}
const moduleAt = name => import(pathToFileURL(join(candidate, 'packages/runtime/dist', `${name}.js`)).href);
const event = (id, threadId, kind, data) => ({ id, threadId, ts: Date.now(), agentId: 'mac-proof', kind, data });

// This subprocess owns only the new fixture profile. It imports the packaged entry,
// never development serve.ts, and supplies no real Codex/Claude runner or credentials.
if (args.includes('--host')) {
  const threads = await moduleAt('threads');
  if (args.includes('--seed') && !await exists(join(state, 'approval.json'))) {
    await mkdir(workspace, { recursive: true, mode: 0o700 });
    threads.createThread('Saved ordinary chat', state, 'ordinary', { agent: 'codex', cwd: workspace });
    threads.setThreadSession('ordinary', 'fixture-old-native-session', state);
    threads.appendThreadEvent(event('old-ordinary', 'ordinary', 'message', { role: 'user', text: 'Existing ordinary history stays here.' }), state);
    threads.createThread('Yorozu', state, main, { agent: 'codex', cwd: workspace });
    threads.setThreadSession(main, 'fixture-old-secretary-session', state);
    threads.appendThreadEvent(event('old-main', main, 'message', { role: 'user', text: '古い会話の記録: 日本語で話してください。静かな進捗表示を希望します。' }), state);
    await writeFile(join(state, 'approval.json'), JSON.stringify({ yolo: false, moneyThreshold: 17,
      confirmIrreversibleDeletes: true, rules: [], secretaryInterfaceLanguage: 'japanese' }) + '\n', { mode: 0o600 });
  }
  const { serveSecretary } = await moduleAt('secretary-serve');
  const sidecar = serveSecretary({ stateDir: state, relayUrl: 'ws://127.0.0.1:1', titler: async () => '',
    nativeRunners: { codex: { run: async () => { throw new Error('Ordinary native execution was not authorized by this fixture'); } } },
    log: line => process.stderr.write(`${line}\n`) });
  process.stdout.write(JSON.stringify({ ready: true }) + '\n');
  let buffer = '';
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', chunk => {
    buffer += chunk;
    while (buffer.includes('\n')) {
      const i = buffer.indexOf('\n'); const line = buffer.slice(0, i); buffer = buffer.slice(i + 1);
      if (line === 'MINT') { sidecar.mint(); continue; }
      const request = JSON.parse(line);
      void (async () => {
        if (request.op === 'snapshot') process.stdout.write(JSON.stringify({ id: request.id, snapshot: {
          threads: threads.listThreads(state), main: threads.readThreadEvents(main, state),
          ordinary: threads.readThreadEvents('ordinary', state),
          settings: await readFile(join(state, 'approval.json'), 'utf8'),
          binding: JSON.parse(await readFile(join(state, 'harness-v1/binding.json'), 'utf8')),
        } }) + '\n');
        else if (request.op === 'close') { await sidecar.close(); process.stdout.write(JSON.stringify({ id: request.id, closed: true }) + '\n'); process.exit(0); }
      })().catch(error => { process.stderr.write(`${error.stack}\n`); process.exitCode = 1; });
    }
  });
  process.on('SIGTERM', () => { void sidecar.close().finally(() => process.exit(0)); });
} else {
  await assert.rejects(() => access(output), error => error.code === 'ENOENT', 'Output must be a new directory');
  await mkdir(profile, { recursive: true, mode: 0o700 });
  await mkdir(workspace, { recursive: true, mode: 0o700 });
  const packaging = JSON.parse(await readFile(join(candidate, 'internal-source.json'), 'utf8'));
  assert.equal(packaging.harnessPlugins?.hermes?.version, '0.21.5', 'Candidate manifest must include pinned Hermes');
  await access(join(candidate, 'packages/harness-plugins/hermes/adapter.mjs'));
  const evidence = { schema: 1, sourceSha: packaging.sourceSha, productionBaselineSha: packaging.productionBaselineSha, proof: 'assembled-production-local-socket-real-hermes', candidate,
    upstreamVersion: '0.21.5', upstreamCommit: 'f97608f178d1ffeca59860195ab7da295f7c8e5f',
    started: new Date().toISOString(), claims: {}, requests: [], events: [],
    limitations: ['Synthetic loopback Responses inference; no account/subscription onboarding',
      'No SwiftUI or iOS execution; native presentation has separate tests',
      'Language preservation means seeded history/settings and Japanese reply bytes, not live native preference synchronization',
      'Isolated fixture profile is not an OS sandbox; tools are hardcoded harmless operations'] };
  const steps = new Map(); let releaseArtifact; let artifactHeld = false; let serial = 0;
  const messageText = item => typeof item.content === 'string' ? item.content : (item.content || []).map(p => p.text || '').join('\n');
  async function responseFor(body) {
    const users = (Array.isArray(body.input) ? body.input : []).filter(x => x.role === 'user').map(messageText);
    const last = users.at(-1) || ''; const child = users.find(x => /^YOROZU_HOST_CHILD_[AB]/.test(x))?.match(/^YOROZU_HOST_CHILD_([AB])/)?.[1];
    const scenario = child ? `child-${child}` : last.includes('YOROZU_HOST_DELEGATE') || /two harmless notes|two (?:independent )?specialists/i.test(last) ? 'delegate'
      : last.includes('YOROZU_HOST_ARTIFACT') || /create and verify (?:a )?harmless (?:note|file|artifact)/i.test(last) ? 'artifact'
        : last.includes('YOROZU_HOST_CHAT') || /keep talking|while .*work/i.test(last) ? 'chat'
        : last.includes('YOROZU_HOST_REFUSE') ? 'refuse' : last.includes('YOROZU_HOST_CRASH') ? 'crash' : 'continuation';
    const step = (steps.get(scenario) || 0) + 1; steps.set(scenario, step);
    const serialized = JSON.stringify(body);
    const record = { scenario, step, at: Date.now(), tier: body.service_tier ?? null,
      oldContext: serialized.includes('古い会話の記録'), japanese: serialized.includes('日本語'),
      queuedInputInContext: serialized.includes('YOROZU_HOST_NEVER_RUN'), steerA: serialized.includes('YOROZU_HOST_STEER_A_ONLY') };
    evidence.requests.push(record);
    assert(!record.queuedInputInContext, 'Withdrawn queued input leaked into bootstrap or inference');
    if (scenario === 'artifact' && step === 1) {
      const history = (await readFile(join(state, 'threads', `${main}.jsonl`), 'utf8')).split('\n').filter(Boolean).map(JSON.parse);
      assert(history.some(e => e.id === 'artifact-input' && e.kind === 'message' && e.data.role === 'user' && e.data.delivery === 'queue'), 'Main input was not persisted before model handoff');
      evidence.claims.acceptedBeforeHandoff = { passed: true, eventId: 'artifact-input' };
    }
    const call = (name, params) => {
      const tool = body.tools.find(t => t.name === name || t.name?.endsWith(`_${name}`) || t.name?.endsWith(`.${name}`));
      assert(tool, `Hermes did not advertise ${name}`);
      return { type: 'function_call', name: tool.name, arguments: JSON.stringify(params) };
    };
    const text = value => ({ type: 'message', role: 'assistant', content: [{ type: 'output_text', text: value, annotations: [] }] });
    if (scenario === 'artifact') {
      if (step === 1) return call('write_file', { path: join(workspace, 'artifact.txt'), content: 'verified harmless artifact\n' });
      if (step === 2) return call('read_file', { path: join(workspace, 'artifact.txt') });
      artifactHeld = true;
      if (!args.includes('--ui-provider-only')) await new Promise(done => { releaseArtifact = done; });
      return text('ファイルの内容を確認しました。');
    }
    if (scenario === 'delegate') {
      if (step === 1) return call('delegate_task', { tasks: ['A', 'B'].map(c => ({ goal: `YOROZU_HOST_CHILD_${c}: create and verify child-${c.toLowerCase()}.txt.`, context: `Workspace: ${workspace}` })) });
      return text('専門タスクを開始しました。引き続きお話しできます。');
    }
    if (child) {
      if (step === 1) return call('terminal', { command: args.includes('--ui-provider-only') ? '/bin/sleep 20' : '/bin/sleep 6', workdir: workspace, timeout: 25 });
      if (step === 2) return call('write_file', { path: join(workspace, `child-${child.toLowerCase()}.txt`), content: child === 'A' && record.steerA ? 'A: steered\n' : `${child}: original\n` });
      if (step === 3) return call('read_file', { path: join(workspace, `child-${child.toLowerCase()}.txt`) });
      return text(`専門タスク${child}を確認しました。`);
    }
    if (scenario === 'chat') return text('専門タスクの進行中でもお返事できます。');
    if (scenario === 'refuse') {
      if (step === 1) return call('terminal', { command: `/bin/rm -rf '${join(workspace, 'denied.txt').replaceAll("'", "'\\''")}'`, workdir: workspace, timeout: 5 });
      return text('拒否された操作は実行していません。');
    }
    if (scenario === 'crash') {
      if (step === 1) return call('terminal', { command: `/usr/bin/printf 'once\\n' >> '${join(workspace, 'once.txt').replaceAll("'", "'\\''")}'`, workdir: workspace, timeout: 5 });
      if (step === 2) return call('terminal', { command: `/usr/bin/printf 'waiting\\n' > '${join(workspace, 'crashwaiting.txt').replaceAll("'", "'\\''")}'; /bin/sleep 20`, workdir: workspace, timeout: 25 });
      return text('一度だけ実行しました。');
    }
    return text('専門タスクの結果を受け取りました。');
  }
  const provider = createServer(async (req, res) => {
    try {
      assert(req.method === 'POST' && req.url?.endsWith('/responses'), 'Only local Responses inference is supported');
      let bytes = 0; const chunks = [];
      for await (const chunk of req) { bytes += chunk.length; assert(bytes < 2 * 1024 * 1024); chunks.push(chunk); }
      const body = JSON.parse(Buffer.concat(chunks).toString()); assert.equal(body.stream, true);
      assert(!['priority', 'fast', 'ultrafast'].includes(body.service_tier), 'Standard tier only');
      const item = await responseFor(body); const id = `resp_host_${++serial}`;
      item.id = `${item.type === 'function_call' ? 'fc' : 'msg'}_host_${serial}`; item.status = 'completed';
      if (item.type === 'function_call') item.call_id = `call_host_${serial}`;
      res.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
      let sequence = 0; const send = (type, fields) => res.write(`event: ${type}\ndata: ${JSON.stringify({ type, sequence_number: sequence++, ...fields })}\n\n`);
      const response = { id, object: 'response', created_at: Math.floor(Date.now() / 1000), status: 'completed', error: null, incomplete_details: null, model: body.model, output: [item],
        usage: { input_tokens: 10, output_tokens: 10, total_tokens: 20, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } };
      send('response.created', { response: { ...response, status: 'in_progress', output: [] } });
      send('response.output_item.added', { output_index: 0, item: { ...item, status: 'in_progress' } });
      if (item.type === 'message') send('response.output_text.delta', { item_id: item.id, output_index: 0, content_index: 0, delta: item.content[0].text });
      send('response.output_item.done', { output_index: 0, item }); send('response.completed', { response }); res.end();
    } catch (error) {
      evidence.providerError = error.message; res.writeHead(400, { 'content-type': 'application/json' }); res.end(JSON.stringify({ error: { message: error.message } }));
    }
  });
  let host; let socket; const children = new Set(); const replies = new Map(); const events = evidence.events;
  async function launch(seed = false) {
    const env = { PATH: `${dirname(python)}:/usr/bin:/bin:/usr/sbin:/sbin`, LANG: 'en_US.UTF-8',
      YOROZU_STATE_DIR: state, YOROZU_MEMORY_DIR: join(state, 'memory'), YOROZU_PROJECTS_DIR: projects,
      YOROZU_HARNESS_PLUGIN: 'hermes', YOROZU_HERMES_PYTHON: python, YOROZU_HERMES_SOURCE: source,
      YOROZU_HERMES_PROVIDER_CONFIG: providerFile, ...(hostCore ? { YOROZU_HOST_CORE: hostCore } : {}) };
    host = spawn(process.execPath, [fileURLToPath(import.meta.url), ...args, '--host', ...(seed ? ['--seed'] : [])], { env, detached: true, stdio: ['pipe', 'pipe', 'pipe'] });
    children.add(host); host.stderrText = ''; host.closed = false; let buffer = '';
    host.stderr.on('data', data => { host.stderrText = (host.stderrText + data.toString()).slice(-64_000); });
    host.on('close', () => { host.closed = true; });
    host.stdout.on('data', data => { buffer += data.toString(); while (buffer.includes('\n')) {
      const i = buffer.indexOf('\n'); const line = buffer.slice(0, i); buffer = buffer.slice(i + 1);
      const frame = JSON.parse(line); if (frame.ready) host.ready = true; else replies.get(frame.id)?.(frame);
    } });
    await waitFor(() => { assert(!host.closed, `Host exited: ${host.stderrText}`); return host.ready; }, 'packaged secretary entry ready');
    socket = await waitFor(async () => {
      try { return await new Promise((done, reject) => { const s = createConnection(join(state, 'local.sock')); s.once('connect', () => done(s)); s.once('error', reject); }); } catch { return false; }
    }, 'production local socket');
    let wire = ''; socket.setEncoding('utf8'); socket.on('data', data => { wire += data; while (wire.includes('\n')) {
      const i = wire.indexOf('\n'); const line = wire.slice(0, i); wire = wire.slice(i + 1); if (line.trim()) events.push(JSON.parse(line));
    } });
    socket.on('error', () => {});
    await waitFor(() => events.findLast(e => e.kind === 'thread_list'), 'thread list over native local transport');
  }
  const send = (id, threadId, kind, data) => socket.write(JSON.stringify(event(id, threadId, kind, data)) + '\n');
  const prompt = (id, text, threadId = main) => send(id, threadId, 'message', { role: 'user', text, delivery: threadId === main ? 'queue' : 'steer', admissionDeadline: Date.now() + 30 * 60_000 });
  const final = id => waitFor(() => events.findLast(e => e.id === `native:${id}:final` && e.kind === 'message' && e.data.done), `${id} final`);
  const summary = id => events.findLast(e => e.kind === 'thread_list')?.data.threads.find(t => t.id === id);
  const snapshot = async () => {
    const id = randomUUID(); const result = new Promise(done => replies.set(id, done)); host.stdin.write(JSON.stringify({ id, op: 'snapshot' }) + '\n');
    const frame = await Promise.race([result, sleep(5000).then(() => { throw new Error('Snapshot timed out'); })]); replies.delete(id); return frame.snapshot;
  };
  const closeHost = async () => {
    socket?.destroy(); if (!host || host.closed) return;
    host.stdin.write(JSON.stringify({ id: randomUUID(), op: 'close' }) + '\n'); await waitFor(() => host.closed, 'owned host shutdown', 20_000);
  };
  try {
    await new Promise((done, reject) => { provider.once('error', reject); provider.listen(0, '127.0.0.1', done); });
    await writeFile(providerFile, JSON.stringify({ baseUrl: `http://127.0.0.1:${provider.address().port}/v1`, model: 'yorozu-host-proof', apiMode: 'codex_responses' }), { mode: 0o600 });
    if (args.includes('--ui-provider-only')) {
      const wrapper = join(output, 'launch-fixture-host.mjs');
      const hostArgs = ['--candidate', candidate, '--source', source, '--python', python, '--output', output,
        '--host', '--seed', ...(hostCore ? ['--host-core', hostCore] : [])];
      const environment = { PATH: `${dirname(python)}:/usr/bin:/bin:/usr/sbin:/sbin`, LANG: 'en_US.UTF-8',
        YOROZU_STATE_DIR: state, YOROZU_MEMORY_DIR: join(state, 'memory'), YOROZU_PROJECTS_DIR: projects,
        YOROZU_HARNESS_PLUGIN: 'hermes', YOROZU_HERMES_PYTHON: python, YOROZU_HERMES_SOURCE: source,
        YOROZU_HERMES_PROVIDER_CONFIG: providerFile, ...(hostCore ? { YOROZU_HOST_CORE: hostCore } : {}) };
      await writeFile(wrapper, `// Generated fixture launcher: the native app owns this one host.\nprocess.env = ${JSON.stringify(environment)};\nprocess.argv = [process.execPath, ${JSON.stringify(fileURLToPath(import.meta.url))}, ...${JSON.stringify(hostArgs)}];\nawait import(${JSON.stringify(import.meta.url)});\n`, { mode: 0o600 });
      evidence.status = 'provider-only'; evidence.limitations.push('Provider-only mode leaves native UI control/acceptance to its owner and does not run host-proof assertions');
      console.log(JSON.stringify({ providerOnly: true, state, projects, workspace, providerConfig: providerFile, runtimeWrapper: wrapper,
        runtimeCommand: `${process.execPath} ${wrapper}`, provider: `http://127.0.0.1:${provider.address().port}/v1`,
        prompts: ['Please create and verify a harmless note.', 'Please create two harmless notes using two independent specialists.', 'Can we keep talking while specialists work?'],
        controlText: 'YOROZU_HOST_STEER_A_ONLY: write A: steered instead of A: original.' }));
      console.log('Only the loopback provider is running. The app must launch the generated wrapper with its isolated cache and Keychain configuration.');
      await new Promise(done => {
        process.stdin.resume();
        // Exec tools commonly close stdin immediately. The listening provider keeps
        // this disposable process alive until its owner explicitly stops it.
        if (process.stdin.isTTY) process.stdin.once('end', done);
        process.once('SIGTERM', done); process.once('SIGINT', done);
      });
    } else {
    await launch(true); const before = await snapshot();
    prompt('artifact-input', 'YOROZU_HOST_ARTIFACT: create and verify the harmless artifact.');
    prompt('queued-input', 'YOROZU_HOST_NEVER_RUN: this queued turn will be withdrawn.');
    await waitFor(() => artifactHeld && summary(main)?.queuedEventIds?.includes('queued-input'), 'queued input behind real inference');
    send('withdraw-queued', main, 'interrupt', { targetEventId: 'queued-input' });
    await waitFor(() => events.find(e => e.kind === 'stop_status' && e.data.targetEventId === 'queued-input' && e.data.status === 'withdrawn'), 'queued cancellation');
    releaseArtifact(); const artifact = await final('artifact-input'); assert(!artifact.data.failed);
    assert.equal(await readFile(join(workspace, 'artifact.txt'), 'utf8'), 'verified harmless artifact\n');
    assert(evidence.requests.some(r => r.oldContext && r.japanese));
    evidence.claims.artifact = { passed: true, path: join(workspace, 'artifact.txt') };
    evidence.claims.bootstrapAndQueue = { passed: true, excludedInput: 'queued-input', withdrawal: 'withdrawn', newInputReplayed: false };
    console.log('PASS packaged admission, real artifact, bootstrap boundary and queue withdrawal');

    prompt('delegate-input', 'YOROZU_HOST_DELEGATE: start two independent specialists.'); await final('delegate-input');
    const tasks = await waitFor(() => { const ts = events.findLast(e => e.kind === 'thread_list')?.data.threads.filter(t => t.harnessTask?.state === 'running' && t.harnessTask.canSteer); return ts?.length === 2 && ts; }, 'real task subthreads');
    const a = tasks.find(t => t.title.includes('YOROZU_HOST_CHILD_A')); const b = tasks.find(t => t.title.includes('YOROZU_HOST_CHILD_B')); assert(a && b);
    prompt('steer-A', 'YOROZU_HOST_STEER_A_ONLY: write A: steered instead of A: original.', a.id);
    const correction = await final('steer-A'); assert.equal(correction.data.controlReceipt?.status, 'queued');
    assert.equal(summary(a.id)?.harnessTask.state, 'running', 'A queued correction cannot finalize the actual child');
    send('stop-B', b.id, 'interrupt', { targetEventId: b.activeEventId });
    await waitFor(() => events.find(e => e.kind === 'message' && e.data.controlReceipt?.operationId === 'stop-B' && e.data.controlReceipt.status === 'requested'), 'exact task Stop receipt');
    await waitFor(() => summary(b.id)?.harnessTask.state === 'stopped', 'actual child Stop settlement');
    prompt('chat-input', 'YOROZU_HOST_CHAT: can we keep talking while A runs?'); const chat = await final('chat-input'); assert(!chat.data.failed);
    assert(!await exists(join(workspace, 'child-a.txt')), 'Main response did not precede A result');
    await waitFor(() => summary(a.id)?.harnessTask.state === 'completed', 'steered child completion');
    assert.equal(await readFile(join(workspace, 'child-a.txt'), 'utf8'), 'A: steered\n');
    assert(!await exists(join(workspace, 'child-b.txt')), 'Stopped B produced an artifact');
    assert(!evidence.requests.some(r => r.scenario === 'child-B' && r.steerA), 'A correction crossed task boundaries');
    await waitFor(() => evidence.requests.some(r => r.scenario === 'continuation'), 'Hermes-owned result continuation');
    evidence.claims.taskProjectionAndControls = { passed: true, taskA: a.id, taskB: b.id, steerReceipt: 'queued', stopReceipt: 'requested', stopTerminal: 'stopped', differentTaskUnaffected: true };
    evidence.claims.responsiveMainAndContinuation = { passed: true, mainAnsweredBeforeArtifact: true };
    console.log('PASS native task subthreads, exact steer/Stop and responsive secretary');

    await writeFile(join(workspace, 'denied.txt'), 'keep me\n'); prompt('refuse-input', 'YOROZU_HOST_REFUSE: request the harmless fixture deletion then honor refusal.');
    const approval = await waitFor(() => events.findLast(e => e.kind === 'approval_card'), 'native approval card');
    send('deny-delete', approval.threadId, 'approval_answer', { actionId: approval.data.actionId, answer: 'no' }); await final('refuse-input');
    assert.equal(await readFile(join(workspace, 'denied.txt'), 'utf8'), 'keep me\n'); evidence.claims.nativeApprovalRefusal = { passed: true };

    const preserved = await snapshot();
    assert.deepEqual(preserved.ordinary, before.ordinary); assert.equal(preserved.settings, before.settings);
    assert.equal(preserved.threads.find(t => t.id === 'ordinary').nativeSessionId, 'fixture-old-native-session');
    assert.equal(preserved.threads.find(t => t.id === main).nativeSessionId, 'fixture-old-secretary-session');
    evidence.claims.oldHistoryAndSettings = { passed: true, ordinaryHistoryBytesEquivalent: true, oldSessionMetadataPreserved: true, selectedLanguage: 'japanese' };
    if (args.includes('--interactive')) {
      evidence.status = 'interactive'; evidence.limitations.push('Interactive mode skips crash/restart; use default mode for that proof');
      console.log(JSON.stringify({ interactive: true, state, workspace, provider: `http://127.0.0.1:${provider.address().port}/v1`, hostPid: host.pid }));
      console.log('Provider and host stay alive until stdin closes. This is a new fixture profile, not an installed app profile.');
      await new Promise(done => {
        process.stdin.resume();
        if (process.stdin.isTTY) process.stdin.once('end', done);
        process.once('SIGTERM', done); process.once('SIGINT', done);
      });
    } else {
    prompt('crash-input', 'YOROZU_HOST_CRASH: append once, then pause.');
    await waitFor(() => exists(join(workspace, 'crashwaiting.txt')), 'once-only action before actual host crash');
    assert.equal(await readFile(join(workspace, 'once.txt'), 'utf8'), 'once\n');
    process.kill(-host.pid, 'SIGKILL'); await waitFor(() => host.closed, 'owned host process-group crash'); socket.destroy();
    const count = evidence.requests.length; await launch(); const restarted = await snapshot();
    assert.equal(restarted.binding.runs['crash-input'].state, 'unknown');
    send('reconnect-sync', main, 'sync_request', { lastSeen: {}, threadId: main, includeCurrent: true });
    prompt('after-crash-input', 'YOROZU_HOST_CHAT: execution must remain held until the prior outcome is checked.');
    const refusal = await final('after-crash-input'); assert.equal(refusal.data.failed, true); assert.match(refusal.data.text, /unconfirmed/i);
    await sleep(750); assert.equal(evidence.requests.length, count, 'Restart admitted new inference');
    assert.equal(await readFile(join(workspace, 'once.txt'), 'utf8'), 'once\n');
    evidence.claims.restartNoReplay = { passed: true, state: 'unknown', onceOnlyBytes: 'once\\n', furtherInference: 0 };
    console.log('PASS old data preserved and crash outcome remains unknown without replay'); evidence.status = 'passed';
    }
    }
  } catch (error) { evidence.status = 'failed'; evidence.failure = error.message; process.exitCode = 1; console.error(`FAIL ${error.message}`); }
  finally {
    releaseArtifact?.(); await closeHost().catch(() => {});
    for (const child of children) { if (!child.closed) { try { process.kill(-child.pid, 'SIGKILL'); } catch {} } if (child.stderrText) await writeFile(join(output, `host-${child.pid}-stderr.txt`), child.stderrText, { mode: 0o600 }); }
    provider.closeAllConnections(); await new Promise(done => provider.close(done));
    evidence.finished = new Date().toISOString(); await writeFile(join(output, 'evidence.json'), JSON.stringify(evidence, null, 2) + '\n', { mode: 0o600 });
    console.log(`Evidence: ${join(output, 'evidence.json')}`);
  }
}

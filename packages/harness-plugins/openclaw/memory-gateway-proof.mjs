#!/usr/bin/env node
/** Integrated uniform-memory proof: actual host HarnessProcess transport, actual
 * host WorkerMemory SQL + workerMemoryTools, this adapter under the actual macOS
 * per-agent sandbox, the actual pinned native Gateway with the native memory
 * plugin loaded, ordinary paired literal chat.send, and synthetic LOCAL loopback
 * inference that emits worker_memory tool calls. No external provider/account.
 * It does not exercise PersonAgentRuntime/HarnessRunner or the approval card UI;
 * execution currency and share approval are emulated by this host per contract.
 */
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { createServer as tcpServer } from 'node:net';
import { mkdir, readFile, writeFile, realpath } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { UPSTREAM, CURATED_RUNTIME } from './adapter.mjs';
import { MEMORY_PLUGIN_ID, MEMORY_TOOL } from './memory-plugin/memory-bridge.mjs';

const options = new Map();
for (let index = 2; index < process.argv.length; index += 2) options.set(process.argv[index], process.argv[index + 1]);
const required = key => { const value = options.get(key); if (!value || !value.startsWith('/')) throw new Error(`${key} must be an authorized absolute task path`); return value; };
const source = await realpath(required('--source'));
const node = await realpath(required('--node'));
// Signed bundle proofs: the host-verified sealed Node hash (nested-signed stage) replaces the unsigned pin.
const nodeIntegrity = options.has('--node-integrity') ? { sha256: options.get('--node-integrity'), hashStage: 'after-nested-signing-before-outer-bundle-signing' } : undefined;
const git = options.has('--git') ? await realpath(required('--git')) : undefined;
// App-shaped sealed runs: like the packaged host, verify the exact commit and full diff with
// host git OUTSIDE the sandbox and hand the adapter the exact record; no git inside.
const sealedSourceIntegrity = options.get('--sealed-source') === 'host-verified' ? await (async () => {
  const { execFile } = await import('node:child_process'); const { promisify } = await import('node:util'); const run = promisify(execFile);
  const env = { PATH: '/usr/bin:/bin', GIT_OPTIONAL_LOCKS: '0', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' };
  assert.equal((await run('/usr/bin/git', ['-C', source, 'rev-parse', 'HEAD'], { env })).stdout.trim(), CURATED_RUNTIME.sourceCommit);
  // No worktree diff: it refreshes and rewrites .git/index, breaking the sealed inventory; the
  // inventory already proves worktree bytes, so only the exact commit and the full patch are checked.
  const patch = await run('/usr/bin/git', ['-C', source, 'diff', UPSTREAM.commit, 'HEAD', '--binary', '--abbrev=8', '--no-color', '--no-ext-diff', '--no-textconv', '--src-prefix=a/', '--dst-prefix=b/'], { env, maxBuffer: 512 * 1024 });
  assert.equal(createHash('sha256').update(patch.stdout).digest('hex'), CURATED_RUNTIME.patchSha256);
  return { kind: 'sealed-inventory-v1', sourceSha: CURATED_RUNTIME.sourceCommit, patchSha256: CURATED_RUNTIME.patchSha256 };
})() : undefined;
const gitReadRootsRequested = options.has('--git-read-roots');
if (sealedSourceIntegrity && (git || gitReadRootsRequested)) throw new Error('host-verified sealed source excludes --git/--git-read-roots');
const readRootList = value => value.startsWith('[') ? JSON.parse(value) : value.split(':').filter(Boolean);
const gitReadRoots = options.has('--git-read-roots') ? await Promise.all(readRootList(options.get('--git-read-roots')).map(path => realpath(path))) : [];
const output = resolve(required('--output'));
await mkdir(output, { mode: 0o700 }); // Fresh evidence/profiles only; never adopts or deletes an old fixture.
const root = await realpath(output);
const evidence = { schema: 1, kind: 'actual-openclaw-gateway-uniform-memory', upstream: UPSTREAM, curatedRuntime: CURATED_RUNTIME, success: false,
  liveSubscription: false, capabilityAdvertisedByThisProof: false, personAgentRuntimeExercised: false, approvalCardUiExercised: false, sandboxGit: options.has('--git') ? 'explicit-developer-git' : options.get('--sealed-source') === 'host-verified' ? 'none-host-verified-record' : '/usr/bin/git',
  checks: {}, requests: [], events: [], memoryCalls: [], failures: [], output: root };
// Actual host implementation. Either a compiled host dist (--host-runtime) or the
// exact repository TypeScript sources transpiled here with the explicitly selected
// local TypeScript module (--host-source + --typescript); both forms are hashed.
let hostRuntime;
if (options.has('--host-runtime')) hostRuntime = await realpath(required('--host-runtime'));
else {
  const hostSource = await realpath(required('--host-source')); const ts = (await import(pathToFileURL(await realpath(required('--typescript'))))).default;
  hostRuntime = join(root, 'host-code'); await mkdir(hostRuntime);
  evidence.hostSource = { directory: hostSource, typescript: ts.version, files: {} };
  for (const file of ['agent-scope', 'agent-store', 'agent-isolation', 'agent-listener', 'harness-contract', 'harness-process', 'worker-memory', 'worker-tools']) {
    const original = await readFile(join(hostSource, `${file}.ts`), 'utf8');
    const compiled = ts.transpileModule(original, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ES2022 } }).outputText;
    await writeFile(join(hostRuntime, `${file}.js`), compiled);
    evidence.hostSource.files[file] = { originalSha256: createHash('sha256').update(original).digest('hex'), executedSha256: createHash('sha256').update(compiled).digest('hex') };
  }
  await writeFile(join(hostRuntime, 'package.json'), '{"type":"module"}\n');
}
const { PersonAgentStore } = await import(pathToFileURL(join(hostRuntime, 'agent-store.js')));
const { isolatedAgentLaunch } = await import(pathToFileURL(join(hostRuntime, 'agent-isolation.js')));
const { acquireHostListener, prepareHostListenerTransfer, releaseHostListener } = await import(pathToFileURL(join(hostRuntime, 'agent-listener.js')));
const { HarnessProcess } = await import(pathToFileURL(join(hostRuntime, 'harness-process.js')));
const { WorkerMemory } = await import(pathToFileURL(join(hostRuntime, 'worker-memory.js')));
const { workerMemoryTools, parseWorkerMemoryEnvelope } = await import(pathToFileURL(join(hostRuntime, 'worker-tools.js')));
const adapterFile = join(dirname(fileURLToPath(import.meta.url)), 'adapter.mjs');
const AGENTS = { alice: ['memory'], bob: ['memory'], carol: [] };
const store = new PersonAgentStore(join(root, 'fictional-host-state'));
let revision = 0;
for (const [id, allowedTools] of Object.entries(AGENTS)) revision = store.create({ id, name: `Fictional ${id}`, role: 'Uniform memory proof', pluginId: 'openclaw', allowedTools }, revision).revision;
// Host-owned canonical SQL, outside every agent grant and denied to every native process.
const sqlRoot = join(root, 'host-sql', 'worker-memory-v1');
await mkdir(dirname(sqlRoot), { recursive: true, mode: 0o700 });
const sql = new WorkerMemory(sqlRoot, id => Object.hasOwn(AGENTS, id));
const sqlFile = join(sqlRoot, 'worker-memory.sqlite');

async function listen(server) {
  await new Promise((yes, no) => { server.once('error', no); server.listen(0, '127.0.0.1', yes); });
  return server.address().port;
}
const waitFor = async (predicate, label, milliseconds = 60_000) => {
  const deadline = Date.now() + milliseconds;
  while (!predicate()) { if (Date.now() >= deadline) throw new Error(`timed out: ${label}`); await new Promise(yes => setTimeout(yes, 50)); }
};
function sse(response, type, data) { response.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`); }
let responseSequence = 0;
function respondText(response, text) {
  const id = `resp_${randomUUID().replaceAll('-', '')}`; const itemId = `msg_${randomUUID().replaceAll('-', '')}`;
  response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
  const base = { id, object: 'response', created_at: Math.floor(Date.now() / 1000), model: 'synthetic', status: 'in_progress', output: [], error: null, incomplete_details: null, usage: null };
  sse(response, 'response.created', { response: base, sequence_number: ++responseSequence });
  const item = { id: itemId, type: 'message', role: 'assistant', status: 'in_progress', content: [] };
  sse(response, 'response.output_item.added', { output_index: 0, item, sequence_number: ++responseSequence });
  sse(response, 'response.content_part.added', { item_id: itemId, output_index: 0, content_index: 0, part: { type: 'output_text', text: '', annotations: [] }, sequence_number: ++responseSequence });
  sse(response, 'response.output_text.delta', { item_id: itemId, output_index: 0, content_index: 0, delta: text, sequence_number: ++responseSequence });
  const part = { type: 'output_text', text, annotations: [] };
  sse(response, 'response.output_text.done', { item_id: itemId, output_index: 0, content_index: 0, text, sequence_number: ++responseSequence });
  sse(response, 'response.content_part.done', { item_id: itemId, output_index: 0, content_index: 0, part, sequence_number: ++responseSequence });
  const finalItem = { ...item, status: 'completed', content: [part] };
  sse(response, 'response.output_item.done', { output_index: 0, item: finalItem, sequence_number: ++responseSequence });
  sse(response, 'response.completed', { response: { ...base, status: 'completed', output: [finalItem], usage: { input_tokens: 100, output_tokens: 10, total_tokens: 110, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } }, sequence_number: ++responseSequence });
  response.end();
}
let callSequence = 0;
function respondToolCall(response, name, args) {
  const id = `resp_${randomUUID().replaceAll('-', '')}`; const itemId = `fc_${randomUUID().replaceAll('-', '')}`; const callId = `call_proof_${++callSequence}`;
  const encoded = JSON.stringify(args);
  response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
  const base = { id, object: 'response', created_at: Math.floor(Date.now() / 1000), model: 'synthetic', status: 'in_progress', output: [], error: null, incomplete_details: null, usage: null };
  sse(response, 'response.created', { response: base, sequence_number: ++responseSequence });
  const item = { id: itemId, type: 'function_call', call_id: callId, name, arguments: '', status: 'in_progress' };
  sse(response, 'response.output_item.added', { output_index: 0, item, sequence_number: ++responseSequence });
  sse(response, 'response.function_call_arguments.delta', { item_id: itemId, output_index: 0, delta: encoded, sequence_number: ++responseSequence });
  sse(response, 'response.function_call_arguments.done', { item_id: itemId, output_index: 0, arguments: encoded, sequence_number: ++responseSequence });
  const finalItem = { ...item, arguments: encoded, status: 'completed' };
  sse(response, 'response.output_item.done', { output_index: 0, item: finalItem, sequence_number: ++responseSequence });
  sse(response, 'response.completed', { response: { ...base, status: 'completed', output: [finalItem], usage: { input_tokens: 100, output_tokens: 10, total_tokens: 110, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } }, sequence_number: ++responseSequence });
  response.end();
}
const itemText = item => typeof item?.content === 'string' ? item.content : Array.isArray(item?.content) ? item.content.map(part => typeof part?.text === 'string' ? part.text : '').join('\n') : '';
/** The synthetic model reads an explicit PROOF directive from the literal user text. */
function script(body) {
  const input = Array.isArray(body.input) ? body.input : [];
  let lastUser = -1;
  input.forEach((item, index) => { if (item?.role === 'user' && item?.type !== 'function_call_output') lastUser = index; });
  const text = lastUser >= 0 ? itemText(input[lastUser]) : typeof body.input === 'string' ? body.input : '';
  const outputs = input.slice(lastUser + 1).filter(item => item?.type === 'function_call_output');
  const match = /PROOF (\{.*\})/s.exec(text);
  const directive = match ? JSON.parse(match[1]) : undefined;
  return { directive, outputs, userText: text.slice(0, 200) };
}
const transfers = []; const hosts = new Map(); let provider; let forbidden; let probeChild; let forbiddenConnections = 0;
const memoryState = { approvals: 0, cancelledApproval: undefined, cancelBeforeTerminal: undefined, applyAfterCancel: undefined, pendingApproval: undefined, rejectedEnvelopes: 0 };
let pendingApprovalSeen; const approvalPending = new Promise(yes => { pendingApprovalSeen = yes; });
function approver(agentId, turn) {
  return async (request, apply, signal) => {
    assert.equal(agentId, 'alice'); assert.equal(request.toAgentId, 'bob'); assert.equal(request.key, 'note');
    if (request.operationId === 'share-1') { memoryState.approvals++; apply(); return; }
    if (request.operationId === 'cancel-share') {
      memoryState.pendingApproval = true; pendingApprovalSeen();
      // The host-side turn scope is deliberately NOT aborted here: the fence must
      // arrive through adapter revocation -> worker.memory.cancel -> HarnessProcess.
      await new Promise(yes => { signal.addEventListener('abort', yes, { once: true }); setTimeout(yes, 60_000).unref(); });
      memoryState.cancelledApproval = signal.aborted; memoryState.cancelBeforeTerminal = !turn.ended;
      try { apply(); memoryState.applyAfterCancel = 'APPLIED'; } catch { memoryState.applyAfterCancel = 'fenced'; }
      throw new Error('Memory sharing was cancelled before confirmation');
    }
    throw new Error('Memory sharing was not approved');
  };
}
let turnCounter = 0;
async function startHost(agentId, fixedPort) {
  const agent = store.list().agents.find(a => a.id === agentId); const paths = store.paths(agentId); const base = store.resolveScope(agentId);
  const profileDir = join(root, 'runtime', agentId); await mkdir(profileDir, { recursive: true, mode: 0o700 });
  const others = store.list().agents.filter(a => a.id !== agentId).map(a => store.paths(a.id).memoryDir);
  // Mirror PersonAgentRuntime: uniform memory lives only behind the host capability;
  // the agent's native memory directory is denied and removed from file grants.
  const deniedRoots = [...new Set([...base.deniedRoots, sqlRoot, paths.memoryDir, ...others])];
  const directories = base.directories.filter(grant => grant.path !== paths.memoryDir);
  const osScope = { ...base, deniedRoots, directories };
  const lease = await acquireHostListener(agentId, fixedPort);
  let launch;
  try {
    launch = isolatedAgentLaunch(osScope, { command: node, args: [adapterFile], readPaths: [dirname(adapterFile), source, ...(git ? [git] : []), ...gitReadRoots], runtimeDir: profileDir, brokerPorts: [providerPort, lease.port], inheritedListeners: [lease] });
  } catch (error) { await releaseHostListener(lease); throw error; }
  assert.equal(launch.command, '/usr/bin/sandbox-exec'); assert.match(launch.policy, /\(deny default\)/); assert.ok(!launch.policy.includes('(allow network-bind'));
  assert.ok(launch.policy.includes(`(subpath ${JSON.stringify(sqlRoot)})`), 'host SQL root must be denied to the native process');
  await writeFile(join(profileDir, 'proof-provider.json'), JSON.stringify({ baseUrl: `http://127.0.0.1:${providerPort}/v1`, model: 'synthetic', api: 'openai-responses' }), { mode: 0o600 });
  const initialize = { upstreamVersion: UPSTREAM.version, source, node, ...(nodeIntegrity ? { nodeIntegrity } : {}), ...(sealedSourceIntegrity ? { sourceIntegrity: sealedSourceIntegrity } : {}), ...(git ? { git } : {}), workspace: agent.workspace, profileDir, agentId, workerMemory: true,
    scope: { allowedTools: [...base.allowedTools], directories: directories.map(grant => ({ ...grant })), workspace: agent.workspace, memoryDir: agent.memoryDir, deniedRoots },
    isolation: launch.isolation, providerConfigPath: join(profileDir, 'proof-provider.json'), platform: { team: false, computer: false } };
  const host = { agentId, profileDir, port: lease.port, launch, initialize, events: [], turns: new Map(), active: undefined, sessionId: undefined, conversationId: `conversation-${agentId}`, bindingId: `binding-${agentId}` };
  host.process = new HarnessProcess({ pluginId: 'openclaw', command: launch.command, args: launch.args, upstreamVersion: UPSTREAM.version, initialize, inheritedListeners: [lease],
    workerTool: async (method, params, signal) => {
      const envelope = parseWorkerMemoryEnvelope(params); const turn = host.active;
      if (!turn || turn.ended || envelope.execution.sessionId !== host.sessionId || envelope.execution.runId !== turn.runId || envelope.execution.attemptId !== turn.attemptId) {
        memoryState.rejectedEnvelopes++; throw new Error('Worker memory requires exact active execution authority');
      }
      evidence.memoryCalls.push({ agentId, action: envelope.request.action, runId: turn.runId });
      const invoke = workerMemoryTools(sql.bind(agentId), () => { if (turn.ended || turn.controller.signal.aborted) throw new Error('Memory tool is not granted to this execution'); }, approver(agentId, turn));
      return invoke(method, envelope.request, AbortSignal.any([signal, turn.controller.signal]));
    } });
  host.process.listeners.add(event => { evidence.events.push({ agentId, ...event }); host.events.push(event);
    if (event.kind === 'turn.terminal') { const turn = [...host.turns.values()].find(t => t.runId === event.runId && t.attemptId === event.attemptId); if (turn) { turn.ended = true; turn.state = event.data.state; turn.text = event.data.text; turn.controller.abort(); } } });
  host.process.failures.add(reason => evidence.failures.push({ agentId, reason }));
  const ready = await host.process.start();
  assert.equal(ready.workerMemory, true); assert.equal(ready.pluginId, 'openclaw'); assert.equal(ready.agentId, agentId); assert.equal(ready.auth.status, 'local-proof');
  hosts.set(agentId, host);
  return host;
}
async function openSession(host, sessionId) {
  const opened = await host.process.request('session.open', { conversationId: host.conversationId, bindingId: host.bindingId, ...(sessionId ? { sessionId } : {}) });
  assert.ok(typeof opened.sessionId === 'string' && opened.sessionId); host.sessionId = opened.sessionId; return opened;
}
async function turn(host, text) {
  const runId = `host-run-${++turnCounter}`; const attemptId = `host-attempt-${turnCounter}`;
  const record = { runId, attemptId, controller: new AbortController(), ended: false };
  host.turns.set(runId, record); host.active = record;
  let receipt;
  for (let index = 0; index < 100; index++) {
    receipt = await host.process.request('turn.submit', { conversationId: host.conversationId, bindingId: host.bindingId, runId, attemptId, text });
    if (receipt.status !== 'busy' || receipt.handoff !== 'not-submitted') break;
    await new Promise(yes => setTimeout(yes, 100));
  }
  assert.equal(receipt.status, 'accepted', JSON.stringify(receipt));
  return record;
}
async function finished(host, record) {
  await waitFor(() => record.ended, `terminal for ${record.runId} (${host.agentId})`, 120_000);
  const terminal = host.events.find(event => event.kind === 'turn.terminal' && event.runId === record.runId);
  const text = host.events.filter(event => event.kind === 'assistant.update' && event.runId === record.runId).at(-1)?.data.text ?? '';
  return { state: terminal.data.state, text };
}
const proof = (call, reply) => `PROOF ${JSON.stringify({ call, reply })}`;
async function memoryTurn(host, call, reply) {
  const record = await turn(host, proof(call, reply));
  const result = await finished(host, record);
  assert.equal(result.state, 'completed', `${host.agentId} ${reply}: ${JSON.stringify(result)}`);
  const prefix = `${reply}:`; assert.ok(result.text.startsWith(prefix), `${host.agentId} reply missing ${reply}: ${result.text.slice(0, 300)}`);
  return result.text.slice(prefix.length);
}
let providerPort;
try {
  provider = createServer(async (request, response) => {
    if (request.url === '/health') { response.end('own-loopback-proof'); return; }
    if (request.method !== 'POST' || request.url !== '/v1/responses') { response.writeHead(404); response.end(); return; }
    let buffer = '';
    for await (const bytes of request) { buffer += bytes; if (Buffer.byteLength(buffer) > 4 * 1024 * 1024) { response.writeHead(413); response.end(); return; } }
    const body = JSON.parse(buffer);
    const tools = (body.tools ?? []).map(tool => tool.name ?? tool.function?.name ?? '?');
    const { directive, outputs, userText } = script(body);
    const outputText = item => typeof item.output === 'string' ? item.output : JSON.stringify(item.output);
    evidence.requests.push({ model: body.model, tools, userText, toolOutputs: outputs.map(item => outputText(item).slice(0, 300)), directive: directive?.call?.action ?? null });
    if (body.model !== 'synthetic' || body.service_tier === 'priority' || tools.some(name => name !== MEMORY_TOOL)) { response.writeHead(400); response.end('proof request violated native tool/model/tier policy'); return; }
    if (!directive) { respondText(response, 'PLAIN_REPLY'); return; }
    if (outputs.length === 0) { respondToolCall(response, MEMORY_TOOL, directive.call); return; }
    respondText(response, `${directive.reply}:${outputs.map(outputText).join('|')}`);
  });
  providerPort = await listen(provider);
  forbidden = tcpServer(socket => { forbiddenConnections++; socket.destroy(); }); const forbiddenPort = await listen(forbidden);
  // 1. Kernel probe under the exact alice policy: SQL and peer memory are denied inside the sandbox.
  const aliceBase = store.resolveScope('alice'); const alicePaths = store.paths('alice'); const bobPaths = store.paths('bob');
  const peerFile = join(bobPaths.memoryDir, 'canary.txt'); await writeFile(peerFile, 'Fictional peer fixture, never user data.\n', { mode: 0o600 });
  const probeLease = await acquireHostListener('alice');
  const probeScope = { ...aliceBase, deniedRoots: [...new Set([...aliceBase.deniedRoots, sqlRoot, alicePaths.memoryDir, bobPaths.memoryDir, store.paths('carol').memoryDir])], directories: aliceBase.directories.filter(g => g.path !== alicePaths.memoryDir) };
  const probeFile = join(alicePaths.workspace, 'kernel-probe.mjs');
  await mkdir(join(root, 'runtime', 'probe'), { recursive: true, mode: 0o700 });
  const probeLaunch = isolatedAgentLaunch(probeScope, { command: node, args: [probeFile], readPaths: [dirname(adapterFile), source], runtimeDir: join(root, 'runtime', 'probe'), brokerPorts: [providerPort, probeLease.port], inheritedListeners: [probeLease] });
  const probeTransfer = prepareHostListenerTransfer([probeLease], 'alice'); transfers.push(probeTransfer);
  await writeFile(probeFile, `import fs from 'node:fs';import net from 'node:net';import http from 'node:http';
    const result={};const denied=e=>['EPERM','EACCES'].includes(e.code);
    result.allowedConnect=await fetch('http://127.0.0.1:${providerPort}/health').then(r=>r.text())==='own-loopback-proof';
    result.deniedConnect=await fetch('http://127.0.0.1:${forbiddenPort}/',{signal:AbortSignal.timeout(3000)}).then(()=>false,e=>denied(e.cause??{}));
    result.deniedListen=await new Promise(yes=>{const s=net.createServer();s.once('error',e=>yes(denied(e)));s.listen(0,'0.0.0.0',()=>s.close(()=>yes(false)));});
    try{fs.readFileSync(${JSON.stringify(sqlFile)});result.sqlDenied=false}catch(e){result.sqlDenied=denied(e)}
    try{fs.writeFileSync(${JSON.stringify(join(sqlRoot, 'intruder'))},'x');result.sqlWriteDenied=false}catch(e){result.sqlWriteDenied=denied(e)}
    try{fs.readFileSync(${JSON.stringify(peerFile)});result.peerDenied=false}catch(e){result.peerDenied=denied(e)}
    try{fs.readdirSync(${JSON.stringify(alicePaths.memoryDir)});result.ownNativeMemoryDenied=false}catch(e){result.ownNativeMemoryDenied=denied(e)}
    const server=http.createServer((req,res)=>res.end('own-inherited-kernel-proof'));await new Promise((yes,no)=>{server.once('error',no);server.listen({fd:3},yes)});
    const address=server.address();result.inheritedPort=address.port;console.log(JSON.stringify(result));
    process.stdin.resume();process.stdin.once('end',()=>server.close(()=>process.exit(0)));`, { mode: 0o600 });
  probeChild = spawn(probeLaunch.command, probeLaunch.args, { cwd: alicePaths.workspace, env: { HOME: join(root, 'runtime', 'probe'), TMPDIR: join(root, 'runtime', 'probe'), PATH: '/usr/bin:/bin', NODE_DISABLE_COMPILE_CACHE: '1' }, stdio: ['pipe', 'pipe', 'pipe', probeTransfer.descriptors[0].stdioFd] });
  let probeOut = ''; let probeErr = ''; probeChild.stdout.on('data', b => { probeOut += b; }); probeChild.stderr.on('data', b => { probeErr = (probeErr + b).slice(-8192); });
  const probeDone = new Promise((yes, no) => { probeChild.once('error', no); probeChild.once('exit', code => yes(code)); });
  await probeTransfer.afterSpawn(probeChild);
  assert.equal(await fetch(`http://127.0.0.1:${probeLease.port}`, { signal: AbortSignal.timeout(15_000) }).then(r => r.text()), 'own-inherited-kernel-proof');
  probeChild.stdin.end(); assert.equal(await probeDone, 0, probeErr); probeChild = null;
  const physical = JSON.parse(probeOut.trim().split('\n').at(-1));
  assert.deepEqual(physical, { allowedConnect: true, deniedConnect: true, deniedListen: true, sqlDenied: true, sqlWriteDenied: true, peerDenied: true, ownNativeMemoryDenied: true, inheritedPort: probeLease.port });
  assert.equal(forbiddenConnections, 0); evidence.checks.actualKernel = physical;
  // 2. Two memory-granted agents and one zero-tool agent, each an actual confined Gateway.
  const alice = await startHost('alice'); const bob = await startHost('bob'); const carol = await startHost('carol');
  for (const host of [alice, bob, carol]) {
    const config = JSON.parse(await readFile(join(host.profileDir, 'openclaw.json'), 'utf8'));
    const granted = AGENTS[host.agentId].includes('memory');
    assert.equal(config.plugins.slots.memory, 'none'); assert.equal(config.memory.search.enabled, false); assert.equal(config.agents.defaults.contextInjection, 'never');
    assert.equal(config.agents.defaults.compaction.memoryFlush.enabled, false); assert.equal(config.hooks.enabled, false);
    assert.equal(config.plugins.enabled, granted); assert.deepEqual(config.plugins.allow, granted ? [MEMORY_PLUGIN_ID] : []);
    assert.deepEqual(granted ? config.tools.allow : config.tools.deny, granted ? [MEMORY_TOOL] : ['*']);
    const owner = JSON.parse(await readFile(join(host.profileDir, '.yorozu-openclaw-owner.json'), 'utf8'));
    assert.equal(owner.schema, 5); assert.equal(owner.memoryContract, 'worker-memory-v1'); assert.equal(owner.inputContract, 'literal-v1');
    evidence.checks[`uniformConfig:${host.agentId}`] = { memoryGranted: granted, pluginsEnabled: config.plugins.enabled, memorySlot: config.plugins.slots.memory, ownerSchema: owner.schema, memoryContract: owner.memoryContract };
  }
  const aliceOpened = await openSession(alice); await openSession(bob); await openSession(carol);
  // 3. Zero-tool uniform agent: literal chat works with no native tool catalog at all.
  const carolRecord = await turn(carol, 'Reply once with a harmless phrase.'); const carolResult = await finished(carol, carolRecord);
  assert.equal(carolResult.state, 'completed'); assert.equal(carolResult.text, 'PLAIN_REPLY');
  assert.deepEqual(evidence.requests.at(-1).tools, []); evidence.checks.zeroToolCatalogEmpty = true;
  // 4. Ordinary paired literal chat.send -> native catalog [worker_memory] -> native dispatcher -> FD4 -> adapter -> host SQL.
  const written = await memoryTurn(alice, { action: 'write', key: 'note', body: 'Fictional native SQL evidence', operationId: 'write-1' }, 'WRITE_RESULT');
  assert.ok(written.includes('"ok":true'), written);
  assert.equal(sql.bind('alice').read('alice', 'note'), 'Fictional native SQL evidence');
  const aliceCatalog = evidence.requests.filter(r => r.directive === 'write').map(r => r.tools);
  assert.ok(aliceCatalog.length >= 1 && aliceCatalog.every(tools => tools.length === 1 && tools[0] === MEMORY_TOOL), JSON.stringify(aliceCatalog));
  evidence.checks.gatewayCatalogExactlyWorkerMemory = true; evidence.checks.gatewayDispatchReachedHostSql = true;
  const read = await memoryTurn(alice, { action: 'read', ownerId: 'alice', key: 'note' }, 'READ_RESULT');
  assert.ok(read.includes('Fictional native SQL evidence'), read);
  // 5. Private isolation: bob cannot read alice; model-supplied identity fields are rejected.
  const bobPrivate = await memoryTurn(bob, { action: 'read', ownerId: 'alice', key: 'note' }, 'BOB_PRIVATE');
  assert.ok(!bobPrivate.includes('Fictional native SQL evidence'), bobPrivate);
  const forged = await memoryTurn(bob, { action: 'read', ownerId: 'alice', key: 'note', agentId: 'alice' }, 'BOB_FORGED');
  assert.ok(!forged.includes('Fictional native SQL evidence'), forged);
  assert.throws(() => sql.bind('bob').read('alice', 'note')); evidence.checks.twoAgentPrivateIsolation = true;
  // 6. Exact approval share, grant currency, immediate revoke.
  const granted = await memoryTurn(alice, { action: 'grant', key: 'note', toAgentId: 'bob', operationId: 'share-1' }, 'GRANT_RESULT');
  assert.ok(granted.includes('"ok":true'), granted); assert.equal(memoryState.approvals, 1);
  const shared = await memoryTurn(bob, { action: 'read', ownerId: 'alice', key: 'note' }, 'BOB_SHARED');
  assert.ok(shared.includes('Fictional native SQL evidence'), shared);
  const search = await memoryTurn(bob, { action: 'search', ownerId: 'alice', query: 'native' }, 'BOB_SEARCH');
  assert.ok(search.includes('"key":"note"'), search);
  const revoked = await memoryTurn(alice, { action: 'revoke', key: 'note', toAgentId: 'bob', operationId: 'revoke-1' }, 'REVOKE_RESULT');
  assert.ok(revoked.includes('"ok":true'), revoked);
  const afterRevoke = await memoryTurn(bob, { action: 'read', ownerId: 'alice', key: 'note' }, 'BOB_REVOKED');
  assert.ok(!afterRevoke.includes('Fictional native SQL evidence'), afterRevoke); assert.throws(() => sql.bind('bob').read('alice', 'note'));
  evidence.checks.exactApprovalShareAndImmediateRevoke = true;
  // 7. Stop while a share approval is pending: adapter revocation -> worker.memory.cancel -> host approval fenced before SQL apply.
  const pendingRecord = await turn(alice, proof({ action: 'grant', key: 'note', toAgentId: 'bob', operationId: 'cancel-share' }, 'CANCELLED_GRANT'));
  await approvalPending; assert.equal(memoryState.pendingApproval, true);
  const stop = await alice.process.request('run.stop', { conversationId: alice.conversationId, bindingId: alice.bindingId, runId: pendingRecord.runId, attemptId: pendingRecord.attemptId, operationId: 'exact-native-stop' });
  assert.equal(stop.status, 'requested', JSON.stringify(stop));
  const stopped = await finished(alice, pendingRecord);
  assert.equal(stopped.state, 'stopped');
  await waitFor(() => memoryState.applyAfterCancel !== undefined, 'approval fence observation');
  assert.equal(memoryState.cancelledApproval, true); assert.equal(memoryState.cancelBeforeTerminal, true); assert.equal(memoryState.applyAfterCancel, 'fenced');
  assert.throws(() => sql.bind('bob').read('alice', 'note'));
  evidence.checks.cancelFencedPendingApproval = { cancelledBeforeTerminal: memoryState.cancelBeforeTerminal, applyAfterCancel: memoryState.applyAfterCancel };
  // 8. Lifetime continues after Stop; retained SQL is unchanged.
  const afterStop = await memoryTurn(alice, { action: 'read', ownerId: 'alice', key: 'note' }, 'AFTER_STOP');
  assert.ok(afterStop.includes('Fictional native SQL evidence'), afterStop); evidence.checks.lifetimeAfterStop = true;
  assert.equal(memoryState.rejectedEnvelopes, 0);
  // 9. Embedding-owned stop and restart of alice on the same profile; host SQL persists; no replay.
  const requestsBeforeRestart = evidence.requests.length;
  await alice.process.close(); hosts.delete('alice');
  await waitFor(() => !existsSync(join(alice.profileDir, '.adapter-owner.lock')), 'previous owner lock release', 15_000);
  const restarted = await startHost('alice', alice.port);
  assert.equal(restarted.launch.isolation.policyDigest, alice.launch.isolation.policyDigest);
  const reopened = await openSession(restarted, aliceOpened.sessionId); assert.equal(reopened.recovery, 'snapshot-only');
  const persisted = await memoryTurn(restarted, { action: 'read', ownerId: 'alice', key: 'note' }, 'AFTER_RESTART');
  assert.ok(persisted.includes('Fictional native SQL evidence'), persisted);
  assert.ok(evidence.requests.length >= requestsBeforeRestart + 2);
  evidence.checks.restartSameProfilePersistsHostSql = true;
  for (const host of hosts.values()) { await host.process.close(); }
  hosts.clear();
  evidence.checks.cleanNativeShutdown = evidence.failures.every(f => /Harness closed|exited/.test(f.reason));
  evidence.success = true;
} catch (error) {
  evidence.failure = { message: error.message, stack: error.stack }; process.exitCode = 1;
} finally {
  for (const host of hosts.values()) { try { await host.process.close(); } catch (error) { evidence.shutdownFailure = error.message; evidence.success = false; process.exitCode = 1; } }
  if (probeChild && probeChild.exitCode === null && probeChild.signalCode === null) probeChild.kill('SIGTERM');
  for (const transfer of transfers) { try { await transfer.release(); } catch (error) { evidence.listenerReleaseFailure = error.message; } }
  for (const server of [provider, forbidden]) if (server) { server.closeAllConnections?.(); await new Promise(yes => server.close(yes)); }
  sql.close();
  evidence.memoryState = { approvals: memoryState.approvals, cancelledApproval: memoryState.cancelledApproval, applyAfterCancel: memoryState.applyAfterCancel, rejectedEnvelopes: memoryState.rejectedEnvelopes };
  evidence.sourceHashes = { adapter: createHash('sha256').update(await readFile(adapterFile)).digest('hex') };
  await writeFile(join(root, 'evidence.json'), JSON.stringify(evidence, null, 2) + '\n', { mode: 0o600 });
  console.log(JSON.stringify({ success: evidence.success, output: join(root, 'evidence.json'), checks: Object.keys(evidence.checks), failure: evidence.failure?.message }));
}

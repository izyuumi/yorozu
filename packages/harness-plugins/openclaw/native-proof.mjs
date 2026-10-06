#!/usr/bin/env node
/** Actual confined Gateway proof; synthetic inference only, no live accounts or native tools. */
import { spawn } from 'node:child_process';
import { createServer } from 'node:http';
import { createServer as tcpServer } from 'node:net';
import { mkdir, readFile, writeFile, realpath } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';
import assert from 'node:assert/strict';
import { UPSTREAM, CURATED_RUNTIME, CAPABILITIES } from './adapter.mjs';

const options = new Map();
for (let index = 2; index < process.argv.length; index += 2) options.set(process.argv[index], process.argv[index + 1]);
const required = key => { const value = options.get(key); if (!value || !value.startsWith('/')) throw new Error(`${key} must be an authorized absolute task path`); return value; };
const source = await realpath(required('--source'));
const node = await realpath(required('--node'));
const hostRuntime = await realpath(required('--host-runtime'));
// Explicit read-only verifier code/dependencies; never a data/profile grant.
const git = options.has('--git') ? await realpath(required('--git')) : undefined;
const gitReadRoots = options.has('--git-read-roots') ? await Promise.all(JSON.parse(options.get('--git-read-roots')).map(path => realpath(path))) : [];
const output = resolve(required('--output'));
await mkdir(output, { mode: 0o700 }); // Fresh evidence/profile only; never adopts or deletes an old fixture.
const root = await realpath(output);
const evidence = { schema: 1, kind: 'actual-openclaw-gateway-synthetic-inference', upstream: UPSTREAM, curatedRuntime: CURATED_RUNTIME, success: false,
  liveSubscription: false, nativeToolExecution: false, capabilityParity: false, nativeUI: false, checks: {}, events: [], requests: [], output: root };
const { PersonAgentStore } = await import(pathToFileURL(join(hostRuntime, 'agent-store.js')));
const { isolatedAgentLaunch } = await import(pathToFileURL(join(hostRuntime, 'agent-isolation.js')));
const { acquireHostListener, prepareHostListenerTransfer, releaseHostListener } = await import(pathToFileURL(join(hostRuntime, 'agent-listener.js')));
const adapterFile = join(dirname(fileURLToPath(import.meta.url)), 'adapter.mjs');
const profileDir = join(root, 'vendor-runtime'); const workspace = join(profileDir, 'scratch');
await mkdir(workspace, { recursive: true, mode: 0o700 });
const store = new PersonAgentStore(join(root, 'fictional-host-state'));
store.create({ id: 'proof-main', name: 'Fictional proof secretary', role: 'Chat proof', pluginId: 'openclaw', allowedTools: [] }, 0);
store.create({ id: 'proof-other', name: 'Fictional private peer', role: 'Confinement canary', pluginId: 'hermes', allowedTools: [] }, 1);
const scope = store.resolveScope('proof-main');
const peerFile = join(store.paths('proof-other').memoryDir, 'canary.txt');
await writeFile(peerFile, 'Fictional peer fixture, never user data.\n', { mode: 0o600 });

async function listen(server) {
  await new Promise((yes, no) => { server.once('error', no); server.listen(0, '127.0.0.1', yes); });
  return server.address().port;
}
const pendingResponses = new Set();
const transfers = [];
let provider;
let forbidden;
let adapter;
let probeChild;
let heldClosed = false;
let forbiddenConnections = 0;
function sse(response, type, data) { response.write(`event: ${type}\ndata: ${JSON.stringify({ type, ...data })}\n\n`); }
function respond(response, marker, hold) {
  const id = `resp_${randomUUID().replaceAll('-', '')}`; const itemId = `msg_${randomUUID().replaceAll('-', '')}`;
  response.writeHead(200, { 'content-type': 'text/event-stream', 'cache-control': 'no-cache' });
  const base = { id, object: 'response', created_at: Math.floor(Date.now() / 1000), model: 'synthetic', status: 'in_progress', output: [], error: null, incomplete_details: null, usage: null };
  sse(response, 'response.created', { response: base });
  const item = { id: itemId, type: 'message', role: 'assistant', status: 'in_progress', content: [] };
  sse(response, 'response.output_item.added', { output_index: 0, item });
  sse(response, 'response.content_part.added', { item_id: itemId, output_index: 0, content_index: 0, part: { type: 'output_text', text: '', annotations: [] } });
  sse(response, 'response.output_text.delta', { item_id: itemId, output_index: 0, content_index: 0, delta: marker });
  if (hold) { pendingResponses.add(response); response.once('close', () => { pendingResponses.delete(response); heldClosed = true; }); return; }
  const part = { type: 'output_text', text: marker, annotations: [] };
  sse(response, 'response.output_text.done', { item_id: itemId, output_index: 0, content_index: 0, text: marker });
  sse(response, 'response.content_part.done', { item_id: itemId, output_index: 0, content_index: 0, part });
  const finalItem = { ...item, status: 'completed', content: [part] };
  sse(response, 'response.output_item.done', { output_index: 0, item: finalItem });
  sse(response, 'response.completed', { response: { ...base, status: 'completed', output: [finalItem], usage: { input_tokens: 100, output_tokens: 10, total_tokens: 110, input_tokens_details: { cached_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } } } });
  response.end();
}
const waitFor = async (predicate, label, milliseconds = 30_000) => {
  const deadline = Date.now() + milliseconds;
  while (!predicate()) { if (Date.now() >= deadline) throw new Error(`timed out: ${label}`); await new Promise(yes => setTimeout(yes, 50)); }
};
async function processRun(launch, transfer) {
  const child = spawn(launch.command, launch.args, { cwd: workspace,
    env: { HOME: profileDir, CODEX_HOME: join(profileDir, 'isolated-codex'), TMPDIR: profileDir, PATH: '/usr/bin:/bin', NODE_DISABLE_COMPILE_CACHE: '1' }, stdio: ['pipe', 'pipe', 'pipe', transfer.descriptors[0].stdioFd] });
  let stdout = ''; let stderr = '';
  child.stdout.on('data', bytes => { stdout += bytes; if (stdout.length > 1024 * 1024) child.kill('SIGTERM'); });
  child.stderr.on('data', bytes => { stderr = (stderr + bytes).slice(-16 * 1024); });
  const done = new Promise((yes, no) => { child.once('error', no); child.once('exit', (code, signal) => yes({ code, signal, stdout, stderr })); });
  try { await transfer.afterSpawn(child); } catch (error) { child.kill('SIGTERM'); throw error; }
  return { child, done };
}
async function client(launch, transfer) {
  const child = spawn(launch.command, launch.args, { cwd: workspace,
    env: { HOME: profileDir, CODEX_HOME: join(profileDir, 'isolated-codex'), TMPDIR: profileDir, PATH: '/usr/bin:/bin', NODE_DISABLE_COMPILE_CACHE: '1' }, stdio: ['pipe', 'pipe', 'pipe', transfer.descriptors[0].stdioFd] });
  let buffer = ''; let next = 0; const pending = new Map(); let stderr = ''; let exited = false;
  const rejectPending = error => { for (const entry of pending.values()) { clearTimeout(entry.timer); entry.no(error); } pending.clear(); };
  child.stdin.on('error', rejectPending);
  child.stderr.on('data', bytes => { stderr = (stderr + bytes).slice(-16 * 1024); });
  child.stdout.on('data', bytes => {
    buffer += bytes;
    for (;;) {
      const end = buffer.indexOf('\n'); if (end < 0) break;
      const line = buffer.slice(0, end); buffer = buffer.slice(end + 1); if (!line) continue;
      let frame; try { frame = JSON.parse(line); } catch { continue; }
      if (frame.method === 'harness.event') evidence.events.push(frame.params);
      else if (pending.has(frame.id)) {
        const entry = pending.get(frame.id); pending.delete(frame.id); clearTimeout(entry.timer);
        if (frame.error) entry.no(new Error(`adapter RPC ${entry.method}: ${frame.error.message}`)); else entry.yes(frame.result);
      }
    }
  });
  child.once('error', error => { exited = true; rejectPending(error); });
  child.once('exit', (code, signal) => { exited = true; rejectPending(new Error(`adapter exited (${signal ?? code}): ${stderr}`)); });
  try { await transfer.afterSpawn(child); } catch (error) { child.kill('SIGTERM'); throw error; }
  return { child, stderr: () => stderr,
    call(method, params) { if (exited || child.stdin.destroyed || child.stdin.writableEnded) return Promise.reject(new Error('adapter transport is closed')); const id = ++next; return new Promise((yes, no) => { const timer = setTimeout(() => { pending.delete(id); no(new Error(`adapter RPC timed out: ${method}`)); }, method === 'initialize' ? 80_000 : 45_000); pending.set(id, { yes, no, method, timer }); child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n', error => { if (error) rejectPending(error); }); }); },
    async stop() { if (exited) return; try { await this.call('shutdown', {}); } finally { child.stdin.end(); } await waitFor(() => exited, 'adapter exit', 35_000); },
  };
}
try {
  provider = createServer(async (request, response) => {
    if (request.url === '/health') { response.end('own-loopback-proof'); return; }
    if (request.method !== 'POST' || request.url !== '/v1/responses') { response.writeHead(404); response.end(); return; }
    let buffer = '';
    for await (const bytes of request) { buffer += bytes; if (Buffer.byteLength(buffer) > 2 * 1024 * 1024) { response.writeHead(413); response.end(); return; } }
    const body = JSON.parse(buffer); evidence.requests.push(body);
    if (body.model !== 'synthetic' || (body.tools?.length ?? 0) !== 0 || body.service_tier === 'priority') { response.writeHead(400); response.end('proof request violated native tool/model/tier policy'); return; }
    const index = evidence.requests.length;
    respond(response, index === 1 ? 'OPENCLAW_NATIVE_ONE' : index === 2 ? 'OPENCLAW_NATIVE_TWO' : 'OPENCLAW_NATIVE_BEFORE_STOP', index >= 3);
  });
  const providerPort = await listen(provider);
  forbidden = tcpServer(socket => { forbiddenConnections++; socket.destroy(); }); const forbiddenPort = await listen(forbidden);
  const runtime = { command: node, args: [adapterFile], readPaths: [dirname(adapterFile), source, ...(git ? [git] : []), ...gitReadRoots], runtimeDir: profileDir, brokerPorts: [providerPort] };
  const prepare = async (args, fixedPort) => {
    const lease = await acquireHostListener(scope.agentId, fixedPort);
    try {
    const launch = isolatedAgentLaunch(scope, { ...runtime, args, brokerPorts: [providerPort, lease.port], inheritedListeners: [lease] });
    const transfer = prepareHostListenerTransfer([lease], scope.agentId); transfers.push(transfer);
    const descriptor = transfer.descriptors[0];
    assert.equal(descriptor.fd, 3); assert.equal(descriptor.agentId, scope.agentId); assert.equal(descriptor.host, '127.0.0.1');
    return { launch, transfer, port: lease.port };
    } catch (error) { await releaseHostListener(lease); throw error; }
  };
  const probe = join(workspace, 'kernel-probe.mjs');
  const probeOwner = await prepare([probe]);
  const probePort = probeOwner.port;
  const { launch: probeLaunch } = probeOwner;
  assert.equal(probeLaunch.command, '/usr/bin/sandbox-exec');
  assert.ok(!probeLaunch.policy.includes('(allow network-bind')); assert.ok(!probeLaunch.policy.includes('(allow network*)'));
  await writeFile(probe, `import fs from 'node:fs';import net from 'node:net';import http from 'node:http';import cp from 'node:child_process';
    const result={};
    result.allowedConnect=await fetch('http://127.0.0.1:${providerPort}/health').then(r=>r.text())==='own-loopback-proof';
    result.deniedConnect=await fetch('http://127.0.0.1:${forbiddenPort}/',{signal:AbortSignal.timeout(3000)}).then(()=>false,e=>['EPERM','EACCES'].includes(e.cause?.code));
    result.deniedListen=await new Promise(yes=>{const s=net.createServer();s.once('error',e=>yes(['EPERM','EACCES'].includes(e.code)));s.listen(0,'0.0.0.0',()=>s.close(()=>yes(false)));});
    try{fs.readFileSync(${JSON.stringify(peerFile)});result.peerDenied=false}catch(e){result.peerDenied=['EPERM','EACCES'].includes(e.code)}
    const child=cp.spawnSync('/bin/cat',[${JSON.stringify(peerFile)}],{encoding:'utf8'});result.inheritedPeerDenied=child.status!==0&&!child.stdout;
    const server=http.createServer((req,res)=>res.end('own-inherited-kernel-proof'));await new Promise((yes,no)=>{server.once('error',no);server.listen({fd:3},yes)});
    const address=server.address();result.inheritedAddress=address.address;result.inheritedPort=address.port;console.log(JSON.stringify(result));
    process.stdin.resume();process.stdin.once('end',()=>server.close(()=>process.exit(0)));`, { mode: 0o600 });
  const probeProcess = await processRun(probeLaunch, probeOwner.transfer);
  probeChild = probeProcess.child;
  const physicalResponse = await fetch(`http://127.0.0.1:${probePort}`, { signal: AbortSignal.timeout(10_000) }).then(response => response.text());
  assert.equal(physicalResponse, 'own-inherited-kernel-proof'); probeProcess.child.stdin.end();
  const probeResult = await probeProcess.done;
  probeChild = null;
  assert.equal(probeResult.code, 0, probeResult.stderr);
  const physical = JSON.parse(probeResult.stdout);
  assert.deepEqual(physical, { allowedConnect: true, deniedConnect: true, deniedListen: true, peerDenied: true, inheritedPeerDenied: true, inheritedAddress: '127.0.0.1', inheritedPort: probePort });
  assert.equal(forbiddenConnections, 0); evidence.checks.actualKernel = physical;
  // Fictional offline diagnostics observe session/history failures and identity
  // summaries only; no token, message content, provider bootstrap, native logs
  // or connect responses are projected.
  const adapterEntry = join(workspace, 'diagnostic-adapter.mjs');
  await writeFile(adapterEntry, `import {NativeGateway,serve} from ${JSON.stringify(pathToFileURL(adapterFile).href)};
    const call=NativeGateway.prototype.call;
    NativeGateway.prototype.call=async function(method,params){try{const result=await call.call(this,method,params);
      if(method==='chat.history')process.stderr.write(JSON.stringify({method,keys:Object.keys(result??{}),sessionKey:result?.sessionKey,sessionId:result?.sessionId,sessionInfo:result?.sessionInfo})+'\\n');
      return result;}catch(error){
      if(['sessions.create','chat.history','chat.send'].includes(method))process.stderr.write(JSON.stringify({method,code:error.data?.code,message:error.data?.message})+'\\n');throw error;}};
    serve();`);
  const gatewayOwner = await prepare([adapterEntry]);
  const { launch, transfer } = gatewayOwner; const gatewayPort = gatewayOwner.port;
  assert.equal(launch.command, '/usr/bin/sandbox-exec'); assert.match(launch.policy, /\(deny default\)/);
  assert.ok(!launch.policy.includes('(allow network-bind'), 'actual child may adopt its minted descriptor but may never bind');
  assert.ok(!launch.policy.includes('(allow network*)')); assert.ok(!launch.policy.includes(`127.0.0.1:${forbiddenPort}`));
  assert.equal(createHash('sha256').update(launch.policy).digest('hex'), launch.isolation.policyDigest);
  await writeFile(join(root, 'actual-kernel-policy.sbpl'), launch.policy, { mode: 0o600 });
  await writeFile(join(profileDir, 'proof-provider.json'), JSON.stringify({ baseUrl: `http://127.0.0.1:${providerPort}/v1`, model: 'synthetic', api: 'openai-responses' }), { mode: 0o600 });
  const init = { protocolVersion: 1, upstreamVersion: UPSTREAM.version, source, node, ...(git ? { git } : {}), workspace, profileDir, gatewayPort, agentId: scope.agentId,
    gatewayListener: { transport: CURATED_RUNTIME.transport, fd: 3, host: '127.0.0.1', port: gatewayPort },
    scope: { allowedTools: scope.allowedTools, directories: scope.directories, workspace: store.paths('proof-main').workspace, memoryDir: store.paths('proof-main').memoryDir, deniedRoots: scope.deniedRoots },
    isolation: launch.isolation, providerConfigPath: join(profileDir, 'proof-provider.json'), platform: { team: false, computer: false } };
  adapter = await client(launch, transfer);
  const ready = await adapter.call('initialize', init);
  assert.equal(ready.pluginId, 'openclaw'); assert.equal(ready.auth.status, 'local-proof'); assert.deepEqual(ready.capabilities, CAPABILITIES);
  evidence.checks.realGatewayReadiness = { upstreamVersion: ready.upstreamVersion, isolation: launch.isolation, capabilities: ready.capabilities };
  const session = { conversationId: 'common-secretary-proof', bindingId: 'openclaw-proof-binding' };
  const opened = await adapter.call('session.open', session); evidence.checks.nativeSession = opened;
  const first = { ...session, runId: 'first-native-turn', attemptId: 'first-attempt', text: 'Remember this current harmless phrase: YOROZU_NATIVE_HISTORY_TOKEN. Reply once.' };
  assert.equal((await adapter.call('turn.submit', first)).status, 'accepted');
  await waitFor(() => evidence.events.some(event => event.runId === first.runId && event.kind === 'turn.terminal'), 'first native terminal');
  assert.equal(evidence.events.find(event => event.runId === first.runId && event.kind === 'turn.terminal').data.state, 'completed');
  const second = { ...session, runId: 'second-native-turn', attemptId: 'second-attempt', text: 'Continue this same native secretary conversation with another harmless reply.' };
  let secondReceipt;
  for (let index = 0; index < 20; index++) { secondReceipt = await adapter.call('turn.submit', second); if (secondReceipt.status !== 'busy' || secondReceipt.handoff !== 'not-submitted') break; await new Promise(yes => setTimeout(yes, 100)); }
  assert.equal(secondReceipt.status, 'accepted');
  await waitFor(() => evidence.events.some(event => event.runId === second.runId && event.kind === 'turn.terminal'), 'second native terminal');
  assert.equal(evidence.requests.length, 2);
  const secondInput = JSON.stringify(evidence.requests[1].input);
  assert.ok(secondInput.includes('YOROZU_NATIVE_HISTORY_TOKEN')); assert.ok(secondInput.includes('OPENCLAW_NATIVE_ONE'));
  evidence.checks.nativeConversationHistory = true;
  assert.equal((await adapter.call('turn.submit', second)).status, 'accepted'); assert.equal(evidence.requests.length, 2); evidence.checks.noDuplicateAcceptedTurn = true;
  const held = { ...session, runId: 'stopped-native-turn', attemptId: 'stop-attempt', text: 'Start a harmless held local inference reply for the exact Stop test.' };
  let heldReceipt;
  for (let index = 0; index < 20; index++) { heldReceipt = await adapter.call('turn.submit', held); if (heldReceipt.status !== 'busy' || heldReceipt.handoff !== 'not-submitted') break; await new Promise(yes => setTimeout(yes, 100)); }
  assert.equal(heldReceipt.status, 'accepted');
  await waitFor(() => evidence.requests.length === 3 && evidence.events.some(event => event.runId === held.runId && event.kind === 'assistant.update'), 'held native inference');
  const stop = { ...held, operationId: 'exact-native-stop' };
  assert.equal((await adapter.call('run.stop', stop)).status, 'requested');
  await waitFor(() => evidence.events.some(event => event.runId === held.runId && event.kind === 'turn.terminal'), 'native Stop terminal');
  assert.equal(evidence.events.find(event => event.runId === held.runId && event.kind === 'turn.terminal').data.state, 'stopped');
  await waitFor(() => heldClosed, 'native provider transport cancellation');
  evidence.checks.nativeStop = { terminal: 'stopped', providerTransportClosed: heldClosed };
  for (const event of evidence.events) { assert.equal(event.conversationId, session.conversationId); if (event.runId) assert.ok([first.runId, second.runId, held.runId].includes(event.runId)); }
  assert.deepEqual((await adapter.call('session.snapshot', session)).tasks, []);
  await adapter.stop(); adapter = null;
  const resumed = await prepare([adapterEntry], gatewayPort);
  assert.equal(resumed.launch.isolation.policyDigest, launch.isolation.policyDigest, 'same effective endpoint/scope must preserve profile policy identity');
  adapter = await client(resumed.launch, resumed.transfer); await adapter.call('initialize', init); await adapter.call('session.open', { ...session, sessionId: opened.sessionId });
  assert.equal((await adapter.call('turn.submit', second)).status, 'accepted');
  await new Promise(yes => setTimeout(yes, 500)); assert.equal(evidence.requests.length, 3); evidence.checks.noReplayAfterCleanRestart = true;
  evidence.success = true;
} catch (error) {
  evidence.failure = { message: error.message, stack: error.stack, sessionDiagnostic: adapter?.stderr() }; process.exitCode = 1;
} finally {
  if (adapter) { try { await adapter.stop(); if (evidence.checks.realGatewayReadiness) evidence.checks.cleanNativeShutdown = true; } catch (error) { evidence.shutdownFailure = error.message; evidence.success = false; adapter.child.kill('SIGTERM'); process.exitCode = 1; } }
  for (const response of pendingResponses) response.destroy();
  if (probeChild && probeChild.exitCode === null && probeChild.signalCode === null) probeChild.kill('SIGTERM');
  for (const transfer of transfers) { try { await transfer.release(); } catch (error) { evidence.listenerReleaseFailure = error.message; evidence.success = false; process.exitCode = 1; } }
  for (const server of [provider, forbidden]) if (server) { server.closeAllConnections?.(); await new Promise(yes => server.close(yes)); }
  await writeFile(join(root, 'evidence.json'), JSON.stringify(evidence, null, 2) + '\n', { mode: 0o600 });
  console.log(JSON.stringify({ success: evidence.success, output: join(root, 'evidence.json'), checks: Object.keys(evidence.checks), failure: evidence.failure?.message }));
}

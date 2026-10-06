#!/usr/bin/env node
/** Offline proof against the actual built native registry and dispatcher, with
 * two native plugin processes and real host SQL. No model/provider/Gateway/account
 * or network listener. This does NOT claim paired chat.send lifecycle acceptance.
 */
import assert from 'node:assert/strict';
import { readFile, writeFile, mkdir, readdir } from 'node:fs/promises';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { spawn, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { uniformMemoryConfig, createMemoryHostBridge, attachMemoryHost } from './memory-plugin/memory-bridge.mjs';
const here = dirname(fileURLToPath(import.meta.url));
const [source, output, mode, actor = 'alice', phase = 'main'] = process.argv.slice(2);
if (!source?.startsWith('/') || !output?.startsWith('/')) throw new Error('Explicit source and output required');
const COMMIT = 'f04797ef4d24f3da0f9df74acd58ab773ab5f11e';
const dist = join(source, 'dist');
const sha = text => createHash('sha256').update(text).digest('hex');
async function nativeExport(prefix, exportName) {
  const files = (await readdir(dist)).filter(n => n.startsWith(prefix) && n.endsWith('.mjs'));
  for (const file of files) {
    const text = await readFile(join(dist, file), 'utf8');
    const match = text.match(new RegExp(`(?:^|[, {])${exportName} as ([A-Za-z_$][\\w$]*)[, }]`));
    if (match) return (await import(pathToFileURL(join(dist, file))))[match[1]];
  }
  throw new Error(`Native export unavailable: ${exportName}`);
}
const nativeIdentity = (actor, phase) => ({ nativeRunId: `${actor}-run-${phase}`, nativeSessionId: `${actor}-sid-${phase}`, sessionKey: `agent:${actor}:proof-${phase}` });
if (mode === 'child') {
  const build = JSON.parse(await readFile(join(dist, 'build-info.json'), 'utf8'));
  assert.equal(build.commit, COMMIT);
  await assert.rejects(() => readFile(join(dirname(output), 'sql', 'worker-memory.sqlite')), error => ['EPERM', 'EACCES'].includes(error.code));
  const workspace = join(output, 'workspace'); await mkdir(workspace, { recursive: true });
  await writeFile(join(workspace, 'MEMORY.md'), 'MUST_NOT_INJECT_FICTIONAL_NATIVE_MEMORY');
  const config = uniformMemoryConfig({ agents: { defaults: {}, entries: { [actor]: { workspace, agentDir: join(output, 'agent') } } } }, join(here, 'memory-plugin'), actor, true);
  const validate = await nativeExport('validation-core-', 'validateConfigObject');
  const validated = validate(config); assert.equal(validated.ok, true, JSON.stringify(validated));
  const load = await nativeExport('loader-', 'loadAndActivateRootPluginRegistry');
  const registry = await load({ config, workspaceDir: workspace, cache: false, throwOnLoadError: true });
  assert.deepEqual(registry.plugins.filter(p => p.status === 'loaded').map(p => p.id), ['yorozu-worker-memory']);
  assert.equal(registry.diagnostics.length, 0);
  for (const key of ['hooks', 'typedHooks', 'memoryCapabilities', 'memoryCorpusSupplements', 'memoryPromptPreparations', 'memoryPromptSupplements']) assert.equal(registry[key].length, 0, key);
  const getMemoryRuntime = await nativeExport('memory-state-', 'getMemoryRuntime');
  const flushPlan = await nativeExport('memory-state-', 'resolveMemoryFlushPlan');
  const searchConfig = await nativeExport('memory-search-', 'resolveMemorySearchConfig');
  const injection = await nativeExport('bootstrap-files-', 'resolveContextInjectionMode');
  assert.equal(getMemoryRuntime(), undefined); assert.equal(flushPlan({ cfg: config, agentId: actor }), null);
  assert.equal(searchConfig(config, actor), null); assert.equal(injection(config, actor), 'never');
  const create = await nativeExport('agent-tools-', 'createOpenClawCodingTools');
  let current = true;
  const identity = nativeIdentity(actor, phase);
  const options = { config, workspaceDir: workspace, agentDir: join(output, 'agent'), sessionKey: identity.sessionKey, agentId: actor,
    sessionId: identity.nativeSessionId, runId: identity.nativeRunId, requesterAgentIdOverride: actor, pluginToolAllowlist: ['worker_memory'],
    assertInvocationCurrent: () => { if (!current) throw new Error('Ended native run'); },
    beforeToolCallHookContext: { agentId: actor, sessionKey: identity.sessionKey, sessionId: identity.nativeSessionId, runId: identity.nativeRunId } };
  const names = create(options).map(t => t.name); assert.deepEqual(names, ['worker_memory']);
  console.log('CATALOG', actor, phase, JSON.stringify(names));
  // This is the native supported standalone-request authority seam. The effective
  // coding catalog above is checked separately; no fake native tool executor.
  const standalone = await nativeExport('openclaw-tools-', 'createOpenClawTools');
  const tool = standalone({ ...options, agentSessionKey: options.sessionKey }).find(t => t.name === 'worker_memory');
  assert(tool);
  let sequence = 0;
  const call = (request, signal = new AbortController().signal) => tool.execute(`call-${++sequence}`, request, signal);
  if (actor === 'bob') {
    const read = () => call({ action: 'read', ownerId: 'alice', key: 'note' });
    if (phase === 'shared') assert.equal((await read()).details.value, 'Fictional native SQL evidence');
    else await assert.rejects(read);
    assert.deepEqual((await call({ action: 'write', key: 'bob-note', body: 'Fictional Bob private note', operationId: 'bob-write' })).details, { ok: true });
  } else {
    assert.deepEqual((await call({ action: 'write', key: 'note', body: 'Fictional native SQL evidence', operationId: 'write-1' })).details, { ok: true });
    assert.equal((await call({ action: 'read', ownerId: 'alice', key: 'note' })).details.value, 'Fictional native SQL evidence');
    assert.deepEqual((await call({ action: 'grant', key: 'note', toAgentId: 'bob', operationId: 'share-1' })).details, { ok: true });
    assert.deepEqual((await call({ action: 'revoke', key: 'note', toAgentId: 'bob', operationId: 'revoke-1' })).details, { ok: true });
    const controller = new AbortController();
    process.on('message', message => { if (message.kind === 'approval-pending') controller.abort(); });
    await assert.rejects(() => call({ action: 'grant', key: 'note', toAgentId: 'bob', operationId: 'cancel-share' }, controller.signal));
    current = false;
    await assert.rejects(() => call({ action: 'write', key: 'note', body: 'STALE', operationId: 'write-stale' }));
  }
  console.log('NATIVE_PROOF_PASS', actor, phase); process.exit(0);
} else {
  await mkdir(output, { recursive: false, mode: 0o700 });
  assert.equal(execFileSync('/usr/bin/git', ['-C', source, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(), COMMIT);
  execFileSync('/usr/bin/git', ['-C', source, 'diff', '--quiet', 'HEAD', '--']);
  const host = join(output, 'host-code'); await mkdir(host);
  const hostSource = resolve(here, '../../runtime/src'); const sourceHashes = {};
  // Actual host implementation with ONLY relative import spelling adjusted for
  // builtin Node type stripping. Hash both forms; no fixture SQL replacement.
  for (const file of ['agent-scope', 'worker-memory', 'worker-tools']) {
    const original = await readFile(join(hostSource, `${file}.ts`), 'utf8');
    const text = original.replace('"./agent-scope.js"', '"./agent-scope.ts"');
    sourceHashes[file] = { original: sha(original), executed: sha(text) };
    await writeFile(join(host, `${file}.ts`), text);
  }
  const { WorkerMemory } = await import(pathToFileURL(join(host, 'worker-memory.ts')));
  const { workerMemoryTools } = await import(pathToFileURL(join(host, 'worker-tools.ts')));
  const sql = new WorkerMemory(join(output, 'sql'), id => ['alice', 'bob'].includes(id));
  const alice = sql.bind('alice'), bob = sql.bind('bob');
  let calls = 0, approvals = 0, cancelledApproval = false;
  async function runNative(actor, phase) {
    const root = join(output, `${actor}-${phase}`); await mkdir(root);
    const identity = nativeIdentity(actor, phase);
    const execution = { sessionId: `${actor}-host-sid-${phase}`, runId: `${actor}-host-run-${phase}`, attemptId: `${actor}-host-attempt-${phase}` };
    let child;
    const bridge = createMemoryHostBridge({ agentId: actor, callHost: async (method, envelope, authority) => {
      calls++; assert.deepEqual(envelope.execution, execution);
      const invoke = workerMemoryTools(sql.bind(actor), authority.assertCurrent, async (request, apply, signal) => {
        assert.equal(actor, 'alice'); assert.equal(request.toAgentId, 'bob'); assert.equal(request.key, 'note');
        approvals++;
        if (request.operationId === 'cancel-share') {
          const cancelled = new Promise(resolve => signal.addEventListener('abort', resolve, { once: true }));
          child.send({ kind: 'approval-pending' }); await cancelled;
          cancelledApproval = signal.aborted;
        }
        apply();
      });
      const result = await invoke(method, envelope.request, authority.signal);
      if (actor === 'alice') {
        if (envelope.request.action === 'write') await runNative('bob', 'isolated');
        if (envelope.request.action === 'grant') await runNative('bob', 'shared');
        if (envelope.request.action === 'revoke') await runNative('bob', 'revoked');
      }
      return result;
    } });
    bridge.bind({ ...identity, execution, current: () => true });
    if (process.platform !== 'darwin') throw new Error('This proof requires the actual macOS process isolation boundary');
    const policy = `(version 1)(allow default)(deny network*)(deny file-read* file-write* (subpath ${JSON.stringify(join(output, 'sql'))}) (subpath ${JSON.stringify(host)}))`;
    child = spawn('/usr/bin/sandbox-exec', ['-p', policy, process.execPath, fileURLToPath(import.meta.url), source, root, 'child', actor, phase], {
      env: { PATH: '/usr/bin:/bin', HOME: join(root, 'home'), TMPDIR: root, OPENCLAW_HOME: join(root, 'home'), OPENCLAW_STATE_DIR: join(root, 'state'),
        OPENCLAW_CONFIG_PATH: join(root, 'absent.json'), OPENCLAW_DISABLE_BONJOUR: '1', NODE_DISABLE_COMPILE_CACHE: '1' }, stdio: ['ignore', 'pipe', 'pipe', 'ipc', 'pipe'] });
    const wire = attachMemoryHost(child.stdio[4], bridge);
    let log = ''; child.stdout.on('data', b => { log += b; process.stdout.write(b); }); child.stderr.on('data', b => { log += b; process.stderr.write(b); });
    const timer = setTimeout(() => child.kill('SIGKILL'), 90000);
    const code = await new Promise((resolve, reject) => { child.once('close', resolve); child.once('error', reject); }); clearTimeout(timer); wire.close();
    await writeFile(join(root, 'native.log'), log);
    assert.equal(code, 0); assert(log.includes('NATIVE_PROOF_PASS'));
  }
  try {
    await runNative('alice', 'main');
    assert.equal(calls, 11); assert.equal(approvals, 2); assert.equal(cancelledApproval, true);
    assert.equal(alice.read('alice', 'note'), 'Fictional native SQL evidence');
    assert.throws(() => bob.read('alice', 'note')); assert.throws(() => alice.read('bob', 'bob-note'));
    await writeFile(join(output, 'receipt.json'), JSON.stringify({ nativeCommit: COMMIT, node: process.versions.node, sourceHashes,
      actualNativeCatalog: true, actualNativeDispatch: true, actualNativeProcesses: 4, realHostSql: true, nativeProcessesDeniedDirectSqlFileAccess: true,
      twoNativeAgentIsolationShareRevoke: true, nativeCancellationFencedHostApproval: true, staleNativeToolRejected: true,
      nativeMemorySlotAbsent: true, nativeMemoryHooksAndSupplementsAbsent: true, nativeSearchDisabled: true, nativeFlushPlanAbsent: true, nativeInjectionModeNever: true,
      gatewaySendProof: false, capabilityAdvertised: false }, null, 2));
  } finally { sql.close(); }
}

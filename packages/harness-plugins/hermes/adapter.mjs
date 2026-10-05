#!/usr/bin/env node
import { promises as sealedFs, constants as sealedConstants } from "node:fs";
/** Hermes owns the agent loop. This process translates transport and receipts only. */
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, mkdtemp, readFile, writeFile, readdir, lstat, realpath, copyFile, rm, rename, open } from 'node:fs/promises';
import { resolve, join, dirname, isAbsolute, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID, createHash } from 'node:crypto';

/** Bound the actual JSON-RPC envelope, not raw UTF-8 text. Presentation never interrupts native work. */
function boundedProjection(emit, frame, limit = 256 * 1024) {
  const fits = value => Buffer.byteLength(JSON.stringify({ jsonrpc: '2.0', method: 'harness.event', params: value }) + '\n') <= limit;
  if (fits(frame)) { emit(frame); return true; }
  const unavailable = { ...frame, eventId: `${frame.eventId}:size`, kind: 'capability.unavailable',
    data: { capability: 'replySize', reason: 'Encoded projection exceeded the frame bound; native work was not interrupted' } };
  if (fits(unavailable)) emit(unavailable);
  // Terminal evidence must still reach the host even when its presentation cannot.
  if (frame.kind === 'turn.terminal') {
    const terminal = { ...frame, data: { ...frame.data, text: '', reason: 'Reply omitted: encoded projection exceeded the frame bound' } };
    if (fits(terminal)) emit(terminal);
  }
  return false;
}

/** Independent content pin for the reviewed f97608f source export, including its
 * sealed .git metadata. Not a manifest-supplied digest or an integrity bypass.
 * Rows use package-hermes-runtime.py fields, sorted by full UTF-8 path
 * (not Python Path component ordering), with mode/path/sha256 key order.
 * Source is immutable code under the host-selected signed bundle, never writable
 * agent state. Both host and child rehash it; no Git/toolchain is invoked here.
 */
export const SEALED_HERMES_SOURCE_SHA256 = "bfee32553ccf2291cbd300b1fceed350487578f414a548b3bb7c5138cd4d0145";
export async function verifySealedHermesSource(source) {
  const bad = () => new Error("Sealed Hermes source integrity check failed");
  if (!isAbsolute(source) || resolve(source) !== source || await sealedFs.realpath(source) !== source) throw bad();
  const rows = [];
  let bytes = 0, visited = 0;
  async function walk(directory) {
    const stat = await sealedFs.lstat(directory);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.mode & 0o022) throw bad();
    for (const name of await sealedFs.readdir(directory)) {
      if (++visited > 65536) throw bad();
      const path = join(directory, name), s = await sealedFs.lstat(path);
      if (s.isDirectory()) { await walk(path); continue; }
      // This sealed export contains no links, including anywhere in .git.
      if (!s.isFile() || s.isSymbolicLink() || s.nlink !== 1 || s.mode & 0o022 || s.size > 256 * 1024 * 1024 || (bytes += s.size) > 2 * 1024 * 1024 * 1024) throw bad();
      const file = await sealedFs.open(path, sealedConstants.O_RDONLY | sealedConstants.O_NOFOLLOW | sealedConstants.O_NONBLOCK);
      try {
        const opened = await file.stat();
        if (!opened.isFile() || opened.nlink !== 1 || opened.dev !== s.dev || opened.ino !== s.ino || opened.size !== s.size || opened.mode !== s.mode) throw bad();
        const digest = createHash("sha256"); let read = 0;
        for await (const chunk of file.createReadStream({ autoClose: false })) {
          if ((read += chunk.length) > s.size) throw bad();
          digest.update(chunk);
        }
        if (read !== s.size) throw bad();
        rows.push({ mode: s.mode & 0o111 ? 493 : 420, path: "source/" + path.slice(source.length + 1), sha256: digest.digest("hex") });
      } finally { await file.close(); }
    }
  }
  await walk(source);
  rows.sort((a, b) => Buffer.compare(Buffer.from(a.path), Buffer.from(b.path)));
  if (createHash("sha256").update(JSON.stringify(rows)).digest("hex") !== SEALED_HERMES_SOURCE_SHA256) throw bad();
}

export const UPSTREAM = Object.freeze({ version: '0.21.5', commit: 'f97608f178d1ffeca59860195ab7da295f7c8e5f' });
const FRAME_LIMIT = 256 * 1024;
const TEXT_LIMIT = 192 * 1024;
const MAX_PENDING = 32;
const ACTIVE = new Set(['running', 'waiting', 'stopping']);
const exec = promisify(execFile);
const NATIVE_TOOLS = ['file', 'terminal', 'delegation', 'memory', 'web', 'browser'];
const RESOURCE_TOOLS = ['file', 'terminal', 'web', 'browser'];
const nativeTools = allowed => [...new Set([...allowed.filter(name => RESOURCE_TOOLS.includes(name)), 'memory', 'delegation'])].sort();
const HOST_TOOLS = [...NATIVE_TOOLS, 'team', 'computer'];
const PACKAGE_ROOT = dirname(fileURLToPath(import.meta.url));
export const EXTENSIONS = Object.freeze({ version: 1, connectedLifecycle: false, conversationActions: true, autonomousEvents: false, agentMessaging: true });

export function validateLifecycle(params) {
  const lifecycle = params.lifecycle ?? { version: 1, mode: 'managed' };
  object(lifecycle, ['version', 'mode', 'connectionId'], 'lifecycle');
  if (lifecycle.version !== 1 || !['managed', 'connected'].includes(lifecycle.mode)) throw invalid('unsupported lifecycle');
  if (lifecycle.mode === 'connected') throw new ProtocolError(-32010, 'Hermes connected lifecycle is unavailable: native last-peer detach can reap a live session; no connection was made');
  if (lifecycle.connectionId !== undefined || params.connection !== undefined) throw invalid('managed lifecycle cannot adopt a connection');
  return lifecycle;
}

export class ProtocolError extends Error {
  constructor(code, message, data) { super(message); this.code = code; this.data = data; }
}
const invalid = message => new ProtocolError(-32602, message);
function required(value, name, limit = 4096) {
  if (typeof value !== 'string' || !value.trim() || Buffer.byteLength(value) > limit) throw invalid(`${name} must be a bounded nonempty string`);
  return value;
}
function text(value, limit = TEXT_LIMIT) { return typeof value === 'string' ? Buffer.from(value).subarray(0, limit).toString('utf8') : ''; }
function object(value, keys, name) {
  if (!value || typeof value !== 'object' || Array.isArray(value) || Object.keys(value).some(key => !keys.includes(key))) throw invalid(`${name} has unsupported fields`);
  return value;
}
function contained(root, path) { const rel = relative(root, path); return rel === '' || (!rel.startsWith('..' + '/') && rel !== '..' && !isAbsolute(rel)); }
function tools(value, name) {
  if (!Array.isArray(value) || value.length > HOST_TOOLS.length || value.some(tool => !HOST_TOOLS.includes(tool)) || new Set(value).size !== value.length) throw invalid(`${name} contains an unsupported or duplicate tool`);
  return [...value].sort();
}
/** Trusted host configuration; an attestation is a handshake, never sandbox proof. */
export async function validateAgentScope(params) {
  if (params.agentId === undefined) {
    if (params.scope !== undefined || params.isolation !== undefined || params.platform !== undefined) throw invalid('agentId is required for product scope');
    return null; // Legacy synthetic fixtures make no product scope claim.
  }
  const agentId = required(params.agentId, 'agentId', 128);
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(agentId)) throw invalid('agentId must be a stable opaque identifier');
  const isolation = object(params.isolation, ['backend', 'agentId', 'policyDigest'], 'isolation');
  if (isolation.backend !== 'macos-seatbelt-v1' || isolation.agentId !== agentId || !/^[a-f0-9]{64}$/.test(isolation.policyDigest)) throw invalid('matching macOS host sandbox attestation is required');
  const scope = object(params.scope, ['allowedTools', 'directories', 'workspace', 'memoryDir'], 'scope');
  const allowedTools = tools(scope.allowedTools, 'scope.allowedTools');
  const platform = params.platform === undefined ? { team: false, computer: false } : object(params.platform, ['team', 'computer', 'peers'], 'platform');
  if (typeof platform.team !== 'boolean' || typeof platform.computer !== 'boolean') throw invalid('platform flags must be explicit booleans');
  if (platform.computer || allowedTools.includes('computer')) throw invalid('computer platform broker is unsupported');
  const peers = platform.peers ?? [];
  if (!Array.isArray(peers) || peers.length > 32 || !platform.team && peers.length) throw invalid('platform peers must be bounded explicit team membership');
  const peerIds = new Set();
  for (const peer of peers) {
    object(peer, ['agentId', 'name', 'pluginId'], 'platform peer');
    required(peer.agentId, 'peer agentId', 128); required(peer.name, 'peer name', 128);
    if (peer.pluginId !== 'hermes' || peer.agentId === agentId || peerIds.has(peer.agentId)) throw invalid('platform peer identity is invalid');
    peerIds.add(peer.agentId);
  }
  for (const key of ['workspace', 'memoryDir']) if (!isAbsolute(required(scope[key], `scope.${key}`))) throw invalid(`scope.${key} must be absolute`);
  if (!Array.isArray(scope.directories) || scope.directories.length > 64) throw invalid('scope.directories must be bounded');
  const directories = [];
  for (const item of scope.directories) {
    object(item, ['path', 'access'], 'directory');
    if (!isAbsolute(required(item.path, 'directory.path')) || !['read', 'write'].includes(item.access)) throw invalid('directory needs an absolute path and read/write access');
    const path = await realpath(item.path);
    if (!(await lstat(path)).isDirectory()) throw invalid('scope grants must refer to directories');
    if (path === '/') throw invalid('unrestricted filesystem roots are unsupported');
    if (directories.some(grant => grant.path === path)) throw invalid('duplicate scope directory');
    directories.push({ path, access: item.access });
  }
  const workspace = await realpath(scope.workspace);
  if (!(await lstat(workspace)).isDirectory()) throw invalid('workspace must be a directory');
  const memoryDir = allowedTools.includes('memory') ? await realpath(scope.memoryDir) : resolve(scope.memoryDir);
  if (allowedTools.includes('memory') && !(await lstat(memoryDir)).isDirectory()) throw invalid('private memory must be a directory');
  if (workspace !== await realpath(params.workspace)) throw invalid('workspace must match the immutable agent scope');
  if (!directories.some(grant => contained(grant.path, workspace))) {
    if (!isAbsolute(required(params.profileRoot, 'profileRoot')) || !contained(await realpath(params.profileRoot), workspace)) throw invalid('workspace is outside agent directory scope and owned runtime scratch');
  }
  if (allowedTools.includes('memory') && !directories.some(grant => grant.access === 'write' && contained(grant.path, memoryDir))) throw invalid('enabled private memory directory needs a write grant');
  const normalized = { allowedTools, directories: directories.sort((a, b) => a.path.localeCompare(b.path)), workspace, memoryDir };
  return Object.freeze({ agentId, scope: normalized, isolation: { ...isolation }, platform: { ...platform, peers: peers.map(peer => ({ ...peer })) },
    scopeDigest: createHash('sha256').update(JSON.stringify(normalized)).digest('hex') });
}
function wire(frame) {
  const value = JSON.stringify(frame) + '\n';
  if (Buffer.byteLength(value) > FRAME_LIMIT) throw invalid('frame exceeds 256 KiB');
  return value;
}
function readFrames(stream, onFrame, onFailure) {
  let buffer = Buffer.alloc(0);
  stream.on('data', chunk => {
    buffer = Buffer.concat([buffer, Buffer.from(chunk)]);
    for (;;) {
      const newline = buffer.indexOf(10);
      if (newline < 0) break;
      if (newline > FRAME_LIMIT) { onFailure(new Error('upstream frame exceeds 256 KiB')); return; }
      const line = buffer.subarray(0, newline).toString('utf8');
      buffer = buffer.subarray(newline + 1);
      if (!line.trim()) continue;
      try { onFrame(JSON.parse(line)); } catch { onFailure(new Error('invalid JSON-RPC frame')); return; }
    }
    if (buffer.length > FRAME_LIMIT) onFailure(new Error('unterminated frame exceeds 256 KiB'));
  });
}

export function mergeNativeConfiguration(previousConfig, config, agent) {
  const merged = { ...previousConfig, ...config,
    agent: { ...previousConfig.agent, ...config.agent },
    display: { ...previousConfig.display, ...config.display },
    security: { ...previousConfig.security, ...config.security } };
  const previousDisabled = Array.isArray(previousConfig.agent?.disabled_toolsets) ? previousConfig.agent.disabled_toolsets : [];
  const oldPrototype = previousConfig.desktop?.auto_continue?.enabled === false && previousConfig.approvals?.mode === 'manual'
    && previousConfig.delegation?.max_spawn_depth === 3 && previousConfig.delegation?.max_concurrent_children === 2;
  // The previous prototype generated these behavioral denials from host flags.
  // Otherwise retain native-owned non-resource disabled toolsets on restart.
  merged.agent.disabled_toolsets = [...new Set([...previousDisabled.filter(name => !RESOURCE_TOOLS.includes(name)
    && !['cronjob', 'computer_use'].includes(name) && !(oldPrototype && ['memory', 'delegation'].includes(name))), ...config.agent.disabled_toolsets])];
  if (agent) {
    const nativePlugins = Array.isArray(previousConfig.plugins?.enabled) ? previousConfig.plugins.enabled : [];
    merged.plugins = { ...previousConfig.plugins, ...config.plugins,
      enabled: [...new Set([...nativePlugins, 'yorozu-platform'])],
      entries: { ...previousConfig.plugins?.entries, ...config.plugins.entries } };
  }
  return merged;
}

/** An explicit host-owned directory, never an installed Hermes or Codex profile. */
export async function prepareRuntime(params) {
  validateLifecycle(params);
  if (params.protocolVersion !== 1 || params.upstreamVersion !== UPSTREAM.version) throw invalid('unsupported protocol or Hermes version');
  for (const key of ['profileRoot', 'workspace', 'python', 'sourcePath']) {
    required(params[key], key);
    if (!isAbsolute(params[key])) throw invalid(`${key} must be absolute`);
  }
  const agent = await validateAgentScope(params);
  if (!agent) throw invalid('agentId and product scope are required before preparing a real runtime');
  const sealed = params.sourceIntegrity !== undefined;
  if (sealed) {
    // The root arrives on the existing private host-to-child initialize pipe.
    // It is not self-authenticating: bind it independently to this reviewed code
    // pin and rehash source bytes before Python can load any Hermes module.
    const seal = object(params.sourceIntegrity, ['kind', 'sourceSha', 'inventorySha256'], 'source integrity');
    if (seal.kind !== 'sealed-inventory-v1' || seal.sourceSha !== UPSTREAM.commit || seal.inventorySha256 !== SEALED_HERMES_SOURCE_SHA256)
      throw invalid('unsupported source integrity contract');
    await verifySealedHermesSource(params.sourcePath);
  }
  const sourcePath = await realpath(params.sourcePath);
  if (sourcePath !== params.sourcePath || (await lstat(join(sourcePath, '.git'))).isSymbolicLink()) throw invalid('source and Git metadata must not be symlinks');
  const metadata = await readFile(join(sourcePath, 'pyproject.toml'), 'utf8');
  if (!/^version\s*=\s*"0\.21\.5"\s*$/m.test(metadata)) throw invalid('Hermes source version does not match the pinned release');
  const workspace = await realpath(params.workspace);
  await mkdir(params.profileRoot, { recursive: true, mode: 0o700 });
  const profileRoot = await realpath(params.profileRoot);
  if (!sealed) {
    // Developer checkout contract remains Git-based. The shipping host always
    // selects sealed-inventory-v1, whose independently pinned hash is checked above.
    const gitOptions = { maxBuffer: 1024, env: { PATH: '/usr/bin:/bin', GIT_OPTIONAL_LOCKS: '0', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' } };
    const revision = await exec('git', ['-C', sourcePath, 'rev-parse', 'HEAD'], gitOptions);
    if (revision.stdout.trim() !== UPSTREAM.commit) throw invalid('Hermes source commit does not match the pinned release');
    const verification = await mkdtemp(join(profileRoot, '.hermes-source-verification-'));
    try {
      const privateOptions = { ...gitOptions, env: { ...gitOptions.env, GIT_INDEX_FILE: join(verification, 'index') } };
      const prefix = ['-C', sourcePath, '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null'];
      await exec('git', [...prefix, 'read-tree', UPSTREAM.commit], privateOptions);
      await exec('git', [...prefix, 'diff', '--no-ext-diff', '--no-textconv', '--quiet', 'HEAD', '--'], privateOptions);
    } finally { await rm(verification, { recursive: true, force: true }); }
  }
  const hermesHome = join(profileRoot, 'hermes-runtime');
  await mkdir(hermesHome, { recursive: true, mode: 0o700 });
  if ((await lstat(hermesHome)).isSymbolicLink()) throw invalid('Hermes runtime must not be a symlink');
  const marker = join(hermesHome, '.yorozu-owner.json');
  const ownership = { schema: 1, pluginId: 'hermes', upstreamVersion: UPSTREAM.version, upstreamCommit: UPSTREAM.commit,
    ...(agent ? { agentId: agent.agentId } : {}) };
  try {
    const markerStat = await lstat(marker);
    if (!markerStat.isFile() || markerStat.isSymbolicLink() || markerStat.size > 1024) throw invalid('runtime ownership marker is invalid');
    const previous = JSON.parse(await readFile(marker, 'utf8'));
    if (JSON.stringify(previous) !== JSON.stringify(ownership)) throw invalid('runtime belongs to a different adapter version or agent');
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    if ((await readdir(hermesHome)).length) throw invalid('refusing to adopt an existing Hermes profile');
    await writeFile(marker, JSON.stringify(ownership), { flag: 'wx', mode: 0o600 });
  }
  // This initial slice supports an explicit loopback proof provider only. It never
  // probes installed authentication or falls through to a billed provider.
  let fixture;
  if (params.providerConfigPath) {
    const file = await realpath(params.providerConfigPath);
    if (relative(profileRoot, file).startsWith('..') || isAbsolute(relative(profileRoot, file))) throw invalid('provider config must be inside the explicit profile root');
    const stat = await lstat(file);
    if (!stat.isFile() || stat.size > 4096) throw invalid('provider config must be a bounded JSON file');
    try { fixture = JSON.parse(await readFile(file, 'utf8')); }
    catch { throw invalid('provider config is invalid JSON'); }
    if (Object.keys(fixture).some(key => !['baseUrl', 'model', 'apiMode', 'bearer'].includes(key))) throw invalid('provider config contains unsupported fields');
    const endpoint = new URL(required(fixture.baseUrl, 'baseUrl'));
    if (endpoint.protocol !== 'http:' || !['127.0.0.1', '[::1]'].includes(endpoint.hostname) || endpoint.username || endpoint.password) throw invalid('only an explicit loopback proof provider is supported');
    required(fixture.model, 'model');
    if (fixture.bearer !== undefined && (typeof fixture.bearer !== 'string' || !/^[A-Za-z0-9._~-]{32,256}$/.test(fixture.bearer))) throw invalid('host broker bearer is invalid');
    if (fixture.apiMode !== 'codex_responses') throw invalid('proof provider must use the native Responses transport');
  }
  const provider = fixture ? 'custom:yorozu-local-proof' : null;
  if (params.provider && params.provider !== provider) throw invalid('provider is not available in this isolated profile');
  if (params.model && params.model !== fixture?.model) throw invalid('model is not available in this isolated profile');
  const config = {
    model: { provider: provider ?? 'custom:yorozu-unconfigured', default: fixture?.model ?? 'unconfigured' },
    agent: { disabled_toolsets: ['cronjob', 'computer_use'] }, fallback_model: [],
    display: { busy_input_mode: 'queue' },
    // Curated runtimes never install changing dependencies or a latest-release
    // scanner on demand. Until a pinned scanner is bundled, terminal scanning
    // fails closed against this explicit, unavailable path.
    security: { allow_lazy_installs: false, tirith_enabled: true,
      tirith_path: join(hermesHome, 'curated-tirith-unavailable'), tirith_fail_open: false },
    custom_providers: fixture ? [{ name: 'yorozu-local-proof', base_url: fixture.baseUrl, api_key: fixture.bearer ?? 'yorozu-loopback-proof', api_mode: 'codex_responses' }] : [],
  };
  if (agent) {
    config.agent.disabled_toolsets = [...RESOURCE_TOOLS.filter(name => !agent.scope.allowedTools.includes(name)), 'cronjob', 'computer_use'];
    config.platform_toolsets = { cli: nativeTools(agent.scope.allowedTools) };
    config.plugins = { enabled: ['yorozu-platform'], entries: { 'yorozu-platform': { settings: { team: agent.platform.team, peers: agent.platform.peers } } } };
    const pluginsRoot = join(hermesHome, 'plugins'), pluginRoot = join(pluginsRoot, 'yorozu-platform');
    for (const directory of [pluginsRoot, pluginRoot]) {
      await mkdir(directory, { recursive: true, mode: 0o700 });
      if ((await lstat(directory)).isSymbolicLink()) throw invalid('runtime plugin directories must not be symlinks');
    }
    for (const file of ['__init__.py', 'plugin.yaml']) {
      const destination = join(pluginRoot, file);
      try { if ((await lstat(destination)).isSymbolicLink()) throw invalid('runtime platform files must not be symlinks'); }
      catch (error) { if (error.code !== 'ENOENT') throw error; }
      await copyFile(join(PACKAGE_ROOT, 'platform', file), destination);
    }
  }
  // JSON is a YAML subset; no YAML dependency or arbitrary inherited config.
  const configPath = join(hermesHome, 'config.yaml');
  try { if ((await lstat(configPath)).isSymbolicLink()) throw invalid('runtime config must not be a symlink'); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
  // Native choices (including approval/autonomy/delegation/personality settings)
  // survive a restart. Only this host's resource and broker bindings are reapplied.
  let previousConfig = {};
  try {
    const encoded = await readFile(configPath, 'utf8');
    if (Buffer.byteLength(encoded) > 1024 * 1024) throw invalid('native configuration exceeds its bound');
    try { previousConfig = JSON.parse(encoded); }
    catch {
      try {
        const decoded = await exec(params.python, ['-c', 'import json,sys,yaml; print(json.dumps(yaml.safe_load(open(sys.argv[1])) or {}))', configPath], {
          cwd: sourcePath, env: { PATH: `${dirname(params.python)}:/usr/bin:/bin`, HOME: profileRoot, PYTHONNOUSERSITE: '1', PYTHONDONTWRITEBYTECODE: '1' }, maxBuffer: 1024 * 1024,
        });
        previousConfig = JSON.parse(decoded.stdout);
      } catch { throw invalid('native configuration could not be parsed; its existing file was preserved'); }
    }
    if (!previousConfig || typeof previousConfig !== 'object' || Array.isArray(previousConfig)) throw invalid('native configuration must be a mapping');
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const merged = mergeNativeConfiguration(previousConfig, config, agent);
  await writeFile(configPath, JSON.stringify(merged, null, 2) + '\n', { mode: 0o600 });
  const home = join(profileRoot, 'isolated-home');
  const codexHome = join(profileRoot, 'isolated-codex');
  for (const directory of [home, codexHome]) {
    await mkdir(directory, { recursive: true, mode: 0o700 });
    if ((await lstat(directory)).isSymbolicLink()) throw invalid('isolated homes must not be symlinks');
  }
  return {
    workspace, sourcePath, python: params.python, provider, model: fixture?.model, agent,
    messageJournalPath: join(profileRoot, 'adapter-messages-v1.json'),
    authAvailable: Boolean(fixture),
    env: {
      PATH: `${dirname(params.python)}:/usr/bin:/bin:/usr/sbin:/sbin`,
      HOME: home, CODEX_HOME: codexHome, HERMES_HOME: hermesHome,
      TMPDIR: join(profileRoot, 'tmp'), LANG: 'en_US.UTF-8',
      PYTHONUNBUFFERED: '1', PYTHONDONTWRITEBYTECODE: '1', PYTHONNOUSERSITE: '1',
      HERMES_DISABLE_LAZY_INSTALLS: '1',
      TIRITH_ENABLED: '1', TIRITH_BIN: config.security.tirith_path, TIRITH_FAIL_OPEN: '0',
      ...(agent ? { HERMES_TUI_TOOLSETS: [...nativeTools(agent.scope.allowedTools),
        ...(agent.platform.team ? ['yorozu_platform'] : []), 'yorozu_empty'].join(',') } : {}),
      // No inherited env, .env, sidecars, auth variables or scheduler settings.
    },
  };
}

export class NativeGateway {
  constructor(child) {
    this.child = child; this.pending = new Map(); this.nextId = 0; this.closed = false;
    this.listeners = new Set(); this.closeListeners = new Set();
    this.ready = new Promise((resolveReady, rejectReady) => {
      this.resolveReady = resolveReady; this.rejectReady = rejectReady;
      this.readyTimer = setTimeout(() => this.fail(new Error('Hermes gateway readiness timed out')), 30_000);
    });
    readFrames(child.stdout, frame => this.receive(frame), error => this.fail(error));
    // Diagnostics never contain stdout protocol or unlimited upstream logs.
    let remaining = 16 * 1024;
    child.stderr.on('data', bytes => { if (remaining > 0) { const chunk = bytes.subarray(0, remaining); remaining -= chunk.length; process.stderr.write(chunk); } });
    child.on('error', error => this.fail(error));
    child.on('exit', (code, signal) => this.finish(`Hermes exited (${signal ?? code ?? 'unknown'})`));
    child.stdin.on('error', error => this.fail(error));
  }
  onFrame(listener) { this.listeners.add(listener); return () => this.listeners.delete(listener); }
  onClose(listener) { this.closeListeners.add(listener); return () => this.closeListeners.delete(listener); }
  receive(frame) {
    if (this.closed) return;
    if (frame.jsonrpc !== '2.0') throw new Error('invalid Hermes JSON-RPC version');
    if (frame.method === 'event' && frame.params?.type === 'gateway.ready') {
      clearTimeout(this.readyTimer); this.epoch = frame.params.payload?.replay_epoch; this.resolveReady(frame.params.payload); return;
    }
    if (frame.id !== undefined && !frame.method) {
      const pending = this.pending.get(frame.id);
      if (!pending) return;
      clearTimeout(pending.timer); this.pending.delete(frame.id);
      if (frame.error) pending.reject(new ProtocolError(frame.error.code, text(frame.error.message, 2048)));
      else pending.resolve(frame.result);
      return;
    }
    for (const listener of this.listeners) listener(frame);
  }
  write(frame) {
    if (this.closed || this.child.stdin.destroyed) throw new ProtocolError(-32002, 'Hermes runtime is closed');
    if (this.child.stdin.writableLength > 8 * 1024 * 1024) { this.fail(new Error('Hermes input queue exceeded its bound')); throw new ProtocolError(-32002, 'runtime input queue is full'); }
    this.child.stdin.write(wire(frame));
  }
  call(method, params) {
    if (this.pending.size >= MAX_PENDING) return Promise.reject(new ProtocolError(-32003, 'too many pending Hermes operations'));
    const id = ++this.nextId;
    return new Promise((resolveCall, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(new ProtocolError(-32004, `Hermes ${method} acknowledgement timed out; outcome is unknown`)); }, 30_000);
      this.pending.set(id, { resolve: resolveCall, reject, timer });
      try { this.write({ jsonrpc: '2.0', id, method, params }); } catch (error) { clearTimeout(timer); this.pending.delete(id); reject(error); }
    });
  }
  respond(id, result, error) { this.write({ jsonrpc: '2.0', id, ...(error ? { error } : { result }) }); }
  fail(error) { this.finish(error.message); this.child.kill('SIGTERM'); }
  finish(reason) {
    if (this.closed) return;
    this.closed = true; clearTimeout(this.readyTimer); this.rejectReady(new Error(reason));
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(new ProtocolError(-32002, 'Hermes runtime ended; outcome is unknown')); }
    this.pending.clear();
    for (const listener of this.closeListeners) listener(reason);
  }
  async shutdown() {
    if (this.closed) return;
    this.child.stdin.end();
    await new Promise(resolveExit => {
      const timer = setTimeout(() => { this.child.kill('SIGTERM'); resolveExit(); }, 2000);
      this.child.once('exit', () => { clearTimeout(timer); resolveExit(); });
    });
  }
}

/** Exclusive inert profile lease. Never infer orphan safety from PID absence. */
export async function acquireProfileLock(profileRoot) {
  await mkdir(profileRoot, { recursive: true, mode: 0o700 });
  const lock = join(await realpath(profileRoot), '.hermes-adapter-owner.lock');
  try { await mkdir(lock, { mode: 0o700 }); }
  catch (error) { if (error.code === 'EEXIST') throw invalid('Hermes profile is locked; orphan ownership requires explicit reconciliation'); throw error; }
  let released = false;
  return async () => { if (released) return; released = true; await rm(lock, { recursive: true }); };
}

async function launchGateway(params, preload) {
  if (!await validateAgentScope(params)) throw invalid('agentId and product scope are required before launch');
  if (!isAbsolute(required(params.profileRoot, 'profileRoot'))) throw invalid('profileRoot must be absolute');
  const release = await acquireProfileLock(params.profileRoot);
  let child;
  try {
    const runtime = await prepareRuntime(params);
    await preload?.(runtime);
    if (!runtime.authAvailable) {
      // Do not even start upstream's provider prewarm/auth resolution until an
      // explicit supported provider has been authorized for this fresh profile.
      return { ...runtime, gateway: {
        closed: false, onFrame() {}, onClose() {},
        async call(method) { if (method === 'client.capabilities') return {}; throw new ProtocolError(-32010, 'authentication is unsupported'); },
        async shutdown() { this.closed = true; await release(); },
      } };
    }
    await mkdir(runtime.env.TMPDIR, { recursive: true, mode: 0o700 });
    child = spawn(runtime.python, [join(PACKAGE_ROOT, 'bootstrap.py')], {
      cwd: runtime.sourcePath, env: runtime.env, stdio: ['pipe', 'pipe', 'pipe'],
    });
    child.once('exit', () => { void release().catch(() => {}); });
    const gateway = new NativeGateway(child);
    await gateway.ready;
    return { ...runtime, gateway };
  } catch (error) {
    if (child) child.kill('SIGTERM'); // Keep lock until observed exit; never take over an orphan.
    else await release();
    throw error;
  }
}

async function durableJSON(path, value) {
  const temporary = `${path}.${randomUUID()}.tmp`;
  const file = await open(temporary, 'wx', 0o600);
  try { await file.writeFile(JSON.stringify(value) + '\n'); await file.sync(); }
  finally { await file.close(); }
  await rename(temporary, path);
  const directory = await open(dirname(path), 'r');
  try { await directory.sync(); } finally { await directory.close(); }
}

function peerMessage(params) {
  object(params, ['version', 'messageId', 'exchangeId', 'deliveryId', 'attemptId', 'sessionId', 'origin', 'fromAgentId', 'toAgentId', 'text', 'createdAt'], 'agent message');
  if (params.version !== 1) throw invalid('unsupported agent message version');
  for (const key of ['messageId', 'exchangeId', 'deliveryId', 'attemptId', 'sessionId']) required(params[key], key, 512);
  for (const key of ['fromAgentId', 'toAgentId']) required(params[key], key, 128);
  const origin = object(params.origin, ['version', 'agentId', 'pluginId', 'conversationId', 'sessionId', 'workId', 'bindingEpoch'], 'message origin');
  if (origin.version !== 1 || !['hermes', 'openclaw'].includes(origin.pluginId) || origin.agentId !== params.fromAgentId) throw invalid('message origin does not match sender');
  for (const key of ['agentId', 'conversationId', 'sessionId', 'bindingEpoch']) required(origin[key], `origin.${key}`, 512);
  if (origin.workId !== undefined) required(origin.workId, 'origin.workId', 512);
  if (!Number.isFinite(params.createdAt) || params.createdAt < 0) throw invalid('createdAt must be a nonnegative host timestamp');
  required(params.text, 'message text', 32 * 1024);
  return { version: 1, messageId: params.messageId, exchangeId: params.exchangeId, deliveryId: params.deliveryId,
    attemptId: params.attemptId, sessionId: params.sessionId, origin: { version: 1, agentId: origin.agentId,
      pluginId: origin.pluginId, conversationId: origin.conversationId, sessionId: origin.sessionId,
      ...(origin.workId ? { workId: origin.workId } : {}), bindingEpoch: origin.bindingEpoch }, fromAgentId: params.fromAgentId,
    toAgentId: params.toAgentId, text: params.text, createdAt: params.createdAt };
}
const messageFingerprint = message => JSON.stringify({ ...message, attemptId: undefined, sessionId: undefined });

/** The gateway dependency is also useful to embedders; no model runs in this host. */
export function createAdapter({ emit, launch = launchGateway }) {
  const sessions = new Map(); const liveSessions = new Map(); const requests = new Map();
  const inbox = new Map(); const retired = new Map(); let messageWriting = Promise.resolve();
  let runtime; let initialized = false; let initializing = false; let opening = null;
  const nonce = randomUUID(); let sequence = 0;
  const blockedProjections = new Set();
  function event(session, kind, data, run = session?.current) {
    const key = run && JSON.stringify([session?.conversationId, run.runId, run.attemptId]);
    if (key && blockedProjections.has(key)) {
      if (kind === 'assistant.update') return;
      if (kind === 'turn.terminal') data = { ...data, text: '' };
    }
    const projected = boundedProjection(emit, { protocolVersion: 1, conversationId: session?.conversationId ?? '',
      ...(run ? { runId: run.runId, attemptId: run.attemptId } : {}), eventId: `${nonce}:${++sequence}`, kind, data });
    if (!projected && key) blockedProjections.add(key);
    if (kind === 'turn.terminal') blockedProjections.delete(key);
  }
  function sessionFor(params) {
    const session = sessions.get(required(params.conversationId, 'conversationId'));
    if (!session) throw invalid('conversation is not open');
    if (params.bindingId !== undefined && params.bindingId !== session.bindingId) throw invalid('binding does not own this conversation');
    return session;
  }
  function currency(params) {
    for (const key of ['runId', 'attemptId']) required(params[key], key);
  }
  function currentTask(params) {
    const session = sessionFor(params); currency(params);
    const task = session.tasks.get(required(params.taskId, 'taskId'));
    if (!task || task.originRunId !== params.runId || task.originAttemptId !== params.attemptId || !ACTIVE.has(task.state)) return { session, reason: 'task is stale, settled, or owned by another attempt' };
    return { session, task };
  }
  function publishTask(session, task) {
    event(session, 'task.changed', { taskId: task.taskId,
      ...(task.parentTaskId ? { parentTaskId: task.parentTaskId } : {}), originRunId: task.originRunId,
      title: task.title, state: task.state, ...(task.text ? { text: task.text } : {}),
      canSteer: ACTIVE.has(task.state) && task.state !== 'stopping' && task.canSteer,
      canStop: ACTIVE.has(task.state) && task.canStop }, { runId: task.originRunId, attemptId: task.originAttemptId });
  }
  async function loadMessages() {
    if (!runtime.messageJournalPath) return;
    try {
      const stat = await lstat(runtime.messageJournalPath);
      if (!stat.isFile() || stat.isSymbolicLink() || stat.size > 3 * 1024 * 1024) throw invalid('message journal is not a bounded regular file');
      const saved = JSON.parse(await readFile(runtime.messageJournalPath, 'utf8'));
      object(saved, ['version', 'agentId', 'messages', 'retired'], 'message journal');
      if (saved.version !== 1 || saved.agentId !== runtime.agent?.agentId || !Array.isArray(saved.messages) || saved.messages.length > 64) throw invalid('message journal ownership is invalid');
      if (saved.retired !== undefined) {
        if (!Array.isArray(saved.retired) || saved.retired.length > 1024) throw invalid('retired message bound exceeded');
        for (const entry of saved.retired) {
          if (!Array.isArray(entry) || entry.length !== 2 || typeof entry[1] !== 'string' || !/^[a-f0-9]{64}$/.test(entry[1]) || retired.has(entry[0])) throw invalid('invalid retired message identity');
          required(entry[0], 'retired messageId', 512); retired.set(...entry);
        }
      }
      for (const entry of saved.messages) {
        const message = peerMessage(entry);
        if (inbox.has(message.messageId) || retired.has(message.messageId) || message.toAgentId !== runtime.agent?.agentId) throw invalid('message journal recipient or identity is invalid');
        inbox.set(message.messageId, message);
      }
    } catch (error) { if (error.code !== 'ENOENT') throw error; }
  }
  const journal = (messages = [...inbox.values()], receipts = [...retired]) => ({ version: 1, agentId: runtime.agent.agentId, messages, retired: receipts });
  const fingerprintHash = message => createHash('sha256').update(messageFingerprint(message)).digest('hex');
  async function deliverMessage(params) {
    const message = peerMessage(params);
    const session = [...sessions.values()].find(item => item.storedId === message.sessionId);
    if (!runtime.agent?.platform.team || !runtime.messageJournalPath || message.toAgentId !== runtime.agent.agentId
      || !runtime.agent.platform.peers.some(peer => peer.agentId === message.fromAgentId && peer.pluginId === message.origin.pluginId)) return { status: 'rejected', handoff: 'not-submitted', reason: 'no selected peer/native messaging inbox owns this agent/session' };
    if (!session) return { status: 'busy', handoff: 'not-submitted', reason: 'recipient session is not open; host retains custody' };
    const fingerprint = messageFingerprint(message);
    const operation = messageWriting.then(async () => {
      if (retired.has(message.messageId)) return retired.get(message.messageId) === fingerprintHash(message) ? { status: 'accepted' } : { status: 'rejected', handoff: 'not-submitted', reason: 'retired identity belongs to other content' };
      const previous = inbox.get(message.messageId);
      if (previous) return messageFingerprint(previous) === fingerprint ? { status: 'accepted' }
        : { status: 'rejected', handoff: 'not-submitted', reason: 'messageId already belongs to different content or origin' };
      if (inbox.size >= 64) return { status: 'busy', handoff: 'not-submitted', reason: 'native transport inbox is full; host retains the message' };
      const candidate = journal([...inbox.values(), message]);
      if (Buffer.byteLength(JSON.stringify(candidate) + '\n') > 3 * 1024 * 1024) return { status: 'busy', handoff: 'not-submitted', reason: 'serialized inbox is full; host retains custody' };
      inbox.set(message.messageId, message);
      try { await durableJSON(runtime.messageJournalPath, journal()); }
      catch { inbox.delete(message.messageId); return { status: 'unknown', reason: 'native transport custody could not be durably verified; do not replay automatically' }; }
      return { status: 'accepted' };
    });
    messageWriting = operation.then(() => {}, () => {});
    return operation;
  }
  function onRequest(frame) {
    const session = liveSessions.get(frame.params?.session_id);
    if (!session && opening && frame.params?.session_id && opening.frames.length < 64) { opening.frames.push(frame); return; }
    if (!session) { runtime.gateway.respond(frame.id, null, { code: -32602, message: 'request has no owned session' }); return; }
    if (['yorozu.message_send', 'yorozu.message_read'].includes(frame.method)) {
      if (requests.has(frame.id)) return;
      try {
        if (!runtime.agent?.platform.team || frame.params.agent_session_id !== session.storedId) throw invalid('message request has no native agent-session ownership');
        const call = session.nativeToolCalls.get(required(frame.params.tool_call_id, 'native tool_call_id', 128));
        const expectedTool = frame.method === 'yorozu.message_send' ? 'send_agent_message' : 'read_agent_messages';
        if (!call || call.name !== expectedTool || call.claimed) throw invalid('message request has no unclaimed native tool identity');
        call.claimed = true;
        if (frame.method === 'yorozu.message_read') {
          object(frame.params, ['session_id', 'agent_session_id', 'tool_call_id', 'afterMessageId', 'limit', 'acknowledgeMessageIds'], 'message read');
          if (frame.params.acknowledgeMessageIds !== undefined) {
            const ids = frame.params.acknowledgeMessageIds;
            if (!Array.isArray(ids) || !ids.length || ids.length > 64 || new Set(ids).size !== ids.length) throw invalid('acknowledgement must name 1–64 distinct messages');
            for (const id of ids) required(id, 'acknowledged messageId', 512);
            if (frame.params.afterMessageId !== undefined) throw invalid('acknowledgement starts a fresh page; omit cursor');
            const operation = messageWriting.then(async () => {
              const next = new Map(retired);
              for (const id of ids) {
                if (!inbox.has(id) && !retired.has(id)) throw invalid('acknowledgement has no owned message');
                if (inbox.has(id)) next.set(id, fingerprintHash(inbox.get(id)));
              }
              if (next.size > 1024) throw invalid('retirement receipt capacity reached; unacknowledged custody retained');
              // Commit before removing custody from memory. A failed fsync stays unknown.
              await durableJSON(runtime.messageJournalPath, journal([...inbox.values()].filter(message => !ids.includes(message.messageId)), [...next]));
              for (const id of ids) inbox.delete(id);
              retired.clear(); for (const entry of next) retired.set(...entry);
              runtime.gateway.respond(frame.id, { messages: [], acknowledgedMessageIds: ids });
            });
            messageWriting = operation.catch(() => { runtime.gateway.respond(frame.id, { messages: [], unavailable: true }); });
            return;
          }
          const all = [...inbox.values()];
          let start = 0;
          if (frame.params.afterMessageId !== undefined) {
            required(frame.params.afterMessageId, 'afterMessageId', 512);
            const index = all.findIndex(message => message.messageId === frame.params.afterMessageId);
            if (index < 0) throw invalid('message cursor is not in this native agent inbox');
            start = index + 1;
          }
          const limit = frame.params.limit ?? 4;
          if (!Number.isInteger(limit) || limit < 1 || limit > 4) throw invalid('message page limit must be 1–4');
          const page = [];
          for (const message of all.slice(start, start + limit)) {
            const candidate = [...page, message];
            if (Buffer.byteLength(JSON.stringify({ jsonrpc: '2.0', id: frame.id, result: { messages: candidate, nextAfterMessageId: message.messageId } }) + '\n') > FRAME_LIMIT) break;
            page.push(message);
          }
          if (!page.length && start < all.length) throw invalid('message cannot fit native response envelope');
          runtime.gateway.respond(frame.id, { messages: page, ...(start + page.length < all.length ? { nextAfterMessageId: page.at(-1).messageId } : {}) });
          return;
        }
        object(frame.params, ['session_id', 'agent_session_id', 'tool_call_id', 'messageId', 'exchangeId', 'toAgentId', 'text'], 'message send');
        required(frame.params.messageId, 'messageId', 128); required(frame.params.toAgentId, 'toAgentId', 128);
        required(frame.params.text, 'message text', 32 * 1024);
        if (frame.params.exchangeId !== undefined) required(frame.params.exchangeId, 'exchangeId', 128);
        if (frame.params.toAgentId === runtime.agent.agentId) throw invalid('agent messaging cannot target itself');
        if (!runtime.agent.platform.peers.some(peer => peer.agentId === frame.params.toAgentId)) throw invalid('agent messaging recipient is not a selected peer');
        if ([...requests.values()].some(request => request.messageSend && request.frame.params.messageId === frame.params.messageId)) throw invalid('message admission receipt is already pending for this identity');
        requests.set(frame.id, { frame, session, messageSend: true });
        event(session, 'agent.message', { version: 1, messageId: frame.params.messageId,
          ...(frame.params.exchangeId ? { exchangeId: frame.params.exchangeId } : {}),
          toAgentId: frame.params.toAgentId, text: frame.params.text, sessionId: session.storedId });
      } catch (error) { runtime.gateway.respond(frame.id, { status: 'rejected', reason: text(error.message, 2048) }); }
      return;
    }
    if (frame.method === 'yorozu.team_delegate') {
      runtime.gateway.respond(frame.id, { status: 'rejected', text: 'Legacy execution handoff is unavailable; use messages to existing agents.' });
      event(session, 'capability.unavailable', { capability: 'teamDelegation', reason: 'Yorozu transports agent messages; it does not create teammate executions' });
      return;
    }
    if (!['approval', 'clarify'].includes(frame.method) || (frame.method === 'clarify' && frame.params.questions)) {
      runtime.gateway.respond(frame.id, null, { code: -32601, message: `${frame.method} is unsupported by this Yorozu adapter` });
      event(session, 'capability.unavailable', { capability: frame.method, reason: 'no supported native UI/permission bridge; request refused' }); return;
    }
    if (requests.has(frame.id)) return;
    const nativeChoices = Array.isArray(frame.params.choices) ? frame.params.choices.filter(x => typeof x === 'string').slice(0, 16) : [];
    const label = value => text(value, 256).replace(/[\0\r\n]/g, ' ');
    const choices = nativeChoices.map((choice, index) => frame.method === 'approval'
      ? { id: choice, label: ({ once: 'Allow once', session: 'Allow for this session', always: 'Always allow', deny: 'Decline' })[choice] ?? choice }
      : { id: `choice:${index}`, label: label(choice) });
    requests.set(frame.id, { frame, session, choices, nativeChoices });
    event(session, 'action.open', { version: 1, requestId: String(frame.id), sessionId: session.storedId,
      kind: frame.method === 'approval' ? 'approval' : 'question',
      title: (frame.method === 'approval' ? text(frame.params.tool_name || 'Hermes approval', 128) : text(frame.params.question || 'Hermes question', 512)).replace(/[\0\r\n]/g, ' '),
      ...(frame.method === 'approval' && (frame.params.description || frame.params.command) ? { text: text([text(frame.params.description, 4096), text(frame.params.command, 8192)].filter(Boolean).join('\n'), 8192).replace(/\0/g, '') } : {}),
      choices, allowText: frame.method === 'clarify' && frame.params.multi_select !== true });
  }
  function rejectContinuation(session, reason) {
    session.probe = null; session.unattributedTurn = { state: 'unknown', reason };
    event(session, 'capability.unavailable', { capability: 'autonomousContinuation', reason });
    // Unavailable projection currency is not permission to stop native work.
    // The harness keeps running; the host sees an explicitly unknown projection.
  }
  async function identifyContinuation(session) {
    const probe = session.probe;
    if (!probe || probe.started) return;
    probe.started = true;
    try {
      const snapshot = await runtime.gateway.call('session.activate', { session_id: session.liveId, omit_messages: true });
      let record = snapshot.inflight;
      if (!record && !snapshot.running) {
        // A fast nonstreaming turn may already have ended. Use only the LAST
        // native user row, never a scan for any convenient old completion.
        const history = await runtime.gateway.call('session.history', { session_id: session.liveId });
        record = [...(history.messages ?? [])].reverse().find(row => row.role === 'user');
      }
      if (session.probe !== probe) return;
      const delegationId = record?.display_kind === 'async_delegation_complete' ? record.display_metadata?.delegation_id : null;
      const origin = delegationId && session.delegations.get(delegationId);
      const results = [...session.tasks.values()].filter(task => task.delegationId === delegationId && !task.parentTaskId);
      const expectedCount = record?.display_metadata?.task_count;
      if (!origin || origin.conflict || origin.consumed || !origin.terminal || !results.length || results.some(task => ACTIVE.has(task.state) || task.state === 'unknown')
        || (Number.isSafeInteger(expectedCount) && expectedCount !== results.length)
        || session.stoppedOrigins.has(JSON.stringify([origin.runId, origin.attemptId]))) {
        rejectContinuation(session, 'native continuation lacks a fresh exact delegation origin, or its origin was stopped'); return;
      }
      // A batch is one unit, not one authorization per child. Native metadata,
      // rather than FIFO completion order, identifies the original host attempt.
      origin.consumed = true;
      const resultTaskIds = results.map(task => task.taskId);
      session.current = { runId: origin.runId, attemptId: `hermes-continuation:${nonce}:${probe.seq}`, continuation: true, resultTaskIds, text: '' };
      session.unattributedTurn = null; session.probe = null;
      event(session, 'turn.started', { continuation: true, originRunId: origin.runId, resultTaskIds });
      for (const buffered of probe.frames) onFrame(buffered, true);
    } catch (error) { if (session.probe === probe) rejectContinuation(session, `native continuation identity could not be verified: ${text(error.message, 1024)}`); }
  }
  function onFrame(frame, buffered = false) {
    if (frame.id !== undefined && frame.method && frame.method !== 'event') { onRequest(frame); return; }
    if (frame.method !== 'event') return;
    const { type, session_id: liveId, payload = {}, seq } = frame.params ?? {};
    let session = liveSessions.get(liveId);
    if (!session && opening && liveId) {
      // session.create can emit session.info before its reply. Buffer only a bounded
      // number of frames; attach them after the response supplies exact ownership.
      if (opening.frames.length < 64) opening.frames.push(frame);
      return;
    }
    if (!session) return;
    if (!buffered && Number.isSafeInteger(seq)) {
      if (seq <= session.cursor) return;
      session.cursor = seq;
    }
    if (type === 'request.cancel') {
      if (session.probe && session.probe.frames.some(item => item.id === payload.id && item.method !== 'event')) {
        if (session.probe.frames.length >= 64) { rejectContinuation(session, 'continuation buffer exceeded its bound'); return; }
        session.probe.frames.push(frame); return;
      }
      const request = requests.get(payload.id);
      if (requests.delete(payload.id)) {
        if (request.messageSend) event(session, 'agent.message.status', { version: 1, messageId: request.frame.params.messageId, sessionId: session.storedId, execution: 'unknown', reason: 'native receipt wait ended; delivered peer work is not cancelled' });
        else event(session, request.choices ? 'action.cancel' : 'request.cancel', request.choices
          ? { version: 1, requestId: String(payload.id), sessionId: session.storedId } : { requestId: payload.id });
      }
      return;
    }
    if (type?.startsWith('subagent.')) {
      if (!payload.subagent_id) { event(session, 'capability.unavailable', { capability: 'targetedTaskControl', reason: 'child event lacks exact identity' }); return; }
      const taskId = `hermes:${session.storedId}:${payload.subagent_id}`;
      let task = session.tasks.get(taskId);
      if (session.probe && !task && ![...session.tasks.values()].some(candidate => candidate.upstreamId === payload.parent_id)) {
        // A native continuation can commission its next child before the
        // identity RPC replies. Do not assign it to an unrelated lastRun.
        if (session.probe.frames.length >= 64) { rejectContinuation(session, 'continuation buffer exceeded its bound'); return; }
        session.probe.frames.push(frame); return;
      }
      if (!task) {
        const parent = [...session.tasks.values()].find(t => t.upstreamId === payload.parent_id);
        const known = session.delegations.get(payload.delegation_id);
        const origin = parent ? { runId: parent.originRunId, attemptId: parent.originAttemptId } : session.current ?? (known && !known.conflict ? known : null);
        if (!origin) return; // No host-authorized origin: never manufacture ownership.
        if (session.tasks.size >= 128) { event(session, 'capability.unavailable', { capability: 'taskProjection', reason: 'task projection capacity exceeded' }); return; }
        task = { taskId, upstreamId: payload.subagent_id, originRunId: origin.runId, originAttemptId: origin.attemptId,
          parentTaskId: parent?.taskId, title: text(payload.goal || 'Delegated task', 2048),
          state: type === 'subagent.spawn_requested' ? 'waiting' : 'running', canSteer: type !== 'subagent.spawn_requested', canStop: type !== 'subagent.spawn_requested' };
        session.tasks.set(taskId, task);
      }
      if (typeof payload.delegation_id === 'string' && payload.delegation_id) {
        task.delegationId = payload.delegation_id;
        const prior = session.delegations.get(task.delegationId);
        if (!prior && session.delegations.size < 128) session.delegations.set(task.delegationId, {
          runId: task.originRunId, attemptId: task.originAttemptId, terminal: false, consumed: false,
        });
        if (prior && (prior.runId !== task.originRunId || prior.attemptId !== task.originAttemptId)) prior.conflict = true;
      }
      if (type === 'subagent.start') { task.state = 'running'; task.canSteer = true; task.canStop = true; }
      if (type === 'subagent.complete') {
        const status = payload.status;
        task.state = ['completed', 'complete', 'success'].includes(status) ? 'completed'
          : ['failed', 'error'].includes(status) ? 'failed'
          : ['interrupted', 'cancelled', 'stopped'].includes(status) ? 'stopped' : 'unknown';
        task.text = text(payload.summary || (status === 'timeout' ? 'Hermes timed out while a worker may still be running; outcome is unknown.' : ''), 16 * 1024);
        const unit = session.delegations.get(task.delegationId);
        if (!task.parentTaskId && task.state !== 'unknown' && unit) unit.terminal = true;
      } else if (!ACTIVE.has(task.state)) return;
      publishTask(session, task); return;
    }
    if (type === 'tool.start' && ['send_agent_message', 'read_agent_messages'].includes(payload.name) && typeof payload.tool_id === 'string') {
      if (!session.nativeToolCalls.has(payload.tool_id) && session.nativeToolCalls.size < 64) session.nativeToolCalls.set(payload.tool_id, { run: session.current, name: payload.name, claimed: false });
      return;
    }
    if (type === 'message.start') {
      if (!session.current) {
        // The notification path emits start before initializing inflight metadata
        // (and can emit start twice). Probe after its first actual stream/tool
        // activity, buffer meanwhile, and fail closed if identity is unavailable.
        session.probe ??= { seq: seq ?? ++sequence, frames: [], started: false };
      }
      return;
    }
    if (session.probe && ['message.delta', 'message.interim', 'message.complete', 'tool.start', 'tool.complete', 'error'].includes(type)) {
      if (session.probe.frames.length >= 64) { rejectContinuation(session, 'continuation buffer exceeded its bound'); return; }
      session.probe.frames.push(frame); void identifyContinuation(session); return;
    }
    if (type === 'tool.complete') { session.nativeToolCalls.delete(payload.tool_id); return; }
    const run = session.current;
    if (!run) {
      if (type === 'message.complete') session.unattributedTurn = null;
      return;
    }
    if (type === 'error') {
      // Build/early-cancel failures sometimes emit only a session error, without
      // message.complete. Clear active projection, but do not invent cessation.
      event(session, 'turn.terminal', { text: run.text, state: 'unknown', reason: text(payload.message, 2048) || 'native session failed before terminal evidence' }, run);
      session.lastRun = run; session.current = null; session.nativeToolCalls.clear();
    } else if (type === 'message.delta') {
      if (Buffer.byteLength(run.text) + Buffer.byteLength(text(payload.text)) > TEXT_LIMIT) {
        event(session, 'capability.unavailable', { capability: 'replySize', reason: 'stream exceeded the bounded reply size' });
        return; // A presentation limit cannot stop native reasoning.
      }
      run.text += text(payload.text); event(session, 'assistant.update', { text: run.text });
    } else if (type === 'message.interim') {
      // Interim commentary is already in Hermes's stream/history; never duplicate
      // an already streamed segment or treat commentary as a completed turn.
      if (!payload.already_streamed && payload.text) { run.text = text(run.text + text(payload.text)); event(session, 'assistant.update', { text: run.text }); }
    } else if (type === 'message.complete') {
      const state = payload.status === 'complete' ? 'completed' : payload.status === 'interrupted' ? 'stopped' : payload.status === 'error' ? 'failed' : 'unknown';
      event(session, 'turn.terminal', { text: text(payload.text) || run.text, state,
        ...(payload.error || payload.failure_reason ? { reason: text(payload.error || payload.failure_reason, 2048) } : {}),
        ...(state !== 'unknown' ? { cessation: 'provider-terminal' } : {}),
        ...(run.continuation ? { continuation: true, originRunId: run.runId, resultTaskIds: run.resultTaskIds } : {}) }, run);
      session.lastRun = run; session.current = null; session.nativeToolCalls.clear();
    }
  }
  function onClose(reason) {
    for (const session of sessions.values()) {
      session.probe = null; session.nativeToolCalls.clear();
      if (session.current) { event(session, 'turn.terminal', { text: session.current.text, state: 'unknown', reason: 'Hermes process ended before terminal evidence' }); session.lastRun = session.current; session.current = null; }
      for (const task of session.tasks.values()) if (ACTIVE.has(task.state)) { task.state = 'unknown'; task.canSteer = false; task.canStop = false; publishTask(session, task); }
      for (const [id, request] of requests) if (request.session === session) {
        requests.delete(id);
        if (request.messageSend) event(session, 'agent.message.status', { version: 1, messageId: request.frame.params.messageId, sessionId: session.storedId, execution: 'unknown', reason: 'native connection ended; delivered peer work is not cancelled' });
        else event(session, request.choices ? 'action.cancel' : 'request.cancel', request.choices
          ? { version: 1, requestId: String(id), sessionId: session.storedId } : { requestId: id });
      }
      event(session, 'runtime.closed', { reason: text(reason, 2048) });
    }
  }
  async function control(method, params) {
    const session = sessionFor(params); currency(params); required(params.taskId, 'taskId');
    required(params.operationId, 'operationId');
    if (method === 'task.steer') required(params.text, 'text', 32 * 1024);
    const fingerprint = JSON.stringify([method, params.taskId, params.runId, params.attemptId, params.text]);
    const previous = session.operations.get(params.operationId);
    if (previous) return previous.fingerprint === fingerprint ? previous.result : { status: 'rejected', reason: 'operationId was used for different control currency' };
    const { task, reason } = currentTask(params);
    if (reason) return { status: 'rejected', reason };
    if (!(method === 'task.steer' ? task.canSteer && task.state !== 'stopping' : task.canStop)) return { status: 'unsupported', reason: 'Hermes has not established live control for this child' };
    if (session.operations.size >= 1024) return { status: 'rejected', reason: 'control receipt capacity exceeded' };
    // Reserve before sending: a lost upstream response is never an excuse to replay.
    const receipt = { fingerprint, result: { status: 'unknown', reason: 'control acknowledgement uncertain; do not replay' } };
    session.operations.set(params.operationId, receipt);
    try {
      const result = await runtime.gateway.call(method === 'task.steer' ? 'subagent.steer' : 'subagent.interrupt', {
        session_id: session.liveId, subagent_id: task.upstreamId,
        ...(method === 'task.steer' ? { text: params.text } : {}),
      });
      if (method === 'task.steer') {
        if (result.status === 'queued') receipt.result = { status: 'queued' };
        else if (result.status === 'rejected') receipt.result = { status: 'rejected', reason: 'Hermes rejected the steer' };
      } else if (result.found === true) receipt.result = { status: 'requested' };
      else if (result.found === false) receipt.result = { status: 'rejected', reason: 'Hermes no longer owns this live task' };
      if (receipt.result.status === 'requested' && ACTIVE.has(task.state)) { task.state = 'stopping'; publishTask(session, task); }
    } catch (error) {
      if (error.code === 4010 || error.code === -32601) receipt.result = { status: 'unsupported', reason: error.message };
      else receipt.result = { status: 'unknown', reason: `control acknowledgement uncertain; do not replay: ${text(error.message, 1024)}` };
    }
    return receipt.result;
  }
  return {
    async handle(method, params = {}) {
      if (method === 'initialize') {
        if (initialized || initializing) throw invalid('adapter is already initialized or initializing');
        initializing = true;
        try {
        validateLifecycle(params);
        const agent = await validateAgentScope(params);
        let preloaded = false;
        runtime = await launch(params, async prepared => { runtime = prepared; runtime.agent = agent; await loadMessages(); preloaded = true; });
        runtime.agent = agent;
        if (!preloaded) await loadMessages();
        runtime.gateway.onFrame(onFrame); runtime.gateway.onClose(onClose);
        await runtime.gateway.call('client.capabilities', { server_requests: true });
        initialized = true;
        const delegation = true; // Native orchestration is not a host preference flag.
        return { protocolVersion: 1, pluginId: 'hermes', upstreamVersion: UPSTREAM.version,
          lifecycle: { version: 1, mode: 'managed' },
          extensions: { ...EXTENSIONS, agentMessaging: Boolean(agent?.platform.team && runtime.messageJournalPath) },
          ...(agent ? { agentId: agent.agentId, scopeDigest: agent.scopeDigest, isolation: agent.isolation } : {}),
          capabilities: { backgroundTasks: delegation, targetedSteer: delegation, taskStop: delegation, approvals: true, reconnect: false, attachments: false,
            teamDelegation: false, nativeComputerUse: false, schedules: false },
          auth: { status: runtime.authAvailable ? 'local-proof' : 'unsupported', reason: runtime.authAvailable ? 'explicit loopback proof provider' : 'fresh subscription onboarding is not implemented; installed authentication is never read' } };
        } catch (error) { await runtime?.gateway?.shutdown().catch(() => {}); inbox.clear(); retired.clear(); throw error; }
        finally { initializing = false; }
      }
      if (!initialized) throw new ProtocolError(-32001, 'adapter is not initialized');
      if (['agentId', 'scope', 'isolation', 'platform', 'workspace', 'memoryDir', 'profileRoot', 'sourcePath', 'sourceIntegrity', 'python', 'providerConfigPath', 'lifecycle', 'connection'].some(key => params[key] !== undefined)) throw invalid('agent authority and runtime paths are immutable after initialize');
      if (method === 'detach') return { status: 'unsupported', reason: 'this managed adapter owns its native process; connected lifecycle is unavailable' };
      if (method === 'shutdown') { await messageWriting; await runtime.gateway.shutdown(); return { stopped: runtime.gateway.closed }; }
      if (runtime.gateway.closed && method !== 'session.snapshot') throw new ProtocolError(-32002, 'Hermes runtime is closed; uncertain actions cannot be replayed');
      if (method === 'session.open') {
        if (!runtime.authAvailable) throw new ProtocolError(-32010, 'Hermes subscription authentication is unsupported in this isolated candidate', { status: 'unsupported', capability: 'auth' });
        required(params.conversationId, 'conversationId'); required(params.bindingId, 'bindingId');
        const existing = sessions.get(params.conversationId);
        if (existing) {
          if (existing.bindingId !== params.bindingId || (params.sessionId && existing.storedId !== params.sessionId)) throw invalid('conversation is already owned by another binding/session');
          return { sessionId: existing.storedId };
        }
        if (opening) throw new ProtocolError(-32003, 'another session is opening');
        if (runtime.agent && sessions.size) throw invalid('product agent owns one continuous conversation');
        if (params.provider && params.provider !== runtime.provider) throw invalid('session provider is not available');
        if (params.model && params.model !== runtime.model) throw invalid('session model is not available');
        const resume = Boolean(params.sessionId);
        opening = { frames: [] };
        try {
          const result = await runtime.gateway.call(resume ? 'session.resume' : 'session.create', resume
            ? { session_id: required(params.sessionId, 'sessionId'), source: 'yorozu', lazy: true, omit_messages: true, close_on_disconnect: false }
            : { cwd: runtime.workspace, source: 'yorozu', close_on_disconnect: false,
              model: runtime.model, provider: runtime.provider });
          const session = { conversationId: params.conversationId, bindingId: params.bindingId,
            storedId: required(result.stored_session_id || (resume ? params.sessionId : ''), 'stored_session_id'), liveId: required(result.session_id, 'session_id'),
            tasks: new Map(), attempts: new Set(), operations: new Map(), current: null, lastRun: null, cursor: 0,
            delegations: new Map(), stoppedOrigins: new Set(), nativeToolCalls: new Map(), probe: null, unattributedTurn: null };
          sessions.set(session.conversationId, session); liveSessions.set(session.liveId, session);
          if (result.running || result.auto_continue) session.unattributedTurn = { state: 'unknown', reason: 'native harness is active; ownership projection requires reconciliation' };
          const frames = opening.frames; opening = null;
          for (const frame of frames) onFrame(frame);
          for (const request of result.open_requests ?? []) onRequest({ jsonrpc: '2.0', ...request });
          return { sessionId: session.storedId, ...(resume ? { recovery: 'snapshot-only' } : {}) };
        } finally { opening = null; }
      }
      if (method === 'message.deliver') return deliverMessage(params);
      if (method === 'message.receipt') {
        object(params, ['version', 'messageId', 'status', 'exchangeId', 'reason'], 'message receipt');
        if (params.version !== 1 || !['accepted', 'rejected', 'unknown'].includes(params.status)) throw invalid('invalid message receipt');
        required(params.messageId, 'messageId', 128);
        const request = [...requests.values()].find(item => item.messageSend && item.frame.params.messageId === params.messageId);
        if (!request) return { status: 'rejected', reason: 'native message request is stale or already settled' };
        if (params.exchangeId !== undefined) required(params.exchangeId, 'exchangeId', 128);
        runtime.gateway.respond(request.frame.id, { status: params.status, messageId: params.messageId,
          ...(params.exchangeId ? { exchangeId: params.exchangeId } : {}), ...(params.reason ? { reason: text(params.reason, 2048) } : {}) });
        requests.delete(request.frame.id);
        return { status: 'answered' };
      }
      if (method === 'action.answer') {
        object(params, ['version', 'requestId', 'sessionId', 'workId', 'choiceId', 'text'], 'action answer');
        if (params.version !== 1) throw invalid('unsupported action version');
        const request = [...requests.values()].find(item => String(item.frame.id) === required(params.requestId, 'requestId'));
        if (!request?.choices || request.session.storedId !== params.sessionId || params.workId !== undefined) return { status: 'rejected', reason: 'action session or native request identity is stale' };
        let result;
        if (params.choiceId !== undefined) {
          const index = request.choices.findIndex(choice => choice.id === params.choiceId);
          if (index < 0 || params.text !== undefined) return { status: 'rejected', reason: 'answer must select an offered native choice exactly' };
          result = request.frame.method === 'approval' ? { choice: request.nativeChoices[index] } : { answer: request.nativeChoices[index] };
        } else {
          if (request.frame.method !== 'clarify' || request.frame.params.multi_select === true || typeof params.text !== 'string') return { status: 'rejected', reason: 'native action does not accept a text answer' };
          result = { answer: text(params.text, 16 * 1024) };
        }
        runtime.gateway.respond(request.frame.id, result); requests.delete(request.frame.id);
        event(request.session, 'action.cancel', { version: 1, requestId: String(request.frame.id), sessionId: request.session.storedId });
        return { status: 'answered' };
      }
      if (method === 'turn.submit') {
        const session = sessionFor(params); currency(params); required(params.text, 'text', 64 * 1024);
        if (params.attachments !== undefined && (!Array.isArray(params.attachments) || params.attachments.length)) return { status: 'unsupported', reason: 'scoped attachment staging and atomic admission are not implemented; no attachment was read or submitted' };
        const key = JSON.stringify([params.runId, params.attemptId]);
        if (session.attempts.has(key)) return { status: 'rejected', reason: 'attempt already admitted; upstream has no durable idempotency key' };
        if (session.current || session.probe) return { status: 'rejected', reason: 'secretary turn is active or uncertain; host must queue explicitly' };
        if ([...session.tasks.values()].some(task => ACTIVE.has(task.state) && session.stoppedOrigins.has(JSON.stringify([task.originRunId, task.originAttemptId])))) return { status: 'rejected', reason: 'stopped execution is still settling' };
        // The native gateway has no atomic idle-only public admission method.
        // Inspect immediately before sending and never let its busy fallback
        // silently turn a fresh user topic into steering of another attempt.
        try {
          const status = await runtime.gateway.call('session.activate', { session_id: session.liveId, omit_messages: true });
          if (status.running || status.inflight?.streaming || status.queued || session.current || session.probe) return { status: 'busy', handoff: 'not-submitted', reason: 'native secretary is busy; host must retain its accepted queue' };
          session.unattributedTurn = null; // Exact native idle observation permits a fresh message; no old input is replayed.
        } catch (error) { return { status: 'rejected', reason: `native readiness could not be verified: ${text(error.message, 1024)}` }; }
        if (session.attempts.size >= 4096) return { status: 'rejected', reason: 'admission capacity exceeded' };
        session.attempts.add(key);
        const run = { runId: params.runId, attemptId: params.attemptId, text: '' };
        session.current = run;
        try {
          const result = await runtime.gateway.call('prompt.submit', { session_id: session.liveId, text: params.text, queued: true });
          if (result.status !== 'streaming') {
            // Queued/redirected/steered are not fresh admission receipts.
            event(session, 'turn.terminal', { text: run.text, state: 'unknown', reason: `unexpected Hermes submit acknowledgement: ${result.status ?? 'missing'}` }, run);
            if (session.current === run) session.current = null;
            return { status: 'unknown', reason: 'upstream admission differs from requested fresh turn; do not replay' };
          }
          return { status: 'accepted' };
        } catch (error) {
          if (session.current === run) { event(session, 'turn.terminal', { text: run.text, state: error.code >= 4000 && error.code < 5000 ? 'failed' : 'unknown', reason: text(error.message, 2048) }, run); session.lastRun = run; session.current = null; }
          return { status: error.code >= 4000 && error.code < 5000 ? 'rejected' : 'unknown', reason: text(error.message, 2048) };
        }
      }
      if (method === 'task.steer' || method === 'task.stop') return control(method, params);
      if (method === 'run.stop') {
        const session = sessionFor(params); currency(params); required(params.operationId, 'operationId');
        const previous = session.operations.get(params.operationId);
        const fingerprint = JSON.stringify([method, params.runId, params.attemptId]);
        if (previous) return previous.fingerprint === fingerprint ? previous.result : { status: 'rejected', reason: 'operationId currency mismatch' };
        const run = session.current;
        const children = [...session.tasks.values()].filter(task => ACTIVE.has(task.state));
        const matches = task => task.originRunId === params.runId && task.originAttemptId === params.attemptId;
        if (run && (run.runId !== params.runId || run.attemptId !== params.attemptId)) return { status: 'rejected', reason: 'run currency does not own the active foreground' };
        if (!run && !children.some(matches)) return { status: 'rejected', reason: 'run currency is stale or settled' };
        if (children.some(task => !matches(task))) return { status: 'unsupported', reason: 'Hermes session interrupt would also stop tasks from another origin; use exact task.stop' };
        if (session.operations.size >= 1024) return { status: 'rejected', reason: 'control receipt capacity exceeded' };
        const receipt = { fingerprint, result: { status: 'unknown', reason: 'stop acknowledgement uncertain; do not replay' } };
        session.operations.set(params.operationId, receipt);
        session.stoppedOrigins.add(JSON.stringify([params.runId, params.attemptId]));
        try {
          const result = await runtime.gateway.call('session.interrupt', { session_id: session.liveId });
          if (result.status === 'interrupted') receipt.result = { status: 'requested' };
          else if (result.status === 'not_interrupted') receipt.result = { status: 'rejected', reason: 'Hermes reported no active turn to stop' };
        } catch (error) {
          if (error.code === -32601 || error.code === 4010) receipt.result = { status: 'unsupported', reason: error.message };
          else receipt.result = { status: 'unknown', reason: `stop acknowledgement uncertain; do not replay: ${text(error.message, 1024)}` };
        }
        return receipt.result;
      }
      if (method === 'request.answer') {
        const request = requests.get(required(params.requestId, 'requestId'));
        if (!request || !['approval', 'clarify'].includes(request.frame.method) || request.session.storedId !== params.sessionId) return { status: 'rejected', reason: 'request or session is stale or not an approval/question' };
        let result;
        if (request.frame.method === 'approval') {
          if (typeof params.answer?.approved !== 'boolean') throw invalid('approval needs an explicit boolean decision');
          const choice = params.answer.approved ? 'once' : 'deny';
          if (!request.frame.params.choices?.includes(choice)) return { status: 'unsupported', reason: `upstream does not offer ${choice}; no broader grant will be used` };
          result = { choice };
        } else result = { answer: typeof params.answer?.text === 'string' ? text(params.answer.text, 16 * 1024) : '' };
        runtime.gateway.respond(request.frame.id, result); requests.delete(params.requestId);
        event(request.session, request.choices ? 'action.cancel' : 'request.cancel', request.choices
          ? { version: 1, requestId: String(params.requestId), sessionId: request.session.storedId } : { requestId: params.requestId });
        return { status: 'answered' };
      }
      if (method === 'session.snapshot') {
        const session = sessionFor(params);
        return { sessionId: session.storedId, tasks: [...session.tasks.values()].map(task => ({
          taskId: task.taskId, ...(task.parentTaskId ? { parentTaskId: task.parentTaskId } : {}), originRunId: task.originRunId,
          originAttemptId: task.originAttemptId, title: task.title, state: task.state,
          canSteer: ACTIVE.has(task.state) && task.state !== 'stopping' && task.canSteer,
          canStop: ACTIVE.has(task.state) && task.canStop })),
          current: session.current ? { runId: session.current.runId, attemptId: session.current.attemptId, text: session.current.text } : null,
          ...(session.unattributedTurn ? { unattributedTurn: session.unattributedTurn } : {}),
          cursor: { epoch: runtime.gateway.epoch ?? nonce, sequence: session.cursor },
          runtime: runtime.gateway.closed ? 'closed' : 'connected', recovery: 'snapshot-only' };
      }
      throw new ProtocolError(-32601, `unsupported adapter method: ${method}`);
    },
  };
}

export function serve(input = process.stdin, output = process.stdout) {
  let outputFailed = false;
  function send(frame) {
    if (outputFailed || output.destroyed) return;
    if (output.writableLength > 8 * 1024 * 1024) {
      outputFailed = true; process.stderr.write('Hermes adapter output queue exceeded its bound\n');
      void adapter.handle('shutdown').catch(() => {}); output.destroy(); input.destroy(); return;
    }
    try { output.write(wire(frame)); }
    catch (error) {
      // A host response projection overflow is not a native protocol failure.
      if (frame.id !== undefined) output.write(wire({ jsonrpc: '2.0', id: frame.id, error: { code: -32010, message: 'response exceeds encoded projection bound' } }));
    }
  }
  const adapter = createAdapter({ emit: params => send({ jsonrpc: '2.0', method: 'harness.event', params }) });
  let pending = 0;
  readFrames(input, frame => {
    if (frame.jsonrpc !== '2.0' || typeof frame.method !== 'string' || !['string', 'number'].includes(typeof frame.id)) {
      send({ jsonrpc: '2.0', id: frame.id ?? null, error: { code: -32600, message: 'request needs JSON-RPC 2.0 method and id' } }); return;
    }
    if (pending >= MAX_PENDING) { send({ jsonrpc: '2.0', id: frame.id, error: { code: -32003, message: 'too many pending operations' } }); return; }
    pending++;
    Promise.resolve().then(() => adapter.handle(frame.method, frame.params)).then(
      result => send({ jsonrpc: '2.0', id: frame.id, result }),
      error => send({ jsonrpc: '2.0', id: frame.id, error: { code: error.code ?? -32603, message: text(error.message, 2048), ...(error.data ? { data: error.data } : {}) } }),
    ).finally(() => { pending--; });
  }, () => { process.stderr.write('Hermes adapter protocol input is invalid or oversized\n'); void adapter.handle('shutdown').catch(() => {}); input.destroy(); });
  input.on('end', () => { void adapter.handle('shutdown').catch(() => {}); });
  return adapter;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) serve();

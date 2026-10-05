#!/usr/bin/env node
/** Transport only: the pinned OpenClaw Gateway owns planning and the entire agent loop. */
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, readFile, writeFile, rename, readdir, lstat, realpath, rm } from 'node:fs/promises';
import { closeSync } from 'node:fs';
import { resolve, join, dirname, isAbsolute, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes, randomUUID, createHash } from 'node:crypto';

export const UPSTREAM = Object.freeze({ version: '2026.9.8', commit: 'fc23bc864e4553c2d215e479eeec47b67a0bf943', protocol: 4 });
export const CURATED_RUNTIME = Object.freeze({ sourceCommit: '9bbdbaec153dd28fb452e6652c3dcacd829cb00f', patchSha256: '07febe324718e72b238d465bd33f5196d9c49f3aa864405d6587ba3d9b24c908', entry: 'dist/yorozu-gateway-embedding.js', transport: 'inherited-fd-v1' });
export const CAPABILITIES = Object.freeze({ backgroundTasks: false, targetedSteer: false, taskStop: false, approvals: false, reconnect: false, attachments: false });
export const EXTENSIONS = Object.freeze({ version: 1, connectedLifecycle: true, conversationActions: false, autonomousEvents: false, agentMessaging: false });
const FRAME_LIMIT = 256 * 1024;
const MAX_SESSIONS = 16;
const MAX_RECORDS = 1024;
const exec = promisify(execFile);
const sha = value => createHash('sha256').update(value).digest('hex');
const nativeId = (...ids) => `yz-${sha(JSON.stringify(ids))}`;
export class ProtocolError extends Error {
  constructor(code, message, data) { super(message); this.code = code; this.data = data; }
}
const invalid = message => new ProtocolError(-32602, message);
function object(value, name) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw invalid(`${name} must be an object`);
  return value;
}
function required(value, name, limit = 512) {
  if (typeof value !== 'string' || !value.trim() || Buffer.byteLength(value) > limit) throw invalid(`${name} must be a bounded nonempty string`);
  return value;
}
function only(value, keys, name) {
  object(value, name);
  if (Object.keys(value).some(key => !keys.includes(key))) throw invalid(`${name} contains unsupported fields`);
}
const within = (root, path) => { const part = relative(root, path); return !part.startsWith('..') && !isAbsolute(part); };
const contains = (root, path) => root === path || within(root, path);
function absolute(value, name) { required(value, name, 4096); if (!isAbsolute(value)) throw invalid(`${name} must be absolute`); return resolve(value); }
async function regular(path, maxBytes = 1024 * 1024) {
  const stat = await lstat(path);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > maxBytes) throw invalid('expected bounded regular file');
}
async function directory(path) {
  await mkdir(path, { recursive: true, mode: 0o700 });
  if ((await lstat(path)).isSymbolicLink() || await realpath(path) !== path) throw invalid('private directories must not traverse symlinks');
}
async function atomic(path, value) {
  try { await regular(path, 4 * 1024 * 1024); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const temporary = `${path}.${randomUUID()}.tmp`;
  await writeFile(temporary, JSON.stringify(value) + '\n', { flag: 'wx', mode: 0o600 });
  await rename(temporary, path);
}

export function validateLifecycle(params) {
  const lifecycle = params.lifecycle ?? { version: 1, mode: 'managed' };
  only(lifecycle, ['version', 'mode', 'connectionId'], 'lifecycle');
  if (lifecycle.version !== 1 || !['managed', 'connected'].includes(lifecycle.mode)) throw invalid('unsupported lifecycle');
  if (lifecycle.mode === 'managed') {
    if (lifecycle.connectionId !== undefined || params.connection !== undefined) throw invalid('managed lifecycle cannot adopt an external connection');
    return { mode: 'managed' };
  }
  if (params.protocolVersion !== 1 || params.upstreamVersion !== UPSTREAM.version) throw invalid('unsupported connected protocol or OpenClaw version');
  for (const key of ['source', 'node', 'workspace', 'profileDir', 'scope', 'isolation', 'providerConfigPath', 'platform', 'gatewayPort', 'gatewayListener']) {
    if (params[key] !== undefined) throw invalid('connected lifecycle cannot provision or adopt a native profile/resource scope');
  }
  required(params.agentId, 'agentId', 128);
  const connection = params.connection;
  only(connection, ['version', 'connectionId', 'endpoint', 'nativeAgentId', 'sessionKey', 'sessionId', 'token', 'uiTargetId'], 'trusted connection');
  if (connection.version !== 1 || required(connection.connectionId, 'connectionId', 128) !== lifecycle.connectionId) throw invalid('trusted connection identity does not match lifecycle');
  if (typeof connection.endpoint !== 'string' || !/^ws:\/\/127\.0\.0\.1:[1-9]\d{3,4}\/?$/.test(connection.endpoint)) throw invalid('connected endpoint must be an explicitly selected numeric-loopback Gateway');
  const port = Number(new URL(connection.endpoint).port);
  if (port < 1024 || port > 65535) throw invalid('connected endpoint port is unsupported');
  for (const key of ['nativeAgentId', 'sessionKey', 'sessionId']) required(connection[key], `connection.${key}`);
  if (!connection.sessionKey.startsWith(`agent:${connection.nativeAgentId}:`)) throw invalid('native session key must name the selected native agent');
  if (typeof connection.token !== 'string' || !/^[A-Za-z0-9._~+\/-]{32,256}={0,2}$/.test(connection.token)) throw invalid('trusted Gateway token is invalid');
  if (connection.uiTargetId !== undefined) required(connection.uiTargetId, 'registered UI target', 128);
  return { mode: 'connected', connection: { ...connection } };
}

/** Trusted host input; the isolation assertion must come from the host, never from a chat. */
export async function validateScope(params) {
  only(params.scope, ['allowedTools', 'directories', 'workspace', 'memoryDir', 'deniedRoots'], 'scope');
  only(params.isolation, ['backend', 'agentId', 'policyDigest'], 'isolation');
  const agentId = required(params.agentId, 'agentId', 64);
  if (!/^[a-z0-9_][a-z0-9_-]{0,63}$/.test(agentId)) throw invalid('agentId must be canonical');
  if (params.isolation.backend !== 'macos-seatbelt-v1' || params.isolation.agentId !== agentId || !/^[a-f0-9]{64}$/.test(params.isolation.policyDigest ?? '')) throw invalid('verified per-agent macOS sandbox is required');
  const scope = params.scope;
  if (!Array.isArray(scope.allowedTools) || scope.allowedTools.length > 64 || scope.allowedTools.some(tool => typeof tool !== 'string' || !/^[a-zA-Z0-9_.:-]{1,128}$/.test(tool))) throw invalid('scope.allowedTools is invalid');
  if (!Array.isArray(scope.directories) || scope.directories.length > 64) throw invalid('scope.directories is invalid');
  const directories = [];
  for (const entry of scope.directories) {
    only(entry, ['path', 'access'], 'scope directory');
    const path = absolute(entry.path, 'scope directory');
    if (!['read', 'write'].includes(entry.access) || path === '/' || path === '/Users') throw invalid('scope directory is too broad or invalid');
    if (await realpath(path) !== path) throw invalid('scope directory must not traverse symlinks');
    directories.push({ path, access: entry.access });
  }
  const workspace = absolute(params.workspace, 'workspace');
  const profileDir = absolute(params.profileDir, 'profileDir');
  const memoryDir = absolute(scope.memoryDir, 'scope.memoryDir');
  const grantedWorkspace = absolute(scope.workspace, 'scope.workspace');
  // Vendor transcript/model scratch is an implicit host runtime resource, never
  // a user-data/tool grant. A no-tool agent may use a fresh workspace beneath it.
  const scratchWorkspace = workspace !== profileDir && contains(profileDir, workspace);
  if (!scratchWorkspace && workspace !== grantedWorkspace) throw invalid('workspace does not match the harness scope or private runtime scratch');
  const deniedRoots = scope.deniedRoots ?? [];
  if (!Array.isArray(deniedRoots) || deniedRoots.length > 64) throw invalid('scope.deniedRoots is invalid');
  if (!scratchWorkspace && !directories.some(entry => entry.access === 'write' && contains(entry.path, workspace))) throw invalid('user workspace requires explicit writable scope');
  for (const path of [workspace, profileDir]) {
    if (deniedRoots.some(root => contains(absolute(root, 'denied root'), path) || contains(path, absolute(root, 'denied root')))) throw invalid('private runtime overlaps a denied root');
  }
  // A broad profile may never contain another agent workspace/memory. Host provisioning
  // supplies distinct private paths, and the profile ownership marker binds this agent.
  if (contains(profileDir, grantedWorkspace) || contains(profileDir, memoryDir)) throw invalid('runtime must be separate from agent user workspace and memory');
  if (await realpath(workspace) !== workspace) throw invalid('agent workspace must not traverse symlinks');
  return { agentId, workspace, profileDir, memoryDir, scopeDigest: sha(JSON.stringify(scope)), policyDigest: params.isolation.policyDigest };
}

/** Does not install, repair, update, read ambient auth, or adopt an existing OpenClaw profile. */
export function validateGatewayListener(params) {
  if (!Number.isInteger(params.gatewayPort) || params.gatewayPort < 1024 || params.gatewayPort > 65535) throw invalid('an exact host-reserved Gateway listener port is required');
  only(params.gatewayListener, ['transport', 'fd', 'host', 'port'], 'gatewayListener');
  if (params.gatewayListener.transport !== CURATED_RUNTIME.transport || params.gatewayListener.fd !== 3 || params.gatewayListener.host !== '127.0.0.1' || params.gatewayListener.port !== params.gatewayPort) throw invalid('the exact host-owned numeric-loopback Gateway listener must be inherited as FD3');
}
/** Trusted host bootstrap only. Validation errors never include provider values or secrets. */
export function parseProviderBootstrap(encoded) {
  try {
    if (typeof encoded !== 'string' || Buffer.byteLength(encoded) > 4096) throw new Error();
    const provider = JSON.parse(encoded);
    only(provider, ['baseUrl', 'model', 'api', 'bearer'], 'private inference broker');
    // Check the literal spelling before URL normalization can accept IP aliases.
    if (typeof provider.baseUrl !== 'string' || !/^http:\/\/127\.0\.0\.1:[1-9]\d{3,4}\/v1\/?$/.test(provider.baseUrl)) throw new Error();
    const endpoint = new URL(provider.baseUrl);
    if (Number(endpoint.port) < 1024 || Number(endpoint.port) > 65535) throw new Error();
    if (typeof provider.model !== 'string' || !/^[a-zA-Z0-9_.:-]{1,128}$/.test(provider.model) || provider.api !== 'openai-responses') throw new Error();
    if (provider.bearer !== undefined && (typeof provider.bearer !== 'string' || provider.bearer.length > 256 || !/^[a-zA-Z0-9._~+\/-]{32,256}={0,2}$/.test(provider.bearer))) throw new Error();
    return { baseUrl: provider.baseUrl, model: provider.model, api: provider.api,
      ...(provider.bearer !== undefined ? { bearer: provider.bearer } : {}) };
  } catch {
    throw invalid('Invalid private inference broker bootstrap');
  }
}
export async function prepareRuntime(params) {
  if (validateLifecycle(params).mode !== 'managed') throw invalid('connected lifecycle must use the connection launcher');
  only(params, ['protocolVersion', 'upstreamVersion', 'source', 'node', 'workspace', 'profileDir', 'agentId', 'scope', 'isolation', 'providerConfigPath', 'platform', 'gatewayPort', 'gatewayListener', 'lifecycle'], 'initialize');
  if (params.platform !== undefined) {
    only(params.platform, ['team', 'computer', 'peers'], 'platform');
    if (typeof params.platform.team !== 'boolean' || params.platform.computer !== false) throw invalid('native computer access is unsupported');
    if (params.platform.peers !== undefined && (!Array.isArray(params.platform.peers) || params.platform.peers.length > 32)) throw invalid('platform peer metadata must be bounded');
  }
  if (params.protocolVersion !== 1 || params.upstreamVersion !== UPSTREAM.version) throw invalid('unsupported harness protocol or OpenClaw version');
  validateGatewayListener(params);
  const scoped = await validateScope(params);
  const source = await realpath(absolute(params.source, 'source'));
  const node = await realpath(absolute(params.node, 'node'));
  const packageInfo = JSON.parse(await readFile(join(source, 'package.json'), 'utf8'));
  if (packageInfo.name !== 'openclaw' || packageInfo.version !== UPSTREAM.version) throw invalid('OpenClaw package version does not match the pin');
  const gitOptions = { maxBuffer: 4096, env: { PATH: '/usr/bin:/bin', GIT_OPTIONAL_LOCKS: '0', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' } };
  const revision = await exec('/usr/bin/git', ['-C', source, 'rev-parse', 'HEAD'], gitOptions);
  if (revision.stdout.trim() !== CURATED_RUNTIME.sourceCommit) throw invalid('OpenClaw source commit does not match the explicit curated pin; stock sources are gated');
  await exec('/usr/bin/git', ['-C', source, 'diff', '--quiet', 'HEAD', '--'], gitOptions);
  const patch = await exec('/usr/bin/git', ['-C', source, 'diff', UPSTREAM.commit, 'HEAD', '--binary', '--full-index', '--no-ext-diff', '--no-textconv', '--src-prefix=a/', '--dst-prefix=b/'], { ...gitOptions, maxBuffer: 512 * 1024 });
  if (sha(patch.stdout) !== CURATED_RUNTIME.patchSha256) throw invalid('OpenClaw curated patch digest does not match the approved base and patch');
  try {
    await regular(join(source, 'openclaw.mjs'));
    await regular(join(source, 'dist', 'entry.js'), 16 * 1024 * 1024);
    await regular(join(source, 'dist', 'yorozu-gateway-embedding.js'), 16 * 1024 * 1024);
    await lstat(join(source, 'node_modules'));
    await regular(join(source, 'dist', 'build-info.json'));
  } catch (error) {
    if (error.code === 'ENOENT') throw new ProtocolError(-32020, 'pinned OpenClaw requires its intact built package and node_modules; this adapter never installs or builds it');
    throw error;
  }
  const build = JSON.parse(await readFile(join(source, 'dist', 'build-info.json'), 'utf8'));
  if (build.commit !== CURATED_RUNTIME.sourceCommit || build.version !== UPSTREAM.version) throw invalid('OpenClaw build metadata does not match the explicit curated source pin');
  const probe = await exec(node, ['--input-type=module', '-e', 'process.stdout.write(JSON.stringify({version:process.versions.node,sqlite:!!process.getBuiltinModule("node:sqlite")}))'], { env: { PATH: '/usr/bin:/bin', NODE_DISABLE_COMPILE_CACHE: '1' }, maxBuffer: 4096 });
  const nodeInfo = JSON.parse(probe.stdout);
  const [major, minor] = nodeInfo.version.split('.').map(Number);
  if (!nodeInfo.sqlite || !((major === 24 && minor >= 16) || major > 26 || (major === 26 && minor >= 1))) throw invalid('unsupported OpenClaw Node runtime; automatic recovery/install is disabled');
  await directory(scoped.profileDir);
  const marker = join(scoped.profileDir, '.yorozu-openclaw-owner.json');
  const owner = { schema: 3, pluginId: 'openclaw', upstream: UPSTREAM.commit, curatedSource: CURATED_RUNTIME.sourceCommit, patchSha256: CURATED_RUNTIME.patchSha256, agentId: scoped.agentId };
  try {
    await regular(marker, 2048);
    const previous = JSON.parse(await readFile(marker, 'utf8'));
    if (![2, 3].includes(previous.schema) || Object.entries(owner).some(([key, value]) => key !== 'schema' && previous[key] !== value)) throw invalid('profile belongs to another agent or pinned runtime');
    // Scope is revalidated against the current host sandbox/configuration. It is
    // resource authority, not the identity of native memory and conversation.
    if (previous.schema === 2) await atomic(marker, owner);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
    const bootstrapNames = scoped.workspace === join(scoped.profileDir, 'scratch') ? ['proof-provider.json', 'scratch'] : ['proof-provider.json'];
    if ((await readdir(scoped.profileDir)).some(name => !bootstrapNames.includes(name))) throw invalid('refusing to adopt an existing OpenClaw profile');
    await writeFile(marker, JSON.stringify(owner), { flag: 'wx', mode: 0o600 });
  }
  const home = join(scoped.profileDir, 'isolated-home');
  const state = join(scoped.profileDir, 'openclaw-state');
  const temporary = join(scoped.profileDir, 'tmp');
  for (const path of [home, state, temporary, join(scoped.profileDir, 'isolated-codex')]) await directory(path);
  let provider;
  if (params.providerConfigPath) {
    const file = absolute(params.providerConfigPath, 'providerConfigPath');
    if (!contains(scoped.profileDir, file) || await realpath(file) !== file) throw invalid('proof provider must be in this explicit private profile');
    await regular(file, 4096);
    provider = parseProviderBootstrap(await readFile(file, 'utf8'));
  }
  return { ...scoped, source, node, home, state, temporary, provider, gatewayPort: params.gatewayPort, authAvailable: Boolean(provider), journalPath: join(scoped.profileDir, 'adapter-journal-v1.json') };
}

export function runtimeConfig(runtime, port, token) {
  const model = runtime.provider ? `yorozu-local-proof/${runtime.provider.model}` : 'yorozu-unconfigured/unconfigured';
  return {
    gateway: { mode: 'local', bind: 'loopback', port, auth: { mode: 'token', token, allowTailscale: false }, controlUi: { enabled: false }, uploads: { enabled: false }, cliAgents: { enabled: false }, reload: { mode: 'off' }, tailscale: { mode: 'off' } },
    agents: { ownership: 'explicit', defaults: { model: { primary: model, fallbacks: [] } },
      entries: { [runtime.agentId]: { workspace: runtime.workspace, cwd: runtime.workspace, agentDir: join(runtime.state, 'agent'), model, tools: { deny: ['*'], elevated: { enabled: false } } } } },
    tools: { deny: ['*'], codeMode: false, elevated: { enabled: false }, agentToAgent: { enabled: false }, sessions: { visibility: 'self' } },
    commands: { restart: false }, mcp: { apps: { enabled: false } },
    browser: { enabled: false }, cron: { enabled: false },
    update: { checkOnStart: false, auto: { enabled: false } },
    models: { mode: 'replace', catalogRefresh: { enabled: false }, providers: runtime.provider ? { 'yorozu-local-proof': { baseUrl: runtime.provider.baseUrl, apiKey: runtime.provider.bearer ?? 'yorozu-loopback-proof', auth: 'api-key', api: runtime.provider.api, authHeader: runtime.provider.bearer !== undefined,
      models: [{ id: runtime.provider.model, name: runtime.provider.model, reasoning: false, input: ['text'], contextWindow: 32768, maxTokens: 4096, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] } } : {} },
  };
}
export function mergeRuntimeConfig(previousConfig, hostConfig, agentId) {
  const config = { ...previousConfig, ...hostConfig,
    agents: { ...previousConfig.agents, ...hostConfig.agents,
    defaults: { ...previousConfig.agents?.defaults, ...hostConfig.agents.defaults },
    entries: { ...previousConfig.agents?.entries, [agentId]: {
      ...previousConfig.agents?.entries?.[agentId], ...hostConfig.agents.entries[agentId] } } },
  };
  return config;
}

export function runtimeEnvironment(runtime) {
  return {
    PATH: `${dirname(runtime.node)}:/usr/bin:/bin:/usr/sbin:/sbin`, HOME: runtime.home, CODEX_HOME: join(runtime.profileDir, 'isolated-codex'),
    OPENCLAW_HOME: runtime.home, OPENCLAW_STATE_DIR: runtime.state, OPENCLAW_CONFIG_PATH: join(runtime.profileDir, 'openclaw.json'),
    TMPDIR: runtime.temporary, LANG: 'en_US.UTF-8', NODE_DISABLE_COMPILE_CACHE: '1',
    OPENCLAW_DISABLE_BONJOUR: '1', OPENCLAW_EXEC_SHELL_SNAPSHOT: '0', OPENCLAW_NO_RESPAWN: '1',
    OPENCLAW_SKIP_CHANNELS: '1', OPENCLAW_SKIP_CRON: '1', OPENCLAW_SKIP_GMAIL_WATCHER: '1',
    OPENCLAW_SKIP_BROWSER_CONTROL_SERVER: '1', OPENCLAW_SKIP_CANVAS_HOST: '1',
  };
}
export function nativeGatewayLaunch(runtime) {
  return { command: runtime.node, args: [join(runtime.source, CURATED_RUNTIME.entry), '--port', String(runtime.gatewayPort)],
    options: { cwd: runtime.workspace, env: runtimeEnvironment(runtime), stdio: ['ignore', 'pipe', 'pipe', 3] } };
}
export class NativeGateway {
  constructor(url, token, child, { WebSocketClass = WebSocket, timeoutMs = 10_000, ownership = 'managed' } = {}) {
    this.url = url; this.token = token; this.child = child; this.WebSocketClass = WebSocketClass; this.timeoutMs = timeoutMs;
    this.pending = new Map(); this.listeners = new Set(); this.closeListeners = new Set(); this.nextId = 0; this.closed = false; this.connected = false;
    this.ownership = ownership;
  }
  onFrame(listener) { this.listeners.add(listener); }
  onClose(listener) { this.closeListeners.add(listener); }
  async connect() {
    this.socket = new this.WebSocketClass(this.url);
    const socket = this.socket;
    let ready = false;
    const challenge = new Promise((yes, no) => {
      const timer = setTimeout(() => no(new Error('Gateway challenge timed out')), this.timeoutMs);
      this.challenge = payload => { clearTimeout(timer); ready = true; yes(payload); };
      socket.addEventListener('close', () => { if (!ready) { clearTimeout(timer); no(new Error('Gateway closed before challenge')); } });
      socket.addEventListener('error', () => { if (!ready) { clearTimeout(timer); no(new Error('Gateway connection failed')); } });
    });
    socket.addEventListener('message', event => {
      try {
        if (typeof event.data !== 'string' || Buffer.byteLength(event.data) > FRAME_LIMIT) throw new Error('invalid Gateway frame');
        this.receive(JSON.parse(event.data));
      } catch { this.finish('invalid or oversized Gateway frame'); }
    });
    socket.addEventListener('close', () => { if (this.connected) this.finish('Gateway connection closed; handed-off work is uncertain'); });
    await challenge;
    // gateway-client/backend is the upstream generic embedding class. This is an
    // isolated loopback token session, with no device token, pairing or admin scope.
    const hello = await this.call('connect', {
      minProtocol: UPSTREAM.protocol, maxProtocol: UPSTREAM.protocol,
      client: { id: 'gateway-client', displayName: 'Yorozu harness connection', version: '1', platform: process.platform, mode: 'backend', instanceId: randomUUID() },
      role: 'operator', scopes: ['operator.read', 'operator.write'], auth: { token: this.token }, caps: ['session-scoped-events'],
    });
    if (hello?.type !== 'hello-ok' || hello.protocol !== UPSTREAM.protocol || hello.server?.version !== UPSTREAM.version || hello.auth?.role !== 'operator'
      || hello.auth?.method !== 'token' || hello.auth?.deviceToken || !['operator.read', 'operator.write'].every(scope => hello.auth?.scopes?.includes(scope))
      || hello.auth.scopes.some(scope => !['operator.read', 'operator.write'].includes(scope))
      || ![...(this.ownership === 'managed' ? ['sessions.create'] : []), 'chat.history', 'chat.send', 'chat.abort', 'sessions.messages.subscribe'].every(method => hello.features?.methods?.includes(method))) throw new Error('Gateway identity, scopes or required methods do not match the pinned contract');
    this.connected = true; this.epoch = required(hello.server.bootId ?? hello.server.connId, 'gateway generation');
    return hello;
  }
  receive(frame) {
    if (this.closed) return;
    if (frame.type === 'res') {
      const entry = this.pending.get(frame.id);
      if (!entry) return;
      this.pending.delete(frame.id); clearTimeout(entry.timer);
      if (frame.ok === true) entry.resolve(frame.payload);
      else entry.reject(new ProtocolError(-32030, 'Gateway RPC rejected the request', frame.error));
    } else if (frame.type === 'event') {
      if (frame.event === 'connect.challenge') {
        if (!frame.payload || typeof frame.payload.nonce !== 'string' || !Number.isFinite(frame.payload.ts)) return this.finish('malformed Gateway challenge');
        this.challenge?.(frame.payload); return;
      }
      for (const listener of this.listeners) listener(frame);
      if (frame.event === 'shutdown') this.finish('native Gateway shutdown; no automatic replay or replacement');
    }
  }
  call(method, params) {
    if (this.closed || !this.socket || this.socket.readyState !== 1) return Promise.reject(new Error('Gateway is not connected'));
    if (this.pending.size >= 32) return Promise.reject(new Error('Gateway pending request bound exceeded'));
    const id = String(++this.nextId);
    const frame = JSON.stringify({ type: 'req', id, method, params });
    if (Buffer.byteLength(frame) > FRAME_LIMIT) return Promise.reject(new Error('Gateway request is too large'));
    return new Promise((resolveCall, rejectCall) => {
      const timer = setTimeout(() => { this.pending.delete(id); rejectCall(new Error('Gateway acknowledgement timed out')); }, this.timeoutMs);
      this.pending.set(id, { resolve: resolveCall, reject: rejectCall, timer });
      try { this.socket.send(frame); } catch (error) { this.pending.delete(id); clearTimeout(timer); rejectCall(error); }
    });
  }
  finish(reason) {
    if (this.closed) return;
    this.closed = true; this.connected = false;
    for (const entry of this.pending.values()) { clearTimeout(entry.timer); entry.reject(new Error(reason)); }
    this.pending.clear(); this.socket?.close();
    for (const listener of this.closeListeners) listener(reason);
  }
  async shutdown() {
    if (this.ownership === 'connected') { await this.detach(); return; }
    this.finish('host shutdown');
    if (this.child && this.child.exitCode === null && this.child.signalCode === null) {
      this.child.kill('SIGTERM');
      await new Promise((yes, no) => {
        const timer = setTimeout(() => no(new Error('Gateway has not exited; profile remains exclusively owned')), 30_000);
        this.child.once('exit', () => { clearTimeout(timer); yes(); });
      });
    }
  }
  async detach() {
    // This client owns a socket, never the external service/process or its work.
    // No native shutdown/abort/session-delete method is issued.
    this.finish('Yorozu client detached; native service remains externally owned');
  }
}

export async function launchRuntime(params) {
  const lifecycle = validateLifecycle(params);
  if (lifecycle.mode === 'connected') {
    const gateway = new NativeGateway(lifecycle.connection.endpoint, lifecycle.connection.token, undefined, { ownership: 'connected' });
    try { await gateway.connect(); }
    catch (error) { await gateway.detach(); throw error; }
    return { gateway, ownership: 'connected', connection: lifecycle.connection,
      agentId: lifecycle.connection.nativeAgentId, hostAgentId: params.agentId, authAvailable: true };
  }
  const runtime = await prepareRuntime(params);
  const lock = join(runtime.profileDir, '.adapter-owner.lock');
  try { await mkdir(lock, { mode: 0o700 }); } catch (error) { if (error.code === 'EEXIST') throw invalid('private profile already has an owner; stale ownership requires explicit recovery'); throw error; }
  let child;
  let listenerReleased = false;
  const releaseListener = () => { if (!listenerReleased) { listenerReleased = true; closeSync(3); } };
  try {
    const port = runtime.gatewayPort; // Trusted host lease and inherited descriptor own the endpoint; the child has no bind grant.
    const token = randomBytes(32).toString('hex');
    await atomic(join(runtime.profileDir, 'gateway-token.json'), { token });
    const configPath = join(runtime.profileDir, 'openclaw.json');
    let previousConfig = {};
    try { await regular(configPath); previousConfig = JSON.parse(await readFile(configPath, 'utf8')); object(previousConfig, 'native configuration'); }
    catch (error) {
      if (error instanceof SyntaxError) throw invalid('native configuration could not be parsed; its existing file was preserved');
      if (error.code !== 'ENOENT') throw error;
    }
    const hostConfig = runtimeConfig(runtime, port, token);
    const config = mergeRuntimeConfig(previousConfig, hostConfig, runtime.agentId);
    await atomic(configPath, config);
    const launch = nativeGatewayLaunch(runtime);
    child = spawn(launch.command, launch.args, launch.options);
    child.stdout.on('data', () => {}); // Consume logs without treating them as protocol or exposing private context.
    child.stderr.on('data', () => {});
    await new Promise((yes, no) => { child.once('spawn', yes); child.once('error', no); });
    releaseListener(); // The native child owns its duplicated descriptor from this point.
    let childError;
    child.on('error', error => { childError = error; });
    const gateway = new NativeGateway(`ws://127.0.0.1:${port}`, token, child);
    child.on('exit', (code, signal) => { gateway.finish(code === 78 ? 'native Gateway rejected configuration (exit 78)' : `native Gateway exited (${signal ?? code})`); void rm(lock, { recursive: true }); });
    const deadline = Date.now() + 60_000;
    for (;;) {
      if (childError) throw childError;
      if (child.exitCode !== null || child.signalCode !== null) throw new Error('native Gateway exited before readiness');
      try { await gateway.connect(); break; } catch (error) {
        gateway.socket?.close();
        const startup = error.data?.code === 'UNAVAILABLE' && error.data?.details?.reason === 'startup-sidecars';
        const noHandoffConnectionFailure = /connection failed|before challenge/.test(error.message);
        if (Date.now() >= deadline || (!startup && !noHandoffConnectionFailure)) throw error;
        await new Promise(yes => setTimeout(yes, startup ? Math.min(1000, Math.max(100, error.data.retryAfterMs ?? 500)) : 200));
      }
    }
    return { ...runtime, gateway };
  } catch (error) {
    try { releaseListener(); } catch { /* Failed descriptor ownership remains a startup failure. */ }
    if (child && child.exitCode === null && child.signalCode === null) child.kill('SIGTERM');
    else await rm(lock, { recursive: true });
    throw error;
  }
}

function messageText(message) {
  if (typeof message?.content === 'string') return message.content;
  if (Array.isArray(message?.content)) return message.content.filter(part => part?.type === 'text' && typeof part.text === 'string').map(part => part.text).join('\n');
  return null;
}
const unknown = reason => ({ status: 'unknown', reason });

export function createAdapter({ launch = launchRuntime, emit = () => {} } = {}) {
  let runtime; let initializing = false; let initialized = false;
  const sessions = new Map(); const runs = new Map(); const operations = new Map();
  const pendingEvents = new Map();
  const nonce = randomUUID(); let sequence = 0; let writing = Promise.resolve(); let frames = Promise.resolve();
  const journal = () => ({ schema: 2, upstream: UPSTREAM.commit, curatedSource: CURATED_RUNTIME.sourceCommit, agentId: runtime.agentId, sessions: [...sessions.values()], runs: [...runs.values()], operations: [...operations.values()] });
  const persist = () => {
    if (!runtime.journalPath) return Promise.resolve();
    const value = journal();
    const next = writing.then(() => atomic(runtime.journalPath, value));
    writing = next.catch(() => {}); return next;
  };
  const event = (session, kind, data, run) => emit({ protocolVersion: 1, eventId: `${nonce}:${++sequence}`, conversationId: session.conversationId,
    ...(run ? { runId: run.runId, attemptId: run.attemptId } : {}), kind, data });
  function sessionFor(params) {
    required(params.conversationId, 'conversationId');
    const session = sessions.get(params.conversationId);
    if (!session || session.state !== 'open') throw invalid('conversation has no proven native session');
    if (params.bindingId !== undefined && params.bindingId !== session.bindingId) throw invalid('conversation binding is stale');
    return session;
  }
  function runFor(params) {
    const session = sessionFor(params);
    required(params.runId, 'runId'); required(params.attemptId, 'attemptId');
    const run = runs.get(nativeId(session.bindingId, params.runId, params.attemptId));
    if (!run || run.conversationId !== session.conversationId || run.sessionKey !== session.sessionKey) throw invalid('run currency does not belong to this native agent/session');
    return { session, run };
  }
  async function loadJournal() {
    if (!runtime.journalPath) return;
    let saved;
    try { await regular(runtime.journalPath, 4 * 1024 * 1024); saved = JSON.parse(await readFile(runtime.journalPath, 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return; throw error; }
    only(saved, ['schema', 'upstream', 'curatedSource', 'agentId', 'sessions', 'runs', 'operations'], 'adapter journal');
    if (saved.schema !== 2 || saved.upstream !== UPSTREAM.commit || saved.curatedSource !== CURATED_RUNTIME.sourceCommit || saved.agentId !== runtime.agentId || !Array.isArray(saved.sessions) || saved.sessions.length > MAX_SESSIONS || !Array.isArray(saved.runs) || saved.runs.length > MAX_RECORDS || !Array.isArray(saved.operations) || saved.operations.length > MAX_RECORDS) throw invalid('adapter journal identity or limits are invalid');
    for (const session of saved.sessions) {
      only(session, ['conversationId', 'bindingId', 'sessionKey', 'sessionId', 'state', 'reference'], 'journal session');
      required(session.conversationId, 'conversationId'); required(session.bindingId, 'bindingId');
      if (session.sessionKey !== `agent:${runtime.agentId}:${nativeId(session.bindingId, session.conversationId)}` || !['open', 'unknown'].includes(session.state) || sessions.has(session.conversationId)) throw invalid('journal session origin is invalid');
      if (session.state === 'open') required(session.sessionId, 'sessionId');
      if (typeof session.reference !== 'string' || Buffer.byteLength(session.reference) > 48 * 1024) throw invalid('journal reference is invalid');
      sessions.set(session.conversationId, session);
    }
    for (const run of saved.runs) {
      only(run, ['nativeId', 'conversationId', 'sessionKey', 'runId', 'attemptId', 'fingerprint', 'receipt', 'state', 'text', 'seq'], 'journal run');
      const session = sessions.get(run.conversationId);
      required(run.runId, 'runId'); required(run.attemptId, 'attemptId');
      if (!session || session.sessionKey !== run.sessionKey || run.nativeId !== nativeId(session.bindingId, run.runId, run.attemptId) || !/^[a-f0-9]{64}$/.test(run.fingerprint) || runs.has(run.nativeId) || !['admitting', 'running', 'stopping', 'completed', 'failed', 'stopped', 'unknown'].includes(run.state) || typeof run.text !== 'string' || Buffer.byteLength(run.text) > 128 * 1024 || !Number.isSafeInteger(run.seq)) throw invalid('journal run origin is invalid');
      object(run.receipt, 'journal receipt');
      if (!['completed', 'failed', 'stopped'].includes(run.state)) { run.state = 'unknown'; run.receipt = unknown('adapter restart cannot prove whether native work is still active; no replay'); }
      runs.set(run.nativeId, run);
    }
    for (const operation of saved.operations) {
      only(operation, ['key', 'fingerprint', 'receipt'], 'journal operation');
      required(operation.key, 'operation key', 2048);
      if (!/^[a-f0-9]{64}$/.test(operation.fingerprint) || operations.has(operation.key)) throw invalid('journal operation is invalid');
      object(operation.receipt, 'journal control receipt');
      if (operation.receipt.status === 'unknown') operation.receipt = unknown('control was handed off or reserved before restart; no replay');
      operations.set(operation.key, operation);
    }
  }
  async function onFrame(frame) {
    if (frame.event !== 'chat') return; // No child identity is invented from logs or generic agent events.
    const data = frame.payload;
    const run = runs.get(data?.runId);
    if (!run || data.agentId !== runtime.agentId || data.sessionKey !== run.sessionKey || !Number.isSafeInteger(data.seq) || data.seq <= run.seq) return;
    if (run.state === 'admitting') {
      const buffered = pendingEvents.get(run.nativeId) ?? [];
      if (buffered.length >= 64) throw new Error('pre-ack native event bound exceeded');
      buffered.push(frame); pendingEvents.set(run.nativeId, buffered); return;
    }
    const session = sessions.get(run.conversationId);
    if (!session || ['completed', 'failed', 'stopped'].includes(run.state)) return;
    // Missing sequence creates a truthful uncertain outcome; never patch gaps with invented text.
    if (run.seq >= 0 && data.seq > run.seq + 1) { run.state = 'unknown'; await persist(); event(session, 'capability.unavailable', { capability: 'event-sequence', reason: 'native chat event gap; reconnect recovery is unsupported' }, run); return; }
    run.seq = data.seq;
    if (data.state === 'delta') {
      if (typeof data.deltaText !== 'string') return;
      run.text = data.replace === true ? data.deltaText : run.text + data.deltaText;
      if (Buffer.byteLength(run.text) > 128 * 1024) throw new Error('native text exceeded the adapter bound');
      await persist(); event(session, 'assistant.update', { text: run.text }, run);
    } else if (['final', 'aborted', 'error'].includes(data.state)) {
      if (data.yielded === true) { run.state = 'unknown'; await persist(); event(session, 'capability.unavailable', { capability: 'backgroundTasks', reason: 'native yielded run has no proven continuation ownership in this prototype' }, run); return; }
      const text = messageText(data.message);
      if (text !== null && Buffer.byteLength(text) <= 128 * 1024) run.text = text;
      run.state = data.state === 'final' ? 'completed' : data.state === 'aborted' ? 'stopped' : 'failed';
      await persist();
      if (run.text) event(session, 'assistant.update', { text: run.text }, run);
      event(session, 'turn.terminal', { state: run.state, cessation: 'provider-terminal', ...(data.state === 'error' ? { reason: 'native chat error', errorKind: data.errorKind ?? 'unknown' } : {}) }, run);
    }
  }
  function closed(reason) {
    for (const session of sessions.values()) {
      for (const run of runs.values()) if (run.conversationId === session.conversationId && !['completed', 'failed', 'stopped'].includes(run.state)) run.state = 'unknown';
      event(session, 'runtime.closed', { reason: String(reason).slice(0, 300), uncertain: true });
    }
    void persist().catch(() => {});
  }
  async function reserveOperation(params, method, action) {
    required(params.operationId, 'operationId');
    const key = JSON.stringify([params.conversationId, params.operationId]);
    const fingerprint = sha(JSON.stringify([method, params.runId, params.attemptId, params.taskId ?? null, params.text ?? null]));
    const prior = operations.get(key);
    if (prior) { if (prior.fingerprint !== fingerprint) throw invalid('operation ID was reused for different control currency'); return prior.receipt; }
    if (operations.size >= MAX_RECORDS) throw invalid('control journal bound exceeded');
    const operation = { key, fingerprint, receipt: unknown('control reserved; acknowledgement not yet proven') };
    operations.set(key, operation); await persist();
    try { operation.receipt = await action(); } catch { operation.receipt = unknown('native control acknowledgement is lost or malformed; no replay'); }
    await persist(); return operation.receipt;
  }
  return {
    async handle(method, params = {}) {
      object(params, 'params');
      if (method === 'initialize') {
        if (initialized || initializing) throw invalid('adapter is already initializing or initialized');
        initializing = true;
        try {
          validateLifecycle(params);
          runtime = await launch(params); await loadJournal();
          runtime.gateway.onFrame(frame => { frames = frames.then(() => onFrame(frame)).catch(() => { runtime.gateway.finish?.('native event processing failed'); closed('native event processing failed'); }); });
          runtime.gateway.onClose(closed); initialized = true;
          return { protocolVersion: 1, pluginId: 'openclaw', upstreamVersion: UPSTREAM.version, capabilities: CAPABILITIES, extensions: EXTENSIONS,
            agentId: runtime.hostAgentId ?? runtime.agentId,
            lifecycle: runtime.ownership === 'connected' ? { version: 1, mode: 'connected', connectionId: runtime.connection.connectionId } : { version: 1, mode: 'managed' },
            ...(runtime.scopeDigest && runtime.policyDigest ? { scopeDigest: runtime.scopeDigest,
              isolation: { backend: 'macos-seatbelt-v1', agentId: runtime.agentId, policyDigest: runtime.policyDigest } } : {}),
            auth: { status: runtime.ownership === 'connected' ? 'harness-owned' : runtime.authAvailable ? 'local-proof' : 'unsupported',
              reason: runtime.ownership === 'connected' ? 'explicit Gateway connection authenticated; model sign-in remains owned by the external harness and is not verified here'
                : runtime.authAvailable ? 'explicit loopback proof inference; no live subscription proof' : 'fresh subscription onboarding is not implemented; ambient credentials are never read' } };
        } catch (error) {
          if (runtime?.ownership === 'connected') await runtime.gateway.detach().catch(() => {});
          else await runtime?.gateway?.shutdown().catch(() => {});
          throw error;
        } finally { initializing = false; }
      }
      if (!initialized) throw new ProtocolError(-32001, 'adapter is not initialized');
      if (method === 'detach') {
        if (runtime.ownership !== 'connected') return { status: 'unsupported', reason: 'managed lifecycle owns a native process; use shutdown' };
        await runtime.gateway.detach(); await writing; return { detached: runtime.gateway.closed, nativeStopped: false };
      }
      if (method === 'shutdown') {
        if (runtime.ownership === 'connected') { await runtime.gateway.detach(); await writing; return { detached: runtime.gateway.closed, nativeStopped: false }; }
        await runtime.gateway.shutdown(); await writing; return { stopped: runtime.gateway.closed };
      }
      if (['message.deliver', 'message.receipt', 'action.answer'].includes(method)) return { status: 'unsupported', handoff: 'not-submitted', reason: 'no verified native peer-inbox or action mapping exists for this OpenClaw pin' };
      if (method === 'session.open') {
        required(params.conversationId, 'conversationId'); required(params.bindingId, 'bindingId');
        if (params.provider || params.model || params.attachments) throw invalid('session model/provider/attachment override is unsupported');
        const reference = JSON.stringify({ preferences: params.preferences ?? '', historicalContext: params.context ?? '' });
        if ((params.preferences !== undefined && typeof params.preferences !== 'string') || (params.context !== undefined && typeof params.context !== 'string') || Buffer.byteLength(reference) > 48 * 1024) throw invalid('portable context exceeds its bound or is not text');
        const previous = sessions.get(params.conversationId);
        if (previous) {
          if (previous.bindingId !== params.bindingId || (params.sessionId && params.sessionId !== previous.sessionId)) throw invalid('conversation is already owned by another binding or native session');
          if (previous.state !== 'open') throw new ProtocolError(-32031, 'native session creation acknowledgement is uncertain; no replay');
          return { sessionId: previous.sessionId, recovery: 'snapshot-only' };
        }
        if (params.sessionId && runtime.ownership !== 'connected') throw invalid('only adapter-owned recorded native sessions may be resumed');
        if ([...sessions.values()].some(session => session.bindingId === params.bindingId)) throw invalid('binding is already owned by another conversation');
        if (runtime.gateway.closed) throw new ProtocolError(-32002, 'native Gateway is closed');
        if (sessions.size >= MAX_SESSIONS) throw invalid('session bound exceeded');
        if (runtime.ownership === 'connected' && (sessions.size || params.sessionId && params.sessionId !== runtime.connection.sessionId)) throw invalid('connected lifecycle observes only the explicitly selected native session');
        const session = { conversationId: params.conversationId, bindingId: params.bindingId,
          sessionKey: runtime.ownership === 'connected' ? runtime.connection.sessionKey : `agent:${runtime.agentId}:${nativeId(params.bindingId, params.conversationId)}`, state: 'unknown', reference };
        sessions.set(session.conversationId, session); await persist();
        if (runtime.ownership === 'connected') {
          let history;
          try { history = await runtime.gateway.call('chat.history', { sessionKey: session.sessionKey, agentId: runtime.agentId, sessionId: runtime.connection.sessionId, limit: 1 }); }
          catch { throw new ProtocolError(-32031, 'selected native session could not be observed; no session was created or resumed'); }
          if (history?.sessionKey !== session.sessionKey || history?.sessionId !== runtime.connection.sessionId || history?.sessionInfo?.agentId !== runtime.agentId) throw new ProtocolError(-32031, 'selected native agent/session identity was not verified');
          session.sessionId = history.sessionId;
          const subscribed = await runtime.gateway.call('sessions.messages.subscribe', { key: session.sessionKey, agentId: runtime.agentId, subscriptionId: nativeId('observer', params.bindingId) });
          if (subscribed?.ok !== true) throw new ProtocolError(-32031, 'selected native session observation was not acknowledged');
          session.state = 'open';
          return { sessionId: session.sessionId, recovery: 'snapshot-only', nativeHistoryHydrated: false };
        }
        let created;
        try { created = await runtime.gateway.call('sessions.create', { key: session.sessionKey, agentId: runtime.agentId, idempotencyKey: nativeId('session', params.bindingId, params.conversationId), cwd: runtime.workspace }); }
        catch { throw new ProtocolError(-32031, 'native session creation acknowledgement is uncertain; no replay'); }
        if (created?.ok !== true || created.key !== session.sessionKey || created.runStarted !== false || typeof created.sessionId !== 'string' || !created.sessionId || created.sessionId.length > 512 || created.entry?.sessionId !== created.sessionId) throw new ProtocolError(-32031, 'native session creation identity is unproven; no replay');
        session.sessionId = created.sessionId; session.state = 'open'; await persist();
        await runtime.gateway.call('sessions.messages.subscribe', { key: session.sessionKey, agentId: runtime.agentId, subscriptionId: nativeId('observer', params.bindingId) });
        return { sessionId: session.sessionId };
      }
      if (method === 'turn.submit') {
        const session = sessionFor(params);
        required(params.runId, 'runId'); required(params.attemptId, 'attemptId'); required(params.text, 'text', 64 * 1024);
        if (params.bindingId !== session.bindingId) throw invalid('turn requires the exact conversation binding');
        if (params.attachments) throw invalid('attachments are unsupported');
        const id = nativeId(session.bindingId, params.runId, params.attemptId); const fingerprint = sha(params.text);
        const previous = runs.get(id);
        if (previous) { if (previous.fingerprint !== fingerprint || previous.conversationId !== session.conversationId) throw invalid('attempt ID was reused for another input or conversation'); return previous.receipt; }
        if (!runtime.authAvailable) return { status: 'unsupported', handoff: 'not-submitted', reason: 'subscription authentication is not implemented; provide only an explicit local proof provider' };
        if (runtime.gateway.closed) return unknown('Gateway is closed; session state is uncertain');
        if ([...runs.values()].some(run => run.conversationId === session.conversationId && !['completed', 'failed', 'stopped'].includes(run.state))) return { status: 'busy', handoff: 'not-submitted', reason: 'adapter-owned work is active or uncertain' };
        if (runs.size >= MAX_RECORDS) throw invalid('attempt journal bound exceeded');
        // Reserve before the read to serialize racing fresh topics. Only an idle,
        // branch-CAS send uses followup, so fresh input is never converted to steer.
        const run = { nativeId: id, conversationId: session.conversationId, sessionKey: session.sessionKey, runId: params.runId, attemptId: params.attemptId, fingerprint,
          receipt: unknown('attempt reserved; native handoff has not been proven'), state: 'admitting', text: '', seq: -1 };
        runs.set(id, run); await persist();
        let history;
        try { history = await runtime.gateway.call('chat.history', { sessionKey: session.sessionKey, agentId: runtime.agentId, sessionId: session.sessionId, limit: 1 }); }
        catch { run.state = 'unknown'; await persist(); return run.receipt; }
        const info = history?.sessionInfo;
        if (history?.sessionKey !== session.sessionKey || history?.sessionId !== session.sessionId || info?.agentId !== runtime.agentId || !Array.isArray(info?.activeRunIds) || !Object.hasOwn(info, 'activeLeafEntryId')) { run.state = 'unknown'; await persist(); return run.receipt; }
        if (info.activeRunIds.length || info.hasActiveRun !== false || history.inFlightRun) {
          runs.delete(id); await persist(); return { status: 'busy', handoff: 'not-submitted', reason: 'native session is active; input was not submitted' };
        }
        let receipt;
        // Every post-handoff error remains unknown; native durable idempotency is
        // additional protection, never an excuse to replay an uncertain send.
        try {
          receipt = await runtime.gateway.call('chat.send', { sessionKey: session.sessionKey, sessionId: session.sessionId, agentId: runtime.agentId, message: params.text,
            idempotencyKey: id, queueMode: 'followup', suppressCommandInterpretation: true, expectedLeafEntryId: info.activeLeafEntryId, deliver: false });
          if (receipt?.runId !== id || receipt.status !== 'started') throw new Error('native acknowledgement is queued, redirected or malformed');
          run.receipt = { status: 'accepted' }; if (run.state === 'admitting') run.state = 'running';
          await persist(); event(session, 'turn.started', { background: false }, run);
        } catch { run.receipt = unknown('native send acknowledgement is lost, queued or malformed; no replay'); if (!['completed', 'failed', 'stopped'].includes(run.state)) run.state = 'unknown'; await persist(); }
        const buffered = pendingEvents.get(run.nativeId) ?? []; pendingEvents.delete(run.nativeId);
        frames = frames.then(async () => { for (const frame of buffered) await onFrame(frame); });
        await frames;
        return run.receipt;
      }
      if (method === 'run.stop') {
        const { session, run } = runFor(params);
        return reserveOperation(params, method, async () => {
          if (['completed', 'failed', 'stopped'].includes(run.state)) return { status: 'rejected', reason: 'native run is already terminal' };
          const result = await runtime.gateway.call('chat.abort', { sessionKey: session.sessionKey, agentId: runtime.agentId, runId: run.nativeId, preserveSideRuns: true, discardPendingInput: false });
          if (result?.ok !== true || result.aborted !== true || !Array.isArray(result.runIds) || result.runIds.length !== 1 || result.runIds[0] !== run.nativeId) return unknown('Gateway did not prove abort of exactly the origin run');
          if (!['completed', 'failed', 'stopped'].includes(run.state)) run.state = 'stopping';
          return { status: 'requested', reason: 'native cancellation requested; awaiting terminal event' };
        });
      }
      if (['task.steer', 'task.stop', 'request.answer'].includes(method)) {
        runFor(params);
        if (method.startsWith('task.')) required(params.taskId, 'taskId');
        return reserveOperation(params, method, async () => ({ status: 'unsupported', handoff: 'not-submitted', reason: `${method} has no proven native ownership/permission mapping in this prototype` }));
      }
      if (method === 'session.snapshot') {
        const session = sessionFor(params); await frames;
        const current = [...runs.values()].find(run => run.conversationId === session.conversationId && !['completed', 'failed', 'stopped'].includes(run.state));
        return { sessionId: session.sessionId, tasks: [], current: current ? { runId: current.runId, attemptId: current.attemptId, text: current.text, state: current.state } : null,
          cursor: { epoch: runtime.gateway.epoch ?? nonce, sequence }, runtime: runtime.gateway.closed ? 'closed' : 'connected', recovery: 'snapshot-only', nativeHistoryHydrated: false };
      }
      throw new ProtocolError(-32601, `unsupported adapter method: ${method}`);
    },
    async drain() { await frames; await writing; },
  };
}

export function serve(input = process.stdin, output = process.stdout) {
  let buffer = Buffer.alloc(0); let pending = 0; let failed = false;
  const send = frame => {
    const encoded = JSON.stringify(frame) + '\n';
    if (Buffer.byteLength(encoded) > FRAME_LIMIT || output.writableLength > 8 * 1024 * 1024) { fail(); return; }
    if (!failed) output.write(encoded);
  };
  const adapter = createAdapter({ emit: params => send({ jsonrpc: '2.0', method: 'harness.event', params }) });
  const fail = () => { if (failed) return; failed = true; input.destroy(); void adapter.handle('shutdown').catch(() => {}); };
  input.on('data', chunk => {
    buffer = Buffer.concat([buffer, Buffer.from(chunk)]);
    for (;;) {
      const index = buffer.indexOf(10); if (index < 0) break;
      if (index > FRAME_LIMIT) return fail();
      const line = buffer.subarray(0, index); buffer = buffer.subarray(index + 1);
      let request;
      try { request = JSON.parse(line.toString('utf8')); } catch { return fail(); }
      if (request?.jsonrpc !== '2.0' || typeof request.method !== 'string' || !['string', 'number'].includes(typeof request.id) || typeof request.id === 'number' && !Number.isFinite(request.id)) { send({ jsonrpc: '2.0', id: request?.id ?? null, error: { code: -32600, message: 'request requires JSON-RPC method and id' } }); continue; }
      if (pending >= 32) { send({ jsonrpc: '2.0', id: request.id, error: { code: -32003, message: 'pending request bound exceeded' } }); continue; }
      pending++;
      Promise.resolve().then(() => adapter.handle(request.method, request.params)).then(result => send({ jsonrpc: '2.0', id: request.id, result }), error => send({ jsonrpc: '2.0', id: request.id, error: { code: error.code ?? -32000, message: String(error.message).slice(0, 512), ...(error.data ? { data: error.data } : {}) } })).finally(() => { pending--; });
    }
    if (buffer.length > FRAME_LIMIT) fail();
  });
  input.on('end', () => { void adapter.handle('shutdown').catch(() => {}); });
  input.on('error', fail); output.on('error', fail);
  return adapter;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) serve();

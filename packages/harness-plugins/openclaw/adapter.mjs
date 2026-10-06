#!/usr/bin/env node
/** Transport only: the pinned OpenClaw Gateway owns planning and the entire agent loop. */
import { NATIVE_PINS, INPUT_CONTRACT, RUNTIME_IDENTITY, OWNER_SCHEMA, JOURNAL_SCHEMA, memoryContract, validateLiteralOwner } from './literal-migration.mjs';
// The bridge lives inside the native plugin package: the pinned Gateway captures a
// plugin as a self-contained package (nearest package.json), so shared code outside
// it would require a read grant beyond the plugin tree.
import { uniformMemoryConfig, createMemoryHostBridge, attachMemoryHost, createAdapterMemoryClient } from './memory-plugin/memory-bridge.mjs';
import { spawn, execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdir, readFile, writeFile, rename, readdir, lstat, realpath, rm, open } from 'node:fs/promises';
import { closeSync, fstatSync } from 'node:fs';
import { resolve, join, dirname, isAbsolute, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes, randomUUID, createHash, generateKeyPairSync, createPrivateKey, createPublicKey, sign } from 'node:crypto';

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

export const UPSTREAM = Object.freeze({ version: '2026.9.8', commit: 'fc23bc864e4553c2d215e479eeec47b67a0bf943', protocol: 4 });
export const CURATED_RUNTIME = Object.freeze({ sourceCommit: 'f04797ef4d24f3da0f9df74acd58ab773ab5f11e', patchSha256: '601c2eea193de989977a122a98bda8653910848092f7c4937195e40bf63ebc4e', entry: 'dist/yorozu-gateway-embedding.js', transport: 'inherited-fd-v1' });
export const CAPABILITIES = Object.freeze({ backgroundTasks: false, targetedSteer: false, taskStop: false, approvals: false, reconnect: false, attachments: false });
export const EXTENSIONS = Object.freeze({ version: 1, connectedLifecycle: false, conversationActions: false, autonomousEvents: false, agentMessaging: false });
const FRAME_LIMIT = 256 * 1024;
/** Native memory plugin shipped beside this adapter; the only tool uniform mode can grant. */
const MEMORY_PLUGIN_DIRECTORY = join(dirname(fileURLToPath(import.meta.url)), 'memory-plugin');
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
export async function atomic(path, value, io = { open, rename }) {
  try { await regular(path, 4 * 1024 * 1024); } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const temporary = `${path}.${randomUUID()}.tmp`;
  const file = await io.open(temporary, 'wx', 0o600);
  try { await file.writeFile(JSON.stringify(value) + '\n'); await file.sync(); } finally { await file.close(); }
  await io.rename(temporary, path);
  const directory = await io.open(dirname(path), 'r');
  try { await directory.sync(); } finally { await directory.close(); }
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
  for (const key of ['source', 'node', 'workspace', 'profileDir', 'scope', 'isolation', 'providerConfigPath', 'platform', 'gatewayPort', 'gatewayListener', 'git']) {
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
/** Uniform host-owned memory: trusted host selection only. Accepts the exact
 * narrow resource scope this implementation proves: no tools, or only `memory`.
 * The grant boolean decides whether the native memory plugin/tool exists at all.
 */
export function validateWorkerMemory(params) {
  if (params.workerMemory !== undefined && typeof params.workerMemory !== 'boolean') throw invalid('workerMemory must be boolean');
  const workerMemory = params.workerMemory === true;
  if (!workerMemory) return { workerMemory, memoryGranted: false };
  if (validateLifecycle(params).mode !== 'managed') throw invalid('uniform memory requires a managed owned profile');
  const tools = params.scope?.allowedTools;
  if (!Array.isArray(tools) || tools.some(tool => tool !== 'memory') || tools.length > 1) throw invalid('uniform memory supports only an empty resource scope or exactly [memory]');
  return { workerMemory, memoryGranted: tools.includes('memory') };
}
/** Trusted host record only: after nested code signing the sealed Node's bytes differ
 * from the unsigned development pin. The host supplies the hash it verified from the
 * sealed inventory under the outer bundle signature; chat or events never can. */
export function validateNodeIntegrity(value) {
  if (value === undefined) return undefined;
  only(value, ['sha256', 'hashStage'], 'nodeIntegrity');
  if (!/^[a-f0-9]{64}$/.test(value.sha256 ?? '') || value.hashStage !== 'after-nested-signing-before-outer-bundle-signing') throw invalid('unsupported sealed Node integrity record');
  return { sha256: value.sha256, hashStage: value.hashStage };
}
/** Trusted host record only: the host verified exact commit, clean tree and full
 * upstream diff of a sealed input outside the sandbox. Accepted only when it names
 * this adapter's exact pins; every file-hash and Node pin below still applies. */
export function validateSourceIntegrity(value) {
  if (value === undefined) return undefined;
  only(value, ['kind', 'sourceSha', 'patchSha256'], 'sourceIntegrity');
  if (value.kind !== 'sealed-inventory-v1' || value.sourceSha !== CURATED_RUNTIME.sourceCommit || value.patchSha256 !== CURATED_RUNTIME.patchSha256) throw invalid('unsupported sealed source integrity record');
  return { kind: value.kind, sourceSha: value.sourceSha, patchSha256: value.patchSha256 };
}
export async function prepareRuntime(params) {
  if (validateLifecycle(params).mode !== 'managed') throw invalid('connected lifecycle must use the connection launcher');
  only(params, ['protocolVersion', 'upstreamVersion', 'source', 'node', 'workspace', 'profileDir', 'agentId', 'scope', 'isolation', 'providerConfigPath', 'platform', 'gatewayPort', 'gatewayListener', 'lifecycle', 'git', 'workerMemory', 'nodeIntegrity', 'sourceIntegrity'], 'initialize');
  const nodeIntegrity = validateNodeIntegrity(params.nodeIntegrity);
  const sourceIntegrity = validateSourceIntegrity(params.sourceIntegrity);
  if (sourceIntegrity && params.git !== undefined) throw invalid('a sealed source integrity record and a git verifier are mutually exclusive');
  const memory = validateWorkerMemory(params);
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
  if (!sourceIntegrity) {
    // Development inputs: verify exact commit, clean tree and the full upstream diff
    // with git. A sealed app input has no git toolchain inside the seatbelt; its host
    // verified the same facts outside and supplied the exact record checked above.
    const git = params.git === undefined ? '/usr/bin/git' : await realpath(absolute(params.git, 'git'));
    await regular(git, 16 * 1024 * 1024);
    const gitOptions = { maxBuffer: 4096, env: { PATH: '/usr/bin:/bin', TMPDIR: scoped.profileDir, GIT_OPTIONAL_LOCKS: '0', GIT_CONFIG_NOSYSTEM: '1', GIT_CONFIG_GLOBAL: '/dev/null' } };
    const revision = await exec(git, ['-C', source, 'rev-parse', 'HEAD'], gitOptions);
    if (revision.stdout.trim() !== CURATED_RUNTIME.sourceCommit) throw invalid('OpenClaw source commit does not match the explicit curated pin; stock sources are gated');
    await exec(git, ['-C', source, 'diff', '--quiet', 'HEAD', '--'], gitOptions);
    const patch = await exec(git, ['-C', source, 'diff', UPSTREAM.commit, 'HEAD', '--binary', '--abbrev=8', '--no-color', '--no-ext-diff', '--no-textconv', '--src-prefix=a/', '--dst-prefix=b/'], { ...gitOptions, maxBuffer: 512 * 1024 });
    if (sha(patch.stdout) !== CURATED_RUNTIME.patchSha256) throw invalid('OpenClaw curated patch digest does not match the approved base and patch');
  }
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
  for (const [path, digest] of [
    ['dist/build-info.json', NATIVE_PINS.buildInfoSha256],
    [CURATED_RUNTIME.entry, NATIVE_PINS.entrySha256],
    ['dist/protocol.schema.json', NATIVE_PINS.protocolSchemaSha256],
    ['pnpm-lock.yaml', NATIVE_PINS.lockfileSha256],
  ]) {
    await regular(join(source, path), 16 * 1024 * 1024);
    if (sha(await readFile(join(source, path))) !== digest) throw invalid('native artifact does not match the development pin');
  }
  await regular(node, 256 * 1024 * 1024);
  if (![NATIVE_PINS.node.binarySha256, ...(nodeIntegrity ? [nodeIntegrity.sha256] : [])].includes(sha(await readFile(node)))) throw invalid('Node binary does not match the development pin or the trusted sealed integrity record');
  const build = JSON.parse(await readFile(join(source, 'dist', 'build-info.json'), 'utf8'));
  if (build.commit !== CURATED_RUNTIME.sourceCommit || build.version !== UPSTREAM.version) throw invalid('OpenClaw build metadata does not match the explicit curated source pin');
  const probe = await exec(node, ['--input-type=module', '-e', 'process.stdout.write(JSON.stringify({version:process.versions.node,sqlite:!!process.getBuiltinModule("node:sqlite")}))'], { env: { PATH: '/usr/bin:/bin', NODE_DISABLE_COMPILE_CACHE: '1' }, maxBuffer: 4096 });
  const nodeInfo = JSON.parse(probe.stdout);
  if (!nodeInfo.sqlite || nodeInfo.version !== NATIVE_PINS.node.version) throw invalid('unsupported OpenClaw Node runtime; automatic recovery/install is disabled');
  await directory(scoped.profileDir);
  const marker = join(scoped.profileDir, '.yorozu-openclaw-owner.json');
  const owner = { schema: OWNER_SCHEMA, inputContract: INPUT_CONTRACT, memoryContract: memoryContract(memory.workerMemory), runtimeIdentity: RUNTIME_IDENTITY, pluginId: 'openclaw', upstream: UPSTREAM.commit, curatedSource: CURATED_RUNTIME.sourceCommit, patchSha256: CURATED_RUNTIME.patchSha256, agentId: scoped.agentId };
  try {
    await regular(marker, 2048);
    const previous = JSON.parse(await readFile(marker, 'utf8'));
    validateLiteralOwner(previous, owner);
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
  return { ...scoped, ...memory, source, node, home, state, temporary, provider, gatewayPort: params.gatewayPort, authAvailable: Boolean(provider), journalPath: join(scoped.profileDir, 'adapter-journal-v1.json') };
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

/** Uniform mode replaces retained native memory/plugin/hook settings AFTER the
 * retained-configuration merge, so a previous profile edit can never merge a
 * native memory provider, plugin or hook back in. Without the uniform selection
 * the managed prototype keeps its retained native settings unchanged. */
export function effectiveRuntimeConfig(previousConfig, runtime, port, token) {
  const merged = mergeRuntimeConfig(previousConfig, runtimeConfig(runtime, port, token), runtime.agentId);
  if (runtime.workerMemory !== true) return merged;
  return uniformMemoryConfig(merged, MEMORY_PLUGIN_DIRECTORY, runtime.agentId, runtime.memoryGranted === true);
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
/** FD3 is the unchanged inherited Gateway listener. A granted uniform memory tool
 * adds one private duplex pipe at FD4 for the native plugin; never a listener. */
export function nativeGatewayLaunch(runtime) {
  return { command: runtime.node, args: [join(runtime.source, CURATED_RUNTIME.entry), '--port', String(runtime.gatewayPort)],
    options: { cwd: runtime.workspace, env: runtimeEnvironment(runtime), stdio: ['ignore', 'pipe', 'pipe', 3, ...(runtime.memoryGranted === true ? ['pipe'] : [])] } };
}
// Private isolated-client identity only. Native pairing policy remains authoritative;
// never imports a production identity, fabricates a principal, or broadens scopes.
export async function localDeviceIdentity(profileDir) {
  const path = join(profileDir, 'adapter-device-v1.json');
  let saved;
  try {
    await regular(path, 4096); const info = await lstat(path);
    if (info.nlink !== 1 || info.mode & 0o077) throw invalid('isolated device identity permissions are invalid');
    saved = JSON.parse(await readFile(path, 'utf8'));
  }
  catch (error) {
    if (error.code !== 'ENOENT') throw invalid('isolated device identity is invalid');
    const pair = generateKeyPairSync('ed25519');
    saved = { version: 1, privateKey: pair.privateKey.export({ type: 'pkcs8', format: 'pem' }) };
    await atomic(path, saved);
  }
  try {
    only(saved, ['version', 'privateKey'], 'isolated device identity');
    if (saved.version !== 1) throw new Error();
    const key = createPrivateKey(saved.privateKey);
    if (key.asymmetricKeyType !== 'ed25519') throw new Error();
    const raw = createPublicKey(key).export({ format: 'jwk' }).x;
    const publicKey = Buffer.from(raw, 'base64url').toString('base64url');
    return { key, publicKey, id: createHash('sha256').update(Buffer.from(publicKey, 'base64url')).digest('hex') };
  } catch { throw invalid('isolated device identity is invalid'); }
}
export function signedDevice(identity, nonce, token, platform = process.platform, signedAt = Date.now()) {
  const payload = ['v3', identity.id, 'gateway-client', 'backend', 'operator', 'operator.read,operator.write', String(signedAt), token, nonce, platform.trim().toLowerCase(), ''].join('|');
  return { id: identity.id, publicKey: identity.publicKey, signature: sign(null, Buffer.from(payload), identity.key).toString('base64url'), signedAt, nonce };
}
export class NativeGateway {
  constructor(url, token, child, { WebSocketClass = WebSocket, timeoutMs = 10_000, ownership = 'managed', device } = {}) {
    this.device = device;
    this.url = url; this.token = token; this.child = child; this.WebSocketClass = WebSocketClass; this.timeoutMs = timeoutMs;
    this.pending = new Map(); this.listeners = new Set(); this.closeListeners = new Set(); this.nextId = 0; this.closed = false; this.connected = false;
    this.ownership = ownership; this.released = Promise.resolve();
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
    const challenged = await challenge;
    // gateway-client/backend is the upstream generic embedding class. This is an
    // isolated loopback token session with a private signed device when supplied.
    // Native pairing policy is enforced; issued device tokens are not retained,
    // no production identity is imported, and admin scope is never requested.
    const hello = await this.call('connect', {
      minProtocol: UPSTREAM.protocol, maxProtocol: UPSTREAM.protocol,
      client: { id: 'gateway-client', displayName: 'Yorozu harness connection', version: '1', platform: process.platform, mode: 'backend', instanceId: randomUUID() },
      role: 'operator', scopes: ['operator.read', 'operator.write'], auth: { token: this.token }, caps: ['session-scoped-events'],
      ...(this.device ? { device: signedDevice(this.device, challenged.nonce, this.token) } : {}),
    });
    if (hello?.type !== 'hello-ok' || hello.protocol !== UPSTREAM.protocol || hello.server?.version !== UPSTREAM.version || hello.auth?.role !== 'operator'
      || hello.auth?.method !== 'token' || (!this.device && hello.auth?.deviceToken) || !['operator.read', 'operator.write'].every(scope => hello.auth?.scopes?.includes(scope))
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
    // The shutdown receipt must not precede the profile ownership release.
    await this.released;
  }
  async detach() {
    // This client owns a socket, never the external service/process or its work.
    // No native shutdown/abort/session-delete method is issued.
    this.finish('Yorozu client detached; native service remains externally owned');
  }
}

export function verifyInheritedListener(stat = fstatSync) {
  if (!stat(3).isSocket()) throw invalid('inherited listener must be a socket');
}

export async function launchRuntime(params, { callHost } = {}) {
  const lifecycle = validateLifecycle(params);
  if (lifecycle.mode === 'connected') {
    throw new ProtocolError(-32010, 'Connected lifecycle is held: durable custody and restart guarantees are unproven; no connection was made');

  }
  const runtime = await prepareRuntime(params);
  if (runtime.memoryGranted && typeof callHost !== 'function') throw invalid('uniform memory grant requires the private host memory callback');
  const lock = join(runtime.profileDir, '.adapter-owner.lock');
  try { await mkdir(lock, { mode: 0o700 }); } catch (error) { if (error.code === 'EEXIST') throw invalid('private profile already has an owner; stale ownership requires explicit recovery'); throw error; }
  let child;
  let listenerReleased = false;
  const releaseListener = () => { if (!listenerReleased) { listenerReleased = true; verifyInheritedListener(); closeSync(3); } };
  try {
    verifyInheritedListener();
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
    const config = effectiveRuntimeConfig(previousConfig, runtime, port, token);
    await atomic(configPath, config);
    const bridge = runtime.memoryGranted ? createMemoryHostBridge({ agentId: runtime.agentId, callHost }) : undefined;
    const launch = nativeGatewayLaunch(runtime);
    child = spawn(launch.command, launch.args, launch.options);
    child.stdout.on('data', () => {}); // Consume logs without treating them as protocol or exposing private context.
    child.stderr.on('data', () => {});
    // The private FD4 duplex belongs to this adapter and the native plugin only.
    const memoryWire = bridge ? attachMemoryHost(child.stdio[4], bridge) : undefined;
    await new Promise((yes, no) => { child.once('spawn', yes); child.once('error', no); });
    releaseListener(); // The native child owns its duplicated descriptor from this point.
    let childError;
    child.on('error', error => { childError = error; });
    const gateway = new NativeGateway(`ws://127.0.0.1:${port}`, token, child, { device: await localDeviceIdentity(runtime.profileDir) });
    // Ownership release is awaited by shutdown: the host may kill this adapter right
    // after the shutdown receipt, and an unfinished removal would orphan the lock.
    child.on('exit', (code, signal) => { gateway.finish(code === 78 ? 'native Gateway rejected configuration (exit 78)' : `native Gateway exited (${signal ?? code})`); gateway.released = rm(lock, { recursive: true, force: true }).catch(() => {}); });
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
    return { ...runtime, gateway, ...(bridge ? { memory: { bridge, wire: memoryWire } } : {}) };
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

export function createAdapter({ launch = launchRuntime, emit = () => {}, callHost } = {}) {
  let runtime; let initializing = false; let initialized = false;
  const sessions = new Map(); const runs = new Map(); const operations = new Map();
  const pendingEvents = new Map(); const observedSessions = new Set();
  // RAM-only native memory admissions. Revokers are never journaled, so a restart
  // cannot reconstruct a capability for work whose outcome is unknown.
  const revokers = new Map();
  const revoke = nativeRunId => { const revoker = revokers.get(nativeRunId); if (revoker) { revokers.delete(nativeRunId); revoker(); } };
  const revokeAll = () => { for (const id of [...revokers.keys()]) revoke(id); };
  const nonce = randomUUID(); let sequence = 0; let writing = Promise.resolve(); let frames = Promise.resolve();
  const journal = () => ({ schema: JOURNAL_SCHEMA, inputContract: INPUT_CONTRACT, memoryContract: memoryContract(runtime.workerMemory === true), runtimeIdentity: RUNTIME_IDENTITY, upstream: UPSTREAM.commit, curatedSource: CURATED_RUNTIME.sourceCommit, agentId: runtime.agentId, sessions: [...sessions.values()], runs: [...runs.values()], operations: [...operations.values()] });
  const persist = () => {
    if (!runtime.journalPath) return Promise.resolve();
    const value = journal();
    const next = writing.then(() => atomic(runtime.journalPath, value));
    writing = next.catch(() => {}); return next;
  };
  const blockedProjections = new Set();
  const event = (session, kind, data, run) => {
    const key = run?.nativeId;
    if (kind === 'assistant.update' && blockedProjections.has(key)) return;
    const projected = boundedProjection(emit, { protocolVersion: 1, eventId: `${nonce}:${++sequence}`, conversationId: session.conversationId,
    ...(run ? { runId: run.runId, attemptId: run.attemptId } : {}), kind, data });
    if (!projected && key) blockedProjections.add(key);
    if (kind === 'turn.terminal') blockedProjections.delete(key);
  };
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
    only(saved, ['schema', 'inputContract', 'memoryContract', 'runtimeIdentity', 'upstream', 'curatedSource', 'agentId', 'sessions', 'runs', 'operations'], 'adapter journal');
    if (saved.schema !== JOURNAL_SCHEMA || saved.inputContract !== INPUT_CONTRACT || saved.memoryContract !== memoryContract(runtime.workerMemory === true) || saved.runtimeIdentity !== RUNTIME_IDENTITY || saved.upstream !== UPSTREAM.commit || saved.curatedSource !== CURATED_RUNTIME.sourceCommit || saved.agentId !== runtime.agentId || !Array.isArray(saved.sessions) || saved.sessions.length > MAX_SESSIONS || !Array.isArray(saved.runs) || saved.runs.length > MAX_RECORDS || !Array.isArray(saved.operations) || saved.operations.length > MAX_RECORDS) throw invalid('adapter journal identity or limits are invalid');
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
    // Native chat `seq` is the shared per-run agent-event counter (tool, item, status
    // and lifecycle events consume numbers too, and paced deltas are merged), so chat
    // events are strictly increasing but not consecutive. Ordering is enforced above;
    // the terminal event carries the complete native message, never patched text.
    run.seq = data.seq;
    if (data.state === 'delta') {
      if (typeof data.deltaText !== 'string') return;
      const candidate = data.replace === true ? data.deltaText : run.text + data.deltaText;
      if (Buffer.byteLength(candidate) > 128 * 1024) { event(session, 'capability.unavailable', { capability: 'replySize', reason: 'native text exceeded the projection bound; native work was not interrupted' }, run); return; }
      run.text = candidate;
      await persist(); event(session, 'assistant.update', { text: run.text }, run);
    } else if (['final', 'aborted', 'error'].includes(data.state)) {
      // Memory authority ends with the run, before any terminal projection.
      revoke(run.nativeId);
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
    revokeAll(); runtime.memory?.bridge.close();
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
          validateLifecycle(params); validateWorkerMemory(params);
          if (params.workerMemory === true && typeof callHost !== 'function') throw invalid('uniform memory requires the private host memory callback');
          runtime = await launch(params, { callHost }); await loadJournal();
          if (runtime.memoryGranted && !runtime.memory?.bridge) throw invalid('uniform memory grant was not actually attached to the native Gateway');
          runtime.gateway.onFrame(frame => { frames = frames.then(() => onFrame(frame)).catch(() => { runtime.gateway.finish?.('native event processing failed'); closed('native event processing failed'); }); });
          runtime.gateway.onClose(closed); initialized = true;
          // Acknowledged only after the actual uniform configuration, bridge and
          // Gateway readiness; absence of the flag never permits a native fallback.
          return { protocolVersion: 1, pluginId: 'openclaw', upstreamVersion: UPSTREAM.version, capabilities: CAPABILITIES, extensions: EXTENSIONS,
            ...(runtime.workerMemory === true ? { workerMemory: true } : {}),
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
        revokeAll(); runtime.memory?.bridge.close();
        await runtime.gateway.shutdown(); await writing; return { stopped: runtime.gateway.closed };
      }
      if (['workerMemory', 'agentId', 'scope', 'isolation', 'platform', 'workspace', 'profileDir', 'source', 'node', 'nodeIntegrity', 'sourceIntegrity', 'providerConfigPath', 'lifecycle', 'connection', 'git'].some(key => params[key] !== undefined)) throw invalid('agent authority and runtime paths are immutable after initialize');
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
          observedSessions.delete(previous.sessionKey);
          const subscribed = await runtime.gateway.call('sessions.messages.subscribe', { key: previous.sessionKey, agentId: runtime.agentId, subscriptionId: nativeId('observer', params.bindingId) });
          if (subscribed?.subscribed !== true || subscribed.key !== previous.sessionKey || subscribed.agentId !== runtime.agentId) throw new ProtocolError(-32031, 'native session observation was not acknowledged');
          observedSessions.add(previous.sessionKey);
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
          try { history = await runtime.gateway.call('chat.history', { sessionKey: session.sessionKey, agentId: runtime.agentId, limit: 1 }); }
          catch { throw new ProtocolError(-32031, 'selected native session could not be observed; no session was created or resumed'); }
          if (history?.sessionKey !== session.sessionKey || history?.sessionId !== runtime.connection.sessionId || history?.sessionInfo?.agentId !== runtime.agentId) throw new ProtocolError(-32031, 'selected native agent/session identity was not verified');
          session.sessionId = history.sessionId;
          const subscribed = await runtime.gateway.call('sessions.messages.subscribe', { key: session.sessionKey, agentId: runtime.agentId, subscriptionId: nativeId('observer', params.bindingId) });
          if (subscribed?.subscribed !== true || subscribed.key !== session.sessionKey || subscribed.agentId !== runtime.agentId) throw new ProtocolError(-32031, 'selected native session observation was not acknowledged');
          observedSessions.add(session.sessionKey);
          session.state = 'open';
          return { sessionId: session.sessionId, recovery: 'snapshot-only', nativeHistoryHydrated: false };
        }
        let created;
        try { created = await runtime.gateway.call('sessions.create', { key: session.sessionKey, agentId: runtime.agentId, idempotencyKey: nativeId('session', params.bindingId, params.conversationId), cwd: runtime.workspace }); }
        catch { throw new ProtocolError(-32031, 'native session creation acknowledgement is uncertain; no replay'); }
        if (created?.ok !== true || created.key !== session.sessionKey || created.runStarted !== false || typeof created.sessionId !== 'string' || !created.sessionId || created.sessionId.length > 512 || created.entry?.sessionId !== created.sessionId) throw new ProtocolError(-32031, 'native session creation identity is unproven; no replay');
        session.sessionId = created.sessionId; session.state = 'open'; await persist();
        const subscribed = await runtime.gateway.call('sessions.messages.subscribe', { key: session.sessionKey, agentId: runtime.agentId, subscriptionId: nativeId('observer', params.bindingId) });
        if (subscribed?.subscribed !== true || subscribed.key !== session.sessionKey || subscribed.agentId !== runtime.agentId) throw new ProtocolError(-32031, 'native session observation was not acknowledged');
        observedSessions.add(session.sessionKey);
        return { sessionId: session.sessionId };
      }
      if (method === 'turn.submit') {
        const session = sessionFor(params);
        if (!observedSessions.has(session.sessionKey)) return { status: 'busy', handoff: 'not-submitted', reason: 'native session subscription has not been acknowledged on this connection' };
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
        try { history = await runtime.gateway.call('chat.history', { sessionKey: session.sessionKey, agentId: runtime.agentId, limit: 1 }); }
        catch { run.state = 'unknown'; await persist(); return run.receipt; }
        const info = history?.sessionInfo;
        if (history?.sessionKey !== session.sessionKey || history?.sessionId !== session.sessionId || info?.agentId !== runtime.agentId || !Array.isArray(info?.activeRunIds) || !Object.hasOwn(info, 'activeLeafEntryId')) { run.state = 'unknown'; await persist(); return run.receipt; }
        if (info.activeRunIds.length || info.hasActiveRun !== false || history.inFlightRun) {
          runs.delete(id); await persist(); return { status: 'busy', handoff: 'not-submitted', reason: 'native session is active; input was not submitted' };
        }
        let receipt;
        // Exact native agent/key/SID/run identity is bound to this host execution
        // BEFORE the send, from trusted admitted context only. Currency is live for
        // the narrowly reserved admitting state and running; never unknown/terminal.
        if (runtime.memory) {
          try {
            revokers.set(id, runtime.memory.bridge.bind({ nativeRunId: id, nativeSessionId: session.sessionId, sessionKey: session.sessionKey,
              execution: { sessionId: session.sessionId, runId: params.runId, attemptId: params.attemptId },
              current: () => runs.get(id) === run && ['admitting', 'running'].includes(run.state) && !runtime.gateway.closed && sessions.get(session.conversationId) === session }));
          } catch { runs.delete(id); await persist(); return { status: 'rejected', reason: 'native memory admission could not be bound; input was not submitted' }; }
        }
        // Every post-handoff error remains unknown; native durable idempotency is
        // additional protection, never an excuse to replay an uncertain send.
        try {
          receipt = await runtime.gateway.call('chat.send', { sessionKey: session.sessionKey, sessionId: session.sessionId, agentId: runtime.agentId, message: params.text,
            idempotencyKey: id, queueMode: 'followup', inputMode: 'literal', expectedLeafEntryId: info.activeLeafEntryId, deliver: false });
          if (receipt?.runId !== id || receipt.status !== 'started') throw new Error('native acknowledgement is queued, redirected or malformed');
          run.receipt = { status: 'accepted' }; if (run.state === 'admitting') run.state = 'running';
          await persist(); event(session, 'turn.started', { background: false }, run);
        } catch { revoke(id); run.receipt = unknown('native send acknowledgement is lost, queued or malformed; no replay'); if (!['completed', 'failed', 'stopped'].includes(run.state)) run.state = 'unknown'; await persist(); }
        if (!['admitting', 'running'].includes(run.state)) revoke(id);
        const buffered = pendingEvents.get(run.nativeId) ?? []; pendingEvents.delete(run.nativeId);
        frames = frames.then(async () => { for (const frame of buffered) await onFrame(frame); });
        await frames;
        return run.receipt;
      }
      if (method === 'run.stop') {
        const { session, run } = runFor(params);
        return reserveOperation(params, method, async () => {
          if (['completed', 'failed', 'stopped'].includes(run.state)) return { status: 'rejected', reason: 'native run is already terminal' };
          revoke(run.nativeId); // Memory authority ends before the stop request, whatever its acknowledgement.
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
    let encoded = JSON.stringify(frame) + '\n';
    if (Buffer.byteLength(encoded) > FRAME_LIMIT) {
      if (frame.id === undefined) return;
      encoded = JSON.stringify({ jsonrpc: '2.0', id: frame.id, error: { code: -32010, message: 'response exceeds encoded projection bound' } }) + '\n';
      if (Buffer.byteLength(encoded) > FRAME_LIMIT) return;
    }
    if (output.writableLength > 8 * 1024 * 1024) { fail(); return; }
    if (!failed) output.write(encoded);
  };
  // Private host memory client: forwards checked execution currency and exact
  // per-request cancellation; it never discards the third authority argument.
  const memoryClient = createAdapterMemoryClient(send);
  const adapter = createAdapter({ emit: params => send({ jsonrpc: '2.0', method: 'harness.event', params }), callHost: memoryClient.callHost });
  const fail = () => { if (failed) return; failed = true; memoryClient.close(); input.destroy(); void adapter.handle('shutdown').catch(() => {}); };
  input.on('data', chunk => {
    buffer = Buffer.concat([buffer, Buffer.from(chunk)]);
    for (;;) {
      const index = buffer.indexOf(10); if (index < 0) break;
      if (index > FRAME_LIMIT) return fail();
      const line = buffer.subarray(0, index); buffer = buffer.subarray(index + 1);
      let request;
      try { request = JSON.parse(line.toString('utf8')); } catch { return fail(); }
      if (memoryClient.receive(request)) continue; // Host memory receipts are consumed before request parsing.
      if (request?.jsonrpc !== '2.0' || typeof request.method !== 'string' || !['string', 'number'].includes(typeof request.id) || typeof request.id === 'number' && !Number.isFinite(request.id)) { send({ jsonrpc: '2.0', id: request?.id ?? null, error: { code: -32600, message: 'request requires JSON-RPC method and id' } }); continue; }
      if (pending >= 32) { send({ jsonrpc: '2.0', id: request.id, error: { code: -32003, message: 'pending request bound exceeded' } }); continue; }
      pending++;
      Promise.resolve().then(() => adapter.handle(request.method, request.params)).then(result => send({ jsonrpc: '2.0', id: request.id, result }), error => send({ jsonrpc: '2.0', id: request.id, error: { code: error.code ?? -32000, message: String(error.message).slice(0, 512), ...(error.data ? { data: error.data } : {}) } })).finally(() => { pending--; });
    }
    if (buffer.length > FRAME_LIMIT) fail();
  });
  input.on('end', () => { memoryClient.close(); void adapter.handle('shutdown').catch(() => {}); });
  input.on('error', fail); output.on('error', fail);
  return adapter;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) serve();

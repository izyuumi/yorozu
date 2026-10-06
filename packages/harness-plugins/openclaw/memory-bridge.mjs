/** Private native/host memory bridge. No capability advertisement or ambient profile adoption. */
import { randomUUID } from 'node:crypto';

export const MEMORY_PLUGIN_ID = 'yorozu-worker-memory';
export const MEMORY_TOOL = 'worker_memory';
const MAX_FRAME = 48 * 1024;
const MAX_PENDING = 32;
const fail = () => new Error('Worker memory authority unavailable');
const object = value => value && typeof value === 'object' && !Array.isArray(value)
  && [Object.prototype, null].includes(Object.getPrototypeOf(value));
function exact(value, keys) {
  if (!object(value) || Object.keys(value).length !== keys.length || keys.some(key => !Object.hasOwn(value, key))) throw fail();
}
function identity(value) {
  if (typeof value !== 'string' || !value.trim() || Buffer.byteLength(value) > 512 || /[\0\r\n]/.test(value)) throw fail();
  return value;
}
const fields = Object.freeze({ read: ['action', 'ownerId', 'key'], search: ['action', 'ownerId', 'query'],
  write: ['action', 'key', 'body', 'operationId'], grant: ['action', 'toAgentId', 'key', 'operationId'], revoke: ['action', 'toAgentId', 'key', 'operationId'] });
export function memoryRequest(value) {
  if (!object(value) || !Object.hasOwn(fields, value.action)) throw fail();
  const keys = fields[value.action]; exact(value, keys);
  for (const key of keys) {
    const text = value[key]; const limit = key === 'body' ? 16384 : key === 'query' ? 256 : 128;
    if (typeof text !== 'string' || !text.trim() || text.includes('\0') || Buffer.byteLength(text) > limit) throw fail();
    if (['ownerId', 'toAgentId'].includes(key) && !/^[a-z][a-z0-9_-]{0,63}$/.test(text)) throw fail();
    if (['key', 'operationId'].includes(key) && !/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}$/.test(text)) throw fail();
  }
  return structuredClone(value);
}
function memoryResult(action, value) {
  if (action === 'read') {
    exact(value, ['value']);
    if (value.value !== null && (typeof value.value !== 'string' || Buffer.byteLength(value.value) > 16384)) throw fail();
  } else if (action === 'search') {
    exact(value, ['entries']);
    if (!Array.isArray(value.entries) || value.entries.length > 16) throw fail();
    for (const entry of value.entries) {
      exact(entry, ['key', 'body']); identity(entry.key);
      if (typeof entry.body !== 'string' || Buffer.byteLength(entry.body) > 8192) throw fail();
    }
  } else { exact(value, ['ok']); if (value.ok !== true) throw fail(); }
  return value;
}

/** Replaces (never merges) retained native memory/plugin/hook settings. Canonical
 * SQL stays in the parent sandbox; this configuration has no memory path grant.
 * contextInjection never also excludes AGENTS/USER ambient context intentionally.
 */
export function uniformMemoryConfig(config, pluginDirectory, agentId, memoryGranted = false) {
  if (typeof memoryGranted !== 'boolean') throw fail();
  identity(agentId);
  if (typeof pluginDirectory !== 'string' || !pluginDirectory.startsWith('/')) throw fail();
  const entry = config.agents?.entries?.[agentId];
  if (!entry) throw fail();
  const noMemory = { contextInjection: 'never', startupContext: { enabled: false },
    compaction: { memoryFlush: { enabled: false } } };
  return { ...config,
    agents: { ownership: 'explicit', defaults: { ...config.agents.defaults, ...noMemory, skipBootstrap: true },
      entries: { [agentId]: { ...entry, memory: { search: { enabled: false } }, contextInjection: 'never', tools: { ...(memoryGranted ? { allow: [MEMORY_TOOL] } : { deny: ['*'] }), elevated: { enabled: false } } } } },
    tools: { ...(memoryGranted ? { allow: [MEMORY_TOOL] } : { deny: ['*'] }), codeMode: false, elevated: { enabled: false }, agentToAgent: { enabled: false }, sessions: { visibility: 'self' } },
    memory: { search: { enabled: false } },
    hooks: { enabled: false, internal: { enabled: false } },
    plugins: { enabled: memoryGranted, allow: memoryGranted ? [MEMORY_PLUGIN_ID] : [], load: { paths: memoryGranted ? [pluginDirectory] : [] },
      slots: { memory: 'none' }, entries: memoryGranted ? { [MEMORY_PLUGIN_ID]: { enabled: true } } : {} },
  };
}

/** Exact admission map, populated before send. Never infer a run from latest session.
 * callHost MUST enforce authority.signal/assertCurrent at its final synchronous SQL
 * effect, including after approval. This requirement is not satisfied by a callback
 * that merely checks on entry. The regular host work-current fence is also required.
 */
export function createMemoryHostBridge({ agentId, callHost }) {
  identity(agentId); if (typeof callHost !== 'function') throw fail();
  const runs = new Map(); const admitted = new Set(); let closed = false;
  return Object.freeze({
    bind({ nativeRunId, nativeSessionId, sessionKey, execution, current }) {
      [nativeRunId, nativeSessionId, sessionKey].forEach(identity);
      exact(execution, ['sessionId', 'runId', 'attemptId']); Object.values(execution).forEach(identity);
      if (closed || admitted.has(nativeRunId) || admitted.size >= 4096 || runs.size >= 256 || typeof current !== 'function') throw fail();
      const controller = new AbortController();
      const binding = { nativeSessionId, sessionKey, execution: Object.freeze({ ...execution }), current, controller, used: new Set() };
      admitted.add(nativeRunId); runs.set(nativeRunId, binding);
      return () => { controller.abort(); if (runs.get(nativeRunId) === binding) runs.delete(nativeRunId); };
    },
    async dispatch(envelope, signal) {
      exact(envelope, ['agentId', 'nativeRunId', 'nativeSessionId', 'sessionKey', 'toolCallId', 'request']);
      for (const key of ['agentId', 'nativeRunId', 'nativeSessionId', 'sessionKey', 'toolCallId']) identity(envelope[key]);
      const binding = runs.get(envelope.nativeRunId);
      if (!binding || envelope.agentId !== agentId || envelope.nativeSessionId !== binding.nativeSessionId || envelope.sessionKey !== binding.sessionKey
        || binding.used.has(envelope.toolCallId) || binding.used.size >= 4096) throw fail();
      const request = memoryRequest(envelope.request);
      const combined = AbortSignal.any([binding.controller.signal, ...(signal ? [signal] : [])]);
      const assertCurrent = () => {
        if (closed || combined.aborted || runs.get(envelope.nativeRunId) !== binding || binding.current() !== true) throw fail();
      };
      assertCurrent(); binding.used.add(envelope.toolCallId);
      const result = await callHost('worker.memory', { execution: binding.execution, request }, { signal: combined, assertCurrent });
      assertCurrent(); return memoryResult(request.action, result);
    },
    close() { closed = true; for (const run of runs.values()) run.controller.abort(); runs.clear(); },
  });
}

/** JSON-line framing over an inherited private duplex pipe, not a listener. */
function channel(stream, onFrame, onClose) {
  let buffer = ''; let closed = false;
  const close = () => { if (!closed) { closed = true; stream.destroy(); onClose(); } };
  stream.setEncoding('utf8');
  stream.on('data', chunk => {
    if (closed) return;
    buffer += chunk;
    try {
      for (;;) {
        const end = buffer.indexOf('\n'); if (end < 0) break;
        const line = buffer.slice(0, end); buffer = buffer.slice(end + 1);
        if (Buffer.byteLength(line) > MAX_FRAME) throw fail();
        onFrame(JSON.parse(line));
      }
      if (Buffer.byteLength(buffer) > MAX_FRAME) throw fail();
    } catch { close(); }
  });
  stream.on('error', close); stream.on('close', close); stream.on('end', close);
  return { close, send(frame) {
    const line = JSON.stringify(frame) + '\n';
    if (closed || Buffer.byteLength(line) > MAX_FRAME || stream.writableLength > MAX_FRAME * MAX_PENDING) { close(); throw fail(); }
    stream.write(line);
  } };
}
export function attachMemoryHost(stream, bridge) {
  const pending = new Map();
  const wire = channel(stream, frame => {
    if (frame?.kind === 'cancel') {
      exact(frame, ['kind', 'id']); identity(frame.id); pending.get(frame.id)?.abort(); return;
    }
    exact(frame, ['kind', 'id', 'envelope']); identity(frame.id);
    if (frame.kind !== 'request' || pending.has(frame.id) || pending.size >= MAX_PENDING) throw fail();
    const controller = new AbortController(); pending.set(frame.id, controller);
    void bridge.dispatch(frame.envelope, controller.signal).then(
      result => { if (!controller.signal.aborted) wire.send({ kind: 'result', id: frame.id, result }); },
      () => { if (!controller.signal.aborted) wire.send({ kind: 'error', id: frame.id }); },
    ).catch(() => wire.close()).finally(() => pending.delete(frame.id));
  }, () => { for (const controller of pending.values()) controller.abort(); pending.clear(); bridge.close(); });
  return wire;
}
export function createMemoryNativeClient(stream, timeoutMs = 30000) {
  const pending = new Map();
  const wire = channel(stream, frame => {
    if (frame?.kind === 'result') exact(frame, ['kind', 'id', 'result']);
    else { exact(frame, ['kind', 'id']); if (frame.kind !== 'error') throw fail(); }
    identity(frame.id); const p = pending.get(frame.id); if (!p) return;
    pending.delete(frame.id); p.cleanup(); frame.kind === 'result' ? p.resolve(frame.result) : p.reject(fail());
  }, () => { for (const p of pending.values()) { p.cleanup(); p.reject(fail()); } pending.clear(); });
  return { close: wire.close, request(envelope, signal) {
    if (pending.size >= MAX_PENDING || signal?.aborted) return Promise.reject(fail());
    return new Promise((resolve, reject) => {
      const id = randomUUID();
      const cancel = () => { if (!pending.delete(id)) return; cleanup(); try { wire.send({ kind: 'cancel', id }); } catch {} reject(fail()); };
      const timer = setTimeout(cancel, timeoutMs); timer.unref?.();
      const cleanup = () => { clearTimeout(timer); signal?.removeEventListener('abort', cancel); };
      pending.set(id, { resolve, reject, cleanup }); signal?.addEventListener('abort', cancel, { once: true });
      try { wire.send({ kind: 'request', id, envelope }); } catch { pending.delete(id); cleanup(); reject(fail()); }
    });
  } };
}

/** Native preparation carries trusted HookContext into a per-factory WeakMap.
 * Unlike a session/toolCallId map, object custody cannot cross two live runs with
 * colliding provider tool IDs. No capability token enters model-visible arguments.
 * Native finalization transfers custody only when hooks preserved the exact request.
 */
export function registerMemoryPlugin(api, client) {
  api.registerTool({ contextVersion: 2, create(ctx) {
    if (typeof ctx.assertInvocationCurrent !== 'function') return null;
    const prepared = new WeakMap();
    const executable = new WeakMap();
    return { name: MEMORY_TOOL, label: 'Worker memory', description: 'Host-owned private memory. Sharing requires exact owner approval.',
      parameters: { type: 'object', properties: { action: { type: 'string', enum: Object.keys(fields) },
        ...Object.fromEntries(['ownerId', 'key', 'query', 'body', 'operationId', 'toAgentId'].map(name => [name, { type: 'string' }])) }, required: ['action'], additionalProperties: false },
      prepareBeforeToolCallParams(args, native) {
        ctx.assertInvocationCurrent();
        const hook = native?.hookContext;
        if (!hook || hook.agentId !== ctx.agentId || hook.sessionKey !== ctx.sessionKey || hook.sessionId !== ctx.sessionId
          || !native.signal || native.signal.aborted) throw fail();
        identity(hook.runId); identity(native.toolCallId);
        const request = memoryRequest(args);
        prepared.set(request, { runId: hook.runId, toolCallId: native.toolCallId,
          signal: native.signal, fingerprint: JSON.stringify(request) });
        return request;
      },
      finalizeBeforeToolCallParams(args, original) {
        ctx.assertInvocationCurrent();
        const permit = object(original) ? prepared.get(original) : undefined;
        if (!permit) throw fail();
        prepared.delete(original);
        const request = memoryRequest(args);
        if (JSON.stringify(request) !== permit.fingerprint) throw fail();
        permit.signal.throwIfAborted(); executable.set(request, permit);
        return request;
      },
      async execute(toolCallId, args, signal) {
        ctx.assertInvocationCurrent();
        const permit = object(args) ? executable.get(args) : undefined;
        if (!permit || permit.toolCallId !== toolCallId) throw fail();
        executable.delete(args);
        const request = memoryRequest(args);
        if (permit.fingerprint !== JSON.stringify(request)) throw fail();
        const combined = AbortSignal.any([permit.signal, ...(signal ? [signal] : [])]);
        combined.throwIfAborted(); ctx.assertInvocationCurrent();
        const result = memoryResult(request.action, await client.request({ agentId: ctx.agentId, sessionKey: ctx.sessionKey,
          nativeSessionId: ctx.sessionId, nativeRunId: permit.runId, toolCallId, request }, combined));
        combined.throwIfAborted(); ctx.assertInvocationCurrent();
        return { content: [{ type: 'text', text: JSON.stringify(result) }], details: result };
      } };
  } }, { names: [MEMORY_TOOL] });
}

/** Adapter-side private host JSON-RPC client. Pair with HarnessProcess's per-call
 * worker.memory.cancel handling. The host owns both actor binding and final SQL
 * guard; this client only forwards checked execution currency from the bridge.
 */
export function createAdapterMemoryClient(send, timeoutMs = 30000) {
  const pending = new Map(); const issued = new Set(); let closed = false;
  const close = () => {
    if (closed) return; closed = true;
    for (const p of pending.values()) { p.cleanup(); p.reject(fail()); }
    pending.clear();
  };
  return Object.freeze({ close,
    callHost(method, params, authority) {
      if (closed || method !== 'worker.memory' || pending.size >= MAX_PENDING || issued.size >= 4096
        || !authority?.signal || typeof authority.assertCurrent !== 'function') return Promise.reject(fail());
      try { authority.signal.throwIfAborted(); authority.assertCurrent(); } catch { return Promise.reject(fail()); }
      return new Promise((resolve, reject) => {
        const id = `memory-${randomUUID()}`;
        const cleanup = () => { clearTimeout(timer); authority.signal.removeEventListener('abort', cancel); };
        const cancel = () => {
          if (!pending.delete(id)) return;
          cleanup();
          try { send({ jsonrpc: '2.0', method: 'worker.memory.cancel', params: { requestId: id } }); }
          catch { close(); }
          reject(fail());
        };
        const timer = setTimeout(cancel, timeoutMs); timer.unref?.();
        issued.add(id); pending.set(id, { resolve, reject, cleanup, authority });
        authority.signal.addEventListener('abort', cancel, { once: true });
        try { send({ jsonrpc: '2.0', id, method, params }); }
        catch { pending.delete(id); cleanup(); reject(fail()); close(); }
      });
    },
    receive(frame) {
      if (typeof frame?.id !== 'string' || !issued.has(frame.id)) return false;
      const p = pending.get(frame.id);
      if (!p) return true; // Canceled/late outcome cannot become a new request.
      pending.delete(frame.id); p.cleanup();
      try {
        if (frame.jsonrpc !== '2.0' || Object.keys(frame).length !== 3 || ('result' in frame) === ('error' in frame) || 'error' in frame) throw fail();
        p.authority.signal.throwIfAborted(); p.authority.assertCurrent(); p.resolve(frame.result);
      } catch { p.reject(fail()); }
      return true;
    },
  });
}

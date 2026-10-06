/** Synthetic protocol peer only: no model, native harness, account or provider proof. */
import { createInterface } from 'node:readline';
import { readFileSync } from 'node:fs';
let sequence = 0;
const pending = new Map();
const send = value => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...value }) + '\n');
const tool = params => new Promise(resolve => {
  const id = `memory-${++sequence}`;
  pending.set(id, resolve);
  send({ id, method: 'worker.memory', params });
});
createInterface({ input: process.stdin }).on('line', async line => {
  const frame = JSON.parse(line);
  if (!frame.method) {
    const resolve = pending.get(frame.id); pending.delete(frame.id);
    resolve?.(frame.error ? { error: frame.error } : { result: frame.result });
    return;
  }
  const p = frame.params;
  const reply = result => send({ id: frame.id, result });
  if (frame.method === 'initialize') {
    if (p.workerMemory !== true || p.isolation?.backend !== 'macos-seatbelt-v1') process.exit(2);
    // Test-only path to an existing synthetic host database: actual kernel denial,
    // not a model-facing path capability or an ENOENT mistaken for isolation.
    for (const path of process.argv.slice(2)) {
      try { readFileSync(path); process.exit(3); }
      catch (error) { if (!['EPERM', 'EACCES'].includes(error.code)) process.exit(4); }
    }
    reply({ protocolVersion: 1, pluginId: 'hermes', upstreamVersion: 'synthetic-worker-v1',
      workerMemory: true, agentId: p.agentId, isolation: p.isolation,
      capabilities: { backgroundTasks: false, targetedSteer: false, taskStop: true, approvals: true, reconnect: false, attachments: false } });
  } else if (frame.method === 'session.open') reply({ sessionId: `synthetic-${p.conversationId}` });
  else if (frame.method === 'turn.submit') {
    reply({ status: 'accepted' });
    const responses = [];
    for (const request of JSON.parse(p.text)) responses.push(await tool({ execution: { sessionId: `synthetic-${p.conversationId}`, runId: p.runId, attemptId: p.attemptId }, request }));
    send({ method: 'harness.event', params: { protocolVersion: 1, eventId: `event-${++sequence}`,
      conversationId: p.conversationId, runId: p.runId, attemptId: p.attemptId,
      kind: 'turn.terminal', data: { state: 'completed', text: JSON.stringify(responses), cessation: 'provider-terminal' } } });
  } else if (frame.method === 'shutdown') { reply({ status: 'accepted' }); process.exit(0); }
  else reply({ status: 'unsupported' });
});

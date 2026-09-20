// pnpm --filter @yorozu/runtime build && node scripts/benchmark-sync.mjs
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { eventsAfter, readThreadEvents, SYNC_LIMIT, threadsDir } from '../packages/runtime/dist/threads.js';

const dir = mkdtempSync(join(tmpdir(), 'yorozu-sync-bench-'));
try {
  const count = 10_000;
  const events = Array.from({ length: count }, (_, n) => ({
    id: `e${n}`, threadId: 'bench', ts: n, agentId: 'main', kind: 'message',
    data: { role: 'user', text: '日本語🙂'.repeat(80) },
  }));
  mkdirSync(threadsDir(dir));
  const log = events.map((event) => JSON.stringify(event)).join('\n') + '\n';
  writeFileSync(join(threadsDir(dir), 'bench.jsonl'), log);
  const previous = (id) => {
    const all = readThreadEvents('bench', dir);
    const at = id ? all.findLastIndex((event) => event.id === id) : -1;
    return (at >= 0 ? all.slice(at + 1) : all).filter((event) => event.ts >= 0).slice(0, SYNC_LIMIT);
  };
  const drain = (read) => {
    const started = performance.now();
    let seen = 0;
    let cursor;
    for (;;) {
      const page = read(cursor);
      if (!page.length) break;
      for (const event of page) assert.equal(event.id, `e${seen++}`);
      cursor = page.at(-1).id;
    }
    assert.equal(seen, count);
    return Math.round(performance.now() - started);
  };
  const scanMs = drain(previous);
  const seekMs = drain((id) => eventsAfter('bench', id, dir));
  console.log(JSON.stringify({ events: count, logBytes: Buffer.byteLength(log), scanMs, seekMs,
    speedup: +(scanMs / Math.max(1, seekMs)).toFixed(1) }));
} finally { rmSync(dir, { recursive: true, force: true }); }

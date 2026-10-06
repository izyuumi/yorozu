import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';
const source = process.env.YOROZU_REVIEWED_NATIVE_SOURCE;
if (!source?.startsWith('/') || execFileSync('/usr/bin/git', ['-C', source, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim() !== 'f04797ef4d24f3da0f9df74acd58ab773ab5f11e')
  throw new Error('Exact reviewed native source required');
export default { root: dirname(fileURLToPath(import.meta.url)),
  test: { include: ['memory-native-suppression.test.mjs'], maxWorkers: 1, pool: 'forks', testTimeout: 30000 },
  resolve: { alias: [
    { find: 'vitest', replacement: join(source, 'node_modules/vitest/dist/index.js') },
    { find: '@native/attempt-bootstrap', replacement: join(source, 'src/agents/embedded-agent-runner/run/attempt-context-engine-helpers.ts') },
    { find: /^@openclaw\/normalization-core\/(.*)$/, replacement: join(source, 'packages/normalization-core/src/$1.ts') },
  ] } };

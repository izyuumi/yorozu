/** Native source tests; run only with memory-native-vitest.config.mjs and the exact reviewed source. */
import { test, expect } from 'vitest';
import { resolveAttemptBootstrapContext } from '@native/attempt-bootstrap';
import { uniformMemoryConfig } from './memory-plugin/memory-bridge.mjs';

test('native attempt does not read/inject retained bootstrap memory in uniform mode', async () => {
  const cfg = uniformMemoryConfig({ agents: { defaults: {}, entries: { alice: { workspace: '/fictional' } } } }, '/fictional/plugin', 'alice', true);
  let opens = 0;
  const result = await resolveAttemptBootstrapContext({ contextInjectionMode: cfg.agents.defaults.contextInjection,
    bootstrapMode: 'full', bootstrapContextRunKind: 'default', hasCompletedBootstrapTurn: async () => false,
    resolveBootstrapContextForRun: async () => { opens++; throw new Error('Native memory read must not happen'); } });
  expect(opens).toBe(0); expect(result.bootstrapFiles).toEqual([]); expect(result.contextFiles).toEqual([]);
  expect(result.shouldRecordCompletedBootstrapTurn).toBe(false);
});

import { Socket } from 'node:net';
import { createMemoryNativeClient, registerMemoryPlugin } from './memory-bridge.mjs';
export default { id: 'yorozu-worker-memory', name: 'Yorozu worker memory', register(api) {
  // FD4 is supplied by the isolated embedding owner. No environment endpoint,
  // filesystem socket or fallback to an existing Gateway is accepted.
  const client = createMemoryNativeClient(new Socket({ fd: 4, readable: true, writable: true }));
  registerMemoryPlugin(api, client);
  api.registerService({ id: 'yorozu-worker-memory', start() {}, stop() { client.close(); } });
} };

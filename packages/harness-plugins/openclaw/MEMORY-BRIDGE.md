# Development-only native memory bridge

`memory-plugin/memory-bridge.mjs` and the surrounding `memory-plugin/` package
implement a host-owned SQL memory tool for reviewed native OpenClaw
`f04797ef4d24f3da0f9df74acd58ab773ab5f11e`. The bridge lives inside the plugin
package because the pinned Gateway captures a plugin as a self-contained package
(nearest `package.json`); a sibling import outside that package would need a read
grant beyond the plugin tree and is refused by the loader.
This module registers nothing itself. `adapter.mjs` now performs the integration
hooks below (see the README section "Uniform host-owned memory"), and
`memory-gateway-proof.mjs` is the integrated Gateway acceptance fixture; the
packaged platform registers `worker-memory-v1` for OpenClaw only on that basis.

## Boundaries

- `uniformMemoryConfig(config, pluginDir, agentId, memoryGranted)` replaces native
  memory search, slot, compaction flush, ambient bootstrap/context/startup injection,
  plugins and hooks. It does not erase historical files. Omitted/false memory grants
  disable persistent memory **and all tools**; they do not merely hide memory tools.
- Native `contextVersion: 2` supplies a live invocation guard. The real native
  `prepareBeforeToolCallParams` receives trusted run/session/tool-call context.
  Private per-factory WeakMaps transfer that exact custody through finalization to
  execution. No execution identity or capability token enters model arguments.
  Colliding provider tool IDs in another live run cannot consume that custody.
- The native plugin communicates on inherited private duplex **FD4**, never a
  listener or environment-selected endpoint. FD3 remains the existing Gateway
  listener. Tool messages and replies are bounded; close/cancel/timeout fail closed.
- `createMemoryHostBridge` only accepts host-prebound exact native agent/key/SID/run
  currency, mapped to the exact host session/run/attempt. There is no latest-session
  fallback. Revoked native run IDs cannot be re-admitted within one bridge lifetime.
- The host's existing `WorkerMemory.bind(agentId)` and `workerMemoryTools` own SQL,
  durable mutation receipts, grant approval and final synchronous effect checks.
  Share needs exact approval; revoke is immediate. Direct native access to the SQL
  path must remain denied by the process sandbox.
- `createAdapterMemoryClient` forwards per-call cancellation to `HarnessProcess` as
  `worker.memory.cancel` with only the already-admitted transport request ID. This
  reaches the host approval/apply signal. Rejecting a local promise alone is not
  treated as proof of cancellation. Already committed effects are not rolled back.

## Adapter integration (separately owned)

1. Accept `workerMemory: true` only for managed owned profiles. Version/migrate that
   ownership contract explicitly; never silently adopt a historical native-memory
   profile or replay unknown work. Validate only `[]` or `['memory']` resource tools
   for this narrow implementation. Preserve literal input, paired ordinary scopes,
   strict native session identity and branch CAS.
2. Apply `uniformMemoryConfig` **after** retained configuration merging. Pass the
   exact memory grant boolean; do not allow retained plugins/hooks to merge back in.
3. Construct a bridge with the host RPC callback before native launch. Spawn the
   Gateway with `['ignore','pipe','pipe',3,'pipe']` and immediately attach
   `attachMemoryHost(child.stdio[4], bridge)`. Keep FD3 ownership transfer unchanged.
4. Before `chat.send`, bind `run.nativeId`, `session.sessionId` (native SID in the
   current adapter), `session.sessionKey`, and host execution
   `{sessionId: session.sessionId, runId: run.runId, attemptId: run.attemptId}`.
   Currency may be live during the narrowly reserved `admitting` state and then
   `running`; it must fail for `unknown`, stopping, terminal or unowned work. Keep
   revokers in a RAM-only map, not the serialized journal. Never reconstruct a
   capability from journal recovery.
5. Revoke before requesting stop, on send uncertainty, event gaps/yields, terminal
   processing, shutdown and connection loss. Close the bridge/client on failure.
6. In `serve`, construct `createAdapterMemoryClient(send)`, inject its `callHost`,
   consume `client.receive(frame)` before normal host-request parsing, and close it
   with input/output/adapter lifetime. Do not substitute a callback that discards
   the third `{signal, assertCurrent}` argument.
7. Acknowledge `workerMemory: true` only after actual initialization. Keep global
   capability advertisement and curated nonempty-scope selection gated until the
   integrated adapter/Gateway test passes. Include every bridge/plugin byte in the
   sealed inventory; the native plugin imports its sibling bridge module.

## Tests and evidence limits

- `memory-bridge.test.mjs`: bridge validation, real host SQL, owner isolation,
  approved share/revoke, stale/revoked/cancelled pending approvals, cross-run
  custody, RPC cancellation and an actual `HarnessProcess` child-pipe test.
- `memory-native-proof.mjs <native-source> <fresh-output>`: actual built native
  registry, exact effective catalog, native standalone-request dispatcher, four
  native processes/two agents, real SQL isolation/share/revoke, native cancellation
  reaching pending host approval, stale native closure rejection, and direct SQL
  file-read denial in each native sandbox. No model/provider/Gateway is involved.
  On macOS the parent owns SQL outside the child sandbox; native children each get
  deny-network plus deny-SQL/host-code policies. Nested `sandbox-exec` is unsupported.
- `memory-native-suppression.test.mjs` with `memory-native-vitest.config.mjs` and
  `YOROZU_REVIEWED_NATIVE_SOURCE`: executes the actual pinned bootstrap-attempt
  helper and proves it never opens or injects memory in `contextInjection: never`.
- The bridge Node test uses installed local TypeScript for the actual host transport
  (normal workspace resolution, or explicit `YOROZU_TYPESCRIPT_MODULE`). It never
  installs dependencies. Native source tests need the existing native Vitest closure.

Passing these does not prove paired `chat.send` supplies every required guard,
sealed packaged startup, device approval presentation, embedding-owned restart/stop,
provider/account access or production readiness. Those remain separate gates.

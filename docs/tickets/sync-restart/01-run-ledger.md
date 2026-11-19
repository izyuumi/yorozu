# 01: A restart never runs a message twice, and each restart is counted

- Blocked by: none
- Status: ready
- Executor: codex-sol-xhigh
- Shared: plugins/openclaw-yorozu/src/hub.ts, plugins/openclaw-yorozu/src/conversation.ts, plugins/openclaw-yorozu/test/genui-host.js
- Check: `node --test 'plugins/openclaw-yorozu/test/*.test.ts' && tsc -p plugins/openclaw-yorozu/tsconfig.standalone.json --typeRoots ~/openclaw/node_modules/@types && ~/openclaw/node_modules/.bin/tsc -p plugins/openclaw-yorozu`

## What to build
Spec: `docs/designs/sync-restart.md` (v5), sections "Ticket 01", "Module interfaces (frozen for 01)", "Files and release", "Testing decisions".

A message already handed to the Gateway (or later: started, parked, settled) is never run a second time when the device sends it again after a Gateway restart, or when it arrives on both the relay and direct paths (in one process, any state): the device gets `delivered` again and nothing else. One accepted by an earlier process and never handed runs when resent. Each message gets a durable ledger entry in the plugin's `runs` keyed store, stamped with the boot id of the process that wrote it (A-7, no watermark). The entry is marked handed with an awaited write immediately before the dispatch call (A-4), started at its own `onAgentRunStart`, and settled or parked when the turn ends. At start-up the plugin logs, once per process, one count line per earlier boot id: not handed, handed not started, started, parked. It also logs each dispatch's deferral and late follow-up starts. If the store can't be read, dedupe falls back to the transcript (decision 3). No capability, no new string, no device-visible change beyond the dedupe. A-9's re-park is deferred (spec, "A-9 implementation").

## Acceptance criteria
- [ ] Restart replay: M runs, new ledger with a new boot id and new Hub over the same store, M again: `onMessage` ran once; `delivered` both times (red test, spec Testing #1)
- [ ] Relay and direct copies of M in one process run once (red test #2)
- [ ] An earlier-boot `accepted` entry (never handed) reruns and logs `duplicate message rerun`; a same-boot `accepted` entry stays a duplicate (spec Testing #15, #16)
- [ ] Two messages in one conversation dispatch in order while the handed write is slow (spec Testing #17)
- [ ] The handed write lands before `runChannelInboundEvent` is called (ordering red test)
- [ ] Every entry carries the writing process's boot id; a parked rerun in a new process rewrites it
- [ ] Start-up count line per earlier boot id matches spec Testing #7 exactly, logged once per process (reload and re-import log nothing)
- [ ] Dispatch log lines and `run started … attempt <n> boot <id>` as spec Testing #9
- [ ] Degraded mode: store unreadable → transcript fallback as spec Testing #10
- [ ] Write order and pruning (24 h, 10,000) as spec Testing #11, #12
- [ ] `apps/relay/src/direct.test.ts` and `apps/windows/conformance/host/fake-host.ts` unchanged and green in CI
- [ ] No change to top-level docs/*.md, the plugin README or apps/mcp/src/content.json

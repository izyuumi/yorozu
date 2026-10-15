# OpenClaw channel plugin: SDK facts for Yorozu

Spike #416 for #415. It answers whether a third-party TypeScript channel plugin (`plugins/openclaw-yorozu`, installed with `openclaw plugins install --link`) can do what #415 needs.

**Source read:** OpenClaw `2026.9.8`, commit `245b7f6` (2026-10-08). `openclaw --version` on the owner's machine prints the same version and commit, and the installed global package resolves to that checkout. References are repo-relative in the OpenClaw repo (`openclaw: path:line`). Line numbers are approximate; the symbol names are exact. All answers come from reading the source; the Gateway was not probed live.

**Trust level.** A `--link` install is *not* trusted: `src/plugins/installed-plugin-record-match.ts` (`resolvePluginTrust`) gives it `origin-path`. Only `bundled` plugins or `trustedOfficialInstall` records are trusted, and `docs/tools/plugin.md` says "`--link` and `--force` do not grant trust". Every answer below assumes an **untrusted** plugin.

## Summary

| # | Question | Answer |
|---|---|---|
| 1 | Long-lived outbound WebSocket from `startAccount` | **Yes** |
| 2 | `openclaw yorozu pair` CLI command with a terminal QR | **Yes** |
| 3 | Secrets and small state | **Yes** |
| 4 | Thread-scoped session key; `/new` resets only that thread | **Yes / Yes** |
| 5 | In-process transcript, list, patch, delete, `cron.list` | **Yes**, but not through `api.runtime.gateway.request`, which is trusted-only. Use the session store APIs. `cron.list` has no clean public path (see Q5) |
| 6 | OpenClaw-generated titles for thread sessions | **Partly.** No automatic path exists for channel sessions. The plugin calls OpenClaw's generator itself, and notification exists |
| 7 | Verified-official powers that matter | **None block chat, media, typing or cron delivery.** Owner authority needs a config entry (see Q7) |
| 8 | Cron `delivery.channel: "yorozu"` | **Yes**, through the outbound adapter plus `resolveOutboundSessionRoute` |
| 9 | Tool-call progress | **Yes**: `replyOptions.onToolStart` / `onItemEvent` |

### Points for the owner (none is a stop gate)

- **Q1 is yes.** The Mac bridge fallback is not needed.
- **Titles (#415 says "as for Telegram DM topics").** Telegram's DM-topic labeler only renames the Telegram topic and writes no session field. The core auto-titler only runs for `dashboard:`/`ios-`/`node-` keys. For Yorozu, the plugin must call OpenClaw's exported generator (`generateConversationLabel`, which uses `utilityModel` with the same fallback) on the first turn and write `displayName` itself. The outcome #415 asks for is reachable; only the trigger lives in the plugin.
- **Owner authority.** An untrusted channel cannot *claim* the sender is the owner. Without `commands.ownerAllowFrom` containing `yorozu:owner`, Yorozu turns are non-owner, and owner-only agent tools are denied in Yorozu conversations. Those include `automations` (cron editing, which "Edit in chat" depends on), `sessions`, `gateway` and `nodes`. This is a one-line config change that **only the owner may make**.
- **`/new`** resets only the thread's session, as decided. It keeps the same `sessionId` and appends a reset boundary to the transcript instead of starting a new transcript. History readers must handle that boundary (#427).

---

## Q1. Long-lived outbound WebSocket from `startAccount(ctx)` — **yes**

**Plugins run in-process with full Node access.** `docs/plugins/architecture.md` (~L908) says native plugins "run in-process with the Gateway. They are not sandboxed." There is no `vm`, isolate or worker sandbox in `src/plugins`.

**Network is not a gated capability.** Capability consent covers only these surface groups: channels, providers, tools, contracts, hooks, mcpServers, cliCommands, cliBackends, skills and dangerousConfigFlags (`packages/gateway-protocol/src/schema/plugin-declared-surface-groups.ts`). Neither `globalThis.WebSocket` nor `fetch` is replaced. The only global network change is the proxy-env undici dispatcher (`src/infra/net/undici-global-dispatcher.ts`).

**Effect authority is not a network fence.** `src/shared/effect-authority.ts` is an `AsyncLocalStorage` scope that the host sets only around message-action and send operations. Outside such a scope, `captureEffectAuthority()` is inactive and `initiate(effect)` just runs the effect. Wrapping each provider send in `effect.initiate(...)` is cooperative; the docs ask bundled transports to do it (`docs/plugins/sdk-channel-plugins.md` ~L750).

**The SSRF guard is opt-in.** `fetchWithSsrFGuard` (`plugin-sdk/ssrf-runtime`, implemented in `src/infra/net/fetch-guard.ts`) does not wrap a plugin's own sockets.

**Lifecycle** (`src/gateway/server-channels.ts`):
- `gateway.startAccount` is called with no trust check. It receives `abortSignal` and a host-wrapped `setStatus`.
- The returned promise **must stay pending** while the account runs. Resolving early counts as a failure ("channel exited without an error", ~L960).
- Restart uses backoff `initialMs 5_000`, `maxMs 300_000`, `factor 2`, `jitter 0.1`, and stops after `MAX_RESTARTS = 10`. A run of at least 5 minutes (`CHANNEL_STABLE_RUN_MS`) resets the counter (~L98–104, L1034–1048).
- After abort, the account has `CHANNEL_STOP_ABORT_TIMEOUT_MS = 5_000` to stop.

**Precedents.** These channels hold outbound WebSockets from `startAccount`:
- `extensions/clickclack/src/gateway.ts` (the closest template: a `while (!ctx.abortSignal.aborted)` loop, `channelReadyPatch`, `sleepWithAbort` reconnect)
- `extensions/mattermost/src/mattermost/monitor-websocket.ts`
- `extensions/discord/src/internal/gateway.ts`
- `extensions/signal/src/client-container.ts`
- `extensions/nostr/src/nostr-bus.ts` (Nostr's docs even use `plugins install --link`)

`extensions/qa-channel/src/gateway.ts` long-polls over HTTP, but its status pattern is the one to copy.

**WebSocket without new dependencies.** `openclaw/plugin-sdk/websocket-runtime` (public) re-exports the host's `ws` 8.21.3 as `WebSocket`, plus `startWebSocketKeepalive` (`src/plugin-sdk/websocket-runtime.ts`). Node's global `WebSocket` also works. A linked plugin's own npm dependencies are not installed by OpenClaw (`docs/plugins/dependency-resolution.md` ~L186).

## Q2. CLI command `openclaw yorozu pair` with a terminal QR — **yes**

**Registration.** Call `api.registerCli(registrar, { descriptors: [{ name: "yorozu", description, hasSubcommands: true }] })` (`src/plugins/plugin-api.types.ts` ~L274; context type in `src/plugins/plugin-registration.types.ts` ~L136).
- The registrar receives `{ program /* commander Command */, parentPath, config, workspaceDir, logger }`.
- Commands with no names are rejected ("cli registration missing explicit commands metadata", `src/plugins/registry-registrars-operations.ts`).
- Also declare `"cliCommands": [{ "name": "yorozu", "description": "...", "hasSubcommands": true }]` in `openclaw.plugin.json` (`src/plugins/manifest-types.ts` ~L193; `docs/plugins/manifest/surfaces.md` ~L513). `"activation": { "onCommands": ["yorozu"] }` is optional; `extensions/voice-call/openclaw.plugin.json` does both.
- In a channel entry, put it in `defineChannelPluginEntry({ registerCliMetadata(api) { api.registerCli(...) } })` (`src/plugin-sdk/core.ts` ~L513; `docs/plugins/sdk-channel-plugins.md` ~L478). `extensions/matrix/src/cli-metadata.ts` is a real example that lazy-imports its `cli.js`.

**QR.** `renderQrTerminal(input: string, { small?: boolean }): Promise<string>` comes from public `openclaw/plugin-sdk/media-runtime` (`src/media/qr-terminal.ts`). WhatsApp uses `renderQrTerminal(qr, { small: true })` (`extensions/whatsapp/src/login.ts` ~L74). `renderQrPngDataUrl` and `writeQrPngTempFile` are also exported.

**The CLI runs in a separate process from the Gateway** (`src/plugins/cli-registry-loader.ts` ~L294). The command cannot reach the live channel's in-memory state, so it must call the running plugin over Gateway RPC:
- **Gateway side:** `api.registerGatewayMethod("yorozu.pair.begin", handler, { scope: "operator.admin" })` (`plugin-api.types.ts` ~L255). Omitting `scope` already defaults to `operator.admin` (`src/gateway/methods/descriptor.ts` ~L94). The handler receives `{ params, respond, context }`; reply with `respond(ok, payload?, error?)`.
- **CLI side:** `callGatewayFromCli(method, { json: true, timeout: "30000" }, params, { progress: false })` plus `addGatewayClientOptions(cmd)` from public `openclaw/plugin-sdk/gateway-runtime` (`src/cli/gateway-rpc.ts`). See `extensions/voice-call/src/cli-gateway-call.ts` for a working example.
- WhatsApp does the same split: it logs in in the CLI, then calls `channels.start` on the Gateway (`src/cli/channel-auth.ts` ~L193).

`extensions/device-pair` is not a CLI precedent. It registers a chat `/pair` command and sends a PNG (`extensions/device-pair/index.ts` ~L411, ~L555).

## Q3. Secrets and small state — **yes**

| Need | API (public subpath) | Notes |
|---|---|---|
| Host static key, relay signing key | `createSecretFileAtomic({ rootDir, filePath, content, mode?, dirMode? })`, `readSecretFile`, `tryReadSecretFileSync` from `openclaw/plugin-sdk/secret-file` | Defaults to `0600` file and `0700` dir. First writer wins with no overwrite; the overwriting variant `secret-file-runtime` is private. Root: `resolveOAuthDir()` → `<stateDir>/credentials` (`OPENCLAW_OAUTH_DIR`), from `openclaw/plugin-sdk/state-paths` (`src/config/paths.ts` ~L330). WhatsApp keeps its auth there (`extensions/whatsapp/src/accounts.ts`) |
| Atomic JSON written `0600` | `writeJsonFileAtomically(path, value)` from `openclaw/plugin-sdk/json-store` | `mode 0o600`, `dirMode 0o700`. Use it for key rotation, since `createSecretFileAtomic` cannot overwrite |
| Read cursors, device allowlist, pairing tokens | `api.runtime.state.openKeyedStore<T>({ namespace, maxEntries, overflowPolicy?: "reject-new", defaultTtlMs? })` or `{ namespace, retention: "retained" }` (`src/plugins/runtime/types-core.ts` ~L516) | Per-plugin rows in `<stateDir>/state/openclaw.sqlite` (`0600`). Available to every loaded plugin, linked ones included (`docs/tools/plugin.md`, "Plugin runtime trust refused"). Telegram (update offset), Nostr and Matrix (credentials) use it. `api.runtime.state.openBlobStore` stores binary data |
| State dir | `resolveStateDir()` from `openclaw/plugin-sdk/state-paths`, or `api.runtime.state.resolveStateDir` | |
| Secret values in config | `buildSecretInputSchema`, `resolveSecretInputString` (`openclaw/plugin-sdk/secret-input`) | Not needed: host keys are generated, not configured |

`docs/cli/plugins/install.md` (~L85) says a linked channel needing a "durable ingress queue" is blocked. That line is stale: the code throws `PluginTrustRefusalError` only for `dispatchHookAgentTurn` (`src/plugins/registry-runtime.ts` ~L645). `docs/tools/plugin.md` matches the code.

Unknowns:
- Whether keyed-store rows are encrypted at rest. Nothing suggests they are; they are plaintext in SQLite, like transcripts.
- Whether the CLI process may open the keyed store while the Gateway also holds it. Not checked. Pairing should go through the Gateway method anyway.

## Q4. Thread-scoped DM sessions and `/new` — **yes / yes**

**The key shape is achievable.** Do not use `messaging.resolveSessionConversation`; it only applies to `group`/`channel` raw ids (`src/channels/plugins/types.core.ts` ~L540). Build the key like this:

```ts
import { resolveAgentRoute, resolveThreadSessionKeys } from "openclaw/plugin-sdk/routing";
const route = resolveAgentRoute({ cfg, channel: "yorozu", accountId,
  peer: { kind: "direct", id: "owner" }, dmScope: "per-channel-peer" }); // -> agent:<agent>:yorozu:direct:owner
const { sessionKey } = resolveThreadSessionKeys({ baseSessionKey: route.sessionKey, threadId: convId });
// -> agent:<agent>:yorozu:direct:owner:thread:<convid>
```

- `buildAgentPeerSessionKey` (`src/routing/session-key.ts` ~L206) gives `agent:<a>:<channel>:direct:<peer>` for `per-channel-peer`.
- `resolveAgentRoute` takes a per-call `dmScope` override (`src/routing/resolve-route.ts` ~L49, ~L269). Without it, the global default `main` would give `agent:<a>:main:thread:…`.
- `resolveThreadSessionKeys` (`session-key.ts` ~L318) appends `:thread:<id>`.
- The agent comes from `channels.yorozu.agent`. Since `resolveAgentRoute` picks the agent from bindings, override `route.agentId` and rebuild the key, or build the base string directly (`agent:${agent}:yorozu:direct:owner`). Core accepts an explicit `ctx.SessionKey` (`src/config/sessions/session-key.ts` ~L32).
- Pass the same key as `route.routeSessionKey` and `dispatchSessionKey` to `channelRuntime.inbound.buildContext`, and as `route.sessionKey` to `channelRuntime.inbound.dispatch`. They must be equal (`src/channels/turn/lifecycle.ts` ~L118). The template is `extensions/qa-channel/src/inbound.ts` ~L316–540.

Caveats:
- **Case.** The whole key is lowercased (`packages/session-url-contract/src/session-key-normalization.ts` ~L117), so `convId` must be lowercase-safe; lowercase UUID/hex works.
- **identityLinks.** `session.identityLinks` could rewrite the peer `owner`.
- **No `ParentSessionKey`.** Do not set it for DMs. Telegram DM topics do not, and with it a thread would fork the parent's transcript, possibly again after `/new` (inferred from code; untested).

**`/new` and `/reset` reset only the thread session.**
- `maybeHandleResetCommand` (`src/auto-reply/reply/commands-reset.ts` ~L43) matches `/^\/(new|reset)(?:\s|$)/i`. The rollover runs in `initSessionState` (`src/auto-reply/reply/session.ts` ~L494).
- Only `resolved.normalizedKey`, the thread key, is written. Parent and main keys are only read (`session-accessor.reset.ts` ~L77–105).
- The `sessionId` is kept (`session.ts` ~L723: "Durable resets retain their transcript identity"). A new `lifecycleRevision` is issued, token/model/goal fields are cleared, and a reset boundary `{ context: "clear", reason: "new" | "reset" }` is appended (`session-hooks.ts` ~L30).
- `label`, `displayName` and model selections survive (`session-rollover-state.ts`).
- `/new` is a command, so the plugin must pass `access.commands.authorized: true` in `buildContext`, as qa-channel does.

## Q5. Transcripts, list, patch, delete, `cron.list` in process — **yes, via the store APIs; `cron.list` is the weak spot**

**`api.runtime.gateway.request(...)` is closed to us.** `dispatchTrustedPluginGatewayMethod` throws "Gateway requests are only available to bundled or trusted official plugins" (`src/gateway/server-plugins.ts` ~L93). `api.runtime.gateway.readSessionFacts` runs under a trusted scope as well (`src/gateway/server-plugin-session-facts.ts`). Treat both as unavailable.

**What works for an untrusted plugin:**

| Need | Call | Reference |
|---|---|---|
| List sessions | `api.runtime.agent.session.listSessionEntries({ agentId, readOnly: true })` → `{ sessionKey, entry }[]`; filter on the prefix `agent:<agent>:yorozu:direct:owner:thread:` | `src/plugins/runtime/types-core.ts` ~L395; also `openclaw/plugin-sdk/session-store-runtime` |
| Read one | `api.runtime.agent.session.getSessionEntry({ sessionKey, agentId? })` | same |
| Transcript | `loadTranscriptEventsSync({ agentId, sessionId, sessionKey })` and `readTranscriptStatsSync(...)` from public `openclaw/plugin-sdk/session-store-runtime` (~L199) | `sessionId` comes from the entry. `session-transcript-runtime` (visible-message deltas) is on the private list (`scripts/lib/plugin-sdk-private-local-only-subpaths.json`), so don't use it |
| Rename / title | `api.runtime.agent.session.patchSessionEntry({ sessionKey, update: (e) => ({ label }) })` (or `displayName` for generated titles) | `src/plugins/runtime/runtime-agent.ts` ~L96. `label`, `displayName` and `archivedAt` are public entry fields (`src/config/sessions/session-entry-projection.ts`) |
| Archive | same patch, `update: () => ({ archivedAt: Date.now() })` | Bypasses `sessions.patch` validation (label uniqueness, `archivedBy`) |
| Delete | `deleteSessionEntry({ sessionKey, agentId, archiveTranscript? })` from `session-store-runtime` (~L313) | |
| Change notices | `api.runtime.gateway.subscribeSessionChanges((e) => …)` → `{ agentId, sessionKey, factsInvalidated? }` | `src/plugins/runtime/session-changes.ts`; not trust-gated. Carries no diff, so re-read the entry |

**The Gateway RPC alternative and its scopes** apply only from inside a plugin RPC handler. Use `dispatchGatewayMethod` (`openclaw/plugin-sdk/gateway-method-runtime`) with the manifest contract `contracts.gatewayMethodDispatch: ["authenticated-request"]`. It runs with the *calling* client's scopes, so it cannot serve the background relay loop. The scopes come from `src/gateway/methods/core-descriptors.ts` and `src/shared/session-method-scopes-base.ts`:

| Method | Scope |
|---|---|
| `sessions.list` | `operator.read` |
| `chat.history` | `operator.read` |
| `cron.list` | `operator.read` |
| `sessions.patch` (`label`, `archived` only) | `operator.write` |
| `sessions.delete` | `operator.admin`, or `operator.write` with `archivedOnly: true` on an already-archived row |

Plugin-runtime-dispatched deletes and archives are also ownership-checked (`src/gateway/session-plugin-ownership.ts`). `sessions.list` has no channel filter, only `search` (`src/gateway/session-list-filters.ts`).

**`cron.list` has no clean public path.** There is no `api.runtime.cron` API. Two options:
- (a) `loadCronStore(resolveCronStorePath(...))` from `openclaw/plugin-sdk/cron-store-runtime`. It is in `package.json` exports, so it resolves in the owner's source install. It is also on the private local-only list, so a packaged build may withhold it from third-party plugins. Fragile, but read-only.
- (b) A loopback `GatewayClient` (`openclaw/plugin-sdk/gateway-runtime`) calling `cron.list` with `operator.read`. Shared-secret auth restores full operator scopes regardless of the declared ones (`docs/gateway/operator-scopes.md` ~L642), so this works but is broad.

Unknowns:
- Whether direct store writes broadcast `sessions.changed` to other UIs. The plugin's own subscriber does fire, since it hooks session-entry commits.
- Whether `api.runtime.subagent.getSessionMessages` (`sessions.get`) succeeds for an untrusted plugin outside a request scope.

## Q6. Generated titles — **partly: the plugin calls the generator; notification yes**

**Existing triggers do not cover channel sessions.**
- Core auto-titling `scheduleDashboardSessionTitle` → `maybeGenerateSessionTitle` (`src/gateway/server-methods/chat-send-background.ts` ~L84, `src/gateway/dashboard-session-title.ts` ~L116, ~L324) only accepts keys starting `dashboard:`, `ios-` or `node-`, and only on `chat.send`.
- Telegram's `scheduleDmTopicLabel` (`extensions/telegram/src/bot-message-dispatch.ts` ~L192) runs on the first DM-topic turn and only calls `editForumTopic`. It writes no session field.

**What the plugin does instead:**
1. On the first turn of a thread session (entry without `label`/`displayName`, message not starting with `/`), call `generateConversationLabel({ userMessage, prompt, cfg, agentId, maxLength: 60, timeoutMs })`. It is exported from public `openclaw/plugin-sdk/reply-runtime` (`src/auto-reply/reply/conversation-label-generator.ts` ~L27). It tries the agent's `utilityModel` first, then the primary model.
2. The plugin supplies `prompt`. Copy core's 3–6 word title prompt (`dashboard-session-title.ts`) or Telegram's `AUTO_TOPIC_LABEL_DEFAULT_PROMPT` (`extensions/telegram/src/auto-topic-label-config.ts`).
3. Write the result with `patchSessionEntry(... ({ displayName }))`, skipping it if `label` is set.
4. A manual rename writes `label`, which wins: `deriveSessionTitle` uses `label ?? … ?? displayName` (`src/gateway/session-utils-core.ts` ~L32; `src/gateway/session-title-state.ts`).

**Notification.** Use `api.runtime.gateway.subscribeSessionChanges` (see Q5), or the plugin knows because it wrote the title. Gateway WS clients also get `sessions.changed`. The internal `session:patch` hook does not fire for title writes.

Unknown: whether a plugin can trigger core's own path through `sessions.discussion.open` (`server-methods/session-discussion.ts`). It would need `runtime.gateway.request`, which is closed to us.

## Q7. Verified-official powers a third-party plugin misses — **none block chat, media, typing or cron delivery**

Trust-gated (bundled or `trustedOfficialInstall` only):

1. `runtime.hooks.dispatchHookAgentTurn` (`src/plugins/registry-runtime.ts` ~L645).
2. **Owner elevation.** `runtime.agent.runCommandFromIngress` with `senderIsOwner: true` (~L855: "trusted provenance is required only for owner elevation").
3. **Host-scoped channel runtime.** Untrusted plugins get the plain `runtime.channel` (~L119), which has no participant-evidence binding (`src/channels/message-access/participant-input.ts`). The plain `inbound.ingress`, `buildContext` and `dispatch` all work (`src/plugins/runtime/runtime-channel.ts` ~L128).
4. `runtime.gateway.request`, `readSessionFacts`, and gateway scope elevation (`src/gateway/server-plugin-subagent-runtime.ts` ~L128).
5. **Message-action reads.** Limited to the current conversation (`src/channels/plugins/message-action-dispatch.ts` ~L242). Read authority is bundled-only (`src/plugins/registry-registrars-network.ts` ~L357).
6. Scheduled channel administration (`writeAuthorityActions`; `docs/plugins/sdk-channel-plugins.md` ~L831).
7. Extra inbound media attachment roots (`src/media/channel-inbound-roots.ts` ~L43). Ordinary media in and out is unaffected.
8. **Private SDK subpaths** (`src/plugins/sdk-alias.ts`; `scripts/lib/plugin-sdk-private-local-only-subpaths.json`). Of interest here: `outbound-media`, `session-transcript-runtime` and `cron-store-runtime`.

**What matters for Yorozu: owner identity (2 and 3).**
- An untrusted channel cannot assert owner. Owner status still comes from config identity: `commands.ownerAllowFrom` entries are matched against the sender (`src/auto-reply/command-auth.ts` ~L203, ~L454).
- Non-owner turns lose `GATEWAY_OWNER_ONLY_CORE_TOOLS` (`src/security/dangerous-tools.ts` ~L62: `automations`, `gateway`, `plugins`, `sessions`, `nodes`, `computer`, …; applied in `src/auto-reply/reply/reply-tool-authority.ts` ~L288). Cron-creator authority also needs an owner (`get-reply-run-execute.ts` ~L584).
- **So the owner must add `"yorozu:owner"` to `commands.ownerAllowFrom`**, next to the existing entries. The sender id is `owner`.
- Cron delivery, typing and media have no trust gate. `src/cron` has no origin checks.

## Q8. Cron `delivery: { channel: "yorozu", to, threadId }` — **yes**

**Schema** (`src/cron/types.ts` ~L54): `{ mode: "none" | "announce" | "webhook", channel?, to?, threadId?: string | number, accountId?, bestEffort?, … }`. Use `mode: "announce"`.

**What the plugin must implement:**
- **Be a configured channel when the job is saved** (`src/cron/delivery-channel-validation.ts`). That means an outbound surface plus `config.listAccountIds` returning an enabled, configured account (`src/infra/outbound/channel-selection.ts` ~L79).
- **`outbound.sendText(ctx)` at minimum** (`src/channels/plugins/outbound.types.ts` ~L128; required at `src/infra/outbound/deliver-channel.ts` ~L189). Add `sendMedia` for attachments and `deliveryMode: "direct"`. Alternatively use the `message.send.{text,media,payload}` adapter via `defineChannelMessageAdapter`, as qa-channel does.
- `ctx.threadId` carries the job's `threadId` (`src/cron/isolated-agent/delivery-dispatch.ts` ~L338). `ctx.to` is the job's `to`; use `"owner"`.
- **`messaging.resolveOutboundSessionRoute`**, returning the thread session through `buildThreadAwareOutboundSessionRoute` (`openclaw/plugin-sdk/channel-core`, qa-channel `channel.ts`). Without it, the transcript mirror goes to a base key that ignores `threadId` (`src/infra/outbound/outbound-session.ts` ~L120).
- Optionally `messaging.normalizeTarget` and `outbound.resolveTarget`.

**Transcript mirror.** After a successful send, the text (not media) is mirrored into the target session's transcript, but only if that session entry already exists (`delivery-dispatch-awareness.ts` ~L495–512). A cron targeting a never-used `convId` delivers without mirroring.

## Q9. Tool-call progress — **yes**

Pass these in `replyOptions` to `channelRuntime.inbound.dispatch(...)` (`src/auto-reply/get-reply-options.types.ts`):
- `onToolStart({ toolCallId, name, phase, args })` (~L296)
- `onItemEvent({ toolCallId, kind, title, name, phase, status, summary, progressText })` (~L305)
- `onToolResult(payload)` (~L292)

Tool callbacks are gated on verbose by default. Set `allowToolLifecycleWhenProgressHidden: true` to receive them anyway; qa-channel does this and collects `toolCalls` (`extensions/qa-channel/src/inbound.ts` ~L510). Set `suppressDefaultToolProgressMessages: true` so tool summaries are not sent as text messages. Telegram and Discord do the same (`extensions/telegram/src/bot-message-dispatch-turn.ts` ~L273, `extensions/discord/src/monitor/message-handler.process-progress.ts`).

Alternatives:
- `api.runtime.events.onAgentEvent(listener)`, a global stream filtered by `sessionKey`. Use `stream: "tool"` with `data.phase: "start" | "update" | "result"`.
- `after_tool_call` hooks (`src/plugins/hook-types.ts`).

---

## Implications for #420–#432

**#420 skeleton**
- Mirror the qa-channel layout, but use `defineChannelPluginEntry` from `openclaw/plugin-sdk/channel-core`. qa-channel uses `defineBundledChannelEntry`, which is for bundled plugins.
- Add `setRuntime` from `createPluginRuntimeStore({ pluginId: "yorozu" })` (`openclaw/plugin-sdk/runtime-store`).
- `openclaw.plugin.json`: `"channels": ["yorozu"]`, `"cliCommands": [{ "name": "yorozu", "hasSubcommands": true, … }]`, and `channelConfigs.yorozu.schema`:
  ```json
  { "type": "object", "additionalProperties": false, "properties": {
    "enabled": { "type": "boolean" }, "agent": { "type": "string", "default": "main" },
    "relayUrl": { "type": "string" }, "mediaMaxMb": { "type": "number", "default": 8 },
    "textChunkLimit": { "type": "integer" } } }
  ```
- `package.json`: `openclaw.extensions` and `openclaw.channel` (id `yorozu`). Include `"setupEntry"` with `defineSetupPluginEntry(plugin)`.
- One account, `default`: `listAccountIds: () => ["default"]`, with `inspectAccount`/`resolveAccount` reading `channels.yorozu`.
- `capabilities: { chatTypes: ["direct"], media: true }`.
- `startAccount` must stay pending until `ctx.abortSignal` aborts, then stop within 5 s. Report status with `channelReadyPatch` / `channelStoppedPatch` (`openclaw/plugin-sdk/gateway-runtime`).

**#421 / #422 relay and keys**
- WebSocket: `WebSocket` and `startWebSocketKeepalive` from `openclaw/plugin-sdk/websocket-runtime`, or the global `WebSocket`. No new dependencies.
- Reconnect yourself with backoff inside the loop. Throwing hands control to the host restart policy (10 tries).
- Host keys: `createSecretFileAtomic` under `resolveOAuthDir()/yorozu/` (`0600`). Use `writeJsonFileAtomically` for files that must be overwritten.

**#423 pair**
- CLI: `api.registerCli` in `registerCliMetadata` adds `yorozu pair`.
- The CLI calls `callGatewayFromCli("yorozu.pair.begin", …)`.
- The Gateway side registers it with `api.registerGatewayMethod("yorozu.pair.begin", h, { scope: "operator.admin" })`. It mints the one-time token and secret in the live plugin and returns the `yorozu://pair…` link.
- The CLI prints `await renderQrTerminal(link, { small: true })`.
- Allowlist and pending tokens: `api.runtime.state.openKeyedStore({ namespace: "devices", retention: "retained" })`. Add a TTL'd namespace for tokens.

**#424 text in and out**
- Inbound follows qa-channel `inbound.ts`:
  1. Build the key per Q4. Lowercase the `convId`.
  2. `channelRuntime.inbound.ingress.resolveStable(...)`
  3. `channelRuntime.inbound.buildContext({ …, route: { routeSessionKey, dispatchSessionKey }, reply: { to: "owner", messageThreadId: convId }, access: { commands: { authorized: true } } })`
  4. `channelRuntime.inbound.dispatch({ route: { agentId, dmScope: "per-channel-peer", sessionKey }, ctxPayload, delivery: { deliver }, dispatcherOptions: { typingCallbacks }, replyOptions })`
- **run_started / typing:** `createTypingCallbacks({ start, stop, keepaliveIntervalMs, maxDurationMs })` from `openclaw/plugin-sdk/channel-outbound`, passed as `dispatcherOptions.typingCallbacks`. `onReplyStart` marks the run as started. There is no outbound `sendTyping` method.
- **Whole replies, no streaming:** don't pass `onPartialReply`. Deliver `info.kind === "final"` payloads.
- **Chunking:** set `outbound.chunker` (`runtime.channel.text.chunkMarkdownText` / `chunkText`) and `textChunkLimit`; chunking only happens when `chunker` is set. Core resolves `channels.yorozu.textChunkLimit`, else the adapter's limit, else 4000 (`src/auto-reply/chunk.ts`).
- **Tool calls:** `replyOptions: { allowToolLifecycleWhenProgressHidden: true, suppressDefaultToolProgressMessages: true, onToolStart, onItemEvent }`. Send these as a collapsed `tool` envelope kind.
- **`/new`:** pass the text through. Core handles it per thread.
- **Owner step:** `commands.ownerAllowFrom` += `"yorozu:owner"`.

**#427 history**
- `listSessionEntries` + `getSessionEntry` → `entry.sessionId` → `loadTranscriptEventsSync({ agentId, sessionId, sessionKey })`.
- Page in the plugin. Handle reset-boundary events from `/new`, since the same `sessionId` spans resets.

**#428 titles, rename, archive, delete**
- First-turn `generateConversationLabel` → `patchSessionEntry({ displayName })`, unless `label` is set.
- Rename: `patchSessionEntry({ label })`. Archive: `{ archivedAt }`. Delete: `deleteSessionEntry`.
- Push list updates from `api.runtime.gateway.subscribeSessionChanges`.
- Enforce label uniqueness yourself if wanted; the direct patch skips `sessions.patch` validation.

**#429 read marks**
- Cursor per `convId` in `openKeyedStore({ namespace: "read", retention: "retained" })`.

**#430 attachments**
- **Inbound:** `saveMediaBuffer(buffer, mime, "inbound", maxBytes, fileName)` (`openclaw/plugin-sdk/media-store`) → `toInboundMediaFactsWithMetadata([{ path, contentType }])` (`openclaw/plugin-sdk/channel-inbound`) → `buildContext({ media })`.
- **Outbound:** implement `sendMedia` (or `message.send.media`/`payload`). Load the file with public `resolveOutboundAttachmentFromUrl(mediaUrl, maxBytes, { mediaAccess, localRoots: ctx.mediaLocalRoots, readFile: ctx.mediaReadFile })` (`openclaw/plugin-sdk/media-runtime`). qa-channel's `loadOutboundMediaFromUrl` (`outbound-media`) is private.
- Limit: `resolveChannelMediaMaxBytes` (`media-runtime`) honours `channels.yorozu.mediaMaxMb`, then `agents.defaults.mediaMaxMb`.

**#431 push**
- Fire on the final delivery in `deliver`, and on cron delivery in `sendText`/`sendMedia`.

**#432 Crons tab**
- `cron.list` per Q5: prefer `cron-store-runtime`'s `loadCronStore` read-only and accept the fragility, or a loopback `GatewayClient` with `operator.read`.
- Cron delivery into a conversation needs Q8's `resolveOutboundSessionRoute` + `sendText`.
- "Edit in chat" needs the owner step (the `automations` tool is owner-only).

## Unknowns

- Whether direct session-store writes emit `sessions.changed` to other Gateway clients.
- Whether `api.runtime.subagent.getSessionMessages` works for an untrusted plugin.
- Whether a packaged OpenClaw build withholds `cron-store-runtime` from linked plugins. The owner's source install exports it.
- Whether keyed-store rows are encrypted at rest; assume not.
- Whether the CLI process can safely share the keyed store with a running Gateway.
- Whether a thread re-forks after `/new` if `ParentSessionKey` were set. Not relevant if it is unset.

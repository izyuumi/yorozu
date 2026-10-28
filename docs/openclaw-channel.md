# OpenClaw SDK surface for the Yorozu channel

This page lists what `plugins/openclaw-yorozu` relies on from OpenClaw, and the Gateway behaviour that shaped it. The plugin's own behaviour is in [its README](../plugins/openclaw-yorozu/README.md). Statements about OpenClaw internals come from the OpenClaw source at the minimum version in `package.json` (`peerDependencies.openclaw`, `>=2026.9.8`). Check them against the OpenClaw source before relying on them for a newer version.

## Trust level

A `--link` install is an untrusted plugin. The plugin is designed around that:

- No `api.runtime.gateway.request`. That call is limited to trusted plugins, so the plugin cannot call Gateway RPCs such as `sessions.list`, `chat.history` or `cron.list`. It reads and writes the session store directly (`openclaw/plugin-sdk/session-store-runtime`) and reads the cron store directly (`cron-store-runtime`).
- It cannot claim that a sender is the owner. A Yorozu turn is a non-owner turn unless `commands.ownerAllowFrom` contains `yorozu:owner`; without it, OpenClaw's owner-only agent tools are denied ([setup.md](setup.md#owner-only-tools)).
- Chat, media, typing, tool progress and cron delivery work without trust.

## SDK subpaths used

| Subpath | Used for |
|---|---|
| `channel-core` | `defineChannelPluginEntry`, `defineSetupPluginEntry`, `createChatChannelPlugin`, `buildThreadAwareOutboundSessionRoute` |
| `channel-contract`, `account-id` | `ChannelGatewayContext` (`startAccount`), `DEFAULT_ACCOUNT_ID` (the one account) |
| `gateway-runtime` | `channelReadyPatch` / `channelStoppedPatch` (status), `errorShape` (Gateway method errors), `callGatewayFromCli` / `addGatewayClientOptions` (CLI) |
| `websocket-runtime`, `runtime-env`, `fetch-runtime` | `WebSocket`, `computeBackoff` / `sleepWithAbort` (redial), `captureEffectAuthority` (wraps each relay send) |
| `runtime-store` | `createPluginRuntimeStore`; `runtime.state.openKeyedStore` (plugin state), `runtime.gateway.subscribeSessionChanges`, `runtime.channel.reply.dispatchReplyFromConfig`, `runtime.version` |
| `secret-file`, `state-paths` | `createSecretFileAtomic` / `tryReadSecretFileSync` under `resolveOAuthDir()` (host keys) |
| `routing` | `resolveAgentRoute` (with `dmScope: "per-channel-peer"`), `resolveThreadSessionKeys`, `normalizeAgentId` |
| `channel-inbound` | `buildChannelInboundEventContext`, `runChannelInboundEvent`, `toInboundMediaFactsWithMetadata` |
| `channel-outbound` | `createTypingCallbacks`, `sendDurableMessageBatch` (Gateway notices, with a transcript `mirror`) |
| `reply-runtime` | `chunkMarkdownText`, `resolveTextChunkLimit`, `generateConversationLabel` |
| `session-store-runtime` | `listSessionEntries`, `getSessionEntry`, `patchSessionEntry`, `deleteSessionEntry`, `loadTranscriptEventsSync`, `readTranscriptStatsSync` |
| `cron-store-runtime`, `agent-scope-runtime` | `loadCronStore`, `resolveCronStorePath`, `tryResolveDefaultAgentId` |
| `media-runtime`, `media-store`, `media-local-roots` | `renderQrTerminal`, `resolveChannelMediaMaxBytes`, `resolveOutboundAttachmentFromUrl`, `extractOriginalFilename`, `saveMediaBuffer`, `getAgentScopedMediaLocalRoots` |

`cron-store-runtime` is on OpenClaw's private local-only subpath list. It resolves for a linked plugin on a source install because it is in the package's `exports`. A packaged build may withhold it; then `cron_list` answers with `error`. The alternative would be a loopback Gateway client calling `cron.list`.

## Behaviour the plugin depends on

- **`startAccount`** must stay pending while the account runs, and stop soon after `abortSignal` aborts. The plugin redials the relay itself instead of throwing.
- **CLI process**: `openclaw yorozu …` runs in its own process and cannot see the channel's memory, so each command calls a Gateway method that the plugin registers (`api.registerGatewayMethod`, scope `operator.admin`). The CLI is declared both in `registerCliMetadata` and in the manifest's `cliCommands`.
- **Session key**: `resolveAgentRoute` with `dmScope: "per-channel-peer"` and peer `owner` gives `agent:<agent>:yorozu:direct:owner`, and `resolveThreadSessionKeys` adds `:thread:<convId>`. OpenClaw lowercases session keys, so `convId`s are lowercase.
- **`/new` and `/reset`** reset only the thread session. The `sessionId` and the transcript stay the same, and a reset event is appended to the transcript. History shows it as a `reset` item. `label` and `displayName` survive the reset.
- **Tool progress**: the plugin passes `replyOptions.onToolStart` and `onItemEvent`, with `allowToolLifecycleWhenProgressHidden` and `suppressDefaultToolProgressMessages`. Without those two flags, tool callbacks depend on verbose mode, and tool summaries would arrive as text.
- **Replies**: whole messages, not streamed (`disableBlockStreaming`). They are chunked by `resolveTextChunkLimit`, which reads `channels.yorozu.textChunkLimit` with 4000 as the fallback.
- **Reply targets**: `buildChannelInboundEventContext`'s `messageId` becomes `MessageSid`, and `supplemental.quote` (`id`, `body`, `senderAllowed`) becomes `ReplyToId` and `ReplyToBody`, shown to the agent as "Reply target of current user message". Outbound, a channel without its own `threading.resolveReplyToMode` defaults to `all`, which puts the current message's id on every reply; the plugin returns `off`, so only `[[reply_to_current]]`, `[[reply_to:<id>]]` and the message tool's `replyTo` reach `deliver`, `sendText` and `sendMedia` as `replyToId`. `capabilities.reply` is descriptive only.
- **Titles**: OpenClaw titles only its own dashboard and node sessions, not channel thread sessions. So the plugin calls `generateConversationLabel` itself; it tries the agent's `utilityModel` first, then the primary model. A manual `label` wins over `displayName`.
- **Session-store writes** skip `sessions.patch` validation, including label uniqueness. `preserveActivity: true` leaves `updatedAt` alone. `subscribeSessionChanges` fires for these writes and for changes made through the Gateway.
- **Cron delivery** (`delivery: { mode: "announce", channel: "yorozu", to: "owner", threadId: "<convId>" }`) needs:
  - a configured, enabled account (`listAccountIds`, `inspectAccount`);
  - `outbound.sendText`;
  - `messaging.resolveOutboundSessionRoute`, so the transcript mirror goes to the thread session. Only text is mirrored, and only when the session entry already exists.
- **`openclaw cron add --thread-id`** accepts only positive integers (Telegram topic ids). A job that delivers into a Yorozu conversation is made with the agent's cron tool or `cron.add`.
- **Media**: outbound media paths must be under `getAgentScopedMediaLocalRoots(cfg, agentId)`. `sendMedia` is called once per file, with the caption on the first.
- **Auto-update checks**: OpenClaw exports no helper that says whether its auto-updater can run, so the plugin repeats its checks: the `update.auto` and `update.checkOnStart` config, `OPENCLAW_NO_AUTO_UPDATE`, and the service marker `OPENCLAW_SERVICE_MARKER=openclaw` with `OPENCLAW_SERVICE_KIND=gateway`, which the service environment from `openclaw gateway install` carries on every platform. OpenClaw's own supervisor check also accepts other launchd and systemd hints, so a Gateway under a hand-written service gets the "not running as a service" notice anyway. `update.run` and `update.status` need `operator.admin`, so the plugin does not trigger updates.
- **Keyed state store** rows live in OpenClaw's state database. They are not known to be encrypted at rest.

## Gateway gotchas

- **Probing by hand**: `openclaw gateway call <method> --json --params '<json>'`. Use throwaway session keys and delete them afterwards. For anything bigger, use an isolated profile ([plugin README](../plugins/openclaw-yorozu/README.md#trying-it-without-the-main-gateway)).
- **`chat.history` truncates** long text fields and old messages. That is why the plugin reads transcripts from the store.
- **`--link` installs** load the linked directory on each Gateway start. If that directory is removed, every `openclaw plugins` command reports `Configured plugin load path is unavailable` until the plugin is installed again from a path that exists.
- **Console capture redacts** key- and token-like text. That is why the CLI prints the pairing link with `process.stdout.write`.

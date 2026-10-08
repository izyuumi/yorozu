# Setup

What a Mac needs to build and run Yorozu v2, and where the app keeps its data and secrets.

## Tools

| Need | Version | Notes |
|---|---|---|
| Xcode | 27 | Provides the Swift toolchain. |
| Tuist | pinned in `mise.toml` | `mise install`. Generated `.xcodeproj`/`.xcworkspace` are gitignored. `apps/mac/Tuist.swift` and `apps/ios/Tuist.swift` exist so generation also works in a git worktree, where `.git` is a file. |
| GRDB | locked in `Package.resolved` | SwiftPM dependency of `ProjectXCore`. Uses the system SQLite, whose FTS5 must have the `trigram` tokenizer (SQLite 3.34 or later) for memory search. |
| swift-toml | 2.0.0, exact in `Package.swift` | SwiftPM dependency of `ProjectXCore` (product `TOML`). Decodes `config.toml` ([Settings](#settings-configtoml)); Yorozu writes the file itself. |
| OpenClaw | the running Gateway's build | `openclaw` CLI on `PATH`; the app also searches `/opt/homebrew/bin` and `/usr/local/bin`. Source of the running build: `~/openclaw`. |
| Upload tools | system | `upload_ios.sh` also uses `openssl`, `curl`, `jq`, `awk` and `xxd`. |
| CuaDriver | 0.28.2 checked | `/Applications/CuaDriver.app`, installed separately ([cua-integration.md](cua-integration.md)). Not needed to build or run the app; workers need it to operate the Mac. |

Deployment targets are in `Package.swift` and the Tuist manifests. `ProjectXCore` declares an older macOS than the Mac app, so macOS APIs newer than its own target need availability checks there.

## OpenClaw Gateway

Local mode, bound to loopback on port 18789 (`ws://127.0.0.1:18789`), token auth. The app reaches it through the `openclaw` CLI with the CLI's own configured credentials; it never reads or copies them. Call details and gotchas: [openclaw-integration.md](openclaw-integration.md).

### The `projectx` agent

The app talks only to agent `projectx`. The agent id is `[harness] agent` in `config.toml`, whose code default is the generic `yorozu`; until #317 lets the app run on another id, this build refuses to start live with anything but `projectx`, so a live `config.toml` sets `agent = "projectx"`. Its entry in `~/.openclaw/openclaw.json` (`agents.entries.projectx`) has this shape:

```json5
{
  name: "projectx",
  workspace: "~/Projects/PROJECTX",   // the main checkout; coding worktrees are cut from it
  agentDir: "…",                      // OpenClaw's per-agent directory
  identity: { … },
  model: { primary: "openai-pool/gpt-6-astra", fallbacks: [] },
  contextInjection: "never",          // the default is "always"
  skills: [],
  subagents: { allowAgents: [] },     // the default is ["*"]
  // no `tools` key: workers inherit the global tool profile (full)
}
```

`agents.defaults.modelPolicy.allow` is the list Yorozu's automatic model choices pick from, and `model.primary` is the worker default ([Models](#models)).

The entries for `openai-pool/gpt-6-sol` and `openai-pool/gpt-6-astra` under `models.providers.openai-pool.models` must set `contextWindow: 272000`, the window those models really take (owner decision). Yorozu reads the window per session (`contextTokens` from `sessions.describe`) to decide when to compact a topic session, and never counts more than 258,400 tokens as usable ([openclaw-integration.md](openclaw-integration.md#compaction)).

## Settings (`config.toml`)

Yorozu's settings are one file, `config.toml`, in the data root in use ([Where data lives](#where-data-lives)), so fixture and `PROJECTX_DATA` runs each have their own and v1, which shares the bundle id, never sees it (`Config.swift`). A launch with no file writes one with the defaults below; no default is specific to one owner. There is no Settings UI for it yet (phase B of #312): edit the file by hand, or ask Yorozu in the chat, which has a worker edit it ([architecture.md](architecture.md#settings)).

| Key | Default | Meaning |
|---|---|---|
| `general.start_at_login` | `true` | Login item ([Start at login and keep awake](#start-at-login-and-keep-awake)) |
| `general.keep_mac_awake` | `false` | No idle sleep while Yorozu runs |
| `general.yolo` | `false` | YOLO mode ([architecture.md](architecture.md#mcp-servers-and-computer-use)) |
| `general.send_key` | `"smart"` | `"smart"` or `"cmd-enter"` |
| `general.global_shortcut` | `""` (off) | Shortcut that opens the popover |
| `general.appearance` | `"system"` | `"system"`, `"light"` or `"dark"` |
| `general.show_advanced` | `false` | Shows the Advanced tab |
| `notifications.enabled` | `true` | |
| `notifications.destination` | `"mac"` | `"mac"` or `"phones"` |
| `routing.personal_knowledge` | `""` | The user's personal notes, named in the routing policy as a source only a worker can read; empty drops that clause; at most 200 bytes of UTF-8 |
| `routing.self_topic` | `"Yorozu"` | The topic that holds work on Yorozu itself; at most 80 characters |
| `relay.url` | `"wss://relay.yumi.to"` | Relay for the iPhone app, `ws://` or `wss://` with a host |
| `harness.kind` | `"openclaw"` | The only harness today |
| `harness.agent` | `"yorozu"` | Harness agent id, 1–64 letters, digits, `-` or `_` ([The `projectx` agent](#the-projectx-agent)) |
| `harness.transport` | `"native"` | `"native"` or `"cli"` ([openclaw-integration.md](openclaw-integration.md#transport)) |
| `harness.gateway_url` | `"ws://127.0.0.1:18789"` | Loopback `ws`/`wss` only, with no path, query or credentials |
| `harness.dev_repo` | `""` | Main checkout for coding work, an absolute or `~/` path; empty ends coding work with a notice |
| `models.secretary`, `models.extraction`, `models.worker`, `models.review` | absent (automatic) | `"provider/model"` ([Models](#models)) |
| `models.coding.<executor>` | absent (automatic) | `claude` or `codex` = `"provider/model"` |
| `models.rules.min_context_tokens`, `models.rules.min_output_tokens` | `32000`, `16000` | Inputs of the automatic secretary and extraction choice |
| `mcp_servers.<name>` | `cua-driver` ([MCP servers](#mcp-servers)) | `command` and `args` |

`send_key`, `global_shortcut`, `appearance`, `show_advanced` and `notifications.*` are validated and kept, but nothing uses them until phase B.

- **Format.** Yorozu writes the whole file in one canonical layout: known keys in a fixed order, each with Yorozu's own comment, absent model keys as commented examples, and unknown keys kept as data after them. Hand-written comments are not kept. Every write goes to a temporary file in the same folder, mode 0600, flushed to disk, then is renamed over `config.toml`; a write that would be invalid is refused. Writes from Settings (phase B) are read-modify-write (`Config.update`), so a recent hand or worker edit survives. In phase A the app writes the file only to create it.
- **Reload.** `ConfigWatcher` watches the folder with FSEvents, so in-place edits and atomic saves are both seen, and debounces for 300 ms: a saved change is applied within about a second. An unchanged file is ignored; the comparison starts from the file as read at launch, so an edit made while the app was starting is applied too.
- **Invalid edits.** A file that does not parse or validate, or is missing, leaves the last valid settings in force and posts one `failure` notice per distinct problem, code `config_invalid`, naming the file, the line when known, the key and the reason: "Settings not applied: config.toml line 12 (relay.url): expected a ws:// or wss:// address. The last valid settings stay in force." An invalid or unreadable file at launch is left untouched: that run uses the code defaults plus the environment, posts the same notice ending "Yorozu runs on its default settings until the file is fixed.", and applies the file once it is fixed. In live mode the default agent `yorozu` still stops that launch unless `PROJECTX_AGENT=projectx` is set (until #317).
- **Security-relevant keys.** `general.yolo`, `relay.url`, every `harness.*` key, every `models.*` role and `models.coding` key, and `mcp_servers`. Their comments say "Security-relevant: ask the user before changing it", and a worker asks for the user's yes in the chat before changing them. A reload that changes any of them posts an `acknowledgment` notice, code `settings_changed`: "Settings changed: relay.url". Direct connection joins the list with #315.
- **When a change applies.** Models, YOLO, routing hints and `dev_repo` from the next route, task or extraction; automatic models after the model metadata is read again. MCP servers when the next worker session is prepared ([openclaw-integration.md](openclaw-integration.md#mcp-servers)). `relay.url` restarts the relay host on the new relay with the same keys and devices; every phone must pair again, since its pairing names the old relay. `keep_mac_awake` and `start_at_login` at once. `harness.kind`, `agent`, `transport` and `gateway_url` only at the next launch; the status line says "Relaunch Yorozu to apply: …".

### Precedence

Each value comes from the first of: a `PROJECTX_*` environment variable, `config.toml`, the automatic choice (models only), the code default (`ResolvedSettings`). Environment values override for that run only and are never written to the file.

| Variable | Key |
|---|---|
| `PROJECTX_TRANSPORT` | `harness.transport` |
| `PROJECTX_GATEWAY_URL` | `harness.gateway_url` |
| `PROJECTX_AGENT` | `harness.agent` |
| `PROJECTX_DEV_REPO` | `harness.dev_repo` |
| `PROJECTX_RELAY_URL` | `relay.url` |
| `PROJECTX_SECRETARY_MODEL` | `models.secretary` and `models.extraction` |
| `PROJECTX_MODEL` | `models.worker` |
| `PROJECTX_REVIEW_MODEL` | `models.review` |
| `PROJECTX_CLAUDE_MODEL` | `models.coding.claude` |
| `PROJECTX_CODEX_MODEL` | `models.coding.codex` |

`PROJECTX_MODE` and `PROJECTX_DATA` stay environment-only: they choose the data root that holds `config.toml`. An environment value that fails the key's rule stops the launch, for example "PROJECTX_TRANSPORT: expected one of "native", "cli".".

### MCP servers

Yorozu keeps the list of MCP servers its workers may use as `[mcp_servers.<name>]` tables in `config.toml`. The default:

```toml
[mcp_servers.cua-driver]
command = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"
args = ["mcp"]
```

Each server is stdio: `command` is an absolute path, `args` is optional, and a name is 1–23 letters, digits, `-` or `_`. `env` is refused for now: a removed value would linger in OpenClaw's merge-patched config, and values would travel in command-line arguments. The app mirrors the list into OpenClaw itself, again whenever it changes ([openclaw-integration.md](openclaw-integration.md#mcp-servers)); nothing needs registering by hand. The cua-driver entry needs CuaDriver.app with Accessibility and Screen Recording granted to it (`cua-driver permissions grant`, run by the owner); its `mcp` proxy launches the CuaDriver daemon when it is not running.

The list used to be `mcp-servers.json` in the data root. When `config.toml` is first created, a valid `mcp-servers.json` next to it is imported into `[mcp_servers]` once; after that the JSON file is never read and can be deleted.

### Start at login and keep awake

- `start_at_login` registers the running app bundle as a login item with `SMAppService.mainApp` (for the dev app, `build/Yorozu.app`) and records that in `login-item-registered` in the data root; `false` unregisters the item only when that file exists, so an item this app did not register is never removed. It is on by default. When macOS wants approval, the status line says "Start at login needs approval in System Settings › General › Login Items". Fixture and `PROJECTX_DATA` runs never touch the login item.
- Known limit: v1 shares the bundle id, and `SMAppService.mainApp` could act on its login item. While LaunchServices knows any other bundle with this id (`/Applications/Yorozu.app`, or another build copy), the app leaves login items alone and, with `start_at_login` on, the status line says "Start at login is off while another Yorozu with the same id is installed".
- `keep_mac_awake` holds a `ProcessInfo` activity with `.idleSystemSleepDisabled` while the app runs (`pmset -g assertions` lists it). A closed lid still sleeps.

## Models

No model id is in the code. Each role uses its explicit choice (`[models]` in `config.toml`, or its [environment variable](#precedence)); without one, an automatic choice computed from the harness's model metadata (`ModelDefaults.resolve`), recomputed at launch and after every reload:

| Role | Key | Automatic choice |
|---|---|---|
| Secretary | `models.secretary` | The cheapest priced allowed model with at least `min_context_tokens` of context and `min_output_tokens` of output; if none fits, the agent's primary model |
| Memory extraction | `models.extraction` | Same rule as the secretary |
| The one stronger routing review | `models.review` | The most expensive priced allowed model other than the secretary's (the secretary's when it is the only one) |
| Thinking worker | `models.worker` | The agent's primary model; without one, the most expensive priced allowed model |
| Coding worker, Claude Code | `models.coding.claude` | Among allowed models its runtime (`claude-cli`) can run: the primary if it is one, else the most expensive priced one with an output cap, else the one with the largest context |
| Coding worker, Codex | `models.coding.codex` | The same among models the `codex` runtime can run |

- Price is input plus output price per million tokens. A model without a price, or with a 0/0 cost (as a local proxy may declare), counts as unknown and is left out of the cheapest and most-expensive picks; a model with no output cap is left out of both too. When no allowed model has a price, the secretary, extraction, review and worker roles all use the agent's primary model.
- An explicit choice the harness does not list is still used.
- The metadata comes from the Gateway ([openclaw-integration.md](openclaw-integration.md#model-metadata)). It is read at launch, where queued work waits up to 10 s for it before resuming, and after each reload; while no read has succeeded, it is read again before a message at most every 30 s. A failed read keeps the last good one. With no metadata and no explicit choice a role has no model, and its runs fail with "No model is set for this role; choose one in Settings › Advanced."
- A changed model reaches existing topic, controller and coding sessions at their next use ([openclaw-integration.md](openclaw-integration.md#model-changes)).
- The owner's local `config.toml` sets the model ids in use before #312, so the owner's roles did not change; the computed values are an [open item](status.md#open-items).

## Signing

| App | Bundle id | Signing |
|---|---|---|
| Mac | `to.yumi.yorozu` (v1's) | Team `AN5KM8QGEF`, manual signing, hardened runtime. The identity comes from `apps/mac/Signing.xcconfig`, which includes the gitignored `apps/mac/Signing.local.xcconfig` (`*.local.xcconfig`) when it exists. That local file sets `CODE_SIGN_IDENTITY` to the Developer ID Application identity for the team in the login keychain and `OTHER_CODE_SIGN_FLAGS = --timestamp`; the comment in `Signing.xcconfig` shows the shape. Without it the app is signed ad hoc (`-`), which runs only on the Mac that built it. Entitlements match v1 (`apps/mac/Yorozu.entitlements`); no app sandbox. |
| iOS | `to.yumi.yorozu.ios` | Team `AN5KM8QGEF`, automatic signing. Xcode issues the distribution certificate and profile itself during `upload_ios.sh`, using the App Store Connect key. |

## App Store Connect credentials

`upload_ios.sh` needs `ASC_KEY_ID` and `ASC_ISSUER_ID` in the environment and reads the private key from `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8` (mode 600), or from `ASC_KEY_PATH` when set. The key file stays outside the repository.

## Keychain items

| Service | Account | Holds | Created by |
|---|---|---|---|
| `to.yumi.yorozu.relay` | `host` | The Mac's relay identity (Ed25519 and X25519 keys). Losing it means a new relay room, so every phone must pair again. | Mac app, first live launch |
| `to.yumi.yorozu.gateway` | `<gateway URL>\|webchat\|operator` | The native transport's device key and Gateway-issued device token | Mac app, native enrollment only (Settings, Gateway tab); a launch without a token creates nothing |
| `to.yumi.yorozu.ios` | `pairings-v2` | The phone's pairing and identity | iOS app, on the phone |

The Mac items are `WhenUnlockedThisDeviceOnly`; the phone item is `AfterFirstUnlockThisDeviceOnly`. A Keychain the relay host cannot read stops the relay (not the app) rather than minting new keys; the app tries to start the relay again every 30 s, so unlocking the login Keychain is enough.

## Where data lives

| Data | Live mode | `PROJECTX_DATA=<dir>` | Fixture mode |
|---|---|---|---|
| App state (`operations.sqlite`, `app.lock`) | `~/Library/Application Support/<bundle id>/` | `<dir>/` | `~/Library/Application Support/<bundle id>/Fixture/` |
| Chat search indexes (`messageSearch` and `eventSearch` tables) | inside `operations.sqlite` | same | same |
| Markdown memory | `~/Yorozu/memory/` (notes, `knowledge/`, `history/`, `.writer.lock`) | `<dir>/memory/` | `…/Fixture/memory/` |
| Memory index (`discovery` and `search_trigram` tables) | `~/Library/Caches/<bundle id>/memory-index.sqlite` | `<dir>/memory-index.sqlite` | `…/Fixture/memory-index.sqlite` |
| Paired phones (`relay-devices.json`, mode 600) | `~/Library/Application Support/<bundle id>/` | same as live | none (no relay) |
| Settings (`config.toml`, mode 600) | `~/Library/Application Support/<bundle id>/` | `<dir>/` | `…/Fixture/` |
| Retired MCP server list (`mcp-servers.json`) | imported once into a new `config.toml`, then unused ([MCP servers](#mcp-servers)) | same | same |

`<bundle id>` is the Mac bundle id from [Signing](#signing), also when `Bundle.main` has none. Directories are created 0700. `app.lock` is held with an exclusive lock, so only one process opens a data directory. Schema changes to `operations.sqlite` are GRDB migrations that run at launch (`native-r1`, `r2-executor`, `memory-job-reasons`, `message-notice`, `message-search`, `sync-r1`) and only add tables, columns, indexes and triggers. Moving data between folders or machines stays manual. The memory index is a cache rebuilt at launch, which leaves the older `search` table in place for builds from before batch 2 of issue #310 that share the cache. The chat search indexes are different: they live in `operations.sqlite` next to the messages and events, triggers keep them in sync on every write, and each is built once by its migration, not at launch; `INSERT INTO messageSearch(messageSearch) VALUES ('rebuild')` (or `eventSearch`) rebuilds one from its table ([architecture.md](architecture.md#chat-search)). `sync-r1` (#313) also sets `readAt = created` on every existing user message, so history is never routed again, and adds the change sequence and read cursor ([architecture.md](architecture.md#change-sequence-and-history-window)). OpenClaw keeps session transcripts and worktrees on its side.

Read app state without disturbing the running app with a read-only SQLite connection, for example `sqlite3 "file:$HOME/Library/Application Support/to.yumi.yorozu/operations.sqlite?mode=ro" "SELECT id,state FROM work ORDER BY created DESC LIMIT 5"`. User messages a quit left unrouted are `SELECT id,created FROM messages WHERE role='user' AND readAt IS NULL`.

## Environment variables

| Variable | Read by | Meaning |
|---|---|---|
| `PROJECTX_MODE` | app | `live` (default), `fixture` or `offline`; anything else means `offline` |
| `PROJECTX_DATA` | app | Puts app state, memory and index in one directory (see above) |
| `PROJECTX_TRANSPORT`, `PROJECTX_GATEWAY_URL`, `PROJECTX_AGENT`, `PROJECTX_DEV_REPO`, `PROJECTX_RELAY_URL`, `PROJECTX_SECRETARY_MODEL`, `PROJECTX_MODEL`, `PROJECTX_REVIEW_MODEL`, `PROJECTX_CLAUDE_MODEL`, `PROJECTX_CODEX_MODEL` | app | Override a `config.toml` key for that run ([Precedence](#precedence)) |
| `BUILD` | both scripts | Build number; skips the App Store Connect lookup in `upload_ios.sh` |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` | `upload_ios.sh` | App Store Connect credentials (above) |

`open` starts the app with the login session's environment, not the shell's, so settings that must survive a restart (including a worker's `build_native.sh --restart`) belong in `config.toml`. To set variables for one run, launch the binary directly, for example `PROJECTX_MODE=fixture build/Yorozu.app/Contents/MacOS/Yorozu`. A live-mode launch from an OpenClaw worker shell is refused ([openclaw-integration.md](openclaw-integration.md#launch-environment)).

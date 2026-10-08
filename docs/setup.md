# Setup

What a Mac needs to build and run Yorozu v2, and where the app keeps its data and secrets.

## Tools

| Need | Version | Notes |
|---|---|---|
| Xcode | 27 | Provides the Swift toolchain. |
| Tuist | pinned in `mise.toml` | `mise install`. Generated `.xcodeproj`/`.xcworkspace` are gitignored. `apps/mac/Tuist.swift` and `apps/ios/Tuist.swift` exist so generation also works in a git worktree, where `.git` is a file. |
| GRDB | locked in `Package.resolved` | SwiftPM dependency of `ProjectXCore`. Uses the system SQLite, whose FTS5 must have the `trigram` tokenizer (SQLite 3.34 or later) for memory search. |
| OpenClaw | the running Gateway's build | `openclaw` CLI on `PATH`; the app also searches `/opt/homebrew/bin` and `/usr/local/bin`. Source of the running build: `~/openclaw`. |
| Upload tools | system | `upload_ios.sh` also uses `openssl`, `curl`, `jq`, `awk` and `xxd`. |
| CuaDriver | 0.28.2 checked | `/Applications/CuaDriver.app`, installed separately ([cua-integration.md](cua-integration.md)). Not needed to build or run the app; workers need it to operate the Mac. |

Deployment targets are in `Package.swift` and the Tuist manifests. `ProjectXCore` declares an older macOS than the Mac app, so macOS APIs newer than its own target need availability checks there.

## OpenClaw Gateway

Local mode, bound to loopback on port 18789 (`ws://127.0.0.1:18789`), token auth. The app reaches it through the `openclaw` CLI with the CLI's own configured credentials; it never reads or copies them. Call details and gotchas: [openclaw-integration.md](openclaw-integration.md).

### The `projectx` agent

The app talks only to agent `projectx`. Its entry in `~/.openclaw/openclaw.json` (`agents.entries.projectx`) has this shape:

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

`agents.defaults.modelPolicy.allow` must list every model in the next table.

The entries for `openai-pool/gpt-6-sol` and `openai-pool/gpt-6-astra` under `models.providers.openai-pool.models` must set `contextWindow: 272000`, the window those models really take (owner decision). Yorozu reads the window per session (`contextTokens` from `sessions.describe`) to decide when to compact a topic session, and never counts more than 258,400 tokens as usable ([openclaw-integration.md](openclaw-integration.md#compaction)).

### MCP servers

Yorozu keeps the list of MCP servers its workers may use in `mcp-servers.json` ([Where data lives](#where-data-lives)). A missing file is created with the default below; edit it by hand, then relaunch the app (it is read once per run).

```json
{
  "mcpServers": {
    "cua-driver": { "args": ["mcp"], "command": "/Applications/CuaDriver.app/Contents/MacOS/cua-driver" }
  }
}
```

Each server is stdio: `command` is an absolute path, `args` is optional, and a name is 1–23 letters, digits, `-` or `_`. `env` is refused for now: a removed value would linger in OpenClaw's merge-patched config, and values would travel in command-line arguments. The app mirrors the list into OpenClaw itself ([openclaw-integration.md](openclaw-integration.md#mcp-servers)); nothing needs registering by hand. The cua-driver entry needs CuaDriver.app with Accessibility and Screen Recording granted to it (`cua-driver permissions grant`, run by the owner); its `mcp` proxy launches the CuaDriver daemon when it is not running.

## Models

These are the code defaults. The owner decided that roles will get defaults computed from the harness's model metadata, overridable in Settings ([OWNER_DECISIONS.md](../OWNER_DECISIONS.md#engineering)); until that lands, these ids stay.

| Role | Default | Override |
|---|---|---|
| Secretary and memory extractor | `openai-pool/gpt-6-astra` | `PROJECTX_SECRETARY_MODEL` |
| The one stronger routing review | `openai-pool/gpt-6-sol` | `PROJECTX_REVIEW_MODEL` |
| Thinking worker | `openai-pool/gpt-6-sol` | `PROJECTX_MODEL` |
| Coding worker, Claude Code | `anthropic/claude-opus-5-5` | `PROJECTX_CLAUDE_MODEL` |
| Coding worker, Codex | `openai/gpt-6-sol` | `PROJECTX_CODEX_MODEL` |

## Signing

| App | Bundle id | Signing |
|---|---|---|
| Mac | `to.yumi.yorozu` (v1's) | Team `AN5KM8QGEF`, manual signing with the Developer ID Application identity for that team in the login keychain, hardened runtime, `--timestamp`. Entitlements match v1 (`apps/mac/Yorozu.entitlements`); no app sandbox. |
| iOS | `to.yumi.yorozu.ios` | Team `AN5KM8QGEF`, automatic signing. Xcode issues the distribution certificate and profile itself during `upload_ios.sh`, using the App Store Connect key. |

## App Store Connect credentials

`upload_ios.sh` needs `ASC_KEY_ID` and `ASC_ISSUER_ID` in the environment and reads the private key from `~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8` (mode 600), or from `ASC_KEY_PATH` when set. The key file stays outside the repository.

## Keychain items

| Service | Account | Holds | Created by |
|---|---|---|---|
| `to.yumi.yorozu.relay` | `host` | The Mac's relay identity (Ed25519 and X25519 keys). Losing it means a new relay room, so every phone must pair again. | Mac app, first live launch |
| `to.yumi.yorozu.gateway` | `<gateway URL>\|webchat\|operator` | The native transport's device key and Gateway-issued device token | Mac app, native enrollment only |
| `to.yumi.yorozu.ios` | `pairings-v2` | The phone's pairing and identity | iOS app, on the phone |

The Mac items are `WhenUnlockedThisDeviceOnly`; the phone item is `AfterFirstUnlockThisDeviceOnly`. A Keychain the relay host cannot read stops the relay (not the app) rather than minting new keys.

## Where data lives

| Data | Live mode | `PROJECTX_DATA=<dir>` | Fixture mode |
|---|---|---|---|
| App state (`operations.sqlite`, `app.lock`) | `~/Library/Application Support/<bundle id>/` | `<dir>/` | `~/Library/Application Support/<bundle id>/Fixture/` |
| Markdown memory | `~/Yorozu/memory/` (notes, `knowledge/`, `history/`, `.writer.lock`) | `<dir>/memory/` | `…/Fixture/memory/` |
| Memory index (`discovery` and `search_trigram` tables) | `~/Library/Caches/<bundle id>/memory-index.sqlite` | `<dir>/memory-index.sqlite` | `…/Fixture/memory-index.sqlite` |
| Paired phones (`relay-devices.json`, mode 600) | `~/Library/Application Support/<bundle id>/` | same as live | none (no relay) |
| MCP server list (`mcp-servers.json`) | `~/Library/Application Support/<bundle id>/` | `<dir>/` | not used |

`<bundle id>` is the Mac bundle id from [Signing](#signing), also when `Bundle.main` has none. Directories are created 0700. `app.lock` is held with an exclusive lock, so only one process opens a data directory. The app has no migration code; the memory index is a cache rebuilt at launch, which drops the older `search` table (a build from before batch 2 of issue #310 recreates it, harmlessly). OpenClaw keeps session transcripts and worktrees on its side.

Read app state without disturbing the running app with a read-only SQLite connection, for example `sqlite3 "file:$HOME/Library/Application Support/to.yumi.yorozu/operations.sqlite?mode=ro" "SELECT id,state FROM work ORDER BY created DESC LIMIT 5"`.

## Environment variables

| Variable | Read by | Meaning |
|---|---|---|
| `PROJECTX_MODE` | app | `live` (default), `fixture` or `offline`; anything else means `offline` |
| `PROJECTX_DATA` | app | Puts app state, memory and index in one directory (see above) |
| `PROJECTX_TRANSPORT` | app | `native` selects the WebSocket Gateway client instead of the CLI |
| `PROJECTX_GATEWAY_URL` | app | Gateway URL, loopback only; default `ws://127.0.0.1:18789` |
| `PROJECTX_AGENT` | app | Must be unset or `projectx` |
| `PROJECTX_SECRETARY_MODEL`, `PROJECTX_REVIEW_MODEL`, `PROJECTX_MODEL`, `PROJECTX_CLAUDE_MODEL`, `PROJECTX_CODEX_MODEL` | app | Model overrides ([Models](#models)) |
| `PROJECTX_DEV_REPO` | app | Main checkout named in the coding prompt; default `~/Projects/PROJECTX` |
| `PROJECTX_RELAY_URL` | app | Relay URL; default `wss://relay.yumi.to` |
| `BUILD` | both scripts | Build number; skips the App Store Connect lookup in `upload_ios.sh` |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` | `upload_ios.sh` | App Store Connect credentials (above) |

`open` starts the app with the login session's environment, not the shell's. To set variables, launch the binary directly, for example `PROJECTX_MODE=fixture build/Yorozu.app/Contents/MacOS/Yorozu`. A live-mode launch from an OpenClaw worker shell is refused ([openclaw-integration.md](openclaw-integration.md#launch-environment)).

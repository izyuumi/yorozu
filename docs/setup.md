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
| Node.js | what the OpenClaw build needs | `node` found by the same rule as `openclaw`; setup runs `openclaw --version` through it, since a Finder launch's `PATH` may lack the folder the script's `env node` needs. |
| Upload tools | system | `upload_ios.sh` also uses `openssl`, `curl`, `jq`, `awk` and `xxd`. |
| Hermes Agent | 0.21.6 (`HermesHarness.testedVersions`; written against its docs and source, not yet run live) | Only when Hermes is the main harness ([Hermes Agent](#hermes-agent)). Installed by the user with Hermes's own installer; Yorozu never installs or updates it and warns on an untested version. |
| CuaDriver | 0.28.2 checked | Optional. `/Applications/CuaDriver.app`, installed separately ([cua-integration.md](cua-integration.md)). Not needed to build or run the app; workers need it to operate the Mac while the `cua` integration is on. |

Deployment targets are in `Package.swift` and the Tuist manifests. `ProjectXCore` declares an older macOS than the Mac app, so macOS APIs newer than its own target need availability checks there.

## First setup

What a new person needs before Yorozu can answer, and how Yorozu walks them through it (#317). The owner and existing installs use the same flow; it skips whatever is already in place. Yorozu checks read-only and asks; it never installs software, signs in or grants permissions, and gives the command to run instead, with a copy button.

The user does these, on the Mac that runs the Gateway:

1. Install Node.js and OpenClaw, so `node` and `openclaw` resolve on `PATH`, `/opt/homebrew/bin` or `/usr/local/bin` ([Tools](#tools)).
2. Start the Gateway: `openclaw gateway run` (local mode, loopback, [OpenClaw Gateway](#openclaw-gateway)).
3. Let setup write Yorozu's agent entry with one click ([Yorozu's agent](#yorozus-agent)). When OpenClaw's agent list is not explicit, setup offers `openclaw agents add <agent> --non-interactive --workspace <folder>` to copy and run instead.
4. Sign in to each provider the role models use: `openclaw models auth login --agent <agent> --provider <provider>`; setup lists the providers that are not signed in.
5. In the app, connect the native transport once and approve this Mac's device on the host (`openclaw devices list`, [openclaw-integration.md](openclaw-integration.md#native-transport)).
6. Optional, computer use: install CuaDriver and run `cua-driver permissions grant` ([cua-integration.md](cua-integration.md#permissions)), or turn the `cua` integration off.
7. Optional, coding: install Claude Code and Codex and sign in to both where the Gateway runs (OpenClaw runs them, not Yorozu), then choose a git repository in Settings › Advanced › Coding (`harness.dev_repo`; `dev_base` optional, [Settings](#settings-configtoml)). Coding stays off until a repository is set.

Hermes Agent as the main harness has its own steps ([Hermes Agent](#hermes-agent)).

Setup runs in the setup window, which opens at launch until setup is done and again from Settings › General › Run Setup Again…, or in a shell through [`Yorozu setup`](#yorozu-setup), which a user or their agent drives. Both run the same step engine (`SetupEngine`, [architecture.md](architecture.md#setup-and-readiness)), so a step answered in one shows as done in the other.

| Step | Checks (read-only) | Question |
|---|---|---|
| `welcome` | none | `start` |
| `harness` | The main harness's detection: `openclaw` and `node` found, the OpenClaw version, Gateway `health`; then Yorozu's own agent entry and its shape ([openclaw-integration.md](openclaw-integration.md#assisted-setup)) | `harness` (which installed harness to use) when the main one is not installed but another is, and on the done step while several are installed; `openclaw_setup` (`apply`, `skip`) when the assisted write would add or change Yorozu's entry; otherwise `check` or `skip` |
| `gateway` | Native enrollment, for OpenClaw on the native transport | App-only (Settings › Advanced › Gateway) |
| `models` | Each role model usable (`models.list`) and its provider signed in (`models.authStatus`) | `openclaw_setup` when the write would only add allow-list items; otherwise `check` or `skip` |
| `integrations` | Each enabled integration's checks | `integrations.<name>` (`on`, `off`) for the first one with a failed check |
| `yolo` | none | `off` (default) or `on` |
| `start_at_login` | none | `on` (default) or `off`; app-only (Settings › General › Start at login) |
| `pair_iphone` | A paired phone | `paired` or `skip`; app-only (Settings › Devices › Pair iPhone) |
| `path_link` | `~/.local/bin/yorozu` points to this binary | `no` (default) or `yes` ([The `yorozu` command](#the-yorozu-command)) |
| `done` | Every step done | none |

- A step is done when its checks pass or the user answered or skipped it (`setup.answered`). The CLI asks only steps still needed; the window may still offer a done step's question (the harness choice, YOLO) so the answer can change. `check` re-runs the checks, and `apply` makes the assisted write and checks again; `skip` and the other answers record the step. Choosing a harness is not a skip: its checks still have to pass.
- App-only steps need the running app. Outside it they show as `app` with where to finish them, and answering one is refused.
- When every step is done, setup writes `setup.done = true` and the window stops opening at launch. Completion lives only in `config.toml`, never in v1's `onboardingCompleted` key.
- Each answer is one read-modify-write of `config.toml` (`Config.update`, atomic), or the assisted OpenClaw write, or the PATH link. A running app picks up the file through its watcher. An explicit answer is the user's word for a security-relevant key (the harness, YOLO).

### `Yorozu setup`

The app binary doubles as the setup CLI (`SetupCLI.swift`):

```sh
<Yorozu.app>/Contents/MacOS/Yorozu setup [--json]                      # check, then print the next step
<Yorozu.app>/Contents/MacOS/Yorozu setup answer <id> <value> [--json]  # apply one answer, then print the next step
```

- It opens no window, shows no Dock icon, takes no `app.lock` and never opens the Store, so it works while the app runs. It uses the app's data root (`PROJECTX_DATA`, `PROJECTX_MODE`) and the `PROJECTX_*` overrides, and writes `config.toml` with the defaults when it is missing.
- It talks to the Gateway over the CLI transport. Started with the OpenClaw exec markers set (from an OpenClaw agent's shell, [openclaw-integration.md](openclaw-integration.md#launch-environment)), it makes no Gateway call: the `harness` and `models` steps show as `app` with "Open Yorozu from Finder and finish setup there".
- `<id>` is the question's `id` (`openclaw_setup` and `integrations.<name>` differ from their step ids); `<value>` is one of its `choices`.
- Exit codes: `0` a step was printed; `2` usage, an id with no question now, a value outside the choices, or an app-only step ("Finish this in the Yorozu app: <where>."); `1` anything else, such as an invalid `config.toml` or OpenClaw's config changing since it was checked.
- Errors: with `--json`, `{"error": "<message>"}` on stdout; without, `error: <message>` on stderr.
- Without `--json` the same content prints as plain text, ending with the question, its choices and the `setup answer` line to run.

The JSON is one object, keys sorted:

```json
{
  "steps": [
    {"id": "welcome", "title": "Welcome", "state": "done"},
    {"id": "gateway", "title": "Connect to the Gateway", "state": "app", "where": "Settings › Advanced › Gateway"}
  ],
  "checks": [
    {"step": "harness", "id": "openclaw.gateway", "title": "…", "severity": "warning", "detail": "…",
     "fix": {"title": "Copy start command", "copy": "openclaw gateway run"}}
  ],
  "step": "harness",
  "question": {"id": "openclaw_setup", "text": "…", "choices": ["apply", "skip"], "default": "apply"},
  "changes": [{"path": "agents.entries.yorozu.contextInjection", "old": null, "new": "\"never\""}],
  "confirm": false
}
```

- `steps`: every step with `state` `done`, `needed` or `app` (plus `where`).
- `checks`: every check with its step, `severity` (`ok`, `warning`, `blocking`), the raw `detail` when there is one, and a `fix`: `{"step": <id>}`, `{"title", "copy": <command>}` or `{"title", "open": <url>}`.
- `step` and `question`: the first step with something to ask. For `openclaw_setup`, `changes` lists each config path with its old and new value as JSON text (`null` when absent), and `confirm` is true when Yorozu's existing entry would change.
- With nothing left to ask, `"done": true` replaces `step` and `question`, plus `finish_in_app`, `[{"id", "title", "where"}]`, for app-only steps still open.

### The `yorozu` command

Step `path_link` offers a `yorozu` command: answered `yes`, it links `~/.local/bin/yorozu` to the app binary, so `yorozu setup --json` works from any shell with `~/.local/bin` on `PATH` (user-writable, no sudo; CuaDriver's installer uses the same folder). The default is `no`. A file already at that path that is not this link is left alone, and the answer fails until it is removed.

### Paste-in message

The text a user pastes into an agent they already use (Claude Code, Codex, OpenClaw…) so it drives `Yorozu setup` with them. #321 publishes it in `Start.md` and on the website; keep those copies the same as this one.

```text
Help me set up Yorozu on this Mac. Yorozu has a setup command: you run it, and I answer its questions.

1. Run: "/Applications/Yorozu.app/Contents/MacOS/Yorozu" setup --json
   If Yorozu.app is somewhere else, ask me where it is.
2. Read the JSON. Show me the checks that are not "ok", with their fix commands. If there is a "question", ask me its text with its choices and default. If there are "changes", show them to me before I answer.
3. Run: "/Applications/Yorozu.app/Contents/MacOS/Yorozu" setup answer <question id> <my answer> --json
   Then go back to step 2 with its output.
4. Stop when the output has "done": true. Tell me each "finish_in_app" item and where in the Yorozu app to finish it.

Rules: never install software, sign in or grant permissions for me, and never run a fix command yourself. Show me the command; after I run it, answer "check". Never choose an answer for me, and never edit Yorozu's or OpenClaw's config files. If a command fails, show me the error and stop.
```

The message assumes `/Applications/Yorozu.app`. Until Mac distribution exists, a dev build lives elsewhere (`build/Yorozu.app`), and v1, which shares the bundle id, has no `setup` subcommand: the path must point at the v2 app.

## OpenClaw Gateway

Local mode, bound to loopback on port 18789 (`ws://127.0.0.1:18789`), token auth. The app reaches it through the `openclaw` CLI with the CLI's own configured credentials; it never reads or copies them. Call details and gotchas: [openclaw-integration.md](openclaw-integration.md).

### Yorozu's agent

The app talks to the agent named by `[harness] agent` in `config.toml`, whose code default is the generic `yorozu`. The owner's `config.toml` sets `agent = "projectx"`, which keeps the existing session keys ([openclaw-integration.md](openclaw-integration.md#sessions-and-runs)). Its entry in `~/.openclaw/openclaw.json` (`agents.entries.<agent>`) has this shape, shown for the owner's `projectx`:

```json5
{
  name: "projectx",
  workspace: "~/Projects/PROJECTX",   // dev_repo, the main checkout; coding worktrees are cut from it
  agentDir: "…",                      // OpenClaw's per-agent directory
  identity: { … },
  model: { primary: "openai-pool/gpt-6-astra", fallbacks: [] },
  contextInjection: "never",          // the default is "always"
  skills: [],
  subagents: { allowAgents: [] },     // the default is ["*"]
  // no `tools` key: workers inherit the global tool profile (full)
}
```

Setup checks this shape and offers to write what is missing or different: `workspace`, `model.primary`, `contextInjection`, `skills`, `subagents.allowAgents`, and the removal of a `tools` key ([openclaw-integration.md](openclaw-integration.md#assisted-setup)). The workspace is `dev_repo` when it is set, else an empty Yorozu-owned folder, `<data root>/openclaw-workspace` (mode 0700, created just before the write). `model.primary` is `models.worker` when set, else `agents.defaults.model`'s primary.

The model policy in force, the entry's own `modelPolicy.allow` or else `agents.defaults.modelPolicy.allow`, is the list Yorozu's automatic model choices pick from, and `model.primary` is the worker default ([Models](#models)). An explicit per-agent list replaces the defaults' for that agent, so when setup adds a role model it writes the entry's own list seeded from the policy in force; it never touches `agents.defaults`.

The entries for `openai-pool/gpt-6-sol` and `openai-pool/gpt-6-astra` under `models.providers.openai-pool.models` must set `contextWindow: 272000`, the window those models really take (owner decision). Yorozu reads the window per session (`contextTokens` from `sessions.describe`) to decide when to compact a topic session, and never counts more than 258,400 tokens as usable ([openclaw-integration.md](openclaw-integration.md#compaction)).

## Hermes Agent

Needed only with `[harness] kind = "hermes"`. Hermes runs its API server on loopback (`http://127.0.0.1:8642`) and serves Yorozu's two profiles under it; call details, profiles and hazards are in [hermes-integration.md](hermes-integration.md). The user does the install and provider steps; Yorozu writes only its own two profiles.

1. Install Hermes with its installer and leave out its computer-use driver, so a second CuaDriver.app does not compete with the installed one for macOS permissions: `curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-computer-use`. It installs to `~/.hermes` with the launcher `~/.local/bin/hermes`; pip and Homebrew installs are not supported by Hermes.
2. When the setup wizard reports an OpenClaw installation and offers to migrate it, decline. Never run `hermes claw migrate` or `hermes claw cleanup`: cleanup renames `~/.openclaw`, which the OpenClaw harness needs ([hermes-integration.md](hermes-integration.md#openclaw-migration-hazards)).
3. Turn on the API server in the default Hermes profile, which serves the named profiles (multiplexing). Yorozu checks this read-only and shows the same commands; it never edits the default profile:

   ```sh
   hermes config set API_SERVER_ENABLED true
   hermes config set API_SERVER_KEY "$(openssl rand -hex 32)"   # only if the default profile has no key of 16+ characters
   hermes gateway restart
   ```

4. Run the Hermes setup step, which creates and configures `yorozu-worker` and `yorozu-roles` and stores their API keys in the Keychain ([Keychain items](#keychain-items)). The step is `HermesProfiles.plan` and `apply`; it has no caller yet: the #317 setup steps cover Hermes only through its detection (`HermesSetup`); Hermes setup steps are not built yet.
5. Configure providers and logins for both Yorozu profiles in Hermes, for example `hermes -p yorozu-worker model` and `hermes -p yorozu-roles model`. Provider keys stay in Hermes; Yorozu never reads them. The profiles do not adopt the Claude Code and Codex logins (`auth.adopt_external_logins: false`).
6. Set `[harness] kind = "hermes"` in `config.toml` (or `PROJECTX_HARNESS=hermes` for one run) and relaunch. The popover header shows "Hermes Agent <version>", and an orange line lists anything not ready or an untested version.

## Settings (`config.toml`)

Yorozu's settings are one file, `config.toml`, in the data root in use ([Where data lives](#where-data-lives)), so fixture and `PROJECTX_DATA` runs each have their own and v1, which shares the bundle id, never sees it (`Config.swift`). A launch with no file writes one with the defaults below; no default is specific to one owner. Change it in the Settings window (⌘, or Settings… in the menu-bar menu; the Advanced tab shows while `general.show_advanced` is on, [architecture.md](architecture.md#mac-ui)), by hand, or by asking Yorozu in the chat, which has a worker edit it ([architecture.md](architecture.md#settings)). A row whose key is set by an environment variable is disabled in Settings and labelled "Set by `PROJECTX_…`" ([Precedence](#precedence)); `models.rules.*`, `routing.*`, `direct.*`, `harness.kind`, `harness.hermes_url`, `mcp_servers` and user integrations' other keys have no Settings row, and `setup.*` is written by setup.

| Key | Default | Meaning |
|---|---|---|
| `general.start_at_login` | `true` | Login item ([Start at login and keep awake](#start-at-login-and-keep-awake)) |
| `general.keep_mac_awake` | `false` | No idle sleep while Yorozu runs |
| `general.yolo` | `false` | YOLO mode ([architecture.md](architecture.md#mcp-servers-and-computer-use)) |
| `general.send_key` | `"smart"` | `"smart"` (Return sends a one-line draft) or `"cmd-enter"` (Return is always a new line); ⌘Return always sends ([architecture.md](architecture.md#mac-ui)) |
| `general.global_shortcut` | `""` (off) | Shortcut that toggles the popover: modifiers and one key joined by `+`, such as `"option+space"`, `"cmd+shift+y"` or `"ctrl+f5"`; a key other than F1–F12 needs a modifier ([architecture.md](architecture.md#mac-ui)) |
| `general.appearance` | `"system"` | `"system"`, `"light"` or `"dark"` |
| `general.show_advanced` | `false` | Shows the Advanced tab |
| `notifications.enabled` | `true` | macOS notifications for results, failures and questions; the menu-bar dot shows either way |
| `notifications.destination` | `"mac"` | `"mac"` or `"phones"`; with `"phones"` the Mac posts none, and phone push comes with #320 |
| `routing.personal_knowledge` | `""` | The user's personal notes, named in the routing policy as a source only a worker can read; empty drops that clause; at most 200 bytes of UTF-8 |
| `routing.self_topic` | `"Yorozu"` | The topic that holds work on Yorozu itself; at most 80 characters |
| `relay.url` | `"wss://relay.yumi.to"` | Relay for the iPhone app, `ws://` or `wss://` with a host |
| `direct.enabled` | `true` | The direct listener paired phones may dial over the LAN or a VPN; a phone dials it only after its own Direct connection setting is on ([Direct connection](#direct-connection)) |
| `direct.port` | `8738` | TCP port of the direct listener, 1024–65535 |
| `harness.kind` | `"openclaw"` | Main harness: `"openclaw"` or `"hermes"`; applies at the next launch, and only once no work is active or uncertain ([architecture.md](architecture.md#harness-seam)) |
| `harness.agent` | `"yorozu"` | Harness agent id, 1–64 letters, digits, `-` or `_` ([Yorozu's agent](#yorozus-agent)) |
| `harness.transport` | `"native"` | `"native"` or `"cli"`; a native launch still sends admin-scope calls through the CLI ([openclaw-integration.md](openclaw-integration.md#transport)) |
| `harness.gateway_url` | `"ws://127.0.0.1:18789"` | Loopback `ws`/`wss` only, with no path, query or credentials |
| `harness.hermes_url` | `"http://127.0.0.1:8642"` | Hermes API server root, loopback `http`/`https` only, with no path, query or credentials; profiles are reached under `/p/<profile>/` |
| `harness.dev_repo` | `""` | Main checkout for coding work, an absolute or `~/` path; empty turns coding work off: the secretary offers no coding executor and says to choose a repository in Settings › Advanced |
| `harness.dev_base` | `""` | Branch of `dev_repo` coding worktrees are cut from and merged into; empty is the branch checked out there when the work starts. The owner's file sets `dev_base = "projectx"` |
| `models.secretary`, `models.extraction`, `models.worker`, `models.review` | absent (automatic) | `"provider/model"` ([Models](#models)) |
| `models.coding.<executor>` | absent (automatic) | An executor id the harness offers (OpenClaw: `claude`, `codex`; Hermes: `hermes`) = `"provider/model"` |
| `models.rules.min_context_tokens`, `models.rules.min_output_tokens` | `32000`, `16000` | Inputs of the automatic secretary and extraction choice |
| `mcp_servers.<name>` | none ([MCP servers](#mcp-servers)) | `command` and `args` |
| `integrations.<name>.enabled` | `true` for the built-in `cua` | Turns an integration on or off ([Integrations](#integrations)); Settings › Advanced › Integrations |
| `setup.done` | `false` | Setup is finished; until then the app opens the setup window at launch ([First setup](#first-setup)) |
| `setup.answered` | `[]` | Ids of the setup steps the user answered or skipped |

`send_key`, `global_shortcut` and `notifications.*` are used by the popover (#311); `appearance` sets the app's appearance and `show_advanced` shows the Advanced tab (#312).

- **Format.** Yorozu writes the whole file in one canonical layout: known keys in a fixed order, each with Yorozu's own comment, absent model keys as commented examples, and unknown keys kept as data after them. Hand-written comments are not kept. Every write goes to a temporary file in the same folder, mode 0600, flushed to disk, then is renamed over `config.toml`; a write that would be invalid is refused. Writes from Settings are read-modify-write (`Config.update`), so a recent hand or worker edit survives, and are applied at once; a refused write shows in the Settings tab. Otherwise the app writes the file only to create it.
- **Reload.** `ConfigWatcher` watches the folder with FSEvents, so in-place edits and atomic saves are both seen, and debounces for 300 ms: a saved change is applied within about a second. An unchanged file is ignored; the comparison starts from the file as read at launch, so an edit made while the app was starting is applied too.
- **Invalid edits.** A file that does not parse or validate, or is missing, leaves the last valid settings in force and posts one `failure` notice per distinct problem, code `config_invalid`, naming the file, the line when known, the key and the reason: "Settings not applied: config.toml line 12 (relay.url): expected a ws:// or wss:// address. The last valid settings stay in force." An invalid or unreadable file at launch is left untouched: that run uses the code defaults plus the environment, posts the same notice ending "Yorozu runs on its default settings until the file is fixed.", and applies the file once it is fixed. That run uses the default agent `yorozu` unless `PROJECTX_AGENT` says otherwise.
- **Security-relevant keys.** `general.yolo`, `relay.url`, `direct.enabled`, `direct.port`, every `harness.*` key, every `models.*` role and `models.coding` key, `mcp_servers` and `integrations`. Their comments say "Security-relevant: ask the user before changing it", and a worker asks for the user's yes in the chat before changing them. A reload that changes any of them posts an `acknowledgment` notice, code `settings_changed`: "Settings changed: relay.url".
- **When a change applies.** Models, YOLO, routing hints, `dev_repo` and `dev_base` from the next route, task or extraction; automatic models after the model metadata is read again. MCP servers, an integration switched on or off included, when the next worker session is prepared ([openclaw-integration.md](openclaw-integration.md#mcp-servers)); integration rules from the next task. `relay.url` restarts the relay host on the new relay with the same keys and devices; every phone must pair again, since its pairing names the old relay. `direct.*` at once: the listener restarts on the new port or stops, closing its direct links, and phones learn the new addresses at their next peer-info exchange. `keep_mac_awake`, `start_at_login`, `appearance`, `send_key` and `notifications.*` at once; `global_shortcut` within 2 s. `harness.kind`, `agent`, `transport`, `gateway_url` and `hermes_url` only at the next launch; the status line says "Relaunch Yorozu to apply: …", adding that a harness switch waits until running work finishes.

### Precedence

Each value comes from the first of: a `PROJECTX_*` environment variable, `config.toml`, the automatic choice (models only), the code default (`ResolvedSettings`). Environment values override for that run only and are never written to the file.

| Variable | Key |
|---|---|
| `PROJECTX_HARNESS` | `harness.kind` |
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

Yorozu keeps the user's own list of MCP servers its workers may use as `[mcp_servers.<name>]` tables in `config.toml`, empty by default:

```toml
[mcp_servers.example]
command = "/absolute/path/to/server"
args = ["--stdio"]
```

Each server is stdio: `command` is an absolute path, `args` is optional, and a name is 1–23 letters, digits, `-` or `_`. `env` is refused for now: a removed value would linger in OpenClaw's merge-patched config, and values would travel in command-line arguments.

Workers get `[mcp_servers]` minus the servers of disabled integrations, plus the servers of enabled ones, with `[mcp_servers]` winning on a name clash (`Config.effectiveMCPServers`). The built-in `cua` integration brings `cua-driver` (`/Applications/CuaDriver.app/Contents/MacOS/cua-driver mcp`), so it is no longer listed here; it needs CuaDriver.app with Accessibility and Screen Recording granted to it (`cua-driver permissions grant`, run by the user), and its `mcp` proxy launches the CuaDriver daemon when it is not running. The app mirrors the list into OpenClaw itself, again whenever it changes ([openclaw-integration.md](openclaw-integration.md#mcp-servers)); nothing needs registering by hand.

The list used to be `mcp-servers.json` in the data root. When `config.toml` is first created, a valid `mcp-servers.json` next to it is imported into `[mcp_servers]` once; after that the JSON file is never read and can be deleted. A file from before integrations whose `[mcp_servers]` has no `cua-driver` entry, and that sets no `[integrations.cua] enabled`, loads with cua off, since removing that entry used to mean computer use off; a file that still lists `cua-driver` keeps it.

### Integrations

An integration is data, never loaded code: MCP servers, worker rules, read-only checks and fixes, and settings, behind an on/off switch ([architecture.md](architecture.md#mcp-servers-and-computer-use)). The built-in one is `cua`, computer use through CuaDriver, on by default ([cua-integration.md](cua-integration.md)):

```toml
[integrations.cua]
enabled = true
```

For a built-in, only `enabled` and `[integrations.<name>.settings]` are read; its servers, rules, checks and fixes ship with the app, and other keys stay in the file as unknown data. A user integration may set:

```toml
[integrations.notes]
enabled = true
title = "Notes server"
rules = "Use the notes MCP tools only for the user's notes."   # "{session}" is the per-run cua session label
checks = [{ title = "Notes socket", socket = "~/Library/Caches/notes/notes.sock" },
          { title = "Notes app", file = "/Applications/Notes Server.app" }]
fixes = [{ title = "Copy start command", copy = "notes-server start" },
         { title = "Install guide", url = "https://example.com/notes" }]

[integrations.notes.mcp_servers.notes]
command = "/Applications/Notes Server.app/Contents/MacOS/notes-server"
args = ["mcp"]
```

- A name is 1–64 letters, digits, `-` or `_`; server entries follow the `[mcp_servers]` rule.
- Checks are `file` (a file, folder or app exists) or `socket` (a unix socket accepts a connection); only built-ins may run a command check. Fix URLs are `http` or `https`.
- Checks run only during setup, while Settings › Advanced shows, and on Check again ([architecture.md](architecture.md#mcp-servers-and-computer-use)). Fixes are shown, never run.

### Start at login and keep awake

- `start_at_login` registers the running app bundle as a login item with `SMAppService.mainApp` (for the dev app, `build/Yorozu.app`) and records that in `login-item-registered` in the data root; `false` unregisters the item only when that file exists, so an item this app did not register is never removed. It is on by default. When macOS wants approval, the status line says "Start at login needs approval in System Settings › General › Login Items", and Settings › General says it is waiting and offers Open Login Items…. Fixture and `PROJECTX_DATA` runs never touch the login item, and Settings shows the switch disabled with that reason.
- Known limit: v1 shares the bundle id, and `SMAppService.mainApp` could act on its login item. While LaunchServices knows any other bundle with this id (`/Applications/Yorozu.app`, or another build copy), the app leaves login items alone and, with `start_at_login` on, the status line says "Start at login is off while another Yorozu with the same id is installed"; Settings › General shows the switch off and disabled, naming the other bundle's path.
- `keep_mac_awake` holds a `ProcessInfo` activity with `.idleSystemSleepDisabled` while the app runs (`pmset -g assertions` lists it). A closed lid still sleeps.

### Direct connection

Paired phones can reach the Mac without the relay when both are on the same LAN or the same private VPN (#315; wire in [ios-relay-contract.md](ios-relay-contract.md#direct-path)). The relay stays the fallback.

- Mac: with `[direct] enabled = true` (the default) the app listens for WebSockets on `[direct] port` (8738) and accepts connections only on Wi-Fi/Ethernet (`en*`) and `utun` interfaces; loopback, AWDL and bridges are refused, so `127.0.0.1` never gets in. Only a phone whose key is in `relay-devices.json` gets past the join: pairing still goes over the relay. The addresses phones are told are the Mac's private Wi-Fi/Ethernet addresses (`lan`) and its private `utun` addresses (`vpn`: RFC 1918, 100.64.0.0/10, ULA), never loopback or link-local. Settings › Connection › Direct connection shows the listener, the addresses, each phone's route and the last refused connection.
- macOS firewall: when the application firewall is on, macOS asks whether Yorozu may accept incoming connections. An unsigned or ad hoc build asks again after each rebuild, since its signature changes; a Developer ID signed build may ask once. Deny keeps phones on the relay.
- Local Network on the Mac: the Mac app declares `NSLocalNetworkUsageDescription`; if macOS asks, allow it. A denial shows up later in System Settings › Privacy & Security › Local Network.
- iPhone: Settings › Connection › "Direct connection (LAN / Tailscale)" is off by default (`UserDefaults` key `directPathEnabledV2`; v1's `directConnectionEnabled` is a different key and never read). Turning it on is when iOS asks for Local Network access; denied, the phone stays on the relay and Settings points to Settings › Privacy & Security › Local Network. The Mac's addresses arrive in the sealed peer info over the relay and are stored in the phone's Keychain pairing record, never in `UserDefaults`, so Remove host and Repair drop them. They refresh only at the next peer-info exchange (a new session).
- Tailscale: run Tailscale, signed in to the same tailnet, on both devices. The Mac's Tailscale address (100.64.0.0/10 or fd7a:115c:a1e0::/48 on a `utun` interface) is advertised as `vpn` and shown as "Tailscale"; other WireGuard VPNs with private addresses work the same way, shown as "VPN". Tailnet ACLs must let the phone reach the Mac on the direct port. v1's `tailscale serve` on port 8443 is not involved. The phone tries VPN addresses only while a VPN interface is up and LAN addresses only on Wi-Fi or Ethernet.

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
| Coding worker, Hermes | `models.coding.hermes` | The same rule; every Hermes model runs on its `hermes` runtime. Empty falls back to the thinking worker's model |

- Price is input plus output price per million tokens. A model without a price, or with a 0/0 cost (as a local proxy may declare), counts as unknown and is left out of the cheapest and most-expensive picks; a model with no output cap is left out of both too. When no allowed model has a price, the secretary, extraction, review and worker roles all use the agent's primary model.
- An explicit choice the harness does not list is still used.
- The metadata comes from the main harness: the Gateway ([openclaw-integration.md](openclaw-integration.md#model-metadata)) or Hermes's `/api/model/options`, which has prices but no context window or output cap ([hermes-integration.md](hermes-integration.md#models)). Without those, every automatic role on Hermes resolves to the primary model (the model configured in `yorozu-worker`); set `[models]` explicitly for a cheaper secretary. Hermes needs every model as `provider/model`. It is read at launch, where queued work waits up to 10 s for it before resuming, and after each reload; while no read has succeeded, it is read again before a message at most every 30 s. A failed read keeps the last good one. With no metadata and no explicit choice a role has no model, and its runs fail with "No model is set for this role; choose one in Settings › Advanced."
- Vision (#316): a worker gets attached images as model input only when `models.list` lists `image` in its model's `input`, checked on every call ([openclaw-integration.md](openclaw-integration.md#attachments-and-media)); otherwise, and on Hermes, the path alone. On 2026-10-09 `models.list` for agent `projectx` (`view: "configured"`) listed `["text","image"]` for every row: `openai-pool/gpt-6-astra` (tagged `default`, so the automatic worker model), `openai-pool/gpt-6-sol`, `openai-pool/gpt-6-luna`, `openai/gpt-6-sol`, `anthropic/claude-fable-5-1`, `anthropic/claude-opus-5-5` and `anthropic/claude-sonnet-5`. Re-check with `models.list` after a model or OpenClaw change, never by reading the OpenClaw config.
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
| `to.yumi.yorozu.hermes` | `yorozu-worker`, `yorozu-roles` | Each Yorozu Hermes profile's `API_SERVER_KEY` (43 random characters), mirrored from the profile's `.env`; `AfterFirstUnlockThisDeviceOnly`. Read per request, never logged, put in a URL or written to a receipt. | Mac app, the Hermes setup step only ([Hermes Agent](#hermes-agent)) |
| `to.yumi.yorozu.ios` | `pairings-v2` | The phone's pairing and identity, and the direct addresses the Mac last advertised | iOS app, on the phone |

The relay and Gateway items are `WhenUnlockedThisDeviceOnly`; the phone item is `AfterFirstUnlockThisDeviceOnly`. A Keychain the relay host cannot read stops the relay (not the app) rather than minting new keys; the app tries to start the relay again every 30 s, so unlocking the login Keychain is enough.

## Where data lives

| Data | Live mode | `PROJECTX_DATA=<dir>` | Fixture mode |
|---|---|---|---|
| App state (`operations.sqlite`, `app.lock`) | `~/Library/Application Support/<bundle id>/` | `<dir>/` | `~/Library/Application Support/<bundle id>/Fixture/` |
| Chat search indexes (`messageSearch` and `eventSearch` tables) | inside `operations.sqlite` | same | same |
| Markdown memory | `~/Yorozu/memory/` (notes, `knowledge/`, `history/`, `.writer.lock`) | `<dir>/memory/` | `…/Fixture/memory/` |
| Memory index (`discovery` and `search_trigram` tables) | `~/Library/Caches/<bundle id>/memory-index.sqlite` | `<dir>/memory-index.sqlite` | `…/Fixture/memory-index.sqlite` |
| Paired phones (`relay-devices.json`, mode 600) | `~/Library/Application Support/<bundle id>/` | same as live | none (no relay) |
| Settings (`config.toml`, mode 600) | `~/Library/Application Support/<bundle id>/` | `<dir>/` | `…/Fixture/` |
| Yorozu's OpenClaw agent workspace while `dev_repo` is empty (`openclaw-workspace/`, mode 700, created by the assisted setup write) | `~/Library/Application Support/<bundle id>/` | `<dir>/` | `…/Fixture/` |
| Scheduled jobs (`jobs.toml`, mode 600) | `~/Library/Application Support/<bundle id>/` | `<dir>/` | `…/Fixture/` |
| Job folders (`<id>/`, mode 700, the scripts' working directory; `<id>/runs/*.log`, mode 600, one full log per run) | `~/Yorozu/jobs/` | `<dir>/jobs/` | `…/Fixture/jobs/` |
| Attachments (files users attach and workers return, `<YYYY-MM>/<YYYY-MM-DD_HHMMSS>_<name>`; directories 0700, files 0600; kept until deleted in Finder) | `~/Yorozu/files/` | `<dir>/files/` | `…/Fixture/files/` |
| Phone upload staging (`<device key>/<message id>/<index>-<sha256>.part`, 0700/0600; at most 1 GB and 64 messages, pruned after 48 h untouched) | `~/Library/Application Support/<bundle id>/uploads/` | same as live | none (no relay) |
| Attachment thumbnails (the popover's previews as `<id>-<px>.png`, phones' 512 px previews as `<id>.jpg`; rebuildable) | `~/Library/Caches/<bundle id>/thumbs/` | same as live | same as live |
| Composer scratch files (pasted or dropped image data, downscaled images, Send as Text File; deleted once sent or removed) | `$TMPDIR/Yorozu-attachments/<uuid>/` | same | same |
| Worker scratch folder (files a worker makes before returning them; created by the worker, nothing there needs to last) | `$TMPDIR/yorozu-scratch/<topic id>/` (the app's temporary folder, named in the worker contracts) | same | same |
| Retired MCP server list (`mcp-servers.json`) | imported once into a new `config.toml`, then unused ([MCP servers](#mcp-servers)) | same | same |

Settings › Storage shows the Markdown memory folder and the `files` folder next to it (in live mode `~/Yorozu/files/`, created at launch by the file store) with their sizes and Show in Finder; a files root that resolves inside a git checkout or worktree is refused, and that launch runs with attachments off ("Attachments are off: …" in the status line); Settings › Advanced shows the data folder that holds `config.toml`. `<bundle id>` is the Mac bundle id from [Signing](#signing), also when `Bundle.main` has none. Directories are created 0700. `app.lock` is held with an exclusive lock, so only one process opens a data directory. Schema changes to `operations.sqlite` are GRDB migrations that run at launch (`native-r1`, `r2-executor`, `memory-job-reasons`, `message-notice`, `message-search`, `sync-r1`, `jobs-r1`, `jobs-topic-unique`, `sync-topic-touch`, `receipts-sent-at`, `attachments-r1`) and only add tables, columns, indexes and triggers; `jobs-r1` (#319) adds `jobs`, `jobApprovals` and `jobRuns`, `jobs-topic-unique` makes a topic bind at most one job, `sync-topic-touch` (#313) re-stamps a topic when a message or work row starts using it, `receipts-sent-at` (#314) adds the nullable `messages.sentAt`, the phone's send time, set only on messages that came from a phone ([architecture.md](architecture.md#change-sequence-and-history-window)), and `attachments-r1` (#316) adds `attachments` and `workAttachments` ([architecture.md](architecture.md#attachments)). Moving data between folders or machines stays manual. The memory index is a cache rebuilt at launch, which leaves the older `search` table in place for builds from before batch 2 of issue #310 that share the cache. The chat search indexes are different: they live in `operations.sqlite` next to the messages and events, triggers keep them in sync on every write, and each is built once by its migration, not at launch; `INSERT INTO messageSearch(messageSearch) VALUES ('rebuild')` (or `eventSearch`) rebuilds one from its table ([architecture.md](architecture.md#chat-search)). `sync-r1` (#313) also sets `readAt = created` on every existing user message, so history is never routed again, and adds the change sequence and read cursor ([architecture.md](architecture.md#change-sequence-and-history-window)). OpenClaw keeps session transcripts and worktrees on its side. Hermes keeps its sessions in its own store under `~/.hermes/profiles/yorozu-worker/` and `yorozu-roles/`; a Hermes coding worker's worktree sits next to the dev repo as `<dev repo>-yorozu-<label slug>-<topic id prefix>`.

Read app state without disturbing the running app with a read-only SQLite connection, for example `sqlite3 "file:$HOME/Library/Application Support/to.yumi.yorozu/operations.sqlite?mode=ro" "SELECT id,state FROM work ORDER BY created DESC LIMIT 5"`. User messages a quit left unrouted are `SELECT id,created FROM messages WHERE role='user' AND readAt IS NULL`; phone messages that arrived late are `SELECT id,sentAt,created FROM messages WHERE created - sentAt > 60`.

Jobs (#319): `jobs.toml` is created by the first write (a worker creating a job, or a control); a missing file is no jobs. Its keys are in [architecture.md](architecture.md#jobstoml) and in the header Yorozu writes into the file. Deleting a job leaves its folder, with its run logs, in place; remove it in Finder. A script runs as the user's account, so a macOS privacy prompt it triggers (Files and Folders, Automation, Full Disk Access) is for Yorozu and needs the owner's grant. Recent runs: `SELECT jobID,state,exitCode,notable,posted FROM jobRuns ORDER BY started DESC LIMIT 5`.

### On the phone

| Data | Where | Protection |
|---|---|---|
| Pairing and identity, with the Mac's direct addresses | Keychain item `pairings-v2` ([Keychain items](#keychain-items)) | `AfterFirstUnlockThisDeviceOnly` |
| History-window cache (`mirror.json`) | `Application Support/Mirror/` in the app's container | File protection `completeUntilFirstUserAuthentication` (encrypted at rest, unreadable until the first unlock after a restart, like the Keychain item); the `Mirror` folder is excluded from backup |
| Outbox (`outbox.json`: messages the Mac has not stored, and the marks and times of sent messages until Read) | `Application Support/Outbox/` in the app's container | Same as the cache: `completeUntilFirstUserAuthentication`, so a background flush can read it after the first unlock; the `Outbox` folder is excluded from backup |
| Outbox file copies (`<message id>/<index>`, the files of a message the Mac has not stored, with the upload offsets it confirmed, fsynced) | `Application Support/Uploads/` in the app's container | `completeUntilFirstUserAuthentication`; excluded from backup |
| Attachment cache (thumbnails and opened full files, `<key>/`, keyed by content hash) | `Application Support/Files/` in the app's container | `completeUntilFirstUserAuthentication`; excluded from backup |
| Composer drafts (picked files staged before Send, one folder each) | `tmp/Drafts/` in the app's container | none; deleted at launch and when sent or removed |
| Last connection status (`lastConnectionStatus`) | `UserDefaults` | none; it holds only the status and when it was saved, no chat content |
| Direct connection setting (`directPathEnabledV2`) | `UserDefaults` | none; a Boolean, off by default |

The cache is a cache: a file that does not decode, has another format version or belongs to another pairing (its `owner` is the pairing's session key) loads as nothing and catch-up refills it. The outbox is not a cache: it holds messages that exist nowhere else until the Mac stores them. It is keyed to the pairing the same way, so a file from another pairing is never read. Remove host and every new pairing delete the `Mirror`, `Outbox`, `Uploads` and `Files` folders ([architecture.md](architecture.md#ios-app)).

Notifications: the phone asks for notification permission (alerts, sounds and badges) the first time a message has to wait for a connection. It posts only local notifications, "N messages waiting to send" and "A message to your Mac expired without being read.", never with message content; push comes with #320. Denying permission changes nothing else: messages still queue and send.

## Environment variables

| Variable | Read by | Meaning |
|---|---|---|
| `PROJECTX_MODE` | app, `Yorozu setup` | `live` (default), `fixture` or `offline`; anything else means `offline` |
| `PROJECTX_DATA` | app, `Yorozu setup` | Puts app state, memory, index, `jobs.toml` and the job folders in one directory (see above) |
| `PROJECTX_HARNESS`, `PROJECTX_TRANSPORT`, `PROJECTX_GATEWAY_URL`, `PROJECTX_AGENT`, `PROJECTX_DEV_REPO`, `PROJECTX_RELAY_URL`, `PROJECTX_SECRETARY_MODEL`, `PROJECTX_MODEL`, `PROJECTX_REVIEW_MODEL`, `PROJECTX_CLAUDE_MODEL`, `PROJECTX_CODEX_MODEL` | app, `Yorozu setup` | Override a `config.toml` key for that run ([Precedence](#precedence)) |
| `BUILD` | both scripts | Build number; skips the App Store Connect lookup in `upload_ios.sh` |
| `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_PATH` | `upload_ios.sh` | App Store Connect credentials (above) |

`open` starts the app with the login session's environment, not the shell's, so settings that must survive a restart (including a worker's `build_native.sh --restart`) belong in `config.toml`. To set variables for one run, launch the binary directly, for example `PROJECTX_MODE=fixture build/Yorozu.app/Contents/MacOS/Yorozu`. A live-mode launch from an OpenClaw worker shell is refused ([openclaw-integration.md](openclaw-integration.md#launch-environment)).

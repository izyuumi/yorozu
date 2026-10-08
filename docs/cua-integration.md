# cua integration (R3)

R3 is cua (https://cua.ai) integration so Yorozu can operate the user's computer ([OWNER_DECISIONS.md](../OWNER_DECISIONS.md#workers)). Progress is in [status.md](status.md).

## Route

Workers operate the Mac through the **cua-driver MCP server**, under rules in their prompts (owner decisions, 2026-10-08):

- **CuaDriver is a separate install** (`/Applications/CuaDriver.app`). Yorozu neither bundles it nor starts its daemon: `cua-driver mcp` is a proxy that launches the daemon through LaunchServices (`open -n -g -a CuaDriver --args serve`) when the socket is not answering, so the TCC grants stay with `com.trycua.driver`. The installer registers no MCP client; its `~/.local/bin/cua-driver` link is optional.
- **Yorozu lists it as an MCP server** in its own list (`[mcp_servers]` in `config.toml`, [setup.md](setup.md#mcp-servers)), which the harness adapter mirrors into OpenClaw as `yorozu-cua-driver` ([openclaw-integration.md](openclaw-integration.md#mcp-servers)). Yorozu adds no process and no Swift dependency.
- **Routing**: "operate my Mac / use app X" goes to a thinking worker (no executor), and new coding work that needs an app or a browser goes to Codex unless the user names Claude Code (continuing work keeps its executor). Thinking and Codex workers get the tools; Claude Code does not (an OpenClaw gap the owner left as is, [openclaw-integration.md](openclaw-integration.md#mcp-servers)).
- **Rules** live in `OpenClawHarness.cuaRules(task, yolo:)` (`Harness.swift`), included in both worker contracts. They follow [Worker rules](#worker-rules) below, with the [YOLO](#yolo-mode) variant when `general.yolo` is on. There is no separate executor or lane, so tasks in different topics or with different executors can run at once, even on the same app; see [Concurrency](#concurrency).

The `cua` CLI and the cua SDK manage sandboxes, Spaces and VMs; use them for isolated computers, not for driving the host desktop.

## Host check (2026-10-08, read-only)

| Item | Finding |
|---|---|
| Binary | `~/.local/bin/cua-driver` 0.28.2, a link to `/Applications/CuaDriver.app/Contents/MacOS/cua-driver` |
| Daemon | Running as `cua-driver serve` from CuaDriver.app; socket `~/Library/Caches/cua-driver/cua-driver.sock` |
| Policy | Permission mode `standard` (built-in default); no user policy, managed policy or capability manifest |
| TCC | Accessibility and Screen Recording granted to the daemon. Tahoe direct-capture consent not checked (the status command is read-only) |
| Config | `agent_cursor.enabled: true`, `max_image_dimension: 1568`, `experimental_pip: false` |
| Tools | 56 MCP tools (`cua-driver list-tools`); the ones workers need are under [Targeting one window](#targeting-one-window) |
| OpenClaw | MCP servers `cua-driver` (`cua-driver mcp`, working), `cua` (points at a missing `~/Applications/Cua Spaces.app`, broken) and `computer-use` (another vendor's client, not used here). These are the owner's entries; Yorozu sessions switch all of them off and use their own `yorozu-cua-driver` ([openclaw-integration.md](openclaw-integration.md#mcp-servers)). |
| Skill pack | The cua-driver skill pack is not linked into OpenClaw |
| `cua` CLI | Not on `PATH` |

## Interfaces

| | cua-driver MCP | `cua` CLI | cua SDK |
|---|---|---|---|
| Purpose | Drive native apps on this desktop | Sandboxes, Spaces, auth, one-shot `cua do` actions, its own MCP server ([docs][cli]) | Create and drive isolated Linux, Windows or macOS machines from Python, TypeScript, Swift or Rust ([docs][sdk]) |
| Target | Host apps, by pid and window_id | Sandboxes and VMs (Lume, Docker/QEMU, cloud) | Sandboxes and any `cua-spacesd` host |
| On the host | Yes, daemon running | No (configured binary missing) | Not installed |
| Fit for operating the user's Mac | Primary | No: it targets sandboxes | No: same reason |

`cua-driver call <tool> '<json>'` reaches the same daemon and tools as the MCP server. Use it for diagnostics, not as a second worker path.

## Permissions

- TCC grants belong to the CuaDriver.app daemon (`com.trycua.driver`): Accessibility for AX reads and actions, Screen Recording for screenshots and pixel actions, and direct-capture consent on Tahoe. Yorozu.app, OpenClaw and worker shells need none of them, because every action goes through the daemon socket. Starting the daemon through LaunchServices (`open -n -g -a CuaDriver --args serve`) makes macOS attribute the grants to CuaDriver rather than to the calling terminal ([quickstart][qs]).
- `cua-driver permissions grant` is the only command that prompts. It is the owner's to run.
- Without Accessibility, stop. Without only Screen Recording, a worker may continue with AX-only actions: `get_window_state` with `include_screenshot: false`, then element-token actions.

## Targeting one window

Work on one app window in the background, without taking focus:

1. Resolve the pid and window_id with `list_apps` / `list_windows`. `launch_app` starts an app without bringing it to the front.
2. `get_window_state(pid, window_id)` returns an AX tree with element tokens. Snapshots are per window and replaced by the next one, so take a fresh one every turn.
3. Act with an `element_token` or `element_index`. AX actions work on background, minimized, hidden and other-Space windows without moving the cursor or changing focus. Use `invoke_menu` for menus and `type_text` (an AX selected-text write) for text.
4. Check the postcondition with `verify_state`.

Limits, from upstream docs and `describe` output, not yet exercised on the host:

- Pixel (x, y) actions post events to the pid and need a visible on-screen window.
- Some background scroll and drag shapes are refused on macOS ([platform support][ps]).
- Chrome on macOS returns `browser_input_trust_unavailable` for trusted pointer input ([platform support][ps]).
- In web content (Chromium, WebKit, Electron), `type_text` returns `effect: "unverifiable"`: AXValue does not prove the DOM received the input.
- Canvas, WebGL and video surfaces expose no AX elements; only pixel actions reach them.
- Focus-meaning shortcuts such as ⌘L sent to a background browser pull focus, and `open` or LaunchServices activation brings the app forward.
- `delivery_mode: "foreground"` and `bring_to_front` take focus, so workers never use them (see [Worker rules](#worker-rules)). Some apps accept only foreground input; a worker reports those as not doable in the background.
- The agent cursor overlay is visible on screen even though the user's pointer does not move.

## Worker rules

- Consent: a topic request authorizes reading and operating only the apps it names. Sending, purchasing, posting, deleting, submitting forms, changing settings or credentials, and any other outward-facing action need the user's confirmation in the chat first.
- Scope: bind each step to one (pid, window_id). Use desktop-wide capture (`get_desktop_state`) only when the task needs it. Work in the run's own `session` (`yorozu-<8 random hex characters>`, fresh per run), pass it on every call that takes one, and close it with `end_session`; revive an ended one with `start_session`, and switch to `<label>-2` (then -3) if CuaDriver says the label is not available to this transport (a recycled proxy).
- Sensitive data: screenshots, AX trees and `clipboard_read` can expose passwords, messages and tokens. Keep them out of memory, results and logs; skip password fields; type no secrets.
- Approval per use: `kill_app`, `clipboard_write`, `set_config`, `replay_trajectory`, `start_recording`, `install_ffmpeg`, browser downloads and file uploads (lifted, with requested outward-facing steps, in [YOLO mode](#yolo-mode)). The owner alone runs `update --apply`, `permissions grant`, `skills install` and `stop`.
- Focus (issue #313): workers treat the Mac as unattended, whichever device the request came from. They never take focus or use foreground input: no `bring_to_front`, foreground delivery, focus-taking shortcuts or `open` without `-g`, with the user's approval or without. When an app accepts only foreground input, the worker says it cannot be done in the background and stops. It stops if the user takes over the target window.
- Verification: a successful transport call is not success; confirm with `verify_state` or a fresh snapshot. After a timeout or a call that returned no result, check the effect with a fresh snapshot before retrying: the call may still run.

### YOLO mode

`general.yolo` in `config.toml` (owner decision, 2026-10-09; off by default, offered during onboarding with #317 and switchable in Settings › General with phase B of #312). With it on, from the next task:

- Lifted: the ask-first rule for outward-facing steps the request asks for in an app (sending, posting, purchasing, deleting, submitting), and for the approval-per-use tools `kill_app`, `clipboard_write`, `set_config`, `replay_trajectory`, `start_recording`, `install_ffmpeg`, `browser_download` and `browser_set_input_files`. The worker does them when the task needs them.
- Still asked: changing settings or credentials, and any step the request did not ask for.
- Hard limits, YOLO or not: no secrets typed and no password fields; never taking focus (no `bring_to_front`, foreground delivery, focus-taking shortcuts or `open` without `-g`; YOLO never lifts it); never reading or messaging other agents' sessions. The owner-only commands above stay the owner's.
- `yolo` is a security-relevant key: a worker asks before turning it on, and a change posts "Settings changed: general.yolo".

## Concurrency

CuaDriver has no job queue and no app or window reservation; read in the 0.28.2 source (`libs/cua-driver/rust/crates` at tag `cua-driver-rs-v0.28.2`):

- **Physical input takes turns.** One process-wide lock in the daemon (`cua-driver-core/src/tool.rs`, the desktop action coordinator) admits click, double_click, right_click, scroll, drag, move_cursor, type_text, press_key, hotkey, set_value, bring_to_front and set_window_frame one call at a time, in arrival order, for every session and client on the Mac. A waiting call gets no error and no daemon timeout. The lock is released after each action, so two workers' steps interleave; the release's own docs say "Higher-level sequences can still interleave unless the host schedules them".
- **Outside the lock:** reads (`get_window_state`, `verify_state`, `list_windows`, `zoom`), `invoke_menu`, `launch_app`, `kill_app`, clipboard tools and the legacy `page` tool run in parallel with anything.
- **Same app:** a second `type_text` to a pid that already has one queued or running is refused with `input_busy`. Element tokens belong to the latest snapshot of a window, shared by all sessions, so another worker's `get_window_state` makes yours fail with `stale_element_token` rather than misclick.
- **Sessions** track lifecycle only. A label belongs to the first proxy that uses it; another proxy using it is refused ("session is not available to this transport"), and a proxy that exits ends its sessions for good. OpenClaw recycles proxies when MCP config changes. Hence the per-run label and the `-2` fallback.
- **Timeouts:** the `mcp` proxy gives up after 120 s, but the daemon still runs the call, so a blind retry can repeat an action.
- **Other agents:** every cua client on the Mac (Claude Code, Codex, other OpenClaw agents) shares the same lock, cache and focus.

Yorozu's answer is prompt-level: the per-run session label and no blind retries. Within one topic and executor the Engine already allows one active task. Across topics, two tasks can still drive the same app; a secretary rule to steer such requests into the running task was dropped, because steering cannot leave the target task's topic. A code lane of one waits until stale tokens, `input_busy` or timeouts show up in practice (owner decision, 2026-10-08).

## Smoke test

Passed on 2026-10-08 (dev build with 7f2e2f0). TextEdit had an empty document open in the background (`open -g -a TextEdit <empty file>`), and this message went into the Yorozu chat:

> Using the cua-driver MCP tools only, find TextEdit's front document window, type `yorozu cua smoke` into it with `type_text` in background mode, then confirm the text with `verify_state` from a fresh `get_window_state`. Don't bring TextEdit to the front, and report the pid, the window_id and the verify result.

Pass: the worker reports a verified match, the frontmost app never changed, and the document contains the text.

Result: the secretary delegated it with no executor; the worker reported pid and window_id (matching `list_windows`) and `verify_state` satisfied over 2 samples. An independent `verify_state` read the text area as `yorozu cua smoke`, and the frontmost app, sampled every second, stayed Yorozu for the whole run. The run took under a minute.

A second run after 67f6cce (a new empty document, the worker also asked for its cua session label) passed the same way: the worker used `yorozu-35ae7811`, an independent `verify_state` read `yorozu cua smoke 2`, and Yorozu stayed frontmost.

## Live checks

- 2026-10-08, before the MCP list existed: a throwaway `projectx` session created like a topic session (`openai-pool/gpt-6-sol`, `permissionMode: "full"`, `promptMode: "minimal"`) did not list any cua tool directly but found them with `tool_search`, and `tool_call` ran `get_screen_size` and `check_permissions {prompt: false}` through the daemon (attribution `driver-daemon`, Accessibility and Screen Recording granted, direct capture `not_checked`). No approval step ran.
- 2026-10-08, with the MCP list: the first worker session after the rebuild wrote `mcp.servers.yorozu-cua-driver` (`enabled: false`; the Gateway hot-reloaded only that path) and patched its session to `{yorozu-cua-driver: true, cua-driver: false, cua: false, computer-use: false}`. That run, an owner request, opened a website in a background Safari window. The sub-chat shows such calls only as `Tool: tool_call` and `Tool: tool_describe`, without the cua tool name.

## Unverified

- Tahoe direct-capture consent.
- Computer use from a Codex coding worker, and browser work in Chrome (`browser_input_trust_unavailable` upstream).
- Every upstream "supported" claim above, on this host.

## Sources

[cua.ai docs][docs]; [Cua Driver quickstart][qs]; [Platform support][ps]; [Cua CLI][cli]; [Cua SDK][sdk]; [trycua/cua](https://github.com/trycua/cua) and its [cua-driver README](https://github.com/trycua/cua/blob/main/libs/cua-driver/README.md). Host commands: `cua-driver --help`, `status`, `permissions status`, `config`, `list-tools`, `describe click|type_text`; the cua-driver skill's MACOS.md.

[docs]: https://cua.ai/docs
[qs]: https://cua.ai/docs/cua-driver/quickstart
[ps]: https://cua.ai/docs/cua-driver/concepts/platform-support
[cli]: https://cua.ai/docs/cua-cli
[sdk]: https://cua.ai/docs/cua-sdk

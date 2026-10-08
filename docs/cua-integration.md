# cua integration (R3)

R3 is cua (https://cua.ai) integration so Yorozu can operate the user's computer ([OWNER_DECISIONS.md](../OWNER_DECISIONS.md#workers)). Progress is in [status.md](status.md).

## Route

Workers operate the Mac through the **cua-driver MCP server**, under rules in their prompts (owner decisions, 2026-10-08):

- **CuaDriver is a separate install** (`/Applications/CuaDriver.app`). Yorozu neither bundles it nor starts its daemon: `cua-driver mcp` is a proxy that launches the daemon through LaunchServices (`open -n -g -a CuaDriver --args serve`) when the socket is not answering, so the TCC grants stay with `com.trycua.driver`. The installer registers no MCP client; its `~/.local/bin/cua-driver` link is optional.
- **Yorozu lists it as an MCP server** in its own `mcp-servers.json`, which the harness adapter mirrors into OpenClaw as `yorozu-cua-driver` ([openclaw-integration.md](openclaw-integration.md#mcp-servers)). Yorozu adds no process and no Swift dependency.
- **Routing**: "operate my Mac / use app X" goes to a thinking worker (no executor), and a coding request that needs an app stays with its coding worker. Thinking and Codex workers get the tools; Claude Code does not yet (OpenClaw gap, [status.md](status.md#open-items)).
- **Rules** live in `OpenClawHarness.cuaRules` (`Harness.swift`), included in both worker contracts. They follow [Worker rules](#worker-rules) below. There is no separate executor or lane, so two computer-use tasks can run at once.

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
- `delivery_mode: "foreground"` and `bring_to_front` take focus; treat them as a separate step the user approves. Some apps accept only foreground input.
- The agent cursor overlay is visible on screen even though the user's pointer does not move.

## Worker rules

- Consent: a topic request authorizes reading and operating only the apps it names. Sending, purchasing, posting, deleting, submitting forms, changing settings or credentials, and any other outward-facing action need the user's confirmation in the chat first.
- Scope: bind each step to one (pid, window_id). Use desktop-wide capture (`get_desktop_state`) only when the task needs it. Work in a named `session` and close it with `end_session`.
- Sensitive data: screenshots, AX trees and `clipboard_read` can expose passwords, messages and tokens. Keep them out of memory, results and logs; skip password fields; type no secrets.
- Approval per use: `kill_app`, `clipboard_write`, `set_config`, `replay_trajectory`, `start_recording`, browser downloads and file uploads. The owner alone runs `update --apply`, `permissions grant`, `skills install` and `stop`.
- The user's input: use background delivery while the user is typing, announce any focus change before it happens, and stop if the user takes over the target window.
- Verification: a successful transport call is not success; confirm with `verify_state` or a fresh snapshot.

## Smoke test

Passed on 2026-10-08 (dev build with 7f2e2f0). TextEdit had an empty document open in the background (`open -g -a TextEdit <empty file>`), and this message went into the Yorozu chat:

> Using the cua-driver MCP tools only, find TextEdit's front document window, type `yorozu cua smoke` into it with `type_text` in background mode, then confirm the text with `verify_state` from a fresh `get_window_state`. Don't bring TextEdit to the front, and report the pid, the window_id and the verify result.

Pass: the worker reports a verified match, the frontmost app never changed, and the document contains the text.

Result: the secretary delegated it with no executor; the worker reported pid and window_id (matching `list_windows`) and `verify_state` satisfied over 2 samples. An independent `verify_state` read the text area as `yorozu cua smoke`, and the frontmost app, sampled every second, stayed Yorozu for the whole run. The run took under a minute.

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

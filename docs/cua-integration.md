# cua integration (R3 design)

Design for R3, not implemented: nothing on `projectx` calls cua yet. R3 is cua (https://cua.ai) integration so Yorozu can operate the user's computer ([OWNER_DECISIONS.md](../OWNER_DECISIONS.md#roadmap)). The route below is a recommendation; choosing it is an open item in [status.md](status.md#open-items).

## Recommendation

Topic workers operate the Mac through the **cua-driver MCP server**, which OpenClaw already registers. Yorozu adds no process and no Swift dependency for the first step. The `cua` CLI and the cua SDK manage sandboxes, Spaces and VMs; use them for isolated computers, not for driving the host desktop.

## Host check (2026-10-08, read-only)

| Item | Finding |
|---|---|
| Binary | `~/.local/bin/cua-driver` 0.28.2, a link to `/Applications/CuaDriver.app/Contents/MacOS/cua-driver` |
| Daemon | Running as `cua-driver serve` from CuaDriver.app; socket `~/Library/Caches/cua-driver/cua-driver.sock` |
| Policy | Permission mode `standard` (built-in default); no user policy, managed policy or capability manifest |
| TCC | Accessibility and Screen Recording granted to the daemon. Tahoe direct-capture consent not checked (the status command is read-only) |
| Config | `agent_cursor.enabled: true`, `max_image_dimension: 1568`, `experimental_pip: false` |
| Tools | 56 MCP tools (`cua-driver list-tools`); the ones workers need are under [Targeting one window](#targeting-one-window) |
| OpenClaw | MCP servers `cua-driver` (`cua-driver mcp`, working), `cua` (points at a missing `~/Applications/Cua Spaces.app`, broken) and `computer-use` (another vendor's client, not used here) |
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

Not yet run. The owner opens TextEdit with a new empty document and keeps another app in front, then sends a topic worker:

> Using the cua-driver MCP tools only, find TextEdit's front document window, type `yorozu cua smoke` into it with `type_text` in background mode, then confirm the text with `verify_state` from a fresh `get_window_state`. Don't bring TextEdit to the front, and report the pid, the window_id and the verify result.

Pass: the worker reports a verified match, the frontmost app never changed, and the document contains the text.

## Unverified

- Whether `projectx` worker sessions can see the cua-driver tools (the agent inherits the full tool profile; MCP exposure to its sessions was not checked).
- Tahoe direct-capture consent.
- Every upstream "supported" claim above, on this host.

## Sources

[cua.ai docs][docs]; [Cua Driver quickstart][qs]; [Platform support][ps]; [Cua CLI][cli]; [Cua SDK][sdk]; [trycua/cua](https://github.com/trycua/cua) and its [cua-driver README](https://github.com/trycua/cua/blob/main/libs/cua-driver/README.md). Host commands: `cua-driver --help`, `status`, `permissions status`, `config`, `list-tools`, `describe click|type_text`; the cua-driver skill's MACOS.md.

[docs]: https://cua.ai/docs
[qs]: https://cua.ai/docs/cua-driver/quickstart
[ps]: https://cua.ai/docs/cua-driver/concepts/platform-support
[cli]: https://cua.ai/docs/cua-cli
[sdk]: https://cua.ai/docs/cua-sdk

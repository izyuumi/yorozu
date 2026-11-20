# 0027. Windows app shell, web view lock-down and smoke run

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

The Windows app's UI is a web view. It may only call declared commands and only navigate within the app, and CI needs proof that a built installer actually starts.

## Decision

- Commands: every command the web view may invoke is declared in four places: `commands.rs`, `lib.rs` (`invoke_handler`), `build.rs` (`AppManifest`) and `capabilities/default.json`, which grants it. Declaring the commands in `build.rs` makes each one need an `allow-<command>` permission (spec section 9). Every command but `snapshot` goes to the core's driver. `build.rs` declares twelve; these seven are among them:
  - `snapshot`: returns the state to render; in smoke mode it also ends the run.
  - `submit_link`: hands the pasted pairing link to the core, which asks to confirm.
  - `confirm_pairing`: creates this PC's keys, saves the pairing and starts connecting.
  - `cancel_pairing`: leaves the confirm screen, or stops and wipes a pairing under way.
  - `forget_pairing`: stops the connection and wipes the pairing from this PC.
  - `pair_again`: wipes a removed or unreadable pairing and goes back to the pairing screen.
  - `retry_connection`: redials after "Update required".
- Navigation: the web view may only navigate within the app's own origin (spec section 9). Windows serves it from `tauri.localhost`; macOS and Linux use the `tauri` scheme.
- UI shell: the chat owns its scrolling; shell notices and connection status remain visible.
- Smoke run (`--smoke <file>`): CI's proof that the built app starts and its web view reaches the core. The run writes `ready <version>` to the file on the web view's first `snapshot` call and exits 0; it exits 1 at once if it can't write the file, or after 60 seconds.
  - Parsed before anything else starts a thread, because it sets an environment variable.
  - It sets `WEBVIEW2_USER_DATA_FOLDER`: WebView2 reads this variable in preference to the folder Tauri passes, so the profile goes to a temporary folder, not the real app data folder.
  - The single-instance plugin is not used under `--smoke`: the smoke run must not hand off to, or be blocked by, an installed instance already running.

## Consequences

- Adding a command means editing all four places.

## Where in the code

- `apps/windows/app/src-tauri/src/commands.rs`
- `apps/windows/app/src-tauri/src/lib.rs` — `allowed_navigation`, `run()`
- `apps/windows/app/src-tauri/build.rs` — `AppManifest`
- `apps/windows/app/src-tauri/src/smoke.rs` — `Smoke`, `from_args`
- `apps/windows/app/src/components/chat.css` — `main:has(.chat)`

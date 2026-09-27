# Background-only Mac lifecycle evidence

Tested on macOS with a debug app built from this branch under a distinct bundle ID. It used an isolated `YOROZU_STATE_DIR`, `YOROZU_EPHEMERAL_RUN=1`, and a fresh `YOROZU_TEST_KEYCHAIN_SERVICE`. These last two settings enable a debug-only Keychain override; normal builds keep their existing service. The installed `/Applications/Yorozu.app` and its watchdog stayed running at their original paths.

After building `packages/runtime/dist/serve.js` in the worktree, the app found and started that dev runtime without `YOROZU_RUNTIME_CMD`. Before the path fix, it logged that no dev checkout was available even with the runtime present.

| Interaction | Observed result |
| --- | --- |
| Launch with `-yorozuWatchdogLaunch` | Host process stayed running with no window. Activation policy was `.accessory` (raw value 1). |
| Open Quick Chat from menu bar | One 560 × 660 Quick Chat window appeared. Activation policy stayed `.accessory`. Reopening focused the same window. |
| Open Settings | One 600 × 700 Settings window appeared without changing `.accessory` activation. |
| Use **Close Yorozu Windows** (⌘Q menu command) | Window closed; host process stayed running. |
| Close Quick Chat while the dev runtime was connected | Host and sidecar processes both stayed running; the local socket remained available. |
| Create New Chat, type an unsent draft, close/reopen Quick Chat | Same New Chat and draft returned. |
| Select **Quit Yorozu…** in menu bar | No keyboard equivalent; process exited. Before the delegate routing fix, the same menu action left the process running. |
| Relaunch silently, then open Quick Chat | No window on automatic launch; same New Chat and unsent draft returned when explicitly opened. |

The test bundle ran the local dev runtime rather than a packaged runtime. It verified process continuity without an active task; active-task quit confirmation, notification routing, updater relaunch, and paired-device behavior remain untested. It also did not exercise multiple Spaces/displays or replace the installed app.

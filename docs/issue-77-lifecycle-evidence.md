# Background-only Mac lifecycle evidence

Tested on macOS with a debug app built from this branch under a distinct bundle ID. It used an isolated `YOROZU_STATE_DIR`, `YOROZU_EPHEMERAL_RUN=1`, and a fresh `YOROZU_TEST_KEYCHAIN_SERVICE`. These last two settings enable a debug-only Keychain override; normal builds keep their existing service. The installed `/Applications/Yorozu.app` and its watchdog stayed running at their original paths.

| Interaction | Observed result |
| --- | --- |
| Launch with `-yorozuWatchdogLaunch` | Host process stayed running with no window. Activation policy was `.accessory` (raw value 1). |
| Open Quick Chat from menu bar | One 560 × 660 Quick Chat window appeared. Activation policy stayed `.accessory`. Reopening focused the same window. |
| Open Settings | One 600 × 700 Settings window appeared without changing `.accessory` activation. |
| Use **Close Yorozu Windows** (⌘Q menu command) | Window closed; host process stayed running. |
| Create New Chat, type an unsent draft, close/reopen Quick Chat | Same New Chat and draft returned. |
| Select **Quit Yorozu…** in menu bar | No keyboard equivalent; process exited. Before the delegate routing fix, the same menu action left the process running. |
| Relaunch silently, then open Quick Chat | No window on automatic launch; same New Chat and unsent draft returned when explicitly opened. |

The test bundle had no packaged runtime, so it could not verify task continuity, active-task quit confirmation, notification routing, updater relaunch, or paired-device behavior. It also did not exercise multiple Spaces/displays or replace the installed app.

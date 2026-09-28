# Queued updates and draining

Automatic updates download and queue when automatic updates are enabled. Manual
install requests use the same gate. Only Yorozu-managed agents on the Mac being
updated count; work on other hosts and unrelated Terminal agents does not.

Running and queued native turns, approval/input waits, recovery and pending retries
block the initial idle installation. Final failures and completed cancellations do
not. Unknown runtime status is never idle. Open chat windows do not block updates.
OpenClaw messages do not hold the update gate: they have no Yorozu turn, and one OpenClaw has
not yet taken waits in the channel outbox across the restart.
Builds with interactive remote terminals block update installation until every session
is closed. The updated host removes the old terminal opt-in on first launch and does not
restore terminal sessions. Force quitting an older host still ends its live sessions.

After all work finishes, the Mac must remain idle for 10 continuous seconds.
New submissions take priority and reset the countdown, including work arriving
from a phone. At the cutoff, the runtime closes admission before authorizing the
updater. Task submissions arriving afterward receive no acceptance receipt and remain in
the sending device's encrypted outbox. Reconnection resends their original IDs;
runtime deduplication prevents duplicate execution.

SIGTERM runs the sidecar's normal close path so the SDK can stop its child CLI and
detached Bash tools. A SIGKILL cannot run cleanup: the runtime journals each Claude
CLI's PID and process start time, terminates a matching orphan at next startup,
and refuses recovery if it cannot verify that the old process stopped.

The runtime records when each update was first queued in `update-pending-since.json`.
After 24 hours of pending work, it drains: new submissions stay in client outboxes,
queued native turns stay in the durable native turn queue, and native tool calls
already in flight can finish. Claude Code's `PreToolUse` hook holds new calls;
Codex interrupts at a completed item when no other calls are open. A turn waiting
for approval or a question is interrupted immediately. Interrupted turns resume
through the existing recovery path after restart. If work never reaches a safe
point, the Mac proceeds after five minutes. A user can choose **Install now** to
start draining immediately, or **Postpone 1 hour** to cancel a drain; postponement
is unlimited and resumes interrupted turns. Client-only Macs install immediately
when asked. Background shell processes without a live tool call cannot be held by
the hook; their effects must be treated as potentially still running on recovery.
Read requests and synchronous non-task controls remain available while installation is pending;
approval grants are never added to a durable queue for automatic reauthorization.

The Mac and connected phones show the host's queued, countdown, postponed, draining
and installing states. Either can postpone one hour or request installation now.
This postponement survives a
runtime restart. A missed updater heartbeat resets the countdown, including after
sleep. Loss of the local updater connection cancels an unclaimed countdown.
Once installation is authorized, admission stays closed even if that connection
drops, until the runtime restarts or the updater explicitly cancels installation.

Before an update-triggered restart, the Mac saves composer text, attachments, pending messages,
draft threads and selected thread. A failed snapshot prevents the restart. The
chat window reopens if it was open before the update. Snapshot failures release
the admission gate and retry after a fresh idle countdown. Sending devices retain
pending messages until the runtime acknowledges them, including across app
restarts; queue size alone never discards unsent messages.

## Runtime protocol

`update_control` has `status`, `postpone`, `install_now`, `queue`, `poll` and `cancel` actions.
Only the local socket connection that queued an update may poll or cancel it.
After a disconnect, a local replacement may cancel the same update ID; cancellation
is retried until acknowledged before queuing another update. Asynchronous archive
commands also wait in the existing outbox during installation.
Relay devices may request status, postpone, or start a drain, but cannot authorize
installation. Only the local updater's poll returns the installing authorization.
`queue` is idempotent and also polls, so the updater can recover after a runtime
restart. Update control/status traffic is not persisted in thread history.

`update_status` reports a phase, update ID/version, active thread count, countdown
deadline or postponement deadline. Direct replies echo the command ID as
`requestId`; a broadcast is never enough to authorize installation. The runtime
counts queued native turns as well as running native turns before draining. During
draining, queued turns are held for restart and do not delay installation.
Clients lacking `update-drain-v1` receive the compatible `waiting` phase instead;
they still retain pending submissions and reconnect after the Mac restarts.

The host uses Sparkle's retained installation callbacks for both automatic and
manual updates. Client-only Macs run their own countdown without waiting on the
remote host's agents.
Sparkle holds the selected downloaded update while the gate waits; a newer build
is not discovered during that cycle. The automatic wait is bounded to 24 hours
plus five minutes of draining. User postponements can extend it indefinitely by
choice. This version does not implement automatic rollback if a newly installed
app cannot start; restoring a prior signed build remains a manual recovery.

[Sparkle also completes prepared updates when the application exits independently](https://sparkle-project.org/documentation/api-reference/Protocols/SPUUpdaterDelegate.html)
(a force quit or crash). Its public API does not let this live-app
gate veto installation after process exit. Postponement controls update-triggered
restarts; it cannot guarantee that an already-staged update remains uninstalled
after an independent exit. Drafts are also saved while composing; unsent outbox
items are saved synchronously.
Ordinary Quit and repeated Sparkle install attempts are refused while an update
is queued, with an explanation, so neither bypasses the live gate. A final
synchronous snapshot at termination preserves edits made after installation was
authorized; if saving fails, installation waits and retries.

## Validation

- Gate tests cover priority, continuous idleness, unknown status, heartbeat gaps
  and persisted postponement, 24-hour escalation and manual installation.
- Runtime integration tests cover approval waits, FIFO turns, final failures,
  new work during countdown, control ownership, remote postponement, installation
  admission, replay deduplication, native turn recovery after a drain, and
  orphan cleanup before recovery.
- Swift tests cover event round trips, encrypted restart snapshots, attachments,
  selection, offline submissions and snapshot write failure.

Isolated runtime probes with SDK 0.3.278 / bundled Claude Code 2.1.278 confirmed:
the unmatched `PreToolUse` hook fires inside a subagent; SIGTERM stops the CLI
and a running Bash `sleep`; SIGKILL leaves both alive until startup's PID-verified
cleanup. After an interrupted Bash call, native recovery made a new tool call and
completed. The recovery prompt tells the agent to verify prior effects before
repeating them; a hard-deadline kill can still leave an uncertain external effect.
A shell command explicitly launched in the background survived a completed turn,
so it cannot be counted as an open tool call.

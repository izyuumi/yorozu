# Updates after local agents finish

Automatic updates download and queue when automatic updates are enabled. Manual
install requests use the same gate. Only Yorozu-managed agents on the Mac being
updated count; work on other hosts and unrelated Terminal agents does not.

Running and queued turns, approval/input waits, recovery and pending retries block
installation indefinitely. Final failures and completed cancellations do not.
Unknown runtime status is never idle. Open chat windows do not block updates.
Each open host terminal session blocks both automatic and manual update installs,
even when no command is visibly running. Closing the session releases the gate.

After all work finishes, the Mac must remain idle for 10 continuous seconds.
New submissions take priority and reset the countdown, including work arriving
from a phone. At the cutoff, the runtime closes admission before authorizing the
updater. Task submissions arriving afterward receive no acceptance receipt and remain in
the sending device's encrypted outbox. Reconnection resends their original IDs;
runtime deduplication prevents duplicate execution.
Read requests and synchronous non-task controls remain available while installation is pending;
approval grants are never added to a durable queue for automatic reauthorization.

The Mac and connected phones show the host's queued, countdown, postponed and
installing states. Either can postpone one hour. This postponement survives a
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

`update_control` has `status`, `postpone`, `queue`, `poll` and `cancel` actions.
Only the local socket connection that queued an update may poll or cancel it.
After a disconnect, a local replacement may cancel the same update ID; cancellation
is retried until acknowledged before queuing another update. Asynchronous archive
commands also wait in the existing outbox during installation.
Relay devices may request status or postpone, but cannot authorize installation.
`queue` is idempotent and also polls, so the updater can recover after a runtime
restart. Update control/status traffic is not persisted in thread history.

`update_status` reports a phase, update ID/version, active thread count, countdown
deadline or postponement deadline. Direct replies echo the command ID as
`requestId`; a broadcast is never enough to authorize installation. The runtime
counts queued turns as well as running turns and the OpenClaw recovery ledger.

The host uses Sparkle's retained installation callbacks for both automatic and
manual updates. Client-only Macs run their own countdown without waiting on the
remote host's agents.

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
  and persisted postponement.
- Runtime integration tests cover approval waits, FIFO turns, final failures,
  new work during countdown, control ownership, remote postponement, installation
  admission and replay deduplication.
- Swift tests cover event round trips, encrypted restart snapshots, attachments,
  selection, offline submissions and snapshot write failure.

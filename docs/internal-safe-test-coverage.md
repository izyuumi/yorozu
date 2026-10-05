# Internal safe test coverage

This is a bounded admission gate, not ordinary macOS/Rust/UI aggregate coverage.
Every test below was inspected as an individual case before selection. Receipts
bind exact staged source SHA, file, function names and positive executed counts;
a missing test, skip, zero-match, duplicate or unexpected execution fails closed.
The helper first compiles/lists every selected package/file, validates the entire
selection, then executes exact module/function filters. Merely compiling excluded
tests as part of SwiftPM or a Rust test binary does not execute them.

## Swift

The original four complete safe fixture files remain mandatory: Outbox 42,
HarnessPlatform 3, PersonAgents 2, PersonAgentEditing 8 (55 baseline). Those are
minimums, not frozen totals: added zero-argument tests in these safe files are
required automatically. A reduced baseline fails closed. Swift worker additions
to Outbox therefore need no hardcoded-count update.

Additional complete safe source files: PeerInfoTests (10), SiwcAccountsTests (4),
and apps/mac YorozuAccountsCoreTests/AccountsCoreTests (10). PeerInfo uses ephemeral
identities/counters and direct in-memory frame injection (no live relay connect).
SIWC uses a fake settings transport. Account-helper tests use MemoryBackend,
FakeLocks and FakeBrowser, never real Keychain, OS account locks, browser UI,
provider or account activation. These full safe files also discover additions.

ChatModelTests is mixed and MUST NOT be run as a whole. Only these reviewed
zero-argument functions using FakeTransport and task-owned cache directories run:

- `harnessTaskControlsUseCapabilitiesAndPreserveUnsupportedDrafts`
- `personAgentsRequireDeclaredCapabilityAndHostControlResults`
- `personAgentSelectionAlwaysOpensCanonicalConversationWithoutCreatingAnother`
- `personAgentSettingsSubmissionBlocksDuplicateAndStaleSaves`
- `canonicalAgentDescriptorsRemainNavigableOfflineAfterRelaunch`
- `harnessActionResponseEchoesExactOriginAndDoesNotBecomeUserText`
- `agentExchangePayloadStaysInSeparateInspectionStream`

These cover capability-bound task controls, refusal of remember/share-knowledge,
canonical conversations, exact settings receipts, offline descriptors/outbox,
action-origin/receipt binding and isolated exchange rendering. Other ChatModel
functions—including task recovery during installation, wire-emission FIFO,
open-card queued-send ordering, legacy stop/recovery and UI/timing aggregates—are
not selected. WireTests, Showcase/UI, Keepalive/Watchdog and aggregate app tests
are never executed. apps/mac builds its test bundle but executes ONLY
YorozuAccountsCoreTests functions. No live-account success is inferred.

At base 1f58164, selection is 86 Swift tests (55 original + 31 additions).
This total is informational: receipts derive actual current-source counts.

## Host core

The existing eight alpha/secretary tests remain, now each with exact positive
execution verification. Four additional source files are mixed, so only reviewed
individual functions run. Fresh temp JSON/state operations exercise identity,
owner exclusion, bounded snapshots, invalid-data refusal and private files.
The journal implementation is exercised by stops/steering identity/locking tests,
not by enabling interrupted-tail or historical-repair suites.

### `packages/host-core/tests/alpha.rs`

- `acceptance_retry_stop_and_restart_never_reissue_an_uncertain_task`
- `nonempty_unmarked_directory_is_preserved_and_refused`
- `queued_terminal_is_not_lost_when_worker_exits_while_requests_are_waiting`
- `snapshot_budget_refuses_a_new_task_before_the_native_pipe_limit`
### `packages/host-core/tests/secretary.rs`

- `persistent_runs_share_one_locked_workspace_without_a_global_task_limit`
- `explicit_mode_refuses_existing_data_and_symlinked_workspaces`
- `invalid_payloads_and_conflicting_admissions_never_start_a_run`
- `steering_is_immutable_durable_and_never_reissued_after_reopen`
### `packages/host-core/tests/outbox.rs`

- `duplicate_identity_is_bound_and_conflicts_do_not_overwrite`
- `malformed_and_conflicting_legacy_data_remain_untouched`
- `repeated_ack_is_idempotent_and_metadata_snapshot_excludes_attachment_bytes`
### `packages/host-core/tests/steering.rs`

- `definite_rejection_allows_only_a_fresh_explicit_attempt_and_never_reuses_attempt_identity`
- `original_thread_identity_and_terminal_outcome_cannot_be_changed`
- `bounded_snapshot_pages_and_invalid_intents_cannot_start_effects`
- `linked_journals_are_refused_and_new_steering_files_are_private_without_changing_root_permissions`
### `packages/host-core/tests/stops.rs`

- `ownership_conflicts_and_terminal_downgrades_cannot_replace_committed_proof`
- `malformed_or_conflicting_legacy_owners_are_retained_and_second_writer_is_excluded`
- `replaced_journal_fails_closed_without_touching_the_new_path`
### `packages/host-core/tests/native_queue.rs`

- `retries_are_idempotent_and_owner_or_readiness_conflicts_do_not_poison_valid_queue`
- `concurrent_owners_are_excluded_and_external_mutation_fences_without_overwrite`
- `malformed_duplicate_or_oversized_legacy_data_is_not_rewritten`
- `symlinks_are_refused_and_only_new_private_files_receive_private_permissions`

Total: 22 exact Rust cases. The other tests in outbox/steering/stops/native_queue
are deliberately excluded: actual worker termination, interrupted writes/tail
repair, historical projection cleanup/recovery, withdrawal journal replay and
ambiguous temporary-file recovery. No `cargo test --tests`, `--lib`, recovery,
interposer, FIFO or whole-file mixed-suite invocation is permitted by this gate.
Existing alpha/secretary isolated IPC/state cases remain separately authorized;
that does not authorize the unrelated paused legacy recovery suites.

## Execution and evidence

Run the committed tree through `scripts/check-internal-alpha.sh`. It stages
verified Git blobs with the production baseline, retains the Darwin short
`/tmp/yri.*` fixture root and executes under the CI Node 26 toolchain. It also
keeps the existing bounded TypeScript/adapter/packaging tests and Mac compilation.
`internal-host.json` / `internal-swift.json` are written only on whole-gate
success; old receipts are removed first. CI uploads JSON receipts under always(),
not binaries or secrets. Missing/partial receipts never mean the whole lane passed.
Final hosted CI and native acceptance are independent requirements.

### Native outage recovery regressions

The internal Swift gate additionally selects exactly the three new LocalTransportTests functions `localRuntimeColdOfflineStartReconnectsWhenSocketAppears`, `localRuntimeReconnectsAfterRetryAlreadyFoundSocketMissing`, and `closingLocalTransportCancelsMissingSocketRetry`. These use isolated synthetic Unix sockets and require actual received client bytes (plus a model reply for cold startup), not socket-existence or paired-state assertions alone. The mixed-file aggregate is not enabled.

#!/usr/bin/env python3
"""Run only reviewed host-core cases; never recovery/interposer/FIFO aggregates.

Selectors are exact individual functions, not file-wide cargo test invocations.
The additional cases operate on fresh temporary directories and inert JSON/state;
worker-kill, interrupted-write repair, queue replay and recovery cases are excluded.
Stops/steering exercise journal identity/locking without interrupted-tail recovery.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess

CASES = {
    "alpha": (
        "acceptance_retry_stop_and_restart_never_reissue_an_uncertain_task",
        "nonempty_unmarked_directory_is_preserved_and_refused",
        "queued_terminal_is_not_lost_when_worker_exits_while_requests_are_waiting",
        "snapshot_budget_refuses_a_new_task_before_the_native_pipe_limit",
    ),
    "secretary": (
        "persistent_runs_share_one_locked_workspace_without_a_global_task_limit",
        "explicit_mode_refuses_existing_data_and_symlinked_workspaces",
        "invalid_payloads_and_conflicting_admissions_never_start_a_run",
        "steering_is_immutable_durable_and_never_reissued_after_reopen",
    ),
    "outbox": (
        "duplicate_identity_is_bound_and_conflicts_do_not_overwrite",
        "malformed_and_conflicting_legacy_data_remain_untouched",
        "repeated_ack_is_idempotent_and_metadata_snapshot_excludes_attachment_bytes",
    ),
    "steering": (
        "definite_rejection_allows_only_a_fresh_explicit_attempt_and_never_reuses_attempt_identity",
        "original_thread_identity_and_terminal_outcome_cannot_be_changed",
        "bounded_snapshot_pages_and_invalid_intents_cannot_start_effects",
        "linked_journals_are_refused_and_new_steering_files_are_private_without_changing_root_permissions",
    ),
    "stops": (
        "ownership_conflicts_and_terminal_downgrades_cannot_replace_committed_proof",
        "malformed_or_conflicting_legacy_owners_are_retained_and_second_writer_is_excluded",
        "replaced_journal_fails_closed_without_touching_the_new_path",
    ),
    "native_queue": (
        "retries_are_idempotent_and_owner_or_readiness_conflicts_do_not_poison_valid_queue",
        "concurrent_owners_are_excluded_and_external_mutation_fences_without_overwrite",
        "malformed_duplicate_or_oversized_legacy_data_is_not_rewritten",
        "symlinks_are_refused_and_only_new_private_files_receive_private_permissions",
    ),
}


class CheckFailed(RuntimeError):
    pass


def verify_run(name, output):
    passed = re.findall(r"^test (\w+) \.\.\. ok$", output, re.M)
    summaries = re.findall(r"^test result: ok\. (\d+) passed; (\d+) failed; (\d+) ignored; (\d+) measured; \d+ filtered out;.*$", output, re.M)
    if passed != [name] or summaries != [("1", "0", "0", "0")]:
        raise CheckFailed(f"{name}: missing exact positive execution receipt")


def run_checks(root, runner):
    bases = {}
    # Validate all source and fresh compiled listings before executing any test.
    for suite, names in CASES.items():
        path = root / "packages/host-core/tests" / (suite + ".rs")
        declared = Counter(re.findall(r"#\[test\]\s*fn\s+(\w+)\s*\(", path.read_text()))
        if not names or len(set(names)) != len(names) or any(declared[name] != 1 for name in names):
            raise CheckFailed(f"{suite}: selected source test missing or duplicated")
        base = ["cargo", "test", "--locked", "--manifest-path", str(root / "packages/host-core/Cargo.toml"), "--test", suite]
        result = runner(base + ["--", "--list"])
        listed = Counter(re.findall(r"^(\w+): test$", result.stdout, re.M))
        if result.returncode or any(listed[name] != 1 for name in names):
            raise CheckFailed(f"{suite}: selected compiled test missing or build/list failed")
        bases[suite] = base
    groups = []
    for suite, names in CASES.items():
        for name in names:
            result = runner(bases[suite] + ["--", "--exact", name, "--test-threads=1"])
            if result.returncode:
                raise CheckFailed(f"{suite}/{name}: test process failed")
            verify_run(name, result.stdout)
        groups.append({"source": f"packages/host-core/tests/{suite}.rs", "tests": list(names),
                       "executed": len(names), "passed": len(names), "skipped": 0})
    return {"schemaVersion": 1, "groups": groups, "executed": sum(g["executed"] for g in groups), "skipped": 0}


def command(args):
    print("+ " + " ".join(args), flush=True)
    result = subprocess.run(args, text=True, capture_output=True, check=False, timeout=600)
    print(result.stdout, end="", flush=True)
    print(result.stderr, end="", flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    args.receipt.unlink(missing_ok=True)
    root = Path(__file__).resolve().parent.parent
    result = run_checks(root, command)
    result["sourceSha"] = json.loads((root / "internal-source.json").read_text())["sourceSha"]
    args.receipt.write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()

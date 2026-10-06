#!/usr/bin/env python3
"""Run source-file-scoped safe Swift fixtures with exact, non-vacuous receipts.

All four original fixture files remain mandatory (minimum 55 baseline tests).
Additional pure PeerInfo/SIWC/account-helper files and reviewed ChatModel functions
are explicit selections; never select the mixed ChatModel or UI aggregate.
New functions in complete safe files are discovered, while mixed files require
an explicit selection update. No production Keychain/browser/helper is invoked.
"""
from __future__ import annotations

import argparse
from collections import Counter
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Callable

FIXTURES = ("OutboxTests", "HarnessPlatformTests", "PersonAgentsTests", "PersonAgentEditingTests")
MODULE = "YorozuSharedTests"
# package, module, minimum count, optional exact functions in a mixed source file.
GROUPS = {
    "OutboxTests": ("packages/shared-swift", MODULE, 42, None),
    "HarnessPlatformTests": ("packages/shared-swift", MODULE, 3, None),
    "PersonAgentsTests": ("packages/shared-swift", MODULE, 2, None),
    "PersonAgentEditingTests": ("packages/shared-swift", MODULE, 8, None),
    "PeerInfoTests": ("packages/shared-swift", MODULE, 10, None),
    "SiwcAccountsTests": ("packages/shared-swift", MODULE, 4, None),
    "ChatModelTests": ("packages/shared-swift", MODULE, 7, (
        "harnessTaskControlsUseCapabilitiesAndPreserveUnsupportedDrafts",
        "personAgentsRequireDeclaredCapabilityAndHostControlResults",
        "personAgentSelectionAlwaysOpensCanonicalConversationWithoutCreatingAnother",
        "personAgentSettingsSubmissionBlocksDuplicateAndStaleSaves",
        "canonicalAgentDescriptorsRemainNavigableOfflineAfterRelaunch",
        "harnessActionResponseEchoesExactOriginAndDoesNotBecomeUserText",
        "agentExchangePayloadStaysInSeparateInspectionStream",
    )),
    "LocalTransportTests": ("packages/shared-swift", MODULE, 3, (
        "localRuntimeColdOfflineStartReconnectsWhenSocketAppears",
        "localRuntimeReconnectsAfterRetryAlreadyFoundSocketMissing",
        "closingLocalTransportCancelsMissingSocketRetry",
    )),
    "AccountsCoreTests": ("apps/mac", "YorozuAccountsCoreTests", 10, None),
    "HostWindowModeTests": ("apps/mac", "YorozuKeepaliveTests", 4, None),
    # Reviewed offscreen native field fixture; no app activation or external transport.
    "ComposerEditingTests": ("packages/shared-swift", MODULE, 1, ("composerNewlineUsesNativeSelection",)),
}
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
Runner = Callable[[list[str]], subprocess.CompletedProcess[str]]


class CheckFailed(RuntimeError):
    pass


def source_names(source: str, fixture: str, selected=None) -> list[str]:
    # Deliberately supports only the current zero-argument, top-level fixtures.
    # A move into @Suite or parameterized/trait tests needs explicit adapter review.
    if re.search(r"^\s*@Suite\b", source, re.M):
        raise CheckFailed(f"{fixture}: @Suite migration requires an explicit selector update")
    annotations = re.findall(r"^\s*(?:@MainActor\s+)?@Test\b", source, re.M)
    names = re.findall(
        r"^\s*(?:@MainActor\s+)?@Test\s+(?:@MainActor\s+)?func\s+([A-Za-z_]\w*)\s*\(\s*\)",
        source, re.M,
    )
    if selected is not None:
        if not selected or len(set(selected)) != len(selected) or any(names.count(name) != 1 for name in selected):
            raise CheckFailed(f"{fixture}: missing, duplicate, or unsupported selected @Test declarations")
        return list(selected)
    if not names or len(names) != len(annotations) or len(set(names)) != len(names):
        raise CheckFailed(f"{fixture}: missing, duplicate, or unsupported @Test declarations")
    return names


def resolve_groups(root: Path, listings: dict[str, str]) -> dict[str, list[str]]:
    groups: dict[str, list[str]] = {}
    owned: set[str] = set()
    for fixture, (package, module, minimum, selected) in GROUPS.items():
        listed = Counter(ANSI.sub("", listings[package]).splitlines())
        path = root / package / "Tests" / module / f"{fixture}.swift"
        try:
            names = source_names(path.read_text(), fixture, selected)
        except OSError as error:
            raise CheckFailed(f"{fixture}: source unavailable: {error}") from error
        if len(names) < minimum:
            raise CheckFailed(f"{fixture}: mandatory baseline shrank below {minimum} tests")
        for name in names:
            identifier = f"{module}.{name}()"
            if listed[identifier] != 1 or identifier in owned:
                raise CheckFailed(f"{fixture}: expected exactly one listed test: {identifier}")
            owned.add(identifier)
        groups[fixture] = names
    return groups


def selector(names: list[str], module: str = MODULE) -> str:
    # Swift Testing appends source-location identity beyond the displayed ().
    # Anchor the module and complete function-name boundary, not the display suffix.
    return "^(?:" + "|".join(re.escape(f"{module}.{name}(") for name in names) + ")"


def verify_run(fixture: str, names: list[str], output: str) -> dict:
    output = ANSI.sub("", output)
    passed = re.findall(r"^✔ Test ([A-Za-z_]\w*)\(\) passed after .+$", output, re.M)
    started = re.findall(r"^◇ Test ([A-Za-z_]\w*)\(\) started\.$", output, re.M)
    totals = re.findall(
        r"^✔ Test run with (\d+) tests?(?: in \d+ suites?)? passed after .+$", output, re.M
    )
    if ("skipped" in output.lower() or "no matching test" in output.lower()
            or "recorded an issue" in output.lower()
            or Counter(passed) != Counter(names) or Counter(started) != Counter(names)
            or totals != [str(len(names))] or not names):
        raise CheckFailed(f"{fixture}: incomplete/non-positive execution receipt; expected {len(names)} passes")
    return {"fixture": fixture, "listed": len(names), "executed": len(passed),
            "passed": len(passed), "skipped": 0, "tests": names}


def run_checks(root: Path, scratch: Path, runner: Runner) -> dict:
    bases = {package: ["swift", "test", "--package-path", str(root / package),
                       "--scratch-path", str(scratch / package.replace("/", "-"))]
             for package, _, _, _ in GROUPS.values()}
    listings = {}
    for package, base in bases.items():
        listing = runner(base + ["list"])
        if listing.returncode:
            raise CheckFailed(f"{package}: SwiftPM build/list failed")
        listings[package] = listing.stdout
    groups = resolve_groups(root, listings)
    receipts = []
    # Validate ALL source selections before executing ANY; compile/list is not execution.
    for fixture, names in groups.items():
        package, module, _, _ = GROUPS[fixture]
        result = runner(bases[package] + ["--skip-build", "--no-parallel", "--filter", selector(names, module)])
        if result.returncode:
            raise CheckFailed(f"{fixture}: SwiftPM exited {result.returncode}")
        receipt = verify_run(fixture, names, result.stdout + "\n" + result.stderr)
        receipt.update(package=package, module=module, source=f"{package}/Tests/{module}/{fixture}.swift")
        receipts.append(receipt)
    return {"schemaVersion": 1, "groups": receipts,
            "executed": sum(group["executed"] for group in receipts), "skipped": 0}


def command(args: list[str]) -> subprocess.CompletedProcess[str]:
    print("+ " + " ".join(args), flush=True)
    result = subprocess.run(args, text=True, capture_output=True, check=False)
    print(result.stdout, end="", flush=True)
    print(result.stderr, end="", file=sys.stderr, flush=True)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--scratch-path", type=Path)
    parser.add_argument("--receipt", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    # Never leave an earlier green receipt behind when the current invocation fails.
    if args.receipt:
        args.receipt.unlink(missing_ok=True)
    try:
        if args.scratch_path:
            receipt = run_checks(root, args.scratch_path.resolve(), command)
        else:
            with tempfile.TemporaryDirectory(prefix="yorozu-internal-swift-") as scratch:
                receipt = run_checks(root, Path(scratch), command)
        receipt["sourceSha"] = json.loads((root / "internal-source.json").read_text())["sourceSha"]
        encoded = json.dumps(receipt, indent=2) + "\n"
        if args.receipt:
            args.receipt.write_text(encoded)
        print(encoded, end="")
        return 0
    except (CheckFailed, OSError) as error:
        print(f"Internal Swift gate REFUSED: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())

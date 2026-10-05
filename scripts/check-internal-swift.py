#!/usr/bin/env python3
"""Run only the four internal Swift fixture files, with non-vacuous receipts.

Swift Testing top-level functions are listed as Module.function(), NOT FileTests.
Resolve every source @Test against a fresh SwiftPM listing, then run each file's
functions separately. Require every expected test to pass (no skips), an exact
positive run count, and no extra executed tests. Unsupported source/output syntax
fails closed instead of widening the filter. No UI/wire aggregate is selected.

Usage: python3 scripts/check-internal-swift.py --scratch-path /tmp/unique-swift-build
Optional --receipt writes a JSON receipt only after all four groups pass.
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
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
Runner = Callable[[list[str]], subprocess.CompletedProcess[str]]


class CheckFailed(RuntimeError):
    pass


def source_names(source: str, fixture: str) -> list[str]:
    # Deliberately supports only the current zero-argument, top-level fixtures.
    # A move into @Suite or parameterized/trait tests needs explicit adapter review.
    if re.search(r"^\s*@Suite\b", source, re.M):
        raise CheckFailed(f"{fixture}: @Suite migration requires an explicit selector update")
    annotations = re.findall(r"^\s*(?:@MainActor\s+)?@Test\b", source, re.M)
    names = re.findall(
        r"^\s*(?:@MainActor\s+)?@Test\s+(?:@MainActor\s+)?func\s+([A-Za-z_]\w*)\s*\(\s*\)",
        source, re.M,
    )
    if not names or len(names) != len(annotations) or len(set(names)) != len(names):
        raise CheckFailed(f"{fixture}: missing, duplicate, or unsupported @Test declarations")
    return names


def resolve_groups(root: Path, listing: str) -> dict[str, list[str]]:
    listed = Counter(ANSI.sub("", listing).splitlines())
    groups: dict[str, list[str]] = {}
    owned: set[str] = set()
    for fixture in FIXTURES:
        path = root / "packages/shared-swift/Tests" / MODULE / f"{fixture}.swift"
        try:
            names = source_names(path.read_text(), fixture)
        except OSError as error:
            raise CheckFailed(f"{fixture}: source unavailable: {error}") from error
        for name in names:
            identifier = f"{MODULE}.{name}()"
            if listed[identifier] != 1 or name in owned:
                raise CheckFailed(f"{fixture}: expected exactly one listed test: {identifier}")
            owned.add(name)
        groups[fixture] = names
    return groups


def selector(names: list[str]) -> str:
    # Swift Testing appends source-location identity beyond the displayed ().
    # Anchor the module and complete function-name boundary, not the display suffix.
    return "^(?:" + "|".join(re.escape(f"{MODULE}.{name}(") for name in names) + ")"


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
    base = ["swift", "test", "--package-path", str(root / "packages/shared-swift"),
            "--scratch-path", str(scratch)]
    # Build and list current source once. Runs reuse that exact build; no stale --skip-build listing.
    listing = runner(base + ["list"])
    if listing.returncode:
        raise CheckFailed("SwiftPM build/list failed")
    groups = resolve_groups(root, listing.stdout)
    receipts = []
    # Validate ALL groups before executing ANY. Missing Outbox cannot hide behind other suites.
    for fixture, names in groups.items():
        result = runner(base + ["--skip-build", "--no-parallel", "--filter", selector(names)])
        if result.returncode:
            raise CheckFailed(f"{fixture}: SwiftPM exited {result.returncode}")
        receipts.append(verify_run(fixture, names, result.stdout + "\n" + result.stderr))
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

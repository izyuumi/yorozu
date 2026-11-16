#!/usr/bin/env python3
"""Fail unless the notification service compiles no ActivityKit (Live Activity L1)."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PROJECT = ROOT / "apps/ios/Project.swift"
PBX = ROOT / "apps/ios/Yorozu.xcodeproj/project.pbxproj"
ATTRIBUTES = "YorozuActivityAttributes.swift"
IOS = ROOT / "apps/ios"


def fail(msg: str) -> int:
    print(f"check-nse-no-activitykit: {msg}", file=sys.stderr)
    return 1


def target_source_names(text: str, target: str) -> list[str] | None:
    m = re.search(
        rf"/\* {re.escape(target)} \*/ = \{{[^}}]*isa = PBXNativeTarget;.*?buildPhases = \((.*?)\);",
        text,
        re.S,
    )
    if not m:
        return None
    phase_ids = re.findall(r"([A-F0-9]{24}) /\* Sources \*/", m.group(1))
    if not phase_ids:
        return None
    names: list[str] = []
    for phase_id in phase_ids:
        phase = re.search(
            rf"{phase_id} /\* Sources \*/ = \{{.*?files = \((.*?)\);",
            text,
            re.S,
        )
        if not phase:
            return None
        names.extend(re.findall(r"/\* (.*?) in Sources \*/", phase.group(1)))
    return names


def main() -> int:
    project = PROJECT.read_text()
    nse_target = re.search(
        r'name:\s*"YorozuNotificationService".*?settings:\s*signing\(\)',
        project,
        re.S,
    )
    if not nse_target:
        return fail("could not find the YorozuNotificationService target in apps/ios/Project.swift")
    if not re.search(
        r'\.glob\(\s*"Sources/WidgetShared/Model/\*\*"\s*,\s*excluding:\s*\["Sources/WidgetShared/Model/YorozuActivityAttributes\.swift"\]\s*\)',
        nse_target.group(0),
    ):
        return fail(
            "apps/ios/Project.swift must exclude "
            "Sources/WidgetShared/Model/YorozuActivityAttributes.swift from the NSE target"
        )

    if not PBX.is_file():
        return fail(f"missing {PBX}; run: tuist generate --no-open --path apps/ios")
    text = PBX.read_text()
    nse = target_source_names(text, "YorozuNotificationService")
    widgets = target_source_names(text, "YorozuWidgets")
    app = target_source_names(text, "YorozuIOS")
    if nse is None:
        return fail("could not read YorozuNotificationService sources from the generated pbxproj")
    if ATTRIBUTES in nse:
        return fail(f"{ATTRIBUTES} is still in the YorozuNotificationService sources")
    if ATTRIBUTES not in (widgets or []) and ATTRIBUTES not in (app or []):
        return fail(f"{ATTRIBUTES} is missing from the app and widget sources")

    hits: list[str] = []
    for name in nse:
        if name == ATTRIBUTES:
            hits.append(f"{name} (should have been excluded)")
            continue
        matches = list(IOS.rglob(name))
        # Generated Tuist bundles live under Derived/; still scan them if present.
        files = [p for p in matches if p.is_file()]
        if not files:
            return fail(f"could not find NSE source {name} under apps/ios")
        for path in files:
            if re.search(r"(?m)^\s*import ActivityKit\b", path.read_text()):
                hits.append(str(path.relative_to(ROOT)))
    if hits:
        return fail("ActivityKit import in NSE sources:\n  " + "\n  ".join(hits))

    print(
        f"ok: {ATTRIBUTES} is out of YorozuNotificationService "
        f"({len(nse)} sources) and still in the app or widgets; "
        "no import ActivityKit in the NSE compile set."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

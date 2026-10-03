#!/usr/bin/env python3
"""Assemble the internal candidate without running the paused store migration."""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile

BASELINE = "5be369c8d50833a626c8c0ca3e8fc262c150e8de"
ROOT = Path(__file__).resolve().parent.parent
OVERLAYS = [
    "apps/mac", "packages/shared-swift", "packages/host-core",
    "packages/runtime/src/native.ts", "packages/runtime/src/codex-native.ts",
    "packages/runtime/src/secretary-runner.ts",
    "packages/runtime/src/secretary-worker.ts",
    "packages/runtime/src/secretary-serve.ts",
    "scripts/build-mac.sh", "scripts/build-version.sh",
    "scripts/secretary-production.patch",
]


def git(*args):
    return subprocess.check_output(["git", "-C", str(ROOT), *args])


def stage(destination):
    if git("status", "--porcelain").strip():
        raise SystemExit("Commit the candidate first; internal builds require a clean source tree")
    source = git("rev-parse", "HEAD").decode().strip()
    destination = destination.resolve()
    if destination.exists() and any(destination.iterdir()):
        raise SystemExit("Staging destination must be empty")
    destination.mkdir(parents=True, exist_ok=True)
    for revision, paths in [(BASELINE, []), (source, OVERLAYS)]:
        with tarfile.open(fileobj=io.BytesIO(git("archive", revision, *paths))) as archive:
            archive.extractall(destination, filter="data")
    # This small, version-pinned hook decorates the production runtime's existing
    # tracked runners. Its recovery and readiness paths stay in the baseline.
    patch = destination / "scripts/secretary-production.patch"
    subprocess.run(["git", "apply", "--check", str(patch)], cwd=destination, check=True)
    subprocess.run(["git", "apply", str(patch)], cwd=destination, check=True)
    # Keep the production manifest and lockfile together. Only these explicit new
    # files and the reviewed adapter replace runtime source; serve/storage do not.
    tests = git("ls-tree", "-r", "--name-only", source, "packages/runtime/src").decode().splitlines()
    tests = [name for name in tests if Path(name).name.startswith("secretary-") and name.endswith(".test.ts")]
    if not tests:
        raise SystemExit("Secretary regression tests are missing")
    with tarfile.open(fileobj=io.BytesIO(git("archive", source, *tests))) as archive:
        archive.extractall(destination, filter="data")
    hashes = {}
    for name in OVERLAYS + tests + ["packages/runtime/src/serve.ts", "packages/runtime/src/threads.ts"]:
        path = destination / name
        for file in ([path] if path.is_file() else sorted(path.rglob("*"))):
            if file.is_file() and not file.is_symlink():
                hashes[str(file.relative_to(destination))] = hashlib.sha256(file.read_bytes()).hexdigest()
    manifest = {
        "schemaVersion": 1, "sourceSha": source, "productionBaselineSha": BASELINE,
        "runtimeEntry": "runtime/dist/secretary-serve.js",
        "workerBinary": "yorozu-alpha-host", "workerStore": "secretary-v1",
        "legacyStorageMigration": False, "publicUpdateFeed": False,
        "dependencyLockSha256": hashlib.sha256((destination / "pnpm-lock.yaml").read_bytes()).hexdigest(),
        "overlaySha256": hashes,
    }
    (destination / "internal-source.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(destination)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: stage-internal-alpha.py EMPTY_DESTINATION")
    stage(Path(sys.argv[1]))

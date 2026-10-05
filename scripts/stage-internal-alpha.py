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
    "packages/runtime/src/history-kinds.ts",
    "packages/runtime/src/harness-platform-store.ts",
    "packages/runtime/src/connected-agent-platform.ts",
    "apps/mac", "packages/shared-swift", "packages/host-core",
    "packages/runtime/src/native.ts", "packages/runtime/src/codex-native.ts",
    "packages/runtime/src/secretary-runner.ts",
    "packages/runtime/src/secretary-worker.ts",
    "packages/runtime/src/secretary-serve.ts",
    "packages/runtime/src/secretary-steering.ts",
    "packages/runtime/src/secretary-coordinator.ts",
    "packages/runtime/src/harness-contract.ts",
    "packages/runtime/src/harness-process.ts",
    "packages/runtime/src/harness-ledger.ts",
    "packages/runtime/src/harness-runner.ts",
    "packages/runtime/src/agent-store.ts", "packages/runtime/src/agent-scope.ts",
    "packages/runtime/src/agent-isolation.ts", "packages/runtime/src/agent-listener.ts",
    "packages/runtime/src/person-agent-runtime.ts",
    "packages/runtime/src/person-agent-host.ts", "packages/runtime/src/person-agent-controls.ts",
    "packages/runtime/src/curated-agent-runtime.ts",
    "packages/runtime/src/packaged-agent-runtime.ts",
    "packages/runtime/src/siwc-inference-broker.ts",
    "packages/runtime/src/siwc-https-transport.ts",
    "packages/runtime/src/siwc-account-lifecycle.ts", "packages/runtime/src/siwc-account-https.ts",
    "packages/runtime/src/siwc-id-token-verifier.ts",
    "packages/runtime/src/siwc-person-broker.ts", "packages/runtime/src/siwc-broker-endpoint.ts",
    "packages/runtime/src/siwc-protected-store.ts", "packages/runtime/src/siwc-control-journal.ts",
    "packages/runtime/src/native-account-coordinator.ts", "packages/runtime/src/native-account-callback.ts",
    "packages/runtime/src/native-account-host.ts",
    "packages/runtime/src/fixtures/hermes-siwc-shape.json",
    "packages/runtime/src/host-core-command.ts",
    "packages/runtime/src/rust-sync.ts", "packages/runtime/src/rust-sync-worker.ts",
    "packages/shared/src/events.ts",
    "packages/shared/src/peer-info.ts", "packages/shared/src/person-agents.ts",
    "packages/shared/src/siwc-accounts.ts",
    "packages/shared/src/index.ts",
    "packages/harness-plugins",
    "scripts/harness-proof.mjs",
    "scripts/harness-host-proof.mjs", "docs/harness-host-proof.md",
    "docs/harness-proof.md", "docs/harness-contract.md",
    "docs/siwc-inference-broker.md", "scripts/capture-hermes-siwc-shape.py",
    "docs/siwc-account-lifecycle.md",
    "docs/siwc-id-token-verifier.md",
    "docs/siwc-account-fences.md", "docs/siwc-native-protected-store.md", "docs/siwc-control-journal.md",
    "docs/native-siwc-account-coordinator.md", "docs/native-siwc-account-host.md",
    "docs/siwc-native-helper-packaging.md", "scripts/package-accounts-helper.py", "scripts/package-accounts-helper.test.py",
    "docs/hermes-runtime-packaging.md", "scripts/package-hermes-runtime.py", "scripts/test-package-hermes-runtime.py",
    "scripts/build-mac.sh", "scripts/build-version.sh",
    "scripts/build-internal-alpha.sh", "scripts/check-internal-alpha.sh", "scripts/stage-internal-alpha.py",
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
    tests = [name for name in tests if Path(name).name.startswith(("secretary-", "harness", "agent-", "person-agent-", "curated-agent-", "packaged-agent-", "siwc-", "native-account-")) and name.endswith(".test.ts")]
    shared_tests = git("ls-tree", "-r", "--name-only", source, "packages/shared/src").decode().splitlines()
    tests += [name for name in shared_tests if Path(name).name.startswith(("person-agents", "peer-info", "siwc-")) and name.endswith(".test.ts")]
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
        "harnessProtocolVersion": 1,
        "personAgentPlatform": {"kind": "packaged-hermes-v1", "productionReady": False},
        "harnessPlugins": {"hermes": {"version": "0.21.5", "sourceSha": "f97608f178d1ffeca59860195ab7da295f7c8e5f", "bundledRuntime": False}},
        "dependencyLockSha256": hashlib.sha256((destination / "pnpm-lock.yaml").read_bytes()).hexdigest(),
        "overlaySha256": hashes,
    }
    (destination / "internal-source.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(destination)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: stage-internal-alpha.py EMPTY_DESTINATION")
    stage(Path(sys.argv[1]))

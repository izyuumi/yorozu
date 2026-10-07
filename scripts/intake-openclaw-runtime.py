#!/usr/bin/env python3
"""Fetch/extract the reviewed, hash-pinned sealed OpenClaw runtime input; never execute it."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


packager = load("packager", "package-openclaw-runtime.py")
common = load("runtime_intake", "runtime-intake-common.py")
REPOSITORY, require, sha, download = common.REPOSITORY, common.require, common.sha, common.download
MAX_ARCHIVE = 2 * 1024 * 1024 * 1024
MAX_TOTAL = 6 * 1024 * 1024 * 1024
MAX_MEMBER = 512 * 1024 * 1024
MAX_MANIFEST = 64 * 1024 * 1024
MAX_ENTRIES = 250_000
MANIFEST = "runtime-artifact.json"


def load_pin(path):
    pin = json.loads(Path(path).read_text())
    require(pin.get("schemaVersion") == 1 and pin.get("kind") == "yorozu-openclaw-release-input", "Invalid release input pin")
    for key in ("archiveSha256", "manifestSha256", "inventorySha256"):
        require(isinstance(pin.get(key), str) and re.fullmatch(r"[0-9a-f]{64}", pin[key]), "Invalid digest pin")
    require(type(pin.get("archiveBytes")) is int and 0 < pin["archiveBytes"] <= MAX_ARCHIVE, "Invalid archive size pin")
    require(pin.get("repository") == REPOSITORY, "Runtime input must come from the release repository")
    require(pin.get("tag") == "runtime-input-0.6.0-" + pin["archiveSha256"][:16], "Input tag is not content-addressed")
    require(pin.get("asset") == "yorozu-openclaw-runtime-" + pin["archiveSha256"][:16] + ".tar.gz", "Unexpected input asset name")
    require(pin.get("sourceCommit") == packager.PIN["sourceSha"], "Pinned source commit is not the reviewed native source")
    return pin


def extract(archive, pin, destination, source):
    archive = common.verify_archive(archive, pin, MAX_ARCHIVE)
    destination = common.fresh_destination(destination)
    root = destination / "openclaw"
    root.mkdir(mode=0o755)
    files, links, directories = common.stream_members(
        archive, root, canonical=packager.safe_relative, contained=lambda name: name != ".." and not name.startswith("../"),
        unexpected_root="Runtime member escapes artifact", manifest=MANIFEST,
        max_entries=MAX_ENTRIES, max_total=MAX_TOTAL, max_member=MAX_MEMBER, max_manifest=MAX_MANIFEST)
    manifest_path = root / MANIFEST
    require(MANIFEST in files, "Runtime manifest is missing")
    require(files[MANIFEST]["sha256"] == pin["manifestSha256"], "Runtime manifest differs from pin")
    manifest = json.loads(manifest_path.read_text())
    require(manifest.get("schemaVersion") == 1 and manifest.get("kind") == "yorozu-openclaw-runtime"
            and manifest.get("hashStage") == "assembled-before-signing" and manifest.get("productionReady") is False,
            "Runtime manifest has wrong identity/signing stage")
    require(manifest.get("pins") == packager.PIN, "Runtime manifest pins differ from the reviewed packager pins")
    evidence = manifest.get("dependencyEvidence")
    require(isinstance(evidence, dict) and evidence.get("kind") == "pnpm-frozen-lockfile-install-v1"
            and evidence.get("lockfileMatchEstablished") is True and evidence.get("archiveProvenanceVerified") is True,
            "Runtime dependencies lack frozen-lockfile evidence")
    rows = manifest.get("files")
    require(isinstance(rows, list) and len(rows) <= MAX_ENTRIES
            and all(isinstance(row, dict) and isinstance(row.get("path"), str) for row in rows), "Invalid runtime inventory")
    require(hashlib.sha256(packager.encoded(rows)).hexdigest() == manifest.get("inventorySha256") == pin["inventorySha256"],
            "Runtime inventory is not the reviewed inventory")
    # Digests were taken while extracting; the archive must reproduce the reviewed rows
    # exactly (the manifest row is the only extra) before any link is created.
    actual = [{"path": name, **row} for name, row in files.items() if name != MANIFEST] + [{"path": name, "link": link} for name, link in links.items()]
    require(sorted(actual, key=lambda row: row["path"]) == sorted(rows, key=lambda row: row["path"]),
            "Archive content differs from reviewed inventory")
    # The inventory lists no directories; only parents of reviewed rows may appear.
    expected_dirs = {str(parent) for row in rows for parent in PurePosixPath(row["path"]).parents if str(parent) != "."}
    require(directories <= expected_dirs, "Unexpected runtime directories")
    common.create_links(root, root, links)
    by_path = {row["path"]: row for row in rows}
    require(by_path.get("node", {}).get("sha256") == packager.PIN["nodeSha256"], "Sealed Node differs from the reviewed pin")
    plugin = source / "packages/harness-plugins/openclaw"
    reviewed = {p.relative_to(plugin).as_posix() for p in plugin.rglob("*") if p.is_file()}
    require({row["path"][len("plugin/"):] for row in rows if row["path"].startswith("plugin/")} == reviewed, "Unexpected plugin payload")
    for relative in sorted(reviewed):
        require((root / "plugin" / relative).read_bytes() == (plugin / relative).read_bytes(), "Artifact adapter differs from reviewed source: " + relative)
    receipt = {"schemaVersion": 1, "archiveSha256": pin["archiveSha256"], "archiveBytes": pin["archiveBytes"],
               "manifestSha256": pin["manifestSha256"], "inventorySha256": pin["inventorySha256"],
               "sourceCommit": pin["sourceCommit"], "dependencyEvidence": evidence,
               "pluginBytesMatchReviewedSource": True, "gatewayExecuted": False}
    (destination / "intake-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    return root


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pin", required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--archive", type=Path)
    group.add_argument("--download-directory", type=Path)
    args = parser.parse_args()
    source = args.source_root.resolve(strict=True)
    pin = load_pin(args.pin)
    archive = args.archive if args.archive else download(pin, args.download_directory)
    print(extract(archive, pin, args.destination, source))


if __name__ == "__main__":
    main()

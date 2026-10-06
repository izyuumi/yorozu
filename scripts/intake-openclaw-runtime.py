#!/usr/bin/env python3
"""Fetch/extract the reviewed, hash-pinned sealed OpenClaw runtime input; never execute it."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile

spec = importlib.util.spec_from_file_location("packager", Path(__file__).with_name("package-openclaw-runtime.py"))
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)

REPOSITORY = "izyuumi/yorozu"
MAX_ARCHIVE = 2 * 1024 * 1024 * 1024
MAX_TOTAL = 6 * 1024 * 1024 * 1024
MAX_MEMBER = 512 * 1024 * 1024
MAX_MANIFEST = 64 * 1024 * 1024
MAX_ENTRIES = 250_000
MANIFEST = "runtime-artifact.json"


def require(value, reason):
    if not value:
        raise ValueError(reason)


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


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


def download(pin, directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    subprocess.run(["gh", "release", "download", pin["tag"], "--repo", REPOSITORY,
                    "--pattern", pin["asset"], "--dir", str(directory)], check=True)
    return directory / pin["asset"]


def extract(archive, pin, destination, source):
    archive = Path(archive)
    require(archive.is_file() and not archive.is_symlink(), "Archive must be a regular file")
    require(archive.stat().st_size == pin["archiveBytes"], "Runtime archive size differs from pin")
    require(sha(archive) == pin["archiveSha256"], "Runtime archive hash differs from pin")
    destination = Path(destination).absolute()
    require(not destination.exists() and not destination.is_symlink(), "Use a fresh task-owned extraction destination")
    destination = destination.parent.resolve() / destination.name
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination.mkdir(mode=0o700)
    root = destination / "openclaw"
    root.mkdir(mode=0o755)
    seen, links, total = set(), {}, 0
    # Members are written under a tree that holds no symlink until every regular file is
    # in place; links are created last and then checked for containment.
    with tarfile.open(archive, mode="r|gz") as stream:
        for entry in stream:
            require(len(seen) < MAX_ENTRIES, "Runtime archive contains too many entries")
            name = packager.safe_relative(entry.name.rstrip("/") if entry.isdir() else entry.name)
            require(name not in seen, "Duplicate runtime archive entry")
            seen.add(name)
            require(not entry.issparse(), "Sparse runtime members are forbidden")
            target = root / name
            if entry.isdir():
                require(entry.mode == 0o755 and entry.size == 0, "Unexpected runtime directory metadata")
                target.mkdir(mode=0o755, parents=True, exist_ok=True)
            elif entry.isfile():
                limit = MAX_MANIFEST if name == MANIFEST else MAX_MEMBER
                require(0 <= entry.size <= limit and entry.mode in (0o644, 0o755), "Unsafe runtime member size/mode")
                total += entry.size
                require(total <= MAX_TOTAL, "Runtime archive exceeds uncompressed bound")
                target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                member = stream.extractfile(entry)
                size = 0
                with target.open("xb") as output:
                    while data := member.read(1024 * 1024):
                        size += len(data)
                        require(size <= entry.size, "Runtime member exceeded declared size")
                        output.write(data)
                require(size == entry.size, "Truncated runtime member")
                target.chmod(entry.mode)
            elif entry.issym():
                require(entry.mode == 0o777 and entry.size == 0, "Unexpected runtime link metadata")
                links[name] = entry.linkname
            else:
                raise ValueError("Hardlinks and special runtime entries are forbidden")
    for name, link in links.items():
        target = root / name
        require(not target.exists() and not target.is_symlink(), "Runtime link collides with a member")
        target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        target.symlink_to(link)
    manifest_path = root / MANIFEST
    require(manifest_path.is_file() and not manifest_path.is_symlink(), "Runtime manifest is missing")
    require(sha(manifest_path) == pin["manifestSha256"], "Runtime manifest differs from pin")
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
    require(isinstance(rows, list) and len(rows) <= MAX_ENTRIES, "Invalid runtime inventory")
    require(hashlib.sha256(packager.encoded(rows)).hexdigest() == manifest.get("inventorySha256") == pin["inventorySha256"],
            "Runtime inventory is not the reviewed inventory")
    # The packager's own inventory walk rejects escaping links, hardlinks and special files,
    # and must reproduce the reviewed rows exactly (the manifest row is the only extra).
    actual = [row for row in packager.inventory(root) if row["path"] != MANIFEST]
    require(actual == sorted(rows, key=lambda row: row["path"]), "Archive content differs from reviewed inventory")
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

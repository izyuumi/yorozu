#!/usr/bin/env python3
"""Fetch/extract one reviewed, hash-pinned public runtime input; never execute it."""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath
import re
import subprocess
import tarfile

REPOSITORY = "izyuumi/yorozu"
MAX_ARCHIVE = 512 * 1024 * 1024
MAX_TOTAL = 2 * 1024 * 1024 * 1024
MAX_MEMBER = 512 * 1024 * 1024
MAX_MANIFEST = 8 * 1024 * 1024
MAX_ENTRIES = 35_000
PLUGIN_FILES = ("adapter.mjs", "manifest.json", "README.md", "bootstrap.py", "platform/__init__.py", "platform/plugin.yaml")


def require(value, reason):
    if not value:
        raise ValueError(reason)


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def canonical(value):
    require(isinstance(value, str) and 0 < len(value.encode()) <= 4096, "Invalid member path")
    require(not any(ord(c) < 32 or ord(c) == 127 for c in value), "Control character in path")
    path = PurePosixPath(value)
    require(not path.is_absolute() and str(path) == value and all(p not in ("", ".", "..") for p in path.parts), "Noncanonical member path")
    return value


def load_pin(path, source):
    pin = json.loads(Path(path).read_text())
    require(pin.get("schemaVersion") == 1 and pin.get("kind") == "yorozu-hermes-release-input", "Invalid release input pin")
    for key in ("archiveSha256", "manifestSha256", "inventorySha256", "inputPinSha256", "archiveProvenanceSha256"):
        require(isinstance(pin.get(key), str) and re.fullmatch(r"[0-9a-f]{64}", pin[key]), "Invalid digest pin")
    require(type(pin.get("archiveBytes")) is int and 0 < pin["archiveBytes"] <= MAX_ARCHIVE, "Invalid archive size pin")
    require(pin.get("repository") == REPOSITORY, "Runtime input must come from the release repository")
    require(pin.get("tag") == "runtime-input-0.6.0-" + pin["archiveSha256"][:16], "Input tag is not content-addressed")
    require(pin.get("asset") == "yorozu-hermes-runtime-" + pin["archiveSha256"][:16] + ".tar.gz", "Unexpected input asset name")
    require(pin.get("originalArchivesVerified") is True, "Original archive verification is not attested")
    plugin = source / "packages/harness-plugins/hermes"
    require(sha(plugin / "runtime-input-pin.json") == pin["inputPinSha256"], "Reviewed input pin changed")
    require(sha(source / "docs/hermes-public-archive-provenance.json") == pin["archiveProvenanceSha256"], "Reviewed archive provenance changed")
    return pin


def download(pin, directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    subprocess.run(["gh", "release", "download", pin["tag"], "--repo", REPOSITORY,
                    "--pattern", pin["asset"], "--dir", str(directory)], check=True)
    return directory / pin["asset"]


def extract(archive, pin, destination, source):
    archive = Path(archive)
    require(archive.is_file() and not archive.is_symlink(), "Archive must be a regular file")
    require(archive.stat().st_size == pin["archiveBytes"] <= MAX_ARCHIVE, "Runtime archive size differs from pin")
    require(sha(archive) == pin["archiveSha256"], "Runtime archive hash differs from pin")
    destination = Path(destination).absolute()
    require(not destination.exists() and not destination.is_symlink(), "Use a fresh task-owned extraction destination")
    destination.mkdir(mode=0o700, parents=True)
    root = destination / "hermes"
    seen, files, directories, links = set(), {}, set(), {}
    total = 0
    # No extraction helper follows symlinks. Create verified contained links last.
    with tarfile.open(archive, mode="r|gz") as stream:
        for entry in stream:
            require(len(seen) < MAX_ENTRIES, "Runtime archive contains too many entries")
            name = canonical(entry.name.rstrip("/") if entry.isdir() else entry.name)
            require(name == "hermes" or name.startswith("hermes/"), "Runtime archive has an unexpected root")
            require(name not in seen, "Duplicate runtime archive entry")
            seen.add(name)
            require(not entry.issparse(), "Sparse runtime members are forbidden")
            target = destination / name
            require(not any(str(parent.relative_to(destination)) in links for parent in target.parents if parent != destination and destination in parent.parents), "Member has a symlink parent")
            if entry.isdir():
                require(entry.mode == 0o755 and entry.size == 0, "Unexpected runtime directory metadata")
                target.mkdir(mode=0o755, parents=True, exist_ok=True)
                directories.add(name)
            elif entry.isfile():
                limit = MAX_MANIFEST if name == "hermes/runtime-artifact.json" else MAX_MEMBER
                require(0 <= entry.size <= limit and entry.mode in (0o644, 0o755), "Unsafe runtime member size/mode")
                total += entry.size
                require(total <= MAX_TOTAL, "Runtime archive exceeds uncompressed bound")
                target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
                member = stream.extractfile(entry)
                digest, size = hashlib.sha256(), 0
                with target.open("xb") as output:
                    while data := member.read(1024 * 1024):
                        size += len(data)
                        require(size <= entry.size, "Runtime member exceeded declared size")
                        digest.update(data)
                        output.write(data)
                require(size == entry.size, "Truncated runtime member")
                target.chmod(entry.mode)
                files[name] = {"sha256": digest.hexdigest(), "mode": entry.mode}
            elif entry.issym():
                require(entry.mode == 0o777 and entry.size == 0, "Unexpected runtime link metadata")
                link = entry.linkname
                require(isinstance(link, str) and 0 < len(link) <= 4096 and not PurePosixPath(link).is_absolute()
                        and not any(ord(c) < 32 or ord(c) == 127 for c in link), "Invalid runtime symlink")
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), link))
                require(resolved == "hermes" or resolved.startswith("hermes/"), "Runtime symlink escapes artifact")
                links[name] = link
            else:
                raise ValueError("Hardlinks and special runtime entries are forbidden")
    manifest_path = root / "runtime-artifact.json"
    require(sha(manifest_path) == pin["manifestSha256"], "Runtime manifest differs from pin")
    manifest = json.loads(manifest_path.read_text())
    require(manifest.get("schemaVersion") == 1 and manifest.get("kind") == "yorozu-hermes-runtime"
            and manifest.get("hashStage") == "assembled-before-signing", "Runtime manifest has wrong identity/signing stage")
    rows = manifest.get("files")
    require(isinstance(rows, list) and len(rows) <= 25_000, "Invalid runtime inventory")
    digest = hashlib.sha256(json.dumps(rows, sort_keys=True, ensure_ascii=False, separators=(",", ":")).encode()).hexdigest()
    require(digest == manifest.get("inventorySha256") == pin["inventorySha256"], "Runtime inventory is not the reviewed inventory")
    expected_files = {"hermes/runtime-artifact.json": files.get("hermes/runtime-artifact.json")}
    expected_links, expected_dirs, row_paths = {}, {"hermes"}, set()
    for row in rows:
        require(isinstance(row, dict), "Invalid inventory row")
        relative = canonical(row.get("path"))
        require(relative not in row_paths and relative != "runtime-artifact.json", "Duplicate inventory path")
        row_paths.add(relative)
        name = "hermes/" + relative
        parent = PurePosixPath(name).parent
        expected_dirs.update(str(p) for p in [parent, *parent.parents] if str(p) != ".")
        if "link" in row:
            require(set(row) == {"path", "link"}, "Unexpected link inventory fields")
            expected_links[name] = row["link"]
        else:
            require(set(row) == {"path", "sha256", "mode"}, "Unexpected file inventory fields")
            expected_files[name] = {"sha256": row["sha256"], "mode": row["mode"]}
    require(files == expected_files and links == expected_links, "Archive content differs from reviewed inventory")
    require(directories <= expected_dirs, "Unexpected runtime directories")
    for name, link in links.items():
        target = destination / name
        target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        require(not target.exists() and not target.is_symlink(), "Runtime link collides with a member")
        target.symlink_to(link)
    for name in links:
        resolved = (destination / name).resolve(strict=True)
        require(resolved == root or root in resolved.parents, "Resolved runtime link escapes artifact")
    plugin = source / "packages/harness-plugins/hermes"
    require(manifest["upstream"] == json.loads((plugin / "runtime-input-pin.json").read_text()), "Artifact upstream differs from committed input pin")
    require({r["path"] for r in rows if r["path"].startswith("plugin/")} == {"plugin/" + n for n in PLUGIN_FILES}, "Unexpected plugin payload")
    require(not any(n.startswith("hermes/plugin/") for n in links), "Plugin symlinks are forbidden")
    for relative in PLUGIN_FILES:
        require((root / "plugin" / relative).read_bytes() == (plugin / relative).read_bytes(), "Artifact adapter differs from reviewed source: " + relative)
    # File-only inventories omit this empty Git structural directory. Recreate
    # only after validation, never through an archive-supplied symlink.
    git_dir = root / "source/.git"
    if git_dir.exists() or git_dir.is_symlink():
        require(not (root / "source").is_symlink() and not git_dir.is_symlink()
                and git_dir.is_dir(), "Git structural parent must be a real directory")
        refs = git_dir / "refs"
        require(not refs.is_symlink(), "Git refs structural directory must not be a symlink")
        refs.mkdir(mode=0o755, exist_ok=True)
        require(refs.is_dir(), "Git refs must be a directory")
    receipt = {"schemaVersion": 1, "archiveSha256": pin["archiveSha256"], "archiveBytes": pin["archiveBytes"],
               "manifestSha256": pin["manifestSha256"], "inventorySha256": pin["inventorySha256"],
               "archiveProvenanceSha256": pin["archiveProvenanceSha256"], "pluginBytesMatchReviewedSource": True,
               "gatewayExecuted": False}
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
    pin = load_pin(args.pin, source)
    archive = args.archive if args.archive else download(pin, args.download_directory)
    root = extract(archive, pin, args.destination, source)
    print(root)


if __name__ == "__main__":
    main()

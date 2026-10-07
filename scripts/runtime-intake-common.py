"""Shared streaming extraction for the hash-pinned runtime intakes; never executes payloads."""
import hashlib
from pathlib import Path, PurePosixPath
import posixpath
import subprocess
import tarfile

REPOSITORY = "izyuumi/yorozu"


def require(value, reason):
    if not value:
        raise ValueError(reason)


def sha(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def download(pin, directory):
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    subprocess.run(["gh", "release", "download", pin["tag"], "--repo", REPOSITORY,
                    "--pattern", pin["asset"], "--dir", str(directory)], check=True)
    return directory / pin["asset"]


def verify_archive(archive, pin, max_archive):
    archive = Path(archive)
    require(archive.is_file() and not archive.is_symlink(), "Archive must be a regular file")
    require(archive.stat().st_size == pin["archiveBytes"] <= max_archive, "Runtime archive size differs from pin")
    require(sha(archive) == pin["archiveSha256"], "Runtime archive hash differs from pin")
    return archive


def fresh_destination(destination):
    destination = Path(destination).absolute()
    require(not destination.exists() and not destination.is_symlink(), "Use a fresh task-owned extraction destination")
    # Canonicalize only the trusted parent, never the fresh leaf: a leaf
    # swapped to a symlink after the check must fail atomic mkdir, not redirect
    # extraction. Parent aliases (/tmp, /var) and '..' remain supported.
    destination = destination.parent.resolve() / destination.name
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    destination.mkdir(mode=0o700)
    return destination


def stream_members(archive, base, *, canonical, contained, unexpected_root, manifest,
                   max_entries, max_total, max_member, max_manifest):
    """Write directories and regular files under base, hashing as they stream.

    No link is created and no member may sit under a link, so nothing written here
    can follow one. Returns files {name: {sha256, bytes, mode}}, links and directories.
    """
    seen, files, links, directories, total = set(), {}, {}, set(), 0
    with tarfile.open(archive, mode="r|gz") as stream:
        for entry in stream:
            require(len(seen) < max_entries, "Runtime archive contains too many entries")
            name = canonical(entry.name.rstrip("/") if entry.isdir() else entry.name)
            require(contained(name), unexpected_root)
            require(name not in seen, "Duplicate runtime archive entry")
            seen.add(name)
            require(not entry.issparse(), "Sparse runtime members are forbidden")
            require(not any(str(parent) in links for parent in PurePosixPath(name).parents), "Member has a symlink parent")
            target = base / name
            if entry.isdir():
                require(entry.mode == 0o755 and entry.size == 0, "Unexpected runtime directory metadata")
                target.mkdir(mode=0o755, parents=True, exist_ok=True)
                directories.add(name)
            elif entry.isfile():
                limit = max_manifest if name == manifest else max_member
                require(0 <= entry.size <= limit and entry.mode in (0o644, 0o755), "Unsafe runtime member size/mode")
                total += entry.size
                require(total <= max_total, "Runtime archive exceeds uncompressed bound")
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
                files[name] = {"sha256": digest.hexdigest(), "bytes": size, "mode": entry.mode}
            elif entry.issym():
                require(entry.mode == 0o777 and entry.size == 0, "Unexpected runtime link metadata")
                link = entry.linkname
                require(isinstance(link, str) and 0 < len(link) <= 4096 and not PurePosixPath(link).is_absolute()
                        and not any(ord(c) < 32 or ord(c) == 127 for c in link), "Invalid runtime symlink")
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), link))
                require(contained(resolved), "Runtime symlink escapes artifact")
                links[name] = link
            else:
                raise ValueError("Hardlinks and special runtime entries are forbidden")
    return files, links, directories


def create_links(base, root, links):
    """Create links validated against the reviewed inventory; each must resolve inside root."""
    for name, link in links.items():
        target = base / name
        target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
        require(not target.exists() and not target.is_symlink(), "Runtime link collides with a member")
        target.symlink_to(link)
    for name in links:
        resolved = (base / name).resolve(strict=True)
        require(resolved == root or root in resolved.parents, "Resolved runtime link escapes artifact")

#!/usr/bin/env python3
"""Stage an internal alpha from built inputs. Never builds, installs, or launches."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("ui", "host", "node", "runtime", "shared_resources", "output"):
        parser.add_argument("--" + name.replace("_", "-"), type=Path, required=True)
    parser.add_argument("--source-sha", required=True)
    parser.add_argument("--identity", default="-")
    args = parser.parse_args()
    binaries = [args.ui.resolve(), args.host.resolve(), args.node.resolve()]
    runtime = args.runtime.resolve()
    resources = args.shared_resources.resolve()
    output = args.output.absolute()
    staging_roots = [Path(__file__).resolve().parent.parent,
                     Path(tempfile.gettempdir()).resolve(), Path("/tmp").resolve()]
    if not any(output.resolve().is_relative_to(root) for root in staging_roots):
        parser.error("output must stay in this checkout or OS temporary staging")
    if output.exists() or output.is_symlink():
        parser.error("output already exists; select a fresh isolated path")
    if output.name != "YorozuAlpha.app":
        parser.error("output must be named YorozuAlpha.app")
    if not all(p.is_file() and os.access(p, os.X_OK) for p in binaries):
        parser.error("ui, host and node must be built executable files")
    if not (runtime / "dist/alpha-worker.js").is_file() or not resources.is_dir():
        parser.error("runtime needs dist/alpha-worker.js; shared resources must be a bundle")
    # Deploy rather than copying workspace links that lead outside the sealed bundle.
    for p in runtime.rglob("*"):
        if p.is_symlink() and not p.resolve().is_relative_to(runtime):
            parser.error("runtime has an external symlink; use pnpm deploy first")
    for p in binaries:
        linked = subprocess.check_output(["otool", "-L", str(p)], text=True)
        if any(not line.strip().startswith(("/usr/lib/", "/System/Library/", "@"))
               for line in linked.splitlines()[1:] if line.strip()):
            parser.error(f"{p.name} links non-system libraries; use a relocatable binary")
    subprocess.run([str(binaries[2]), "--version"], check=True)
    macos = output / "Contents/MacOS"
    dest = output / "Contents/Resources"
    macos.mkdir(parents=True)
    dest.mkdir()
    shutil.copy2(binaries[0], macos / "YorozuAlpha")
    shutil.copy2(binaries[1], dest / "yorozu-alpha-host")
    shutil.copy2(binaries[2], dest / "node")
    shutil.copytree(runtime, dest / "runtime", symlinks=True)
    shutil.copytree(resources, dest / resources.name, symlinks=True)
    # Remove Finder/resource-fork detritus from this copied staging tree only.
    subprocess.run(["xattr", "-cr", str(output)], check=True)
    identifier = "to.yumi.yorozu.alpha.internal"
    with (output / "Contents/Info.plist").open("wb") as file:
        plistlib.dump({"CFBundleExecutable": "YorozuAlpha", "CFBundleIdentifier": identifier,
                      "CFBundleName": "Yorozu Alpha Internal", "CFBundlePackageType": "APPL",
                      "CFBundleShortVersionString": "0.6.0", "CFBundleVersion": "1",
                      "LSMinimumSystemVersion": "15.0", "NSHighResolutionCapable": True}, file)
    manifest = {"format": 1, "sourceSha": args.source_sha, "bundleId": identifier,
                "distribution": "internal-only", "notarized": False,
                "provider": "installed official Codex app-server; existing client auth",
                "migration": "none; explicit temporary alpha profile",
                "inputs": {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in binaries}}
    (dest / "alpha-candidate.json").write_text(json.dumps(manifest, indent=2) + "\n")
    # Node's JIT exception belongs to Node only. Developer signing is opt-in; internal
    # ad-hoc bundles have no transferable native TCC permission identity.
    entitlements = output.parent / (output.name + ".node-entitlements.plist")
    with entitlements.open("wb") as file:
        plistlib.dump({"com.apple.security.cs.allow-jit": True}, file)
    sign = ["codesign", "--force", "--sign", args.identity]
    if args.identity != "-":
        sign += ["--options", "runtime", "--timestamp"]
    for p in sorted(output.rglob("*"), key=lambda p: len(p.parts), reverse=True):
        if p.is_file() and not p.is_symlink():
            kind = subprocess.check_output(["file", "-b", str(p)], text=True)
            if "Mach-O" in kind:
                subprocess.run(sign + (["--entitlements", str(entitlements)] if p == dest / "node" else []) + [str(p)], check=True)
    subprocess.run(sign + ["--identifier", identifier, str(output)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(output)], check=True)
    entitlements.unlink()
    manifest["files"] = {str(p.relative_to(output)): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in sorted(output.rglob("*")) if p.is_file() and not p.is_symlink()}
    output.with_suffix(".manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(output)


if __name__ == "__main__":
    main()

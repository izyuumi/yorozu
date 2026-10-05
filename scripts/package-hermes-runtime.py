#!/usr/bin/env python3
"""Assemble an offline, relocatable Hermes runtime from explicitly prepared inputs.

This helper does not install, download, launch a gateway, or read profiles.
Only the explicitly pinned copied JPEG library receives a local ad-hoc signature.
"""
import argparse
import base64
import csv
import email
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib

SOURCE_SHA = "f97608f178d1ffeca59860195ab7da295f7c8e5f"
PYTHON_VERSION = "3.13.16"
PLUGIN_FILES = ("adapter.mjs", "manifest.json", "README.md", "bootstrap.py", "platform/__init__.py", "platform/plugin.yaml")
MANIFEST = "runtime-artifact.json"
MACHO = {b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca", b"\xca\xfe\xba\xbf", b"\xbf\xba\xfe\xca"}
JPEG_DERIVATION = {"path": "python/lib/python3.13/site-packages/PIL/.dylibs/libjpeg.62.4.0.dylib",
                   "inputSha256": "cf7c4e5c2d2c007fc51afcb95b649415cfe0bc4d7137ace897a6eff6550fa967",
                   "removeRpath": "/Users/runner/work/Pillow/Pillow/build/deps/darwin/lib"}
JPEG_RPATH_OUTPUT_SHA = "56a3a10ac81f12a0e6ae7cc5a023924067f4e7c2defd8308b9ed806064ab560d"


def fail(message):
    raise ValueError(message)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()


def tree_digest(rows):
    return hashlib.sha256(encoded(rows)).hexdigest()


def normalized_name(name):
    return re.sub(r"[-_.]+", "-", name).lower()


def within(root, path):
    return path == root or root in path.parents


def inventory(root, exclude=None):
    rows = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if exclude and exclude(relative):
            continue
        info = path.lstat()
        if path.is_symlink():
            target = os.readlink(path)
            if Path(target).is_absolute() or not within(root.resolve(), path.resolve(strict=True)):
                fail("Artifact contains an escaping or absolute symlink")
            rows.append({"path": relative, "link": target})
        elif stat.S_ISREG(info.st_mode):
            rows.append({"path": relative, "sha256": digest(path), "mode": 0o755 if info.st_mode & 0o111 else 0o644})
        elif not stat.S_ISDIR(info.st_mode):
            fail("Artifact contains a special file")
    return rows


def python_excluded(relative):
    parts = Path(relative).parts
    return "__pycache__" in parts or relative.endswith((".pyc", ".pyo")) or "site-packages" in parts


def python_inventory(root):
    rows = inventory(root, python_excluded)
    # Runtime only: omit headers and console/install scripts, retain library resources.
    return [row for row in rows if row["path"].startswith(("lib/", "share/")) or row["path"] in ("bin/python3.13", "bin/python3", "bin/python")]


def git(repo, *args, input=None, stdout=subprocess.PIPE, index_file=None):
    environment = {"PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "LANG": "C"}
    if index_file is not None:
        environment["GIT_INDEX_FILE"] = str(index_file)
    result = subprocess.run(["/usr/bin/git", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-C", str(repo), *args], input=input, stdout=stdout,
                            stderr=subprocess.PIPE, env=environment, check=False)
    if result.returncode:
        fail("Pinned public source Git verification failed")
    return result.stdout


def verify_source(source):
    if git(source, "rev-parse", "HEAD").decode().strip() != SOURCE_SHA:
        fail("Hermes source HEAD differs from the approved pin")
    # Git diff can refresh its index even with optional locks disabled. A new
    # private index also prevents inherited assume-unchanged flags hiding edits.
    with tempfile.TemporaryDirectory(prefix="yorozu-source-verify-") as private:
        index = Path(private) / "index"
        git(source, "read-tree", SOURCE_SHA, index_file=index)
        git(source, "diff", "--quiet", "--no-ext-diff", "--no-textconv", "HEAD", "--", index_file=index)
    project = tomllib.loads((source / "pyproject.toml").read_text())
    if project["project"]["version"] != "0.21.5":
        fail("Hermes source version differs from the approved pin")
    return git(source, "rev-parse", "HEAD^{tree}").decode().strip()


def dependency_inventory(source, venv):
    site = venv / "lib/python3.13/site-packages"
    lock = tomllib.loads((source / "uv.lock").read_text())
    locked = {(normalized_name(item["name"]), item["version"]) for item in lock["package"]}
    distributions = []
    seen = set()
    claimed = set()
    for metadata_dir in sorted(site.glob("*.dist-info")):
        metadata = email.message_from_bytes((metadata_dir / "METADATA").read_bytes())
        name, version = normalized_name(metadata["Name"]), metadata["Version"]
        if name in seen or (name, version) not in locked:
            fail("Prepared dependency is duplicate or differs from the frozen lock")
        seen.add(name)
        record = metadata_dir / "RECORD"
        verified = 0
        with record.open(newline="") as stream:
            for relative, hash_value, size in csv.reader(stream):
                path = (site / relative).resolve(strict=True)
                if not within(venv, path) or not path.is_file():
                    fail("Installed dependency RECORD escapes the prepared environment")
                claimed.add(path)
                if not hash_value and path != record.resolve() and not site_excluded(relative):
                    fail("Dependency RECORD contains an unhashed payload")
                if hash_value:
                    algorithm, value = hash_value.split("=", 1)
                    if algorithm not in {"sha256", "sha384", "sha512"}:
                        fail("Unsupported dependency RECORD digest")
                    actual = base64.urlsafe_b64encode(hashlib.new(algorithm, path.read_bytes()).digest()).decode().rstrip("=")
                    if actual != value or size and path.stat().st_size != int(size):
                        fail("Prepared dependency bytes differ from installed RECORD")
                    verified += 1
        distributions.append({"name": name, "version": version, "inputRecordSha256": digest(record), "verifiedRecordFiles": verified})
    if "hermes-agent" not in seen or "packaging" not in seen:
        fail("Prepared environment lacks Hermes metadata or dependency validation support")
    # No arbitrary executable startup hooks enter the bundled interpreter.
    allowed_hooks = {"__editable__.hermes_agent-0.21.5.pth", "_virtualenv.pth"}
    if {path.name for path in site.glob("*.pth")} - allowed_hooks:
        fail("Prepared environment contains an unreviewed Python startup hook")
    validate_site_ownership(site, claimed)
    return site, distributions


def validate_site_ownership(site, claimed=None):
    """Reject import hooks even if owned, and every unowned retained payload."""
    prepared_input = claimed is not None
    if claimed is None:
        claimed = set()
        for record in site.glob("*.dist-info/RECORD"):
            with record.open(newline="") as stream:
                for relative, _, _ in csv.reader(stream):
                    path = (site / relative).resolve(strict=True)
                    if not within(site.resolve(), path):
                        fail("Artifact RECORD escapes site-packages")
                    claimed.add(path)
    for path in site.rglob("*"):
        relative = path.relative_to(site).as_posix()
        if any(part.split(".")[0] in {"sitecustomize", "usercustomize"} for part in Path(relative).parts):
            fail("Forbidden Python startup customization hook")
        if path.is_dir() and not path.is_symlink():
            continue
        if site_excluded(relative) and path.name != "RECORD":
            if not prepared_input:
                fail("Artifact retains stripped startup/generated payload: " + relative)
            continue
        if path.is_symlink() or path.resolve() not in claimed:
            fail("Unowned site-packages payload: " + relative)


def copy_rows(source, destination, rows):
    for row in rows:
        relative = row["path"]
        src, dst = source / relative, destination / relative
        dst.parent.mkdir(parents=True, exist_ok=True)
        if "link" in row:
            dst.symlink_to(row["link"])
        else:
            shutil.copyfile(src, dst)
            dst.chmod(row["mode"])


def export_source(source, destination):
    destination.mkdir()
    with tempfile.TemporaryDirectory(prefix="yorozu-git-template-") as empty_template:
        git(destination, "init", "--quiet", "--template=" + empty_template)
    objects = git(source, "rev-list", "--objects", "--no-object-names", SOURCE_SHA + "^{tree}") + (SOURCE_SHA + "\n").encode()
    with tempfile.TemporaryFile() as pack:
        git(source, "pack-objects", "--stdout", "--window=0", input=objects, stdout=pack)
        pack.seek(0)
        # A complete one-commit pack, never a shared/alternate object store.
        git(destination, "index-pack", "--stdin", input=pack.read())
    control = destination / ".git"
    (control / "config").write_text("[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = false\n")
    (control / "HEAD").write_text(SOURCE_SHA + "\n")
    (control / "shallow").write_text(SOURCE_SHA + "\n")
    git(destination, "read-tree", SOURCE_SHA)
    git(destination, "checkout-index", "--all", "--force")
    verify_source(destination)


def site_excluded(relative):
    parts = Path(relative).parts
    return ("__pycache__" in parts or relative.endswith((".pyc", ".pyo", ".pth"))
            or relative.startswith("__editable__") or relative == "_virtualenv.py"
            or parts[-1] in {"direct_url.json", "uv_cache.json", "uv_build.json", "RECORD"})


def rewrite_records(site):
    # Removed console scripts/editable hooks have no corresponding artifact files.
    for metadata_dir in sorted(site.glob("*.dist-info")):
        original = metadata_dir / "RECORD.input"
        with original.open(newline="") as stream:
            paths = [row[0] for row in csv.reader(stream)]
        original.unlink()
        record = metadata_dir / "RECORD"
        rows = []
        for relative in sorted(set(paths)):
            path = site / relative
            if ".." in Path(relative).parts or not path.is_file() or path.is_symlink() or path == record:
                continue
            value = base64.urlsafe_b64encode(bytes.fromhex(digest(path))).decode().rstrip("=")
            rows.append((relative, "sha256=" + value, str(path.stat().st_size)))
        rows.append((record.relative_to(site).as_posix(), "", ""))
        with record.open("w", newline="") as stream:
            csv.writer(stream, lineterminator="\n").writerows(rows)


def expand_dyld(value, loader, executable):
    for prefix, base in (("@loader_path", loader.parent), ("@executable_path", executable.parent)):
        if value == prefix:
            return base
        if value.startswith(prefix + "/"):
            return base / value[len(prefix) + 1:]
    return Path(value) if value.startswith("/") else None


def system_library(value):
    return str(value).startswith(("/usr/lib/", "/System/Library/")) and ".." not in Path(value).parts


def validate_rpaths(rpaths, loader, executable, root):
    for value in rpaths:
        expanded = expand_dyld(value, loader, executable)
        if expanded is None or not (within(root, expanded.resolve()) or system_library(expanded)):
            fail("Mach-O RPATH escapes the relocatable artifact")


def resolve_dependency(dependency, loader, executable, rpaths, root):
    if system_library(dependency):
        return "system"
    candidates = []
    if dependency.startswith("@rpath/"):
        for rpath in rpaths:
            base = expand_dyld(rpath, loader, executable)
            if base is not None:
                candidates.append(base / dependency[len("@rpath/"):])
    else:
        candidate = expand_dyld(dependency, loader, executable)
        if candidate is not None:
            candidates.append(candidate)
    for candidate in candidates:
        if system_library(candidate):
            return "system"
        if candidate.exists() and within(root, candidate.resolve()):
            return candidate.resolve().relative_to(root).as_posix()
    fail("Mach-O dependency is unresolved or escapes the relocatable artifact")


def macho_rpaths(output):
    return re.findall(r"cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset \d+\)", output)


def audit_macho(root):
    executable = root / "python/bin/python3.13"
    def inspect(path, option):
        return subprocess.check_output(["/usr/bin/otool", option, str(path)], env={"PATH": "/usr/bin:/bin", "LANG": "C"}).decode()
    executable_rpaths = macho_rpaths(inspect(executable, "-l"))
    result = []
    for path in sorted(root.rglob("*")):
        if path.is_symlink() or not path.is_file():
            continue
        with path.open("rb") as stream:
            is_macho = stream.read(4) in MACHO
        if not is_macho:
            continue
        commands = inspect(path, "-l")
        local_rpaths = macho_rpaths(commands)
        validate_rpaths(local_rpaths, path, executable, root)
        install_ids = re.findall(r"cmd LC_ID_DYLIB\s+cmdsize \d+\s+name (.+?) \(offset \d+\)", commands)
        dependencies = []
        for line in inspect(path, "-L").splitlines():
            match = re.match(r"\s+(.+?) \(compatibility version", line)
            if match:
                name = match.group(1)
                if name in install_ids:
                    continue  # A dylib's own identity is not an external load command.
                # Executable RPATHs are expanded relative to the executable, not this library.
                inherited = [str(executable.parent / p[len("@loader_path/"):]) if p.startswith("@loader_path/") else p for p in executable_rpaths]
                dependencies.append({"load": name, "resolved": resolve_dependency(name, path, executable, local_rpaths + inherited, root)})
        architectures = subprocess.check_output(["/usr/bin/lipo", "-archs", str(path)], env={"PATH": "/usr/bin:/bin", "LANG": "C"}).decode().split()
        if "arm64" not in architectures:
            fail("Native interpreter/dependency lacks the curated arm64 architecture")
        result.append({"path": path.relative_to(root).as_posix(), "architectures": architectures, "dependencies": dependencies})
    if not result:
        fail("Artifact has no native interpreter")
    return result


def curate_native_loads(root):
    # The sole reviewed native derivation. Never modifies installed/cache inputs.
    path = root / JPEG_DERIVATION["path"]
    if digest(path) != JPEG_DERIVATION["inputSha256"]:
        fail("Copied JPEG library differs from the explicitly reviewed native input")
    commands = subprocess.check_output(["/usr/bin/otool", "-l", str(path)], env={"PATH": "/usr/bin:/bin", "LANG": "C"}, stderr=subprocess.PIPE).decode()
    if macho_rpaths(commands) != [JPEG_DERIVATION["removeRpath"]]:
        fail("Copied JPEG library RPATH differs from the reviewed derivation")
    subprocess.run(["/usr/bin/install_name_tool", "-delete_rpath", JPEG_DERIVATION["removeRpath"], str(path)],
                   env={"PATH": "/usr/bin:/bin", "LANG": "C"}, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    modified = digest(path)
    if modified != JPEG_RPATH_OUTPUT_SHA:
        fail("Copied JPEG load-command output differs from the reviewed derivation")
    # The edit invalidates the wheel's existing ad-hoc signature. This uses no
    # Keychain, identity selection or distribution signing.
    signing_environment = {"PATH": "/usr/bin:/bin", "LANG": "C"}
    subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(path)], env=signing_environment,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    subprocess.run(["/usr/bin/codesign", "--verify", "--verbose=2", str(path)], env=signing_environment,
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True)
    return [{**JPEG_DERIVATION, "operation": "install_name_tool -delete_rpath", "outputSha256": modified},
            {"path": JPEG_DERIVATION["path"], "operation": "codesign --force --sign -", "inputSha256": modified,
             "outputSha256": digest(path), "identity": "ad-hoc", "distributionSigning": False}]


def probe_python(python):
    # Inert imports only; no Hermes modules, native Gateway, model or auth calls.
    probe = '''import importlib.metadata as m,json,pathlib,platform,ssl,sqlite3,sys
import certifi,openai,pydantic_core,yaml,PIL.Image
from packaging.requirements import Requirement
pending=[("hermes-agent",())];seen=set();checked=[]
while pending:
 name,extras=pending.pop();key=(name,extras)
 if key in seen:continue
 seen.add(key);dist=m.distribution(name);checked.append(dist.metadata["Name"])
 for line in dist.requires or []:
  req=Requirement(line)
  if req.marker and not any(req.marker.evaluate({"extra":extra}) for extra in (extras or ("",))):continue
  child=m.distribution(req.name)
  if req.specifier and not req.specifier.contains(child.version,prereleases=True):raise RuntimeError("dependency version mismatch")
  pending.append((req.name,tuple(sorted(req.extras))))
print(json.dumps({"version":platform.python_version(),"system":platform.system(),"machine":platform.machine(),"prefix":sys.prefix,"basePrefix":sys.base_prefix,"certifi":certifi.where(),"dependencyClosure":sorted(set(checked))}))
'''
    with tempfile.TemporaryDirectory(prefix="yorozu-python-probe-") as temporary:
        isolated = Path(temporary)
        home = isolated / "home"
        home.mkdir()
        environment = {"PATH": "/usr/bin:/bin", "HOME": str(home), "TMPDIR": str(isolated), "LANG": "C", "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"}
        result = subprocess.run([str(python), "-I", "-B", "-c", probe], cwd=isolated, env=environment, capture_output=True, text=True)
        if result.returncode:
            fail("Bundled interpreter/dependency import probe failed; no Gateway was launched")
        value = json.loads(result.stdout)
    if value["version"] != PYTHON_VERSION or value["system"] != "Darwin" or value["machine"] != "arm64":
        fail("Prepared interpreter platform/version differs from the curated runtime pin")
    return value


def inspect_inputs(source, venv, python_root):
    source_tree = verify_source(source)
    site, dependencies = dependency_inventory(source, venv)
    python_rows = python_inventory(python_root)
    value = {"schemaVersion": 1, "hermesVersion": "0.21.5", "sourceSha": SOURCE_SHA, "sourceTree": source_tree,
            "uvLockSha256": digest(source / "uv.lock"), "pythonVersion": PYTHON_VERSION, "platform": "darwin-arm64",
            "pythonTreeSha256": tree_digest(python_rows), "pythonBinarySha256": digest(python_root / "bin/python3.13"),
            "dependencies": dependencies, "dependencyEvidence": "installed versions match uv.lock and installed RECORD bytes; original wheel archive hashes are not reverified",
            "pythonEvidence": "prepared local CPython snapshot hashes; original download archive receipt is not present"}
    layout = json.loads((Path(__file__).resolve().parent.parent / "packages/harness-plugins/hermes/runtime-layout.json").read_text())
    expected = {"sourceSha": layout["upstream"]["sourceSha"], "sourceTree": layout["upstream"]["sourceTree"], "uvLockSha256": layout["upstream"]["uvLockSha256"],
                "pythonVersion": layout["preparedPython"]["version"], "platform": layout["preparedPython"]["platform"], "pythonTreeSha256": layout["preparedPython"]["runtimeTreeSha256"], "pythonBinarySha256": layout["preparedPython"]["binarySha256"]}
    if any(value[key] != approved for key, approved in expected.items()):
        fail("Source/Python bytes differ from the curated runtime-layout pin")
    return value


def assemble(args):
    source, venv, python_root, plugin_source = (Path(value).resolve(strict=True) for value in (args.source, args.venv, args.python_root, args.plugin_source))
    destination = Path(args.destination).absolute()
    if destination.exists() or any(within(path, destination.resolve()) or within(destination.resolve(), path) for path in (source, venv, python_root, plugin_source)):
        fail("Destination must be a new separate candidate directory")
    observed = inspect_inputs(source, venv, python_root)
    approved = json.loads(Path(args.pin).read_text())
    if observed != approved:
        fail("Prepared runtime inputs differ from the explicitly reviewed input pin")
    if not re.fullmatch(r"[0-9a-f]{40}", args.plugin_revision):
        fail("An exact reviewed adapter source revision is required")
    destination.mkdir(parents=True)
    copy_rows(python_root, destination / "python", python_inventory(python_root))
    site = venv / "lib/python3.13/site-packages"
    target_site = destination / "python/lib/python3.13/site-packages"
    copy_rows(site, target_site, inventory(site, site_excluded))
    for info in site.glob("*.dist-info"):
        shutil.copyfile(info / "RECORD", target_site / info.name / "RECORD.input")
    rewrite_records(target_site)
    export_source(source, destination / "source")
    for relative in PLUGIN_FILES:
        output = destination / "plugin" / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(git(plugin_source, "show", args.plugin_revision + ":packages/harness-plugins/hermes/" + relative))
        output.chmod(0o644)
    transformations = curate_native_loads(destination)
    native = audit_macho(destination)
    probe = probe_python(destination / "python/bin/python3.13")
    if Path(probe["prefix"]).resolve() != destination.resolve() / "python" or Path(probe["basePrefix"]).resolve() != destination.resolve() / "python" or not within(destination.resolve(), Path(probe["certifi"]).resolve()):
        fail("Interpreter or certificate library still resolves outside the candidate")
    probe.pop("prefix"); probe.pop("basePrefix"); probe["certifi"] = "python/lib/python3.13/site-packages/certifi/cacert.pem"
    value = {"schemaVersion": 1, "kind": "yorozu-hermes-runtime", "productionReady": False, "hashStage": "assembled-before-signing",
             "upstream": approved, "adapterSourceSha": args.plugin_revision, "paths": {"python": "python/bin/python3.13", "source": "source", "adapter": "plugin/adapter.mjs"},
             "derivation": {"upstreamSourceModified": False, "pythonSitePackagesReplaced": True, "editableAndStartupHooksRemoved": True, "consoleScriptsExcluded": True, "dependencyRecordsRewritten": True, "sourceGitMetadata": "new one-commit objects/index; no remotes, hooks, alternates or original config", "nativeLoadCommandTransformations": transformations},
             "runtimeRequirements": {"lazyInstalls": "trusted adapter must disable; helper never installs", "ambientPython": False, "ambientProfiles": False, "subscriptionProof": False},
             "inertImportProbe": probe, "machODependencies": native, "files": inventory(destination, lambda name: name == MANIFEST)}
    value["inventorySha256"] = tree_digest(value["files"])
    (destination / MANIFEST).write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"artifact": str(destination), "inventorySha256": value["inventorySha256"], "distributions": len(approved["dependencies"]), "machOFiles": len(native), "gatewayExecuted": False}))


def verify_artifact(root, reseal=False):
    root = root.resolve(strict=True)
    manifest = json.loads((root / MANIFEST).read_text())
    if manifest.get("schemaVersion") != 1 or manifest.get("kind") != "yorozu-hermes-runtime" or manifest["upstream"]["sourceSha"] != SOURCE_SHA:
        fail("Invalid runtime artifact identity")
    if tree_digest(manifest["files"]) != manifest["inventorySha256"]:
        fail("Runtime manifest inventory digest differs from its recorded rows")
    verify_source(root / "source")
    rows = inventory(root, lambda name: name == MANIFEST)
    if reseal:
        prior, current = ({item["path"]: item for item in items} for items in (manifest["files"], rows))
        if prior.keys() != current.keys():
            fail("Signing changed artifact layout")
        known_native = {item["path"] for item in manifest["machODependencies"]}
        for path, item in current.items():
            if prior[path] != item:
                if path not in known_native or "sha256" not in prior[path] or "sha256" not in item:
                    fail("Reseal permits hash updates to existing native files only")
                with (root / path).open("rb") as stream:
                    if stream.read(4) not in MACHO or prior[path].get("mode") != item.get("mode"):
                        fail("Reseal permits existing Mach-O files with unchanged modes only")
        manifest["files"] = rows
        manifest["inventorySha256"] = tree_digest(rows)
        manifest["hashStage"] = "after-nested-signing-before-outer-bundle-signing"
    elif rows != manifest["files"] or tree_digest(rows) != manifest["inventorySha256"]:
        fail("Runtime artifact bytes differ from the sealed inventory")
    native = audit_macho(root)
    value = probe_python(root / "python/bin/python3.13")
    if Path(value["prefix"]).resolve() != root / "python" or Path(value["basePrefix"]).resolve() != root / "python" or not within(root, Path(value["certifi"]).resolve()):
        fail("Relocated runtime resolves an external interpreter/library")
    if reseal:
        value.pop("prefix"); value.pop("basePrefix")
        value["certifi"] = "python/lib/python3.13/site-packages/certifi/cacert.pem"
        manifest["machODependencies"] = native
        manifest["inertImportProbe"] = value
        # Commit the new seal only after every native audit/import has passed.
        with tempfile.NamedTemporaryFile(mode="w", dir=root, prefix=".runtime-artifact-", delete=False) as stream:
            stream.write(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
            replacement = Path(stream.name)
        replacement.chmod(0o644)
        replacement.replace(root / MANIFEST)
    print(json.dumps({"verified": True, "hashStage": manifest["hashStage"], "inventorySha256": manifest["inventorySha256"], "gatewayExecuted": False}))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("inspect", "assemble"):
        sub = commands.add_parser(name)
        for option in ("source", "venv", "python-root"):
            sub.add_argument("--" + option, required=True)
        if name == "assemble":
            for option in ("plugin-source", "plugin-revision", "destination", "pin"):
                sub.add_argument("--" + option, required=True)
    for name in ("verify", "reseal-after-nested-signing"):
        commands.add_parser(name).add_argument("--artifact", required=True)
    args = parser.parse_args()
    if args.command == "inspect":
        print(json.dumps(inspect_inputs(*(Path(value).resolve(strict=True) for value in (args.source, args.venv, args.python_root))), indent=2, sort_keys=True))
    elif args.command == "assemble":
        assemble(args)
    else:
        verify_artifact(Path(args.artifact), args.command == "reseal-after-nested-signing")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError, KeyError) as error:
        print("Hermes packaging failed: " + str(error), file=sys.stderr)
        sys.exit(1)

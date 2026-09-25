#!/usr/bin/env python3
"""Publish release candidates and promote their exact signed artifacts.

Uses only Python's standard library and authenticated gh. Commands never build,
re-sign or replace a published candidate/stable asset. Older main betas are removed.
"""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from urllib.parse import quote, urlencode
import xml.etree.ElementTree as ET

from release_notes import generate_release_notes

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)
VERSION = re.compile(r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)")
CANDIDATE = re.compile(r"candidate-(\d+\.\d+\.\d+)-(\d+)")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def version(value):
    require(isinstance(value, str) and VERSION.fullmatch(value), "version must be MAJOR.MINOR.PATCH")
    return tuple(map(int, value.split(".")))


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def checkout_sha():
    return subprocess.check_output(["git", "rev-parse", "--verify", "HEAD"], text=True).strip()


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def validate_manifest(data, complete=True):
    require(data.get("schema") == 1, "unsupported candidate schema")
    train = version(data.get("version"))
    require(re.fullmatch(r"[1-9]\d*", str(data.get("build", ""))), "invalid candidate build")
    require(re.fullmatch(r"[0-9a-f]{40}", data.get("source_sha", "")), "source must be a full commit SHA")
    branch = data.get("source_branch", "")
    require(branch == "main" or branch == f"release/{train[0]}.{train[1]}", "source branch must be main or release/MAJOR.MINOR matching version")
    require(data.get("tag") == f"candidate-{data['version']}-{data['build']}", "candidate tag does not match version/build")
    for key in ("run_id", "ci_run_id"):
        require(re.fullmatch(r"[1-9]\d*", str(data.get(key, ""))), f"invalid {key}")
    if not complete:
        return
    require(isinstance(data.get("notes"), str) and data["notes"].strip(), "candidate requires generated release notes")
    mac = data.get("mac", {})
    require(mac.get("asset") == "yorozu.dmg", "invalid Mac asset name")
    require(isinstance(mac.get("size"), int) and mac["size"] > 0, "invalid Mac asset size")
    for key in ("sha256", "appcast_sha256"):
        require(re.fullmatch(r"[a-f0-9]{64}", mac.get(key, "")), f"invalid Mac {key}")
    ios = data.get("ios", {})
    require(ios.get("version") == data["version"] and re.fullmatch(r"[1-9]\d*", str(ios.get("build", ""))), "invalid iOS version/build")
    for key in ("app_id", "build_id", "uploaded_date"):
        require(isinstance(ios.get(key), str) and ios[key].strip(), f"missing iOS {key}")


class GitHub:
    def __init__(self, repo):
        require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo), "invalid GitHub repository")
        self.repo = repo

    def call(self, *args, optional=False):
        result = subprocess.run(["gh", *map(str, args)], capture_output=True, text=True, check=False)
        if result.returncode:
            if optional and ("HTTP 404" in result.stderr or "release not found" in result.stderr.lower()):
                return None
            raise RuntimeError(result.stderr.strip() or "GitHub command failed")
        return result.stdout

    def api(self, path, *args, optional=False):
        result = self.call("api", f"repos/{self.repo}/{path}", *args, optional=optional)
        return json.loads(result) if result is not None else None

    def release(self, tag):
        output = self.call("release", "view", tag, "--repo", self.repo,
                           "--json", "tagName,name,isDraft,isPrerelease,targetCommitish,assets", optional=True)
        return json.loads(output) if output is not None else None

    def tag_sha(self, tag):
        ref = self.api("git/ref/tags/" + quote(tag, safe=""), optional=True)
        if ref is None:
            return None
        obj = ref["object"]
        for _ in range(5):
            if obj["type"] == "commit":
                return obj["sha"]
            require(obj["type"] == "tag", "release tag does not refer to a commit")
            obj = self.api("git/tags/" + obj["sha"])["object"]
        raise ValueError("release tag nesting exceeds five levels")

    def download(self, tag, name, directory):
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True)
        # --clobber is local only: a rerun must inspect fresh remote bytes.
        self.call("release", "download", tag, "--repo", self.repo, "--pattern", name,
                  "--dir", directory, "--clobber")
        path = directory / name
        require(path.is_file(), f"release asset missing: {tag}/{name}")
        return path

    def create(self, tag, source, prerelease, notes=None, title=None):
        ref = self.tag_sha(tag)
        require(ref is None or ref == source, f"existing tag {tag} points at another commit")
        args = ["release", "create", tag, "--repo", self.repo, "--target", source,
                "--draft", "--latest=false", "--title", title or f"Yorozu {tag}",
                "--notes", notes or f"Source: {source}\nRelease workflow: docs/RELEASE_WORKFLOW.md"]
        if prerelease:
            args.append("--prerelease")
        self.call(*args)

    def upload(self, tag, path):
        self.call("release", "upload", tag, "--repo", self.repo, str(path))

    def publish(self, tag, prerelease, latest=False):
        self.call("release", "edit", tag, "--repo", self.repo, "--draft=false",
                  f"--prerelease={str(prerelease).lower()}", f"--latest={str(latest).lower()}")

    def delete(self, tag):
        self.call("release", "delete", tag, "--repo", self.repo, "--yes", "--cleanup-tag")


def check_ci(gh, source, branch, run_id=None):
    workflow = gh.api("actions/workflows/ci.yml")
    query = urlencode({"head_sha": source, "branch": branch, "event": "push", "per_page": 100})
    runs = gh.api(f"actions/workflows/ci.yml/runs?{query}")["workflow_runs"]
    matching = [run for run in runs if run.get("workflow_id") == workflow["id"]
                and run.get("head_sha") == source and run.get("head_branch") == branch
                and run.get("event") == "push"]
    require(bool(matching), "candidate requires successful ci.yml push run for exact source SHA and branch")
    newest = max(matching, key=lambda run: int(run["id"]))
    require(not run_id or str(newest["id"]) == str(run_id), "newer CI run exists for candidate source")
    # Get current status: an old successful attempt must not mask a failed rerun.
    run = gh.api(f"actions/runs/{newest['id']}")
    require(run.get("workflow_id") == workflow["id"] and run.get("path") == ".github/workflows/ci.yml"
            and run.get("head_sha") == source and run.get("head_branch") == branch
            and run.get("head_repository", {}).get("full_name") == gh.repo
            and run.get("event") == "push" and run.get("status") == "completed"
            and run.get("conclusion") == "success",
            "candidate requires successful ci.yml push run for exact source SHA and branch")
    return str(run["id"])


def prepare(gh, args):
    require(os.environ.get("GITHUB_RUN_ATTEMPT", "1") == "1", "dispatch a fresh candidate build instead of rerunning uploads")
    require(checkout_sha() == args.source, "checkout HEAD does not match candidate source")
    require(re.fullmatch(r"[1-9]\d*", str(args.run_number)), "run number must be positive")
    data = {"schema": 1, "version": args.version or json.loads(Path("release-please-config.json").read_text())["packages"]["."]["release-as"],
            "build": str(10000 + int(args.run_number)), "source_sha": args.source,
            "source_branch": args.branch, "run_id": str(args.run_id), "ci_run_id": str(args.ci_run_id)}
    data["tag"] = f"candidate-{data['version']}-{data['build']}"
    validate_manifest(data, complete=False)
    require(gh.release(data["tag"]) is None and gh.tag_sha(data["tag"]) is None,
            "candidate already exists; dispatch a fresh build instead of rebuilding its identity")
    check_ci(gh, data["source_sha"], data["source_branch"], data["ci_run_id"])
    data["notes"] = generate_release_notes(gh, data["version"], data["source_sha"])
    write_json(args.output, data)
    return data


def appcast(path, data=None, repo=None, beta=None):
    tree = ET.parse(path)
    items = tree.findall("./channel/item")
    require(bool(items), "appcast contains no updates")
    if data is None:
        result = []
        for item in items:
            enclosure = item.find("enclosure")
            require(enclosure is not None, "appcast item has no enclosure")
            short = item.findtext(f"{{{SPARKLE}}}shortVersionString") or enclosure.get(f"{{{SPARKLE}}}shortVersionString")
            build = item.findtext(f"{{{SPARKLE}}}version") or enclosure.get(f"{{{SPARKLE}}}version")
            require(re.fullmatch(r"[1-9]\d*", build or ""), "appcast build must be numeric")
            result.append((version(short), int(build)))
        return max(result)
    require(len(items) == 1, "candidate appcast must contain exactly one update")
    item = items[0]
    enclosure = item.find("enclosure")
    require(enclosure is not None, "appcast item has no enclosure")
    require(appcast(path) == (version(data["version"]), int(data["build"])), "appcast version/build does not match candidate")
    expected = f"https://github.com/{repo}/releases/download/{data['tag']}/{data['mac']['asset']}"
    require(enclosure.get("url") == expected, "appcast must use permanent candidate asset URL")
    require(enclosure.get("length") == str(data["mac"]["size"]), "appcast size does not match DMG")
    require(len(base64.b64decode(enclosure.get(f"{{{SPARKLE}}}edSignature", ""), validate=True)) == 64,
            "appcast is missing a valid Sparkle EdDSA signature")
    channel = item.findtext(f"{{{SPARKLE}}}channel")
    require(channel == ("beta" if beta else None), "unexpected appcast channel")
    return tree


def immutable_assets(gh, tag, source, paths, prerelease, notes=None, title=None):
    release = gh.release(tag)
    if release is None:
        gh.create(tag, source, prerelease, notes, title)
        release = gh.release(tag)
        require(release is not None, "created release cannot be read")
    require(release["isPrerelease"] == prerelease, "existing release has wrong channel")
    require(title is None or release["name"] == title, "existing release has wrong candidate title")
    ref = gh.tag_sha(tag)
    # GitHub may defer creation of a draft's tag until publication.
    require(ref == source or (ref is None and release["isDraft"] and release.get("targetCommitish") == source), "release tag source does not match candidate")
    names = {asset["name"] for asset in release["assets"]}
    missing = []
    with tempfile.TemporaryDirectory(prefix="yorozu-existing-") as directory:
        for path in map(Path, paths):
            if path.name in names:
                old = gh.download(tag, path.name, directory)
                require(sha256(old) == sha256(path), f"immutable asset differs: {tag}/{path.name}")
            else:
                require(release["isDraft"], f"published release is incomplete: {tag}/{path.name}")
                missing.append(path)
    for path in missing:
        gh.upload(tag, path)
    if release["isDraft"]:
        gh.publish(tag, prerelease, latest=not prerelease)
    require(gh.tag_sha(tag) == source, "published tag does not match candidate source")


def publish_candidate(gh, manifest_path, ios_path, directory):
    directory = Path(directory)
    data = json.loads(Path(manifest_path).read_text())
    validate_manifest(data, complete=False)
    require(checkout_sha() == data["source_sha"], "checkout HEAD does not match candidate source")
    data["ios"] = json.loads(Path(ios_path).read_text())
    asset = "yorozu.dmg"
    dmg = directory / asset
    require(dmg.is_file() and dmg.stat().st_size > 0, f"candidate DMG missing: {dmg}")
    data["mac"] = {"asset": asset, "sha256": sha256(dmg), "size": dmg.stat().st_size,
                   "appcast_sha256": sha256(directory / "appcast.xml")}
    validate_manifest(data)
    appcast(directory / "appcast.xml", data, gh.repo, beta=True)
    check_ci(gh, data["source_sha"], data["source_branch"], data["ci_run_id"])
    check_main_progress(gh, data)
    write_json(directory / "candidate.json", data)
    paths = [directory / name for name in ("candidate.json", asset, "appcast.xml")]
    title = f"Yorozu Beta {data['tag']}" if data["source_branch"] == "main" else f"Yorozu {data['tag']}"
    immutable_assets(gh, data["tag"], data["source_sha"], paths, prerelease=True, notes=data["notes"], title=title)
    if data["source_branch"] == "main":
        remove_old_main_betas(gh, data["tag"])
    return data


def remove_old_main_betas(gh, current_tag):
    pages = gh.api("releases?per_page=100", "--paginate", "--slurp")
    for release in (release for page in pages for release in page):
        tag = release["tag_name"]
        if (tag != current_tag and not release["draft"] and release["prerelease"]
                and CANDIDATE.fullmatch(tag) and release.get("name") == f"Yorozu Beta {tag}"):
            gh.delete(tag)


def fetch(gh, tag, directory):
    require(CANDIDATE.fullmatch(tag), "select a candidate-VERSION-BUILD tag")
    directory = Path(directory)
    release = gh.release(tag)
    require(release is not None and not release["isDraft"] and release["isPrerelease"], "candidate must be a published prerelease")
    data = json.loads(gh.download(tag, "candidate.json", directory).read_text())
    validate_manifest(data)
    require(data["tag"] == tag, "manifest belongs to another candidate")
    require(gh.tag_sha(tag) == data["source_sha"], "candidate tag source does not match manifest")
    check_ci(gh, data["source_sha"], data["source_branch"], data["ci_run_id"])
    for name, digest in ((data["mac"]["asset"], "sha256"), ("appcast.xml", "appcast_sha256")):
        path = gh.download(tag, name, directory)
        require(sha256(path) == data["mac"][digest], f"candidate asset digest mismatch: {name}")
    require((directory / data["mac"]["asset"]).stat().st_size == data["mac"]["size"], "candidate DMG size mismatch")
    appcast(directory / "appcast.xml", data, gh.repo, beta=True)
    return data


def check_main_progress(gh, data):
    """A retained main candidate is also the public beta; reject delayed old builds."""
    if data["source_branch"] != "main":
        return
    pages = gh.api("releases?per_page=100", "--paginate", "--slurp")
    prior = [release for page in pages for release in page
             if not release["draft"] and release["prerelease"]
             and CANDIDATE.fullmatch(release["tag_name"])
             and release.get("name") == f"Yorozu Beta {release['tag_name']}"
             and release["tag_name"] != data["tag"]]
    if not prior:
        return
    latest = max(prior, key=lambda release: (
        version(CANDIDATE.fullmatch(release["tag_name"])[1]),
        int(CANDIDATE.fullmatch(release["tag_name"])[2])))
    tag = latest["tag_name"]
    with tempfile.TemporaryDirectory(prefix="yorozu-beta-source-") as directory:
        previous = json.loads(gh.download(tag, "candidate.json", directory).read_text())
    validate_manifest(previous)
    require(previous["source_branch"] == "main" and previous["tag"] == tag,
            "main beta release has mismatched candidate metadata")
    require(gh.tag_sha(tag) == previous["source_sha"], "main beta tag source does not match manifest")
    require(version(data["version"]) >= version(previous["version"])
            and int(data["build"]) > int(previous["build"]),
            "refusing to move beta backwards in version or build")
    comparison = gh.api(f"compare/{previous['source_sha']}...{data['source_sha']}")
    require(comparison.get("status") in ("ahead", "identical"),
            "refusing to move beta source backwards or across divergent history")


def finish_release_pr(gh, data, publish=False):
    query = urlencode({"state": "closed", "per_page": 100})
    pages = gh.api(f"pulls?{query}", "--paginate", "--slurp")
    major, minor, _ = version(data["version"])
    branches = {"main", f"release/{major}.{minor}"}
    inherited = []
    for pull in (pull for page in pages for pull in page):
        branch = pull.get("base", {}).get("ref")
        if (branch not in branches or not pull.get("merged_at")
                or pull.get("title") != f"chore({branch}): release {data['version']}"
                or not any(label.get("name") == "autorelease: pending" for label in pull.get("labels", []))):
            continue
        merged = pull.get("merge_commit_sha", "")
        require(isinstance(merged, str) and re.fullmatch(r"[0-9a-f]{40}", merged), "release PR has no valid merge commit")
        comparison = gh.api(f"compare/{merged}...{data['source_sha']}")
        ancestor = comparison.get("status") in ("ahead", "identical")
        require(ancestor or branch != data["source_branch"], "candidate source must include release PR merge commit")
        if ancestor:
            inherited.append(pull)
    # A release branch can inherit main's preparation PR. Clear every included
    # preparation only after publication, leaving unrelated branch work pending.
    if publish:
        for pull in inherited:
            gh.call("pr", "edit", pull["number"], "--repo", gh.repo,
                    "--remove-label", "autorelease: pending", "--add-label", "autorelease: tagged")


def promote(gh, tag, directory, expected=None):
    data = fetch(gh, tag, directory)
    require(expected is None or data == expected, "candidate changed after App Store verification")
    for filename in ("version.txt", ".release-please-manifest.json"):
        content = gh.api(f"contents/{filename}?ref={data['source_sha']}")
        text = base64.b64decode(content["content"]).decode().strip()
        actual = json.loads(text).get(".") if filename.endswith(".json") else text
        require(actual == data["version"], "stable candidate must include merged release version metadata")
    finish_release_pr(gh, data)
    directory = Path(directory)
    stable_tag = "v" + data["version"]
    pages = gh.api("releases?per_page=100", "--paginate", "--slurp")
    for release in (release for page in pages for release in page):
        if release["draft"] or release["prerelease"]:
            continue
        previous_tag = release["tag_name"]
        if VERSION.fullmatch(previous_tag.removeprefix("v")) and previous_tag.startswith("v"):
            require(version(previous_tag[1:]) <= version(data["version"]), "refusing to replace a newer stable release")
        names = {asset["name"] for asset in release["assets"]}
        if "appcast.xml" in names:
            with tempfile.TemporaryDirectory(prefix="yorozu-stable-") as old:
                _, previous_build = appcast(gh.download(previous_tag, "appcast.xml", old))
            require(int(data["build"]) > previous_build or previous_tag == stable_tag,
                    "stable candidate build must exceed previously published stable builds")
    # Only feed channel changes. The signed enclosure and binary remain untouched.
    tree = appcast(directory / "appcast.xml", data, gh.repo, beta=True)
    for item in tree.findall("./channel/item"):
        for channel in item.findall(f"{{{SPARKLE}}}channel"):
            item.remove(channel)
    tree.write(directory / "appcast.xml", encoding="utf-8", xml_declaration=True)
    appcast(directory / "appcast.xml", data, gh.repo, beta=False)
    paths = [directory / name for name in ("candidate.json", data["mac"]["asset"], "appcast.xml")]
    immutable_assets(gh, stable_tag, data["source_sha"], paths, prerelease=False, notes=data.get("notes"))
    finish_release_pr(gh, data, publish=True)
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default=os.environ.get("PUBLIC", "izyuumi/yorozu"))
    commands = parser.add_subparsers(dest="command", required=True)
    prepare_parser = commands.add_parser("prepare")
    for name in ("source", "branch", "run-number", "run-id", "ci-run-id"):
        prepare_parser.add_argument("--" + name, required=True)
    prepare_parser.add_argument("--version")
    prepare_parser.add_argument("--output", default="dist/candidate.json")
    ci = commands.add_parser("check-ci")
    ci.add_argument("--source", required=True)
    ci.add_argument("--branch", required=True)
    ci.add_argument("--run-id")
    candidate = commands.add_parser("candidate")
    candidate.add_argument("--manifest", default="dist/candidate.json")
    candidate.add_argument("--ios", default="dist/ios.json")
    candidate.add_argument("--dist", default="dist")
    for command in ("fetch", "promote"):
        sub = commands.add_parser(command)
        sub.add_argument("--candidate", required=True)
        sub.add_argument("--dist", default=f"dist/{command}")
    args = parser.parse_args()
    gh = GitHub(args.repo)
    if args.command == "check-ci":
        print(check_ci(gh, args.source, args.branch, args.run_id))
        return
    if args.command == "prepare":
        result = prepare(gh, args)
    elif args.command == "candidate":
        result = publish_candidate(gh, args.manifest, args.ios, args.dist)
    elif args.command == "promote":
        expected = fetch(gh, args.candidate, args.dist)
        subprocess.run(["node", "scripts/asc-candidate.mjs", "verify", str(Path(args.dist) / "candidate.json")], check=True)
        result = promote(gh, args.candidate, args.dist, expected=expected)
    else:
        result = fetch(gh, args.candidate, args.dist)
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, RuntimeError, OSError, KeyError, TypeError, ET.ParseError, subprocess.CalledProcessError) as error:
        sys.exit(f"release refused: {error}")

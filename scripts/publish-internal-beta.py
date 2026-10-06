#!/usr/bin/env python3
"""Publish verified internal Mac artifacts as an immutable alpha, never a feed/stable/IPA."""
import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
from pathlib import Path
import re
import tempfile

spec = importlib.util.spec_from_file_location("release_publication", Path(__file__).with_name("release.py"))
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)
require = release.require
REPOSITORY = "izyuumi/yorozu"
GROUP = "954b8070-0ad9-4112-a061-2001bdc150b7"
APP = "6811274963"


# These are the branches for which ci.yml runs the assembled internal lane.
INTERNAL_BRANCHES = {"harness-plugins", "integration-0.6-worker", "v0.6.0-alpha"}


def check_source(gh, source, branch, run_id=None):
    """Read-only gate shared by pre-signing checks and alpha publication."""
    require(gh.repo == REPOSITORY, "Wrong internal source repository")
    require(re.fullmatch(r"[0-9a-f]{40}", source or ""), "Exact internal source SHA is required")
    require(branch in INTERNAL_BRANCHES, "Source branch must run the isolated internal CI lane")
    if run_id is not None:
        require(re.fullmatch(r"[1-9]\d*", str(run_id)), "Exact CI run identity is required")
    ref = gh.api("git/ref/heads/" + branch)
    require(ref.get("object", {}).get("type") == "commit" and ref["object"].get("sha") == source,
            "Internal source branch moved after review")
    ci = release.check_ci(gh, source, branch, run_id)
    result = gh.api(f"actions/runs/{ci}/jobs?filter=latest&per_page=100")
    jobs = result.get("jobs", [])
    require(result.get("total_count") == len(jobs), "Incomplete internal CI job evidence")
    for name in ("internal-secretary", "release-checks", "ios"):
        matching = [job for job in jobs if job.get("name") == name]
        require(len(matching) == 1 and matching[0].get("status") == "completed"
                and matching[0].get("conclusion") == "success",
                "Internal CI job must complete successfully: " + name)
    return ci


def publish(gh, root, expected_source, expected_run, availability, now=None):
    require(gh.repo == REPOSITORY, "Alpha target must be the existing Yorozu repository")
    require(os.environ.get("GITHUB_RUN_ATTEMPT", "1") == "1", "Use a fresh release run, not a partial rerun")
    require(re.fullmatch(r"[0-9a-f]{40}", expected_source or ""), "Expected exact source SHA is required")
    require(re.fullmatch(r"[1-9]\d*", str(expected_run)), "Expected workflow run is required")
    root = Path(root).resolve(strict=True)
    data = json.loads((root / "provenance.json").read_text())
    require(data.get("source_sha") == expected_source and str(data.get("workflow_run_id")) == str(expected_run), "Artifacts belong to another source or workflow run")
    require(data.get("version") == "0.6.0" and data.get("internal_only") is True, "Only the internal 0.6 candidate can use this alpha lane")
    branch = data.get("source_branch", "")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", branch) and ".." not in branch
            and branch != "main" and not branch.startswith("release/"), "Alpha source must be the isolated reviewed branch")
    build = str(data.get("mac_build", ""))
    require(re.fullmatch(r"[1-9]\d*", build) and int(build) > 10000, "Invalid global Mac build number")
    ios = json.loads(Path(availability).read_text())
    require(ios.get("app_id") == APP and ios.get("group_id") == GROUP and ios.get("version") == "0.6.0"
            and ios.get("internal_only") is True and ios.get("available") is True
            and ios.get("internal_state") == "IN_BETA_TESTING", "Internal TestFlight availability has not been verified")
    previous = data.get("ios", {})
    require(all(ios.get(k) == previous.get(k) for k in ("build_id", "build", "uploaded_date", "app_id", "group_id", "version")), "TestFlight receipt does not identify this candidate")
    verified = datetime.fromisoformat(ios["verified_at"].replace("Z", "+00:00"))
    now = now or datetime.now(timezone.utc)
    require(0 <= (now - verified).total_seconds() <= 600, "Reverify TestFlight availability immediately before alpha publication")
    required = {"Yorozu.app.zip", "mac/Yorozu.dmg"}
    rows = data.get("artifacts", [])
    paths = {}
    for name in required:
        matches = [row for row in rows if row.get("path") == name]
        require(len(matches) == 1, "Required Mac artifact is missing or duplicated")
        row = matches[0]
        path = root / name
        require(path.is_file() and not path.is_symlink() and path.resolve().is_relative_to(root), "Unsafe Mac artifact path")
        require(type(row.get("size")) is int and row["size"] > 0 and path.stat().st_size == row["size"]
                and release.sha256(path) == row.get("sha256"), "Mac artifact differs from signed-release provenance")
        paths[name] = path
    require(re.fullmatch(r"[1-9]\d*", str(data.get("ci_run_id", ""))), "Exact CI run identity is required")
    ci = check_source(gh, expected_source, branch, str(data.get("ci_run_id", "")))
    intake = data.get("runtime_intake", {})
    require(all(re.fullmatch(r"[0-9a-f]{64}", str(intake.get(k, ""))) for k in
                ("receiptSha256", "archiveSha256", "unsignedInventorySha256", "signedInventorySha256", "archiveProvenanceSha256")), "Runtime intake binding is missing")
    tag = "v0.6.0-alpha." + build
    # Public metadata deliberately excludes Apple recipient/account IDs and the IPA.
    metadata = {"schemaVersion": 1, "channel": "alpha", "tag": tag, "version": "0.6.0", "macBuild": build,
                "sourceSha": expected_source, "ciRunId": ci, "releaseRunId": str(expected_run),
                "internalTestFlightVerified": True, "iosBuild": ios["build"],
                "sparkleFeedChanged": False, "installationPerformed": False, "runtimeIntake": intake,
                "openclawRuntimeIntake": data.get("openclaw_runtime_intake", {}),
                "artifacts": [{"name": path.name, "sha256": release.sha256(path), "size": path.stat().st_size}
                              for _, path in sorted(paths.items())]}
    notes = ("Non-stable Yorozu 0.6 evaluation build. Mac download only; iOS is available through the existing internal TestFlight group.\n\n"
             "This release does not update the stable or beta Sparkle feeds and does not install over an existing Mac app. "
             "Preserve your existing installation and data/rollback path. Unsupported OpenClaw features remain disabled; "
             "live two-harness messaging and account onboarding are not claimed as proven. "
             "This alpha does not supply the required accounts-helper provisioning profile: "
             "SIWC account-helper capability and person-agent SIWC inference are unavailable. "
             "Packaging the helper is not account activation; enabling it requires separately authorized provisioning and native verification.\n\n"
             f"Source: {expected_source}\nCI: https://github.com/{REPOSITORY}/actions/runs/{ci}\n"
             f"Release: https://github.com/{REPOSITORY}/actions/runs/{expected_run}\n")
    with tempfile.TemporaryDirectory(prefix="yorozu-alpha-metadata-") as directory:
        # Legacy asset filename/schema retained; consumers must read channel, not infer it.
        manifest = Path(directory) / "beta.json"
        manifest.write_text(json.dumps(metadata, indent=2) + "\n")
        assets = [paths["mac/Yorozu.dmg"], paths["Yorozu.app.zip"], manifest]
        title = f"Yorozu 0.6.0 Alpha (Mac {build})"
        remote = gh.release(tag)
        if remote is None:
            gh.create(tag, expected_source, True, notes, title)
            remote = gh.release(tag)
        require(remote is not None and remote["isPrerelease"] and remote["name"] == title, "Wrong existing alpha identity")
        ref = gh.tag_sha(tag)
        require(ref == expected_source or (ref is None and remote["isDraft"] and remote.get("targetCommitish") == expected_source), "Wrong existing alpha source")
        expected_names = {p.name for p in assets}
        existing_names = {a["name"] for a in remote["assets"]}
        require(existing_names <= expected_names, "Unexpected existing alpha assets")
        for asset in assets:
            if asset.name not in existing_names:
                require(remote["isDraft"], "Published alpha is incomplete")
                gh.upload(tag, asset)
        remote = gh.release(tag)
        require({a["name"] for a in remote["assets"]} == expected_names, "Unexpected alpha asset set")
        with tempfile.TemporaryDirectory(prefix="yorozu-alpha-prepublish-") as verify_dir:
            for asset in assets:
                require(release.sha256(gh.download(tag, asset.name, verify_dir)) == release.sha256(asset), "Uploaded alpha bytes differ before publication")
        if remote["isDraft"]:
            gh.publish(tag, True, latest=False)
        require(gh.tag_sha(tag) == expected_source, "Published alpha source differs")
        remote = gh.release(tag)
        require(remote is not None and remote["isPrerelease"] and not remote["isDraft"], "Alpha is not published")
        require({a["name"] for a in remote["assets"]} == expected_names, "Unexpected published alpha asset set")
        with tempfile.TemporaryDirectory(prefix="yorozu-alpha-verify-") as verify_dir:
            for asset in assets:
                actual = gh.download(tag, asset.name, verify_dir)
                require(release.sha256(actual) == release.sha256(asset), "Published alpha artifact verification failed")
    return {"available": True, "tag": tag, "url": f"https://github.com/{REPOSITORY}/releases/tag/{tag}",
            "sourceSha": expected_source, "macBuild": build, "iosBuild": ios["build"], "stableChanged": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check-source", action="store_true", help="Read-only branch and CI gate; no release or Apple writes")
    parser.add_argument("--branch")
    parser.add_argument("--ci-run-id")
    parser.add_argument("--dist", type=Path)
    parser.add_argument("--source", required=True)
    parser.add_argument("--run-id")
    parser.add_argument("--availability", type=Path)
    args = parser.parse_args()
    if args.check_source:
        require(args.branch and not any((args.dist, args.run_id, args.availability)), "Read-only source check requires only source, branch and optional CI run")
        print(check_source(release.GitHub(REPOSITORY), args.source, args.branch, args.ci_run_id))
    else:
        require(args.dist and args.run_id and args.availability and not args.branch and not args.ci_run_id,
                "Publication requires dist, source, run-id and availability")
        print(json.dumps(publish(release.GitHub(REPOSITORY), args.dist, args.source, args.run_id, args.availability)))


if __name__ == "__main__":
    main()

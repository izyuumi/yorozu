#!/usr/bin/env python3
"""Publication regression checks using local bytes and a fake GitHub command seam."""

import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("publication", Path(__file__).with_name("release.py"))
publication = importlib.util.module_from_spec(spec)
spec.loader.exec_module(publication)
SHA = "0123456789abcdef0123456789abcdef01234567"
OTHER = "a" * 40
SIGNATURE = base64.b64encode(b"s" * 64).decode()


def feed(version="0.5.0", build="10042", tag=None):
    tag = tag or f"candidate-{version}-{build}"
    return (f'<rss xmlns:sparkle="{publication.SPARKLE}"><channel><item>'
            f'<sparkle:version>{build}</sparkle:version>'
            f'<sparkle:shortVersionString>{version}</sparkle:shortVersionString>'
            '<sparkle:channel>beta</sparkle:channel>'
            f'<enclosure url="https://github.com/fixture/yorozu/releases/download/{tag}/Yorozu-{version}-{build}.dmg" '
            f'length="10" sparkle:edSignature="{SIGNATURE}"/>'
            '</item></channel></rss>').encode()


class FakeGitHub(publication.GitHub):
    def __init__(self):
        super().__init__("fixture/yorozu")
        self.releases = {}
        self.tags = {}
        self.events = []
        self.fail_upload = None
        self.fail_publish = False
        self.source_version = "0.5.0"
        self.pulls = []
        self.compare_status = "ahead"
        self.runs = {"7": {"id": 7, "workflow_id": 9, "path": ".github/workflows/ci.yml", "head_sha": SHA,
                           "head_branch": "main", "head_repository": {"full_name": self.repo}, "event": "push",
                           "status": "completed", "conclusion": "success"}}

    def add_release(self, tag, assets=None, *, draft=False, prerelease=False, source=SHA):
        self.releases[tag] = {"tagName": tag, "isDraft": draft, "isPrerelease": prerelease, "targetCommitish": source, "files": assets or {}}
        self.tags[tag] = source

    def call(self, *args, optional=False):
        args = tuple(map(str, args))
        self.events.append(args)
        if args[0] == "api":
            endpoint = args[1].removeprefix(f"repos/{self.repo}/")
            if endpoint == "actions/workflows/ci.yml":
                result = {"id": 9}
            elif endpoint.startswith("actions/runs/"):
                result = self.runs[endpoint.rsplit("/", 1)[-1]]
            elif endpoint.startswith("actions/workflows/ci.yml/runs?"):
                result = {"workflow_runs": list(self.runs.values())}
            elif endpoint.startswith("git/ref/tags/"):
                tag = endpoint.removeprefix("git/ref/tags/")
                if tag not in self.tags:
                    assert optional
                    return None
                result = {"object": {"type": "commit", "sha": self.tags[tag]}}
            elif endpoint == "releases?per_page=100":
                result = [[{"tag_name": tag, "draft": release["isDraft"], "prerelease": release["isPrerelease"],
                            "assets": [{"name": name} for name in release["files"]]}
                           for tag, release in self.releases.items()]]
            elif endpoint.startswith("pulls?"):
                result = [self.pulls]
            elif endpoint.startswith("contents/"):
                value = json.dumps({".": self.source_version}) if ".json?" in endpoint else self.source_version
                result = {"content": base64.b64encode(value.encode()).decode()}
            elif endpoint.startswith("compare/"):
                result = {"status": self.compare_status}
            else:
                raise AssertionError(f"unexpected API request: {args}")
            return json.dumps(result)
        if args[0:2] == ("pr", "edit"):
            for pull in self.pulls:
                pull["labels"] = [{"name": "autorelease: tagged"}]
            return ""
        assert args[0] == "release", args
        action, tag = args[1:3]
        if action == "view":
            if tag not in self.releases:
                assert optional
                return None
            release = self.releases[tag]
            return json.dumps({**{k: v for k, v in release.items() if k != "files"},
                               "assets": [{"name": name} for name in release["files"]]})
        if action == "create":
            assert tag not in self.releases
            assert "--draft" in args and "--latest=false" in args
            self.add_release(tag, draft=True, prerelease="--prerelease" in args,
                             source=args[args.index("--target") + 1])
        elif action == "download":
            name = args[args.index("--pattern") + 1]
            path = Path(args[args.index("--dir") + 1]) / name
            path.write_bytes(self.releases[tag]["files"][name])
        elif action == "upload":
            path = Path(args[5])
            if self.fail_upload == path.name:
                raise RuntimeError("simulated upload failure")
            files = self.releases[tag]["files"]
            assert path.name not in files or "--clobber" in args, "immutable upload attempted replacement"
            files[path.name] = path.read_bytes()
        elif action == "edit":
            if self.fail_publish:
                raise RuntimeError("simulated publish failure")
            self.releases[tag]["isDraft"] = False
            self.releases[tag]["isPrerelease"] = "--prerelease=true" in args
        else:
            raise AssertionError(f"unexpected mutation: {args}")
        return ""


class ReleaseFixture(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="yorozu-publication-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.dist = self.root / "dist"
        self.dist.mkdir()
        (self.root / "catalog").mkdir()
        (self.root / "catalog/models.json").write_text('{"models": []}\n')
        (self.root / "release-version.txt").write_text("0.5.0\n")
        self.original_cwd = Path.cwd()
        os.chdir(self.root)
        self.addCleanup(os.chdir, self.original_cwd)
        self.gh = FakeGitHub()
        checkout = patch.object(publication, "checkout_sha", return_value=SHA)
        checkout.start()
        self.addCleanup(checkout.stop)
        self.data = {"schema": 1, "version": "0.5.0", "build": "10042", "source_sha": SHA,
                     "source_branch": "main", "tag": "candidate-0.5.0-10042", "run_id": "42", "ci_run_id": "7"}
        self.ios = {"app_id": "123", "build_id": "a-b-c", "version": "0.5.0", "build": "10042",
                    "uploaded_date": "2026-09-24T00:00:00Z"}
        self.tag = self.data["tag"]
        publication.write_json(self.dist / "candidate.json", self.data)
        publication.write_json(self.dist / "ios.json", self.ios)
        (self.dist / "Yorozu-0.5.0-10042.dmg").write_bytes(b"signed DMG")
        (self.dist / "appcast.xml").write_bytes(feed())

    def publish(self):
        return publication.publish_candidate(self.gh, self.dist / "candidate.json", self.dist / "ios.json", self.dist)

    def promote(self):
        return publication.promote(self.gh, self.tag, self.root / "promotion")

    def mutations(self):
        return [event for event in self.gh.events if event[:2] in (("release", "upload"), ("release", "create"), ("release", "edit"))]


class ReleaseTests(ReleaseFixture):
    def test_exact_artifact_promotion_retains_every_release_and_tag(self):
        self.gh.add_release("v0.4.0", {"appcast.xml": feed("0.4.0", "10001")})
        self.publish()
        original = copy.deepcopy(self.gh.releases[self.tag])
        self.promote()
        self.assertEqual(set(self.gh.releases), {"v0.4.0", self.tag, "v0.5.0"})
        stable = self.gh.releases["v0.5.0"]
        self.assertFalse(stable["isDraft"] or stable["isPrerelease"])
        self.assertEqual(stable["files"]["Yorozu.dmg"], b"signed DMG")
        self.assertEqual(stable["files"]["candidate.json"], original["files"]["candidate.json"])
        self.assertNotIn(b"sparkle:channel", stable["files"]["appcast.xml"])
        self.assertIn(self.tag.encode(), stable["files"]["appcast.xml"])
        self.assertIn(SIGNATURE.encode(), stable["files"]["appcast.xml"])
        self.assertEqual(self.gh.releases[self.tag], original)
        self.assertEqual(self.gh.tags["v0.5.0"], SHA)
        self.assertFalse(any("--clobber" in event for event in self.mutations()))

    def test_promotion_retry_is_read_only(self):
        self.publish()
        self.promote()
        self.gh.events.clear()
        self.promote()
        self.assertEqual(self.mutations(), [])

    def test_partial_draft_retry_never_replaces_existing_assets(self):
        self.publish()
        self.gh.fail_upload = "appcast.xml"
        with self.assertRaisesRegex(RuntimeError, "upload failure"):
            self.promote()
        self.assertTrue(self.gh.releases["v0.5.0"]["isDraft"])
        self.gh.fail_upload = None
        self.gh.events.clear()
        self.promote()
        uploads = [event[5] for event in self.gh.events if event[:2] == ("release", "upload")]
        self.assertEqual([Path(path).name for path in uploads], ["appcast.xml", "models.json"])

    def test_digest_or_tag_mismatch_blocks_promotion_before_mutation(self):
        self.publish()
        for corrupt in ("digest", "tag"):
            with self.subTest(corrupt=corrupt):
                saved = copy.deepcopy((self.gh.releases, self.gh.tags))
                if corrupt == "digest":
                    self.gh.releases[self.tag]["files"]["Yorozu-0.5.0-10042.dmg"] = b"replacement"
                else:
                    self.gh.tags[self.tag] = OTHER
                self.gh.events.clear()
                with self.assertRaisesRegex(ValueError, "digest mismatch|source does not match"):
                    self.promote()
                self.assertEqual(self.mutations(), [])
                self.gh.releases, self.gh.tags = saved

    def test_newer_stable_version_or_build_blocks_promotion(self):
        self.publish()
        for tag, short, build in (("v0.6.0", "0.6.0", "10001"), ("v0.4.9", "0.4.9", "10099")):
            with self.subTest(tag=tag):
                self.gh.add_release(tag, {"appcast.xml": feed(short, build)})
                self.gh.events.clear()
                with self.assertRaisesRegex(ValueError, "newer stable|must exceed"):
                    self.promote()
                self.assertEqual(self.mutations(), [])
                del self.gh.releases[tag]

    def test_existing_stable_tag_cannot_be_reassigned(self):
        self.publish()
        self.gh.tags["v0.5.0"] = OTHER
        self.gh.events.clear()
        with self.assertRaisesRegex(ValueError, "another commit"):
            self.promote()
        self.assertEqual(self.mutations(), [])

    def test_candidate_requires_pinned_signed_feed_and_matching_ios(self):
        good = (self.dist / "appcast.xml").read_bytes()
        for bad in (good.replace(self.tag.encode(), b"main-beta"), good.replace(SIGNATURE.encode(), b"")):
            with self.subTest(feed=bad):
                (self.dist / "appcast.xml").write_bytes(bad)
                with self.assertRaises(ValueError):
                    self.publish()
                self.assertEqual(self.mutations(), [])
        (self.dist / "appcast.xml").write_bytes(good)
        publication.write_json(self.dist / "ios.json", {**self.ios, "build": "10043"})
        with self.assertRaisesRegex(ValueError, "iOS version/build"):
            self.publish()
        self.assertEqual(self.mutations(), [])

    def test_existing_published_candidate_is_identical_or_rejected(self):
        self.publish()
        self.gh.events.clear()
        self.publish()
        self.assertEqual(self.mutations(), [])
        (self.dist / "Yorozu-0.5.0-10042.dmg").write_bytes(b"other DMG!")
        with self.assertRaisesRegex(ValueError, "immutable asset differs"):
            self.publish()
        self.assertEqual(self.mutations(), [])

    def test_ci_requires_real_workflow_exact_source_branch_and_success(self):
        original = copy.deepcopy(self.gh.runs["7"])
        for key, bad in (("workflow_id", 99), ("path", ".github/workflows/fake.yml"), ("head_sha", OTHER),
                         ("head_branch", "release/0.5"), ("event", "pull_request"), ("conclusion", "failure"),
                         ("status", "in_progress"), ("head_repository", {"full_name": "fork/yorozu"})):
            with self.subTest(key=key):
                self.gh.runs["7"] = {**original, key: bad}
                with self.assertRaisesRegex(ValueError, "successful ci.yml"):
                    publication.check_ci(self.gh, SHA, "main", "7")
        self.gh.runs["7"] = original
        self.assertEqual(publication.check_ci(self.gh, SHA, "main"), "7")

    def test_prepare_deterministic_version_build_and_existing_identity_refusal(self):
        args = SimpleNamespace(version=None, source=SHA, branch="main", run_number="42", run_id="42",
                               ci_run_id="7", output=self.dist / "prepared.json")
        with patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "1"}):
            result = publication.prepare(self.gh, args)
            self.assertEqual((result["version"], result["build"], result["tag"]), ("0.5.0", "10042", self.tag))
            self.gh.tags[self.tag] = SHA
            with self.assertRaisesRegex(ValueError, "already exists"):
                publication.prepare(self.gh, args)

    def test_prepare_reruns_and_checkout_source_mismatch_fail_before_mutation(self):
        args = SimpleNamespace(version=None, source=SHA, branch="main", run_number="42", run_id="42",
                               ci_run_id="7", output=self.dist / "prepared.json")
        with patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "2"}):
            with self.assertRaisesRegex(ValueError, "fresh candidate"):
                publication.prepare(self.gh, args)
        with patch.object(publication, "checkout_sha", return_value=OTHER):
            with self.assertRaisesRegex(ValueError, "checkout HEAD"):
                self.publish()
        self.assertEqual(self.mutations(), [])

    def test_newer_failed_ci_run_blocks_old_success(self):
        self.gh.runs["8"] = {**self.gh.runs["7"], "id": 8, "conclusion": "failure"}
        with self.assertRaisesRegex(ValueError, "newer CI"):
            publication.check_ci(self.gh, SHA, "main", "7")
        with self.assertRaisesRegex(ValueError, "successful ci.yml"):
            publication.check_ci(self.gh, SHA, "main")

    def test_unmerged_version_metadata_or_changed_verified_candidate_blocks_promotion(self):
        data = self.publish()
        self.gh.events.clear()
        self.gh.source_version = "0.4.0"
        with self.assertRaisesRegex(ValueError, "merged release version"):
            self.promote()
        self.gh.source_version = "0.5.0"
        with self.assertRaisesRegex(ValueError, "changed after App Store"):
            publication.promote(self.gh, self.tag, self.root / "promotion", expected={**data, "run_id": "99"})
        self.assertEqual(self.mutations(), [])

    def test_release_pr_ancestry_checked_before_publish_and_label_updated_after(self):
        self.publish()
        self.gh.pulls = [{"number": 123, "merged_at": "2026-09-24", "title": "chore(main): release 0.5.0",
                          "merge_commit_sha": OTHER, "labels": [{"name": "autorelease: pending"}]}]
        self.gh.compare_status = "diverged"
        self.gh.events.clear()
        with self.assertRaisesRegex(ValueError, "include release PR"):
            self.promote()
        self.assertEqual(self.mutations(), [])
        self.gh.compare_status = "ahead"
        self.promote()
        edit = next(event for event in self.gh.events if event[:2] == ("pr", "edit"))
        publish = next(event for event in self.gh.events if event[:3] == ("release", "edit", "v0.5.0"))
        self.assertLess(self.gh.events.index(publish), self.gh.events.index(edit))
        self.assertEqual(self.gh.pulls[0]["labels"], [{"name": "autorelease: tagged"}])

    def test_cli_checks_asc_before_any_stable_mutation(self):
        self.publish()
        self.gh.events.clear()
        args = ["release.py", "promote", "--candidate", self.tag, "--dist", str(self.root / "promotion")]
        with patch.object(publication.sys, "argv", args), patch.object(publication, "GitHub", return_value=self.gh):
            with patch.object(publication.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "asc")) as verify:
                with self.assertRaises(subprocess.CalledProcessError):
                    publication.main()
                self.assertEqual(verify.call_args.args[0], ["node", "scripts/asc-candidate.mjs", "verify",
                                                           str(self.root / "promotion/candidate.json")])
        self.assertEqual(self.mutations(), [])

    def test_draft_without_tag_requires_exact_target_commit(self):
        self.publish()
        self.gh.add_release("v0.5.0", draft=True, source=OTHER)
        del self.gh.tags["v0.5.0"]
        self.gh.events.clear()
        with self.assertRaisesRegex(ValueError, "source does not match"):
            self.promote()
        self.assertEqual(self.mutations(), [])

    def test_release_branch_must_match_train(self):
        publication.validate_manifest({**self.data, "source_branch": "release/0.5"}, complete=False)
        with self.assertRaisesRegex(ValueError, "matching version"):
            publication.validate_manifest({**self.data, "source_branch": "release/0.4"}, complete=False)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Beta-only publication contract tests with fake GitHub and local inert bytes."""
from datetime import datetime, timezone
import importlib.util
import json
import os
import sys
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


beta = load("internal_beta", "publish-internal-beta.py")
fixtures = load("release_test_seam", "test-release.py")
SHA = fixtures.SHA
NOW = datetime(2026, 10, 6, tzinfo=timezone.utc)


class InternalGitHub(fixtures.FakeGitHub):
    def __init__(self):
        super().__init__()
        self.head = SHA
        self.jobs = [{"name": name, "status": "completed", "conclusion": "success"}
                     for name in ("internal-secretary", "release-checks", "ios")]

    def api(self, path, *args, **kwargs):
        if path.startswith("git/ref/heads/"):
            self.events.append(("api", path))
            return {"object": {"type": "commit", "sha": self.head}}
        if path.endswith("/jobs?filter=latest&per_page=100"):
            self.events.append(("api", path))
            return {"total_count": len(self.jobs), "jobs": self.jobs}
        return super().api(path, *args, **kwargs)


class BetaTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="yorozu-beta-test-")
        self.root = Path(self.temp.name)
        (self.root / "mac").mkdir()
        (self.root / "mac/Yorozu.dmg").write_bytes(b"signed DMG fixture")
        (self.root / "Yorozu.app.zip").write_bytes(b"signed app fixture")
        self.ios = {"app_id": beta.APP, "group_id": beta.GROUP, "version": "0.6.0", "build": "3",
                    "build_id": "fixture-ios-build", "uploaded_date": "2026-10-05T23:00:00Z", "internal_only": True,
                    "available": True, "internal_state": "IN_BETA_TESTING", "verified_at": NOW.isoformat()}
        self.data = {"source_sha": SHA, "source_branch": "harness-plugins", "workflow_run_id": "8", "ci_run_id": "7",
                     "version": "0.6.0", "internal_only": True, "mac_build": "10267", "ios": dict(self.ios),
                     "artifacts": [{"path": n, "sha256": beta.release.sha256(self.root / n), "size": (self.root / n).stat().st_size}
                                   for n in ("mac/Yorozu.dmg", "Yorozu.app.zip")]}
        self.data["runtime_intake"] = {k: "a" * 64 for k in ("receiptSha256", "archiveSha256", "unsignedInventorySha256", "signedInventorySha256", "archiveProvenanceSha256")}
        self.gh = InternalGitHub()
        self.gh.repo = beta.REPOSITORY
        self.gh.runs["7"].update(head_branch="harness-plugins", head_repository={"full_name": beta.REPOSITORY})
        self.tag = "v0.6.0-beta.10267"
        self.environment = patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "1"})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.temp.cleanup()

    def publish(self):
        (self.root / "provenance.json").write_text(json.dumps(self.data))
        receipt = self.root / "availability-fresh.json"
        receipt.write_text(json.dumps(self.ios))
        return beta.publish(self.gh, self.root, SHA, "8", receipt, now=NOW)

    def test_only_nonlatest_beta_mac_assets_are_published_and_read_back(self):
        result = self.publish()
        self.assertTrue(result["available"])
        remote = self.gh.releases[self.tag]
        self.assertTrue(remote["isPrerelease"])
        self.assertFalse(remote["isDraft"])
        self.assertEqual(set(remote["files"]), {"Yorozu.dmg", "Yorozu.app.zip", "beta.json"})
        self.assertFalse(any(event[:2] == ("release", "delete") for event in self.gh.events))
        self.assertFalse(any("--latest=true" in event for event in self.gh.events))
        self.assertGreaterEqual(sum(event[:2] == ("release", "download") for event in self.gh.events), 3)
        metadata = json.loads(remote["files"]["beta.json"])
        self.assertNotIn("group_id", metadata)
        self.assertFalse(metadata["sparkleFeedChanged"])
        self.assertFalse(metadata["installationPerformed"])

    def test_repeat_only_verifies_identical_assets(self):
        self.publish()
        self.gh.events.clear()
        self.publish()
        self.assertFalse(any(event[:2] in [("release", "create"), ("release", "upload"), ("release", "edit"), ("release", "delete")] for event in self.gh.events))

    def test_stale_or_wrong_internal_availability_blocks_all_publication(self):
        for key, value in [("group_id", "other"), ("internal_only", False), ("available", False),
                           ("internal_state", "PROCESSING"), ("verified_at", "2026-10-05T23:00:00Z")]:
            saved = self.ios[key]
            self.ios[key] = value
            with self.assertRaises(ValueError):
                self.publish()
            self.ios[key] = saved
            self.assertFalse(self.gh.releases)

    def test_artifact_tampering_and_wrong_source_are_rejected(self):
        (self.root / "mac/Yorozu.dmg").write_bytes(b"different")
        with self.assertRaisesRegex(ValueError, "artifact differs"):
            self.publish()
        self.assertFalse(self.gh.releases)
        self.data["source_sha"] = "b" * 40
        with self.assertRaisesRegex(ValueError, "another source"):
            self.publish()

    def test_partial_rerun_is_refused(self):
        with patch.dict(os.environ, {"GITHUB_RUN_ATTEMPT": "2"}):
            with self.assertRaisesRegex(ValueError, "partial rerun"):
                self.publish()
        self.assertFalse(self.gh.releases)

    def test_beta_identity_is_never_replaced(self):
        self.gh.add_release(self.tag, prerelease=True, source="c" * 40)
        with self.assertRaises(ValueError):
            self.publish()
        self.assertFalse(any(event[:2] == ("release", "delete") for event in self.gh.events))

    def test_check_source_cli_never_enters_publication(self):
        with patch.object(sys, "argv", ["publish-internal-beta.py", "--check-source", "--source", SHA,
                                       "--branch", "harness-plugins", "--ci-run-id", "7"]), \
             patch.object(beta.release, "GitHub", return_value=self.gh), \
             patch.object(beta, "publish") as publish:
            beta.main()
            publish.assert_not_called()
        self.assertTrue(all(event[0] == "api" for event in self.gh.events))

    def test_readonly_source_gate_and_branch_policy(self):
        self.assertEqual(beta.check_source(self.gh, SHA, "harness-plugins", "7"), "7")
        self.assertTrue(all(event[0] == "api" for event in self.gh.events))
        for branch in ("main", "release/0.6", "unwired-internal", "harness-plugins/../main"):
            with self.assertRaisesRegex(ValueError, "isolated internal CI"):
                beta.check_source(self.gh, SHA, branch, "7")
        self.gh.head = "b" * 40
        with self.assertRaisesRegex(ValueError, "moved after review"):
            self.publish()
        self.assertFalse(self.gh.releases)

    def test_skipped_or_missing_internal_jobs_refuse_publication(self):
        for job in self.gh.jobs:
            job["conclusion"] = "skipped"
            with self.assertRaisesRegex(ValueError, "CI job"):
                self.publish()
            job["conclusion"] = "success"
        self.gh.jobs.pop(0)
        with self.assertRaisesRegex(ValueError, "CI job"):
            self.publish()
        self.assertFalse(self.gh.releases)

    def test_missing_ci_pin_or_newer_run_refuses_publication(self):
        self.data.pop("ci_run_id")
        with self.assertRaisesRegex(ValueError, "CI run identity"):
            self.publish()
        self.data["ci_run_id"] = "7"
        self.gh.runs["8"] = {**self.gh.runs["7"], "id": 8}
        with self.assertRaisesRegex(ValueError, "newer CI run"):
            self.publish()
        self.assertFalse(self.gh.releases)

    def test_extra_draft_ipa_is_never_published(self):
        self.gh.add_release(self.tag, {"x.ipa": b"not public"}, draft=True, prerelease=True,
                            name="Yorozu 0.6.0 Beta (Mac 10267)")
        with self.assertRaisesRegex(ValueError, "Unexpected existing beta assets"):
            self.publish()
        self.assertTrue(self.gh.releases[self.tag]["isDraft"])
        self.assertFalse(any(event[:2] == ("release", "edit") for event in self.gh.events))

    def test_corrupt_upload_stays_draft(self):
        upload = self.gh.upload
        def corrupt(tag, path):
            upload(tag, path)
            self.gh.releases[tag]["files"][path.name] = b"corrupt"
        with patch.object(self.gh, "upload", side_effect=corrupt):
            with self.assertRaisesRegex(ValueError, "before publication"):
                self.publish()
        self.assertTrue(self.gh.releases[self.tag]["isDraft"])

    def test_post_publish_asset_set_is_rechecked(self):
        publish = self.gh.publish
        def extra(tag, prerelease, latest=False):
            publish(tag, prerelease, latest=latest)
            self.gh.releases[tag]["files"]["extra"] = b"unexpected"
        with patch.object(self.gh, "publish", side_effect=extra):
            with self.assertRaisesRegex(ValueError, "Unexpected published beta asset set"):
                self.publish()

    def test_non_successful_ci_cannot_publish(self):
        self.gh.runs["7"]["conclusion"] = "failure"
        with self.assertRaisesRegex(ValueError, "successful ci"):
            self.publish()
        self.assertFalse(self.gh.releases)


if __name__ == "__main__":
    unittest.main()

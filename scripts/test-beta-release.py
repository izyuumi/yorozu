#!/usr/bin/env python3
"""Rolling pointer checks reuse the exact candidate fixture from publication tests."""

import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("release_tests", Path(__file__).with_name("test-release.py"))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
publication = fixtures.publication


class BetaReleaseTests(fixtures.ReleaseFixture):
    def beta(self):
        return publication.rolling_beta(self.gh, self.tag, self.root / "beta")

    def test_beta_keeps_legacy_downloads_and_fixed_tag_with_feed_last(self):
        legacy = {"Yorozu-0.4.0-290.dmg": b"legacy signed DMG", "appcast.xml": fixtures.feed("0.4.0", "290", "main-beta")}
        self.gh.add_release("main-beta", copy.deepcopy(legacy), prerelease=True, source=fixtures.OTHER)
        self.publish()
        self.gh.events.clear()
        self.beta()
        beta = self.gh.releases["main-beta"]
        self.assertEqual(beta["files"]["Yorozu-0.4.0-290.dmg"], legacy["Yorozu-0.4.0-290.dmg"])
        self.assertEqual(self.gh.tags["main-beta"], fixtures.OTHER)
        uploads = [event for event in self.mutations() if event[1] == "upload"]
        self.assertEqual([Path(event[5]).name for event in uploads], ["yorozu.dmg", "candidate.json", "appcast.xml"])
        self.assertIn(self.tag.encode(), beta["files"]["appcast.xml"])
        self.assertEqual(beta["notes"], self.data["notes"])

    def test_new_beta_publishes_only_after_assets_exist(self):
        self.publish()
        self.gh.events.clear()
        self.beta()
        mutations = self.mutations()
        self.assertEqual(mutations[0][:2], ("release", "create"))
        self.assertEqual(mutations[-1][:2], ("release", "edit"))
        self.assertFalse(self.gh.releases["main-beta"]["isDraft"])

    def test_older_version_or_build_cannot_replace_beta(self):
        self.publish()
        for short, build in (("0.6.0", "10000"), ("0.4.9", "10099"), ("0.5.0", "10099")):
            with self.subTest(short=short, build=build):
                self.gh.add_release("main-beta", {"appcast.xml": fixtures.feed(short, build)}, prerelease=True)
                self.gh.events.clear()
                with self.assertRaisesRegex(ValueError, "backwards"):
                    self.beta()
                self.assertEqual(self.mutations(), [])

    def test_delayed_older_source_cannot_move_beta_even_with_larger_build(self):
        data = self.publish()
        previous = {**data, "source_sha": fixtures.OTHER, "build": "10041", "tag": "candidate-0.5.0-10041",
                    "ios": {**data["ios"], "build": "10041"}}
        self.gh.add_release("main-beta", {"appcast.xml": fixtures.feed("0.5.0", "10041"),
                            "candidate.json": fixtures.json.dumps(previous).encode()}, prerelease=True)
        self.gh.compare_status = "behind"
        self.gh.events.clear()
        with self.assertRaisesRegex(ValueError, "source backwards"):
            self.beta()
        self.assertEqual(self.mutations(), [])

    def test_release_branch_candidate_never_moves_beta(self):
        self.data["source_branch"] = "release/0.5"
        self.gh.runs["7"]["head_branch"] = "release/0.5"
        publication.write_json(self.dist / "candidate.json", self.data)
        self.publish()
        self.gh.events.clear()
        with self.assertRaisesRegex(ValueError, "only main"):
            self.beta()
        self.assertEqual(self.mutations(), [])

    def test_failed_alias_upload_leaves_previous_feed_and_legacy_dmg(self):
        legacy = {"appcast.xml": fixtures.feed("0.4.0", "290"), "Yorozu-0.4.0-290.dmg": b"old"}
        self.gh.add_release("main-beta", copy.deepcopy(legacy), prerelease=True)
        self.publish()
        self.gh.fail_upload = "yorozu.dmg"
        with self.assertRaisesRegex(RuntimeError, "upload failure"):
            self.beta()
        self.assertEqual(self.gh.releases["main-beta"]["files"], legacy)


if __name__ == "__main__":
    unittest.main()

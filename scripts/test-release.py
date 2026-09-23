#!/usr/bin/env python3
"""Exercise release publication against local fake build and GitHub commands."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


RELEASE_SCRIPT = Path(__file__).resolve().with_name("release.sh")
TARGET = "v0.2.1"
CURRENT_DMG = "Yorozu-0.2.1-42.dmg"
PREVIOUS_DMG = "Yorozu-0.2.0-41.dmg"

# Each fake records its observable inputs before doing work, so failure tests can
# prove that publication/cleanup commands were never attempted.
FAKE_COMMAND = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["FIXTURE_ROOT"])
command = Path(sys.argv[0]).name
args = sys.argv[1:]
event = {"command": command, "args": args}
dist = root / os.environ["DIST"]
if command == "build-mac.sh":
    event["version"] = os.environ["VERSION"]
    event["build"] = os.environ["BUILD"]
if command == "gh" and args[:2] == ["release", "upload"]:
    event["assets"] = {
        Path(arg).name: Path(arg).read_text()
        for arg in args[5:-1]
    }
with (root / "commands.jsonl").open("a") as log:
    log.write(json.dumps(event) + "\n")

if command == "build-mac.sh":
    dist.mkdir(parents=True)
    (dist / "Yorozu-0.2.1-42.dmg").write_text("current build")
    (dist / "Yorozu-0.2.0-41.dmg").write_text("previous build")
    # A newer file must not accidentally become the stable download.
    (dist / "Yorozu-unreferenced.dmg").write_text("unreferenced build")
elif command == "appcast.sh":
    older = "Yorozu-missing.dmg" if os.environ.get("MISSING_ASSET") else "Yorozu-0.2.0-41.dmg"
    (dist / "appcast.xml").write_text(
        '<rss><channel><item><sparkle:version>42</sparkle:version>'
        '<enclosure url="https://example.test/download/Yorozu-0.2.1-42.dmg"/>'
        '</item><item><enclosure url="https://example.test/download/' + older + '"/>'
        '</item></channel></rss>\n'
    )
elif command == "gh":
    state_path = root / "github.json"
    state = json.loads(state_path.read_text())
    if args[0] == "api":
        print("\n".join(state["published"]))
    elif args[:2] == ["release", "view"]:
        sys.exit(0 if state["exists"] else 1)
    elif args[:2] == ["release", "create"]:
        if "--draft" not in args or "--verify-tag" not in args:
            sys.exit("new releases must be drafts with verified tags")
        state["exists"] = True
    elif args[:2] == ["release", "upload"]:
        if os.environ.get("FAIL_UPLOAD"):
            sys.exit("simulated upload failure")
    elif args[:2] == ["release", "edit"]:
        if os.environ.get("FAIL_PUBLISH"):
            sys.exit("simulated publish failure")
        if args[2] not in state["published"]:
            state["published"].append(args[2])
    elif args[:2] == ["release", "delete"]:
        state["published"].remove(args[2])
        if "--cleanup-tag" in args:
            state["tags"].remove(args[2])
    else:
        sys.exit("unexpected gh command: " + repr(args))
    state_path.write_text(json.dumps(state))
else:
    sys.exit("unexpected command: " + command)
'''


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="yorozu-release-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for directory in ("scripts", "bin", "catalog"):
            (self.root / directory).mkdir()
        shutil.copy2(RELEASE_SCRIPT, self.root / "scripts/release.sh")
        (self.root / "catalog/models.json").write_text('{"models": []}\n')
        for command in ("scripts/build-mac.sh", "scripts/appcast.sh", "bin/gh", "bin/git"):
            path = self.root / command
            path.write_text(FAKE_COMMAND)
            path.chmod(0o755)
        self.env = {
            **os.environ,
            "PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"],
            "FIXTURE_ROOT": str(self.root),
            "DIST": "release-output",
            "PUBLIC": "fixture/yorozu",
            "RELEASE_TAG": TARGET,
            "BUILD": "42",
        }
        for variable in ("FAIL_UPLOAD", "FAIL_PUBLISH", "MISSING_ASSET"):
            self.env.pop(variable, None)

    def run_release(self, *, existing=True, published=None, **environment):
        self.original_tags = ["v0.1.0", "v0.2.0", "mac", TARGET]
        state = {
            "exists": existing,
            "published": ["v0.1.0", "v0.2.0", "mac"] if published is None else published,
            "tags": self.original_tags,
        }
        (self.root / "github.json").write_text(json.dumps(state))
        result = subprocess.run(
            ["sh", str(self.root / "scripts/release.sh")],
            cwd=self.root / "catalog",  # The entry point must locate its own root.
            env={**self.env, **environment},
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.events = [
            json.loads(line)
            for line in (self.root / "commands.jsonl").read_text().splitlines()
        ]
        self.state = json.loads((self.root / "github.json").read_text())
        return result

    def commands(self):
        return [
            " ".join(event["args"][:2]) if event["command"] == "gh" else event["command"]
            for event in self.events
        ]

    def assert_tags_preserved(self):
        self.assertEqual(self.state["tags"], self.original_tags)
        self.assertNotIn("git", [event["command"] for event in self.events])

    def test_successful_existing_and_new_releases(self):
        # A fresh fixture is required for each successful release invocation.
        for existing in (True, False):
            with self.subTest(existing=existing):
                if (self.root / "release-output").exists():
                    shutil.rmtree(self.root / "release-output")
                    (self.root / "commands.jsonl").unlink()
                result = self.run_release(existing=existing)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                expected = ["api repos/fixture/yorozu/releases", "build-mac.sh", "appcast.sh", "release view"]
                if not existing:
                    expected.append("release create")
                expected += ["release upload", "release edit", "api repos/fixture/yorozu/releases"]
                expected += ["release delete"] * 3
                self.assertEqual(self.commands(), expected)
                build = self.events[1]
                self.assertEqual((build["version"], build["build"]), ("0.2.1", "42"))
                upload = next(event for event in self.events if event["args"][:2] == ["release", "upload"])
                self.assertEqual(set(upload["assets"]), {CURRENT_DMG, PREVIOUS_DMG, "Yorozu.dmg", "appcast.xml", "models.json"})
                self.assertEqual(upload["assets"]["Yorozu.dmg"], "current build")
                self.assertEqual(upload["assets"][PREVIOUS_DMG], "previous build")
                publish = next(event for event in self.events if event["args"][:2] == ["release", "edit"])
                self.assertIn("--draft=false", publish["args"])
                self.assertIn("--latest", publish["args"])
                self.assertEqual(self.state["published"], [TARGET])
                self.assert_tags_preserved()
                self.assertEqual(list((self.root / "release-output").glob("stable.*")), [])

    def test_upload_failure_keeps_new_release_hidden_and_old_releases_intact(self):
        result = self.run_release(existing=False, FAIL_UPLOAD="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("simulated upload failure", result.stderr)
        self.assertIn("release create", self.commands())
        self.assertNotIn("release edit", self.commands())
        self.assertNotIn("release delete", self.commands())
        self.assertEqual(self.state["published"], ["v0.1.0", "v0.2.0", "mac"])
        self.assert_tags_preserved()

    def test_publish_failure_keeps_old_releases_intact(self):
        result = self.run_release(FAIL_PUBLISH="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("simulated publish failure", result.stderr)
        self.assertIn("release upload", self.commands())
        self.assertIn("release edit", self.commands())
        self.assertNotIn("release delete", self.commands())
        self.assertEqual(self.state["published"], ["v0.1.0", "v0.2.0", "mac"])
        self.assert_tags_preserved()

    def test_downgrade_stops_before_build_or_mutation(self):
        result = self.run_release(published=["v0.3.0"])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing to replace newer published release", result.stderr)
        self.assertEqual(self.commands(), ["api repos/fixture/yorozu/releases"])
        self.assertEqual(self.state["published"], ["v0.3.0"])
        self.assert_tags_preserved()

    def test_missing_referenced_asset_stops_before_release_mutation(self):
        result = self.run_release(MISSING_ASSET="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("appcast asset missing: Yorozu-missing.dmg", result.stderr)
        self.assertEqual(self.commands(), ["api repos/fixture/yorozu/releases", "build-mac.sh", "appcast.sh"])
        self.assertEqual(self.state["published"], ["v0.1.0", "v0.2.0", "mac"])
        self.assert_tags_preserved()


if __name__ == "__main__":
    unittest.main()

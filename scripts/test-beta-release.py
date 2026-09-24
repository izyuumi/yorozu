#!/usr/bin/env python3
"""Exercise rolling beta publication without GitHub or a real DMG."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("beta-release.sh")
FAKE = r'''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["FIXTURE_ROOT"])
command = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "commands.jsonl").open("a") as log:
    log.write(json.dumps([command, *args]) + "\n")

if command == "git":
    if args[0] == "describe": print("v0.4.0")
    elif args[0] == "rev-list": print("294")
elif command == "appcast.sh":
    assert os.environ["CHANNEL"] == "beta"
    assert os.environ["DOWNLOAD_PREFIX"].endswith("/main-beta/")
    if os.environ.get("FAIL_APPCAST"): sys.exit(1)
    Path(os.environ["DIST"], "appcast.xml").write_text("<sparkle:channel>beta</sparkle:channel>\n")
elif command == "gh":
    if args[:2] == ["release", "view"]:
        if "--json" in args:
            print("Yorozu-0.4.0-293.dmg\nYorozu-0.4.0-294.dmg\nYorozu.dmg\nappcast.xml")
        elif not (root / "release-exists").exists():
            sys.exit(1)
    elif args[:2] == ["release", "create"]:
        (root / "release-exists").touch()
    elif args[:2] == ["release", "upload"]:
        assert Path(args[5]).is_file(), args
'''


class BetaReleaseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="yorozu-beta-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for directory in ("scripts", "bin", "dist"):
            (self.root / directory).mkdir()
        shutil.copy2(SCRIPT, self.root / "scripts/beta-release.sh")
        for name in ("git", "gh", "appcast.sh"):
            path = self.root / ("scripts" if name == "appcast.sh" else "bin") / name
            path.write_text(FAKE)
            path.chmod(0o755)
        (self.root / "dist/Yorozu-0.4.0-294.dmg").write_text("signed DMG")
        self.env = {
            **os.environ,
            "PATH": str(self.root / "bin") + os.pathsep + os.environ["PATH"],
            "FIXTURE_ROOT": str(self.root),
            "DIST": "dist",
            "PUBLIC": "fixture/yorozu",
            "BETA_REMOTE": "github",
        }

    def run_beta(self, **environment):
        result = subprocess.run(
            ["sh", str(self.root / "scripts/beta-release.sh")],
            cwd=self.root,
            env={**self.env, **environment},
            capture_output=True,
            text=True,
            timeout=20,
        )
        self.events = [json.loads(line) for line in (self.root / "commands.jsonl").read_text().splitlines()]
        return result

    def test_existing_beta_updates_feed_then_tag_and_prunes_old_archive(self):
        (self.root / "release-exists").touch()
        result = self.run_beta()
        self.assertEqual(result.returncode, 0, result.stderr)
        uploads = [event for event in self.events if event[:2] == ["gh", "release"] and event[2] == "upload"]
        self.assertEqual([Path(event[6]).name for event in uploads], [
            "Yorozu-0.4.0-294.dmg", "Yorozu.dmg", "appcast.xml"
        ])
        self.assertEqual((self.root / "dist/beta/appcast.xml").read_text(), "<sparkle:channel>beta</sparkle:channel>\n")
        self.assertLess(self.events.index(uploads[-1]), self.events.index(["git", "tag", "-f", "main-beta", "HEAD"]))
        self.assertIn(["gh", "release", "delete-asset", "main-beta", "Yorozu-0.4.0-293.dmg", "--repo", "fixture/yorozu", "--yes"], self.events)
        self.assertNotIn(["gh", "release", "delete-asset", "main-beta", "Yorozu-0.4.0-294.dmg", "--repo", "fixture/yorozu", "--yes"], self.events)

    def test_new_beta_stays_draft_until_uploads_finish(self):
        result = self.run_beta()
        self.assertEqual(result.returncode, 0, result.stderr)
        create = next(i for i, event in enumerate(self.events) if event[:3] == ["gh", "release", "create"])
        publish = next(i for i, event in enumerate(self.events) if event[:3] == ["gh", "release", "edit"])
        uploads = [i for i, event in enumerate(self.events) if event[:3] == ["gh", "release", "upload"]]
        self.assertLess(create, min(uploads))
        self.assertLess(max(uploads), publish)
        self.assertIn("--draft", self.events[create])
        self.assertIn("--prerelease", self.events[create])

    def test_appcast_failure_does_not_touch_release(self):
        result = self.run_beta(FAIL_APPCAST="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(event[0] == "gh" for event in self.events))


if __name__ == "__main__":
    unittest.main()

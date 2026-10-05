#!/usr/bin/env python3
"""Exercise real Git archive overlays using inert source files, never a runtime."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("stage_alpha", Path(__file__).with_name("stage-internal-alpha.py"))
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


class StageTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="yorozu-stage-test-")
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        self.put("pnpm-lock.yaml", "baseline-locked-bytes\n")
        self.put("packages/runtime/src/serve.ts", "baseline\n")
        self.put("packages/runtime/src/threads.ts", "threads\n")
        for directory in ("apps/mac", "packages/shared-swift", "packages/harness-plugins"):
            self.put(directory + "/removed.txt", "must not return\n")
        self.commit("baseline")
        self.baseline = self.git("rev-parse", "HEAD").strip()
        for directory in ("apps/mac", "packages/shared-swift", "packages/harness-plugins"):
            (self.repo / directory / "removed.txt").unlink()
            self.put(directory + "/current.txt", "reviewed\n")
        self.put("packages/runtime/src/harness-fixture.test.ts", "inert test fixture\n")
        self.put("scripts/secretary-production.patch", "--- a/packages/runtime/src/serve.ts\n+++ b/packages/runtime/src/serve.ts\n@@ -1 +1 @@\n-baseline\n+patched\n")
        self.commit("reviewed overlay")
        self.source = self.git("rev-parse", "HEAD").strip()
        self.patches = patch.multiple(stage, ROOT=self.repo, BASELINE=self.baseline,
            OVERLAYS=["apps/mac", "packages/shared-swift", "packages/harness-plugins", "scripts/secretary-production.patch"])
        self.patches.start()

    def tearDown(self):
        self.patches.stop()
        self.temp.cleanup()

    def git(self, *args):
        return subprocess.check_output(["git", "-C", str(self.repo), *args], text=True, stderr=subprocess.PIPE)

    def put(self, name, contents):
        path = self.repo / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents)

    def commit(self, message):
        self.git("add", ".")
        self.git("commit", "-qm", message)

    def test_deleted_overlay_files_do_not_return_and_lock_stays_baseline(self):
        out = self.root / "staged"
        stage.stage(out)
        for directory in ("apps/mac", "packages/shared-swift", "packages/harness-plugins"):
            self.assertFalse((out / directory / "removed.txt").exists())
            self.assertEqual((out / directory / "current.txt").read_text(), "reviewed\n")
        self.assertEqual((out / "packages/runtime/src/serve.ts").read_text(), "patched\n")
        self.assertEqual((out / "pnpm-lock.yaml").read_text(), "baseline-locked-bytes\n")
        manifest = json.loads((out / "internal-source.json").read_text())
        self.assertEqual(manifest["sourceSha"], self.source)
        self.assertEqual(manifest["productionBaselineSha"], self.baseline)
        self.assertFalse(manifest["legacyStorageMigration"])
        self.assertFalse(any(name.endswith("removed.txt") for name in manifest["overlaySha256"]))

    def test_dirty_source_is_rejected(self):
        self.put("unreviewed", "not committed")
        with self.assertRaisesRegex(SystemExit, "clean source"):
            stage.stage(self.root / "staged")

    def test_existing_destination_is_not_overwritten(self):
        out = self.root / "staged"
        out.mkdir()
        (out / "keep").write_text("preserve")
        with self.assertRaisesRegex(SystemExit, "must be empty"):
            stage.stage(out)
        self.assertEqual((out / "keep").read_text(), "preserve")


if __name__ == "__main__":
    unittest.main()

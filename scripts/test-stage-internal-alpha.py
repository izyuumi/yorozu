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
        for directory in ("apps/mac", "apps/ios", "packages/shared-swift", "packages/harness-plugins"):
            self.put(directory + "/removed.txt", "must not return\n")
        self.put("packages/runtime/src/secretary-old.test.ts", "deleted test\n")
        self.put("packages/shared/src/siwc-old.test.ts", "deleted shared test\n")
        self.commit("baseline")
        self.baseline = self.git("rev-parse", "HEAD").strip()
        for directory in ("apps/mac", "apps/ios", "packages/shared-swift", "packages/harness-plugins"):
            (self.repo / directory / "removed.txt").unlink()
            self.put(directory + "/current.txt", "reviewed\n")
        (self.repo / "packages/runtime/src/secretary-old.test.ts").unlink()
        (self.repo / "packages/shared/src/siwc-old.test.ts").unlink()
        self.put("packages/runtime/src/harness-fixture.test.ts", "inert test fixture\n")
        self.put("scripts/secretary-production.patch", "--- a/packages/runtime/src/serve.ts\n+++ b/packages/runtime/src/serve.ts\n@@ -1 +1 @@\n-baseline\n+patched\n")
        self.commit("reviewed overlay")
        self.source = self.git("rev-parse", "HEAD").strip()
        self.patches = patch.multiple(stage, ROOT=self.repo, BASELINE=self.baseline,
            OVERLAYS=["apps/mac", "apps/ios", "packages/shared-swift", "packages/harness-plugins", "scripts/secretary-production.patch"])
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
        for directory in ("apps/mac", "apps/ios", "packages/shared-swift", "packages/harness-plugins"):
            self.assertFalse((out / directory / "removed.txt").exists())
            self.assertEqual((out / directory / "current.txt").read_text(), "reviewed\n")
        self.assertEqual((out / "packages/runtime/src/serve.ts").read_text(), "patched\n")
        self.assertEqual((out / "pnpm-lock.yaml").read_text(), "baseline-locked-bytes\n")
        manifest = json.loads((out / "internal-source.json").read_text())
        self.assertEqual(manifest["sourceSha"], self.source)
        self.assertEqual(manifest["productionBaselineSha"], self.baseline)
        self.assertFalse(manifest["legacyStorageMigration"])
        self.assertFalse(any(name.endswith("removed.txt") for name in manifest["overlaySha256"]))

    def test_deleted_baseline_tests_do_not_run(self):
        out = self.root / "staged"
        stage.stage(out)
        self.assertFalse((out / "packages/runtime/src/secretary-old.test.ts").exists())
        self.assertFalse((out / "packages/shared/src/siwc-old.test.ts").exists())
        self.assertTrue((out / "packages/runtime/src/harness-fixture.test.ts").exists())

    def test_export_ignore_overlay_or_test_is_refused(self):
        for index, name in enumerate(("apps/mac/current.txt", "packages/runtime/src/harness-fixture.test.ts")):
            self.put(".gitattributes", name + " export-ignore\n")
            self.commit("ignored archive path")
            with self.assertRaisesRegex(SystemExit, "Git blob missing"):
                stage.stage(self.root / f"ignored-{index}")

    def test_export_subst_cannot_change_reviewed_bytes(self):
        self.put("apps/mac/current.txt", "$Format:%H$\n")
        self.put(".gitattributes", "apps/mac/current.txt export-subst\n")
        self.commit("archive substitution")
        with self.assertRaisesRegex(SystemExit, "differ from Git blob"):
            stage.stage(self.root / "staged")

    def test_symlink_target_and_executable_mode_are_recorded_and_preserved(self):
        (self.repo / "apps/mac/link").symlink_to("current.txt")
        (self.repo / "apps/mac/current.txt").chmod(0o755)
        self.commit("reviewed symlink")
        out = self.root / "staged"
        stage.stage(out)
        manifest = json.loads((out / "internal-source.json").read_text())
        self.assertEqual(manifest["overlaySymlinks"], {"apps/mac/link": "current.txt"})
        self.assertEqual(str((out / "apps/mac/link").readlink()), "current.txt")
        self.assertTrue((out / "apps/mac/current.txt").stat().st_mode & 0o111)

    def test_checkout_eol_and_clean_filters_cannot_mask_staged_byte_changes(self):
        self.put(".gitattributes", "apps/mac/current.txt text eol=crlf filter=fixture\n")
        self.git("config", "filter.fixture.clean", "cat")
        self.git("config", "filter.fixture.smudge", "cat")
        self.commit("checkout attributes")
        out = self.root / "staged"
        with self.assertRaisesRegex(SystemExit, "differ from Git blob"):
            stage.stage(out)
        # A malicious clean filter must not normalize a substitution back to the blob.
        self.put("apps/mac/current.txt", "$Format:%H$\n")
        self.put(".gitattributes", "apps/mac/current.txt export-subst filter=fixture\n")
        self.commit("substitution with clean filter")
        self.git("config", "filter.fixture.clean", "printf '%s\\n' '$Format:%%H$'")
        with self.assertRaisesRegex(SystemExit, "differ from Git blob"):
            stage.stage(self.root / "substituted")

    def test_worker_boundary_tests_are_part_of_the_staged_gate(self):
        self.put("packages/runtime/src/worker-transport.test.ts", "inert encrypted-transport fixture\n")
        self.commit("worker regression gate")
        out = self.root / "workers"
        stage.stage(out)
        manifest = json.loads((out / "internal-source.json").read_text())
        self.assertIn("packages/runtime/src/worker-transport.test.ts", manifest["overlaySha256"])
        self.assertTrue((out / "packages/runtime/src/worker-transport.test.ts").exists())

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

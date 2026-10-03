#!/usr/bin/env python3
"""Exercise the release command boundary with inert Xcode/Tuist processes."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


@unittest.skipUnless(sys.platform == "darwin", "iOS build script uses Apple's PlistBuddy")
class IOSExportTests(unittest.TestCase):
    def run_build(self, internal, version="0.6.0"):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            (root / "bin").mkdir()
            for name in ("build-ios.sh", "build-version.sh"):
                shutil.copyfile(SCRIPTS / name, root / "scripts" / name)
            (root / "bin" / "tuist").write_text("#!/bin/sh\nexit 0\n")
            (root / "bin" / "xcodebuild").write_text('''#!/usr/bin/env python3
import json, os, pathlib, plistlib, sys
args = sys.argv[1:]
row = {"args": args, "secretary": os.environ.get("YOROZU_SECRETARY_ENABLED"), "sdkroot": os.environ.get("SDKROOT")}
if "-exportArchive" in args:
    row["options"] = plistlib.loads(pathlib.Path(args[args.index("-exportOptionsPlist") + 1]).read_bytes())
    if row["options"]["destination"] == "export":
        out = pathlib.Path(args[args.index("-exportPath") + 1]); out.mkdir(parents=True)
        (out / "Yorozu.ipa").write_bytes(b"inert export fixture")
with open(os.environ["TRACE"], "a") as trace: trace.write(json.dumps(row) + "\\n")
''')
            for tool in (root / "bin").iterdir():
                tool.chmod(0o755)
            trace = root / "trace.jsonl"
            env = {**os.environ, "PATH": f"{root / 'bin'}:{os.environ['PATH']}", "VERSION": version, "BUILD": "7",
                   "INTERNAL_ONLY": internal, "ASC_KEY_ID": "test", "ASC_ISSUER_ID": "test", "ASC_KEY_PATH": str(root / "inert-key"),
                   "DIST": "output with spaces", "TRACE": str(trace), "SDKROOT": "wrong-sdk"}
            for key in ("ASC_KEY_P8", "YOROZU_SECRETARY_ENABLED", "VERSION_LABEL", "VERSION_BUILD"):
                env.pop(key, None)
            result = subprocess.run(["sh", str(root / "scripts/build-ios.sh")], env=env, capture_output=True, text=True)
            rows = [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []
            return result, rows

    def test_internal_export_and_upload_are_both_restricted(self):
        result, rows = self.run_build("1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(rows), 3)
        self.assertIn("MARKETING_VERSION=0.6.0", rows[0]["args"])
        self.assertIn("CURRENT_PROJECT_VERSION=7", rows[0]["args"])
        self.assertEqual([r["options"]["destination"] for r in rows[1:]], ["export", "upload"])
        for row in rows:
            self.assertEqual(row["secretary"], "1")
            self.assertIsNone(row["sdkroot"])
        for row in rows[1:]:
            self.assertTrue(row["options"]["testFlightInternalTestingOnly"])
            self.assertFalse(row["options"]["manageAppVersionAndBuildNumber"])

    def test_public_path_keeps_one_normal_upload(self):
        result, rows = self.run_build("0", "0.5.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(rows), 2)
        self.assertEqual(rows[1]["options"]["destination"], "upload")
        self.assertNotIn("testFlightInternalTestingOnly", rows[1]["options"])
        self.assertIsNone(rows[0]["secretary"])

    def test_invalid_internal_mode_or_version_cannot_start_xcode(self):
        for mode, version in (("true", "0.6.0"), ("1", "0.5.0")):
            result, rows = self.run_build(mode, version)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(rows, [])


if __name__ == "__main__":
    unittest.main()

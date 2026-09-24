#!/usr/bin/env python3
"""Check shipping version inputs without a checkout, packaging tools, or signing keys."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).with_name("build-version.sh").resolve()


class BuildVersionTests(unittest.TestCase):
    def load(self, **metadata):
        with tempfile.TemporaryDirectory() as directory:
            return subprocess.run(
                ["sh", "-eu", "-c", '. "$1"; printf "%s\\n" "$VERSION" "$BUILD" "$VERSION_LABEL" "$VERSION_BUILD"',
                 "sh", str(HELPER)],
                cwd=directory,
                env={"PATH": os.environ["PATH"], **metadata},
                capture_output=True,
                text=True,
            )

    def test_defaults_use_allocated_build_without_git(self):
        for version in ["0.0.0", "0.5.0", "10.20.300"]:
            with self.subTest(version=version):
                result = self.load(VERSION=version, BUILD="12345")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.splitlines(), [version, "12345", version, "12345"])

    def test_display_overrides_remain_explicit(self):
        result = self.load(VERSION="0.5.0", BUILD="12345", VERSION_LABEL="0.5.0 Beta", VERSION_BUILD="7")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["0.5.0", "12345", "0.5.0 Beta", "7"])

    def test_missing_required_inputs_fail(self):
        for metadata in [{}, {"VERSION": "0.5.0"}, {"BUILD": "12345"}]:
            with self.subTest(metadata=metadata):
                result = self.load(**metadata)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("is required", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_invalid_inputs_fail_before_building(self):
        invalid = {
            "VERSION": ["", "0.5", "0.5.0.1", "v0.5.0", "0.5.0-beta", "01.5.0", "0.05.0", "0.5.00",
                        "0.5.-1", "0.5.0\n", "0.5.<0>"],
            "BUILD": ["", "0", "-1", "+1", "01", "1.2", "1\n", "1&2"],
            "VERSION_BUILD": ["0", "-1", "01", "1.2", "1\n"],
            "VERSION_LABEL": ["0.5.0\nBeta", "0.5.0\tBeta", "0.5.0 <Beta>", "0.5.0 & Beta"],
        }
        for name, values in invalid.items():
            for value in values:
                with self.subTest(name=name, value=value):
                    metadata = {"VERSION": "0.5.0", "BUILD": "12345", name: value}
                    result = self.load(**metadata)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(name, result.stderr)
                    self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Inert gate tests: no Rust compile, process termination or production state."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("host_gate", Path(__file__).with_name("check-internal-host.py"))
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


def transcript(name):
    return f"test {name} ... ok\n\ntest result: ok. 1 passed; 0 failed; 0 ignored; 0 measured; 5 filtered out; finished in 0.01s\n"


class HostGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tests = self.root / "packages/host-core/tests"
        self.tests.mkdir(parents=True)
        for suite, names in gate.CASES.items():
            (self.tests / (suite + ".rs")).write_text("\n".join(f"#[test]\nfn {name}() {{}}" for name in names))
        self.calls = []

    def runner(self, args):
        self.calls.append(args)
        suite = args[args.index("--test") + 1]
        if args[-1] == "--list":
            output = "\n".join(name + ": test" for name in gate.CASES[suite])
        else:
            self.assertIn("--exact", args)
            self.assertIn("--test-threads=1", args)
            output = transcript(args[args.index("--exact") + 1])
        return subprocess.CompletedProcess(args, 0, output, "")

    def test_exact_safe_selections_are_nonvacuous(self):
        receipt = gate.run_checks(self.root, self.runner)
        self.assertEqual(receipt["executed"], 22)
        self.assertEqual(len(self.calls), 28)
        self.assertTrue(all(args[-1] == "--list" for args in self.calls[:6]))
        self.assertFalse(any("--tests" in args or "--lib" in args for args in self.calls))

    def test_selected_source_missing_refuses(self):
        (self.tests / "stops.rs").write_text("// removed")
        with self.assertRaisesRegex(gate.CheckFailed, "source test missing"):
            gate.run_checks(self.root, self.runner)
        self.assertTrue(all(args[-1] == "--list" for args in self.calls))

    def test_missing_or_failed_compiled_listing_refuses(self):
        for status in (0, 1):
            with self.assertRaisesRegex(gate.CheckFailed, "build/list failed"):
                gate.run_checks(self.root, lambda args: subprocess.CompletedProcess(args, status, "", ""))

    def test_extra_prohibited_source_test_is_not_selected(self):
        with (self.tests / "outbox.rs").open("a") as file:
            file.write("\n#[test]\nfn prohibited_recovery_interposer() {}")
        receipt = gate.run_checks(self.root, self.runner)
        self.assertEqual(receipt["executed"], 22)
        self.assertNotIn("prohibited_recovery", str(self.calls))

    def test_skipped_empty_extra_or_duplicate_execution_fails_closed(self):
        name = "reviewed"
        for output in ("", transcript(name).replace("1 passed", "0 passed"),
                       transcript(name).replace("0 ignored", "1 ignored"),
                       transcript("other"), transcript(name) + transcript(name),
                       transcript(name) + "test unexpected ... ok\n"):
            with self.subTest(output=output), self.assertRaises(gate.CheckFailed):
                gate.verify_run(name, output)

    def test_nonzero_exit_cannot_be_masked_by_green_output(self):
        def runner(args):
            result = self.runner(args)
            if args[-1] != "--list":
                result.returncode = 1
            return result
        with self.assertRaisesRegex(gate.CheckFailed, "process failed"):
            gate.run_checks(self.root, runner)


if __name__ == "__main__":
    unittest.main()

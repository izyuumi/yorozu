#!/usr/bin/env python3
"""Inert command-seam tests: no Swift process, application, network, or UI."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("check_internal_swift", Path(__file__).with_name("check-internal-swift.py"))
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def transcript(names):
    return "\n".join([line for name in names for line in (
        f"◇ Test {name}() started.", f"✔ Test {name}() passed after 0.001 seconds.")]
        + [f"✔ Test run with {len(names)} tests in 0 suites passed after 0.01 seconds."])


class GateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root / "packages/shared-swift/Tests/YorozuSharedTests"
        self.directory.mkdir(parents=True)
        self.groups = {fixture: [fixture + "First", fixture + "Second"] for fixture in gate.FIXTURES}
        for fixture, names in self.groups.items():
            (self.directory / (fixture + ".swift")).write_text("\n".join(
                "@MainActor\n@Test func " + name + "() async throws {}" for name in names))
        self.listing = "\n".join("YorozuSharedTests." + name + "()"
                                 for names in self.groups.values() for name in names)
        self.calls = []

    def runner(self, args):
        self.calls.append(args)
        if args[-1] == "list":
            return subprocess.CompletedProcess(args, 0, self.listing, "")
        index = len(self.calls) - 2
        fixture = gate.FIXTURES[index]
        self.assertEqual(args[-1], gate.selector(self.groups[fixture]))
        self.assertIn("--no-parallel", args)
        self.assertNotIn("--disable-sandbox", args)
        return subprocess.CompletedProcess(args, 0, transcript(self.groups[fixture]), "")

    def run_gate(self, runner=None):
        return gate.run_checks(self.root, self.root / "scratch", runner or self.runner)

    def test_all_four_groups_have_separate_positive_receipts(self):
        receipt = self.run_gate()
        self.assertEqual(receipt["executed"], 8)
        self.assertEqual([g["fixture"] for g in receipt["groups"]], list(gate.FIXTURES))
        self.assertTrue(all(g["executed"] == 2 for g in receipt["groups"]))
        self.assertEqual(len(self.calls), 5)
        self.assertNotIn("--skip-build", self.calls[0])
        for call in self.calls[1:]:
            self.assertNotIn("WireTests", call[-1])
            self.assertNotIn("Showcase", call[-1])

    def test_missing_outbox_listing_refuses_before_any_execution(self):
        self.listing = "\n".join(line for line in self.listing.splitlines() if "Outbox" not in line)
        with self.assertRaisesRegex(gate.CheckFailed, "OutboxTests"):
            self.run_gate()
        self.assertEqual(len(self.calls), 1)

    def test_missing_any_other_group_refuses_before_any_execution(self):
        self.listing = "\n".join(line for line in self.listing.splitlines() if "Editing" not in line)
        with self.assertRaisesRegex(gate.CheckFailed, "PersonAgentEditingTests"):
            self.run_gate()
        self.assertEqual(len(self.calls), 1)

    def test_missing_outbox_file_refuses(self):
        (self.directory / "OutboxTests.swift").unlink()
        with self.assertRaisesRegex(gate.CheckFailed, "OutboxTests"):
            self.run_gate()

    def test_one_missing_function_refuses_even_if_group_nonempty(self):
        self.listing = self.listing.replace("YorozuSharedTests.OutboxTestsSecond()", "")
        with self.assertRaises(gate.CheckFailed):
            self.run_gate()

    def test_duplicate_listing_refuses(self):
        self.listing += "\nYorozuSharedTests.OutboxTestsFirst()"
        with self.assertRaises(gate.CheckFailed):
            self.run_gate()

    def test_unsupported_source_is_not_silently_ignored(self):
        for source in ("// empty", "@Test(arguments: [1]) func parameterized(_ x: Int) {}",
                       "@Suite struct Changed {\n@Test func nested() {}\n}"):
            with self.subTest(source=source), self.assertRaises(gate.CheckFailed):
                gate.source_names(source, "OutboxTests")

    def test_listing_command_failure_refuses(self):
        with self.assertRaisesRegex(gate.CheckFailed, "build/list"):
            self.run_gate(lambda args: subprocess.CompletedProcess(args, 1, self.listing, "build failed"))

    def test_zero_match_exit_zero_refuses(self):
        def runner(args):
            if args[-1] == "list":
                return self.runner(args)
            return subprocess.CompletedProcess(args, 0, "warning: No matching test cases were run\n", "")
        with self.assertRaisesRegex(gate.CheckFailed, "OutboxTests"):
            self.run_gate(runner)

    def test_test_process_failure_refuses_even_with_green_text(self):
        def runner(args):
            if args[-1] == "list":
                return self.runner(args)
            return subprocess.CompletedProcess(args, 1, transcript(self.groups["OutboxTests"]), "")
        with self.assertRaisesRegex(gate.CheckFailed, "exited 1"):
            self.run_gate(runner)

    def test_receipts_require_every_test_not_just_positive_aggregate(self):
        names = self.groups["OutboxTests"]
        bad = [transcript(names[:1]), transcript(["OtherGroup"]),
               transcript(names) + "\n➜ Test extra() skipped: disabled",
               transcript(names) + "\n✘ Test x() recorded an issue",
               transcript(names).replace("with 2 tests", "with 0 tests"),
               transcript(names).replace(f"✔ Test {names[0]}() passed", f"✔ Test {names[1]}() passed"),
               transcript(names).replace("✔ Test run with 2 tests in 0 suites passed after 0.01 seconds.", ""),
               transcript(names + ["unexpectedUIFixture"])]
        for output in bad:
            with self.subTest(output=output), self.assertRaises(gate.CheckFailed):
                gate.verify_run("OutboxTests", names, output)

    def test_ansi_output_and_older_summary_shape_are_supported(self):
        names = ["single"]
        output = transcript(names).replace(" in 0 suites", "")
        output = "\x1b[32m" + output + "\x1b[0m"
        self.assertEqual(gate.verify_run("OutboxTests", names, output)["executed"], 1)


if __name__ == "__main__":
    unittest.main()

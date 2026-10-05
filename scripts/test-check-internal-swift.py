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
        self.groups = {fixture: list(selected) if selected else [fixture + "First", fixture + "Second"] +
                       [fixture + str(i) for i in range(minimum - 2)]
                       for fixture, (_, _, minimum, selected) in gate.GROUPS.items()}
        for fixture, names in self.groups.items():
            package, module, _, _ = gate.GROUPS[fixture]
            directory = self.root / package / "Tests" / module
            directory.mkdir(parents=True, exist_ok=True)
            (directory / (fixture + ".swift")).write_text("\n".join(
                "@MainActor\n@Test func " + name + "() async throws {}" for name in names))
        self.listing = "\n".join(gate.GROUPS[fixture][1] + "." + name + "()"
                                 for fixture, names in self.groups.items() for name in names)
        self.calls = []

    def runner(self, args):
        self.calls.append(args)
        if args[-1] == "list":
            return subprocess.CompletedProcess(args, 0, self.listing, "")
        fixture = next(f for f, names in self.groups.items() if args[-1] == gate.selector(names, gate.GROUPS[f][1]))
        self.assertIn("--no-parallel", args)
        self.assertNotIn("--disable-sandbox", args)
        return subprocess.CompletedProcess(args, 0, transcript(self.groups[fixture]), "")

    def run_gate(self, runner=None):
        return gate.run_checks(self.root, self.root / "scratch", runner or self.runner)

    def test_all_safe_groups_have_separate_positive_receipts(self):
        receipt = self.run_gate()
        self.assertEqual(receipt["executed"], 89)
        self.assertEqual([g["fixture"] for g in receipt["groups"]], list(gate.GROUPS))
        self.assertTrue(all(g["executed"] >= gate.GROUPS[g["fixture"]][2] for g in receipt["groups"]))
        self.assertEqual(len(self.calls), 11)
        self.assertNotIn("--skip-build", self.calls[0])
        for call in self.calls[2:]:
            self.assertNotIn("WireTests", call[-1])
            self.assertNotIn("Showcase", call[-1])

    def test_missing_outbox_listing_refuses_before_any_execution(self):
        self.listing = "\n".join(line for line in self.listing.splitlines() if "Outbox" not in line)
        with self.assertRaisesRegex(gate.CheckFailed, "OutboxTests"):
            self.run_gate()
        self.assertEqual(len(self.calls), 2)

    def test_missing_any_other_group_refuses_before_any_execution(self):
        self.listing = "\n".join(line for line in self.listing.splitlines() if "Editing" not in line)
        with self.assertRaisesRegex(gate.CheckFailed, "PersonAgentEditingTests"):
            self.run_gate()
        self.assertEqual(len(self.calls), 2)

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
        names = ["first", "second"]
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

    def test_mixed_chatmodel_source_only_selects_reviewed_functions(self):
        source = (self.directory / "ChatModelTests.swift").read_text()
        source += "\n@Test(arguments: [1]) func prohibitedRecovery(_ value: Int) {}\n"
        (self.directory / "ChatModelTests.swift").write_text(source)
        receipt = self.run_gate()
        chat = next(g for g in receipt["groups"] if g["fixture"] == "ChatModelTests")
        self.assertEqual(chat["tests"], self.groups["ChatModelTests"])
        self.assertNotIn("prohibitedRecovery", " ".join(self.calls[-2]))

    def test_deleting_source_test_cannot_reduce_mandatory_baseline(self):
        path = self.directory / "OutboxTests.swift"
        path.write_text("\n".join(path.read_text().splitlines()[:-2]))
        with self.assertRaisesRegex(gate.CheckFailed, "baseline shrank"):
            self.run_gate()

    def test_new_safe_file_test_is_required_without_hardcoding_new_total(self):
        path = self.directory / "OutboxTests.swift"
        path.write_text(path.read_text() + "\n@Test func newSafeOutboxRegression() {}\n")
        self.groups["OutboxTests"].append("newSafeOutboxRegression")
        self.listing += "\nYorozuSharedTests.newSafeOutboxRegression()"
        self.assertEqual(self.run_gate()["executed"], 90)

    def test_missing_selected_chatmodel_or_accounts_helper_test_fails_closed(self):
        for fixture in ("ChatModelTests", "AccountsCoreTests"):
            old = self.listing
            self.listing = self.listing.replace(gate.GROUPS[fixture][1] + "." + self.groups[fixture][0] + "()", "")
            with self.assertRaisesRegex(gate.CheckFailed, fixture):
                self.run_gate()
            self.listing = old

    def test_ansi_output_and_older_summary_shape_are_supported(self):
        names = ["single"]
        output = transcript(names).replace(" in 0 suites", "")
        output = "\x1b[32m" + output + "\x1b[0m"
        self.assertEqual(gate.verify_run("OutboxTests", names, output)["executed"], 1)


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3
"""Inert release/CI policy checks. Never authenticate, dispatch, sign or upload."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parent.parent


def internal_lane(base="", ref="", head=""):
    workflow = (ROOT / ".github/workflows/ci.yml").read_text()
    expression = re.search(r"^      internal: \$\{\{ (.+) \}\}$", workflow, re.M).group(1)
    values = {"base_ref": base, "ref": ref, "head_ref": head}
    clauses = []
    for clause in expression.split(" || "):
        match = re.fullmatch(r"github\.(base_ref|ref|head_ref) == '([^']+)'", clause)
        if not match:
            raise ValueError("Update the policy test for the changed lane expression")
        clauses.append(values[match[1]] == match[2])
    return any(clauses)


class InternalReleasePolicyTests(unittest.TestCase):
    def test_internal_pushes_use_isolated_checks(self):
        for branch in ("harness-plugins", "integration-0.6-worker", "v0.6.0-alpha"):
            self.assertTrue(internal_lane(ref="refs/heads/" + branch))

    def test_public_target_prs_never_skip_public_suites_based_on_source_name(self):
        for base in ("main", "release/0.5", "release/0.6"):
            for head in ("harness-plugins", "integration-0.6-worker", "v0.6.0-alpha", "feature"):
                self.assertFalse(internal_lane(base=base, ref="refs/pull/12/merge", head=head))

    def test_explicit_internal_target_remains_internal(self):
        self.assertTrue(internal_lane(base="v0.6.0-alpha", ref="refs/pull/12/merge", head="feature"))

    def test_every_signing_job_rejects_partial_reruns_before_signing(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        for job, next_job, signing_step in (
            ("candidate", "internal", "Signing identity and notary credentials"),
            ("internal", "internal-beta", "Prepare existing signing credentials"),
            ("internal-beta", None, "Reverify the existing internal TestFlight group without writes"),
        ):
            text = workflow.split("\n  " + job + ":\n", 1)[1]
            if next_job:
                text = text.split("\n  " + next_job + ":\n", 1)[0]
            self.assertLess(text.index('test "$GITHUB_RUN_ATTEMPT" = 1'), text.index(signing_step))

    def test_internal_source_gate_is_readonly_and_runs_before_signing(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        internal = workflow.split("\n  internal:\n", 1)[1].split("\n  internal-beta:\n", 1)[0]
        self.assertIn("contents: read", internal)
        self.assertLess(internal.index("publish-internal-beta.py --check-source"),
                        internal.index("Prepare existing signing credentials"))
        beta_source = (ROOT / "scripts/publish-internal-beta.py").read_text()
        branches = re.search(r"INTERNAL_BRANCHES = (.+)", beta_source).group(1)
        import ast
        for branch in ast.literal_eval(branches):
            self.assertTrue(internal_lane(ref="refs/heads/" + branch))
            self.assertIn('"' + branch + '"', workflow)

    def test_internal_artifacts_never_upload_ipa_or_failed_build_binaries(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        internal = workflow.split("\n  internal:\n", 1)[1].split("\n  internal-beta:\n", 1)[0]
        uploads = [step for step in internal.split("      - name: ") if "actions/upload-artifact@" in step]
        self.assertEqual(len(uploads), 2)
        for step in uploads:
            paths = step.split("          path: |\n", 1)[1]
            self.assertNotIn(".ipa", paths)
            self.assertNotIn("ios/", paths)
            if re.search(r"\.(zip|dmg)", paths):
                self.assertIn("if: success()", step)
                self.assertNotIn("if: always()", step)
        self.assertLess(internal.index("Record internal artifact provenance"),
                        internal.index("Retain verified internal Mac packages"))

    def test_internal_shell_scripts_are_linted(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        line = next(line for line in workflow.splitlines() if line.strip().startswith("shellcheck scripts/"))
        for script in ("check-internal-alpha.sh", "build-internal-alpha.sh"):
            self.assertIn("scripts/" + script, line)

    def test_staged_internal_lane_executes_outbox_and_packaging_regressions(self):
        script = (ROOT / "scripts/check-internal-alpha.sh").read_text()
        self.assertIn('python3 scripts/stage-internal-alpha.py "$SOURCE"', script)
        self.assertIn('cd "$SOURCE"', script)
        self.assertIn("python3 scripts/check-internal-swift.py", script)
        swift = (ROOT / "scripts/check-internal-swift.py").read_text()
        self.assertIn("OutboxTests", swift)
        self.assertIn("HarnessPlatformTests", swift)
        self.assertIn("python3 scripts/package-accounts-helper.test.py", script)
        self.assertNotIn("--disable-sandbox", script)
        self.assertNotIn("ui-tests.yml", script)


if __name__ == "__main__":
    unittest.main()

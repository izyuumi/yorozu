#!/usr/bin/env python3
"""Offline guardrail fixtures: no hook installation, commits, or account access."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / 'scripts/check-commit-msg.sh'
PR = ROOT / 'scripts/check-pr-commit-msg.sh'
HOOK = ROOT / '.githooks/commit-msg'


class Guardrails(unittest.TestCase):
    def run_check(self, command, ok, **kwargs):
        result = subprocess.run([str(x) for x in command], capture_output=True, text=True,
                                timeout=10, **{'cwd': ROOT, **kwargs})
        self.assertEqual(result.returncode == 0, ok, result.stdout + result.stderr)

    def test_subjects(self):
        for subject in ['feat: add feature', 'fix(ui)!: break API', 'docs: 日本語',
                        'refactor!: simplify', 'revert: undo change']:
            with self.subTest(subject=subject):
                self.run_check([CHECK, subject], True)
        for subject in ['', 'feat: ', 'feat:  ', 'feat: \t\r', 'Feat: nope',
                        'feat(): empty scope', 'fixup! feat: later', 'Merge branch x',
                        'feat: valid\ninvalid']:
            with self.subTest(subject=subject):
                self.run_check([CHECK, subject], False)
        self.run_check([CHECK], False)
        self.run_check([CHECK, 'fix: one', 'docs: two'], True)
        self.run_check([CHECK, 'invalid', 'fix: valid'], False)

    def test_real_git_revisions(self):
        # A hermetic two-commit repository: CI checkouts are shallow (no HEAD~1) and the
        # checked-out subjects are not this test's fixture.
        with tempfile.TemporaryDirectory() as directory:
            env = dict(os.environ, GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull,
                       GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t',
                       GIT_COMMITTER_EMAIL='t@t')
            subprocess.run(['git', 'init', '-q', directory], check=True, env=env)
            for subject in ['feat: first', 'docs: second']:
                subprocess.run(['git', '-C', directory, 'commit', '-q', '--allow-empty', '-m', subject],
                               check=True, env=env)
            repo = {'cwd': directory, 'env': env}
            self.run_check([PR, 'ci: check', 'HEAD', 'HEAD'], True, **repo)
            self.run_check([PR, 'ci: check', 'HEAD~1', 'HEAD'], True, **repo)
            for base, head in [('missing-base', 'HEAD'), ('HEAD', 'missing-head'), ('HEAD~2', 'HEAD')]:
                self.run_check([PR, 'ci: check', base, head], False, **repo)
            self.run_check([PR, 'invalid', 'HEAD', 'HEAD'], False, **repo)
            self.run_check([PR], False, **repo)

    def test_enumeration_failure_and_subjects(self):
        with tempfile.TemporaryDirectory() as directory:
            git = Path(directory) / 'git'
            git.write_text('''#!/bin/sh
case "$1" in
  rev-parse) printf '%s\\n' abcdef ;;
  log)
    case "$MODE" in
      fail) exit 128 ;;
      partial) printf '%s\\n' 'fix: partial'; exit 128 ;;
      invalid) printf '%s\\n' 'fix: good' 'bad subject' 'docs: good' ;;
      valid) printf '%s\\n' 'fix: good' 'docs: good' ;;
      empty) exit 0 ;;
    esac ;;
  *) exit 99 ;;
esac
''')
            git.chmod(0o755)
            for mode in ['fail', 'partial', 'invalid', 'valid', 'empty']:
                with self.subTest(mode=mode):
                    env = dict(os.environ, PATH=directory + os.pathsep + os.environ['PATH'], MODE=mode)
                    self.run_check([PR, 'ci: check', 'base', 'head'], mode in ['valid', 'empty'], env=env)

    def test_hook(self):
        with tempfile.TemporaryDirectory() as directory:
            message = Path(directory) / 'message'
            for subject, ok in [('feat: good', True), ('Merge branch x', True),
                                ('fixup! feat: later', True), ('squash! fix: later', True),
                                ('Mergegarbage', False), ('feat:  ', False), ('bad', False)]:
                with self.subTest(subject=subject):
                    message.write_text(subject + '\n\nbody is not checked\n')
                    self.run_check([HOOK, message], ok)
            self.run_check([HOOK, Path(directory) / 'missing'], False)

    def test_workflow_contract(self):
        workflow = (ROOT / '.github/workflows/ci.yml').read_text()
        self.assertIn('types: [opened, synchronize, reopened, edited]', workflow)
        job = workflow.split('  commit-messages:\n', 1)[1].split('\n  rust-host:', 1)[0]
        self.assertIn("if: github.event_name == 'pull_request'", job)
        self.assertIn('fetch-depth: 0', job)
        self.assertIn('TITLE: ${{ github.event.pull_request.title }}', job)
        self.assertIn('BASE: ${{ github.event.pull_request.base.sha }}', job)
        self.assertIn('HEAD: ${{ github.event.pull_request.head.sha }}', job)
        self.assertIn('run: scripts/check-pr-commit-msg.sh "$TITLE" "$BASE" "$HEAD"', job)
        self.assertIn('python3 scripts/test-commit-msg.py', workflow)
        self.assertIn('All commits must use Conventional Commit messages and be cryptographically signed.',
                      (ROOT / 'AGENTS.md').read_text())


if __name__ == '__main__':
    unittest.main(verbosity=2)

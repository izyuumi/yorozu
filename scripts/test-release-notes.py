#!/usr/bin/env python3
"""Regression coverage for complete, exact-source release notes without network access."""

from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import release_notes as notes

SOURCE = 'f' * 40
BASE = 'a' * 40


def log(*messages):
    records = []
    for number, message in enumerate(messages, start=1):
        records += [f'{number:040x}', BASE, message]
    return '\0'.join(records) + '\0'


class ReleaseNotesTests(unittest.TestCase):
    @patch.object(notes, 'ancestor', return_value=True)
    def test_every_type_and_scope_including_custom_and_late_commits(self, _ancestor):
        messages = [f'{kind}(scope): change {kind}' for kind in notes.SECTIONS]
        messages += ['security(crypto): tighten validation', 'FiX(mac): change after version PR',
                     'legacy subject without a conventional prefix']
        with patch.object(notes, 'git', return_value=log(*messages)) as git:
            body = notes.render_notes('fixture/yorozu', '0.5.0', SOURCE, BASE)
        self.assertEqual(body.count('https://github.com/fixture/yorozu/commit/'), len(messages))
        for kind in notes.SECTIONS:
            self.assertIn(f'### {notes.SECTIONS[kind]}', body)
            self.assertIn(f'**scope:** change {kind}', body)
        self.assertIn('security: **crypto:** tighten validation', body)
        self.assertIn('change after version PR', body)
        self.assertIn('legacy subject without a conventional prefix', body)
        git.assert_called_once_with('log', '--reverse', '--topo-order', '-z', '--format=%H%x00%P%x00%B', f'{BASE}..{SOURCE}')
        self.assertIn(f'compare/{BASE}...{SOURCE}', body)

    def test_breaking_markers_and_multiline_footers(self):
        messages = ['feat(api)!: replace protocol',
                    'fix: remove fallback\n\nBREAKING CHANGE: configure the new endpoint\nthen rotate keys.\n\nRefs: #123',
                    'docs: revise deployment\n\nBREAKING-CHANGE: old deployment no longer works\nSigned-off-by: Other']
        with patch.object(notes, 'git', return_value=log(*messages)):
            body = notes.render_notes('fixture/yorozu', '0.5.0', SOURCE)
        self.assertEqual(body.count('### Breaking Changes'), 1)
        self.assertNotIn('### Features', body)
        self.assertIn('configure the new endpoint then rotate keys.', body)
        self.assertIn('old deployment no longer works', body)
        self.assertNotIn('Refs:', body)
        self.assertNotIn('Signed-off-by:', body)
        self.assertEqual(body.count('/commit/'), 3)

    def test_merge_wrappers_do_not_duplicate_but_conventional_merge_subjects_survive(self):
        raw = log('feat(mac): ship update')
        raw += '\0'.join(['b' * 40, f'{BASE} {SOURCE}', 'Merge pull request #9 from fixture/feature\n\nfeat(mac): ship update']) + '\0'
        raw += '\0'.join(['c' * 40, f'{BASE} {SOURCE}', 'fix: resolve merge conflict']) + '\0'
        with patch.object(notes, 'git', return_value=raw):
            body = notes.render_notes('fixture/yorozu', '0.5.0', SOURCE)
        self.assertEqual(body.count('ship update'), 1)
        self.assertIn('resolve merge conflict', body)
        self.assertNotIn('Merge pull request', body)

    @patch.object(notes, 'ancestor', return_value=True)
    def test_empty_range_is_explicit_and_commit_markup_is_escaped(self, _ancestor):
        with patch.object(notes, 'git', return_value=''):
            body = notes.render_notes('fixture/yorozu', '0.5.0', SOURCE, BASE)
        self.assertIn('No source changes', body)
        with patch.object(notes, 'git', return_value=log('fix(ui): render <script> [link](target) @team')):
            body = notes.render_notes('fixture/yorozu', '0.5.0', SOURCE)
        self.assertIn(r'\<script\>', body)
        self.assertNotIn('[link](target)', body)
        self.assertNotIn('@team', body)

    def test_base_uses_published_stable_ancestor_instead_of_global_latest_or_orphan_tags(self):
        releases = [{'tag_name': tag, 'draft': draft, 'prerelease': prerelease} for tag, draft, prerelease in (
            ('v0.4.0', False, False), ('v0.4.1', False, False), ('v0.5.0', False, False),
            ('candidate-0.6.0-10050', False, True), ('v0.4.2', True, False), ('v0.4.3', False, True))]
        gh = SimpleNamespace(api=Mock(return_value=[releases]), tag_sha=Mock(side_effect=lambda tag: tag))
        with patch.object(notes, 'ancestor', side_effect=lambda base, source: base == 'v0.4.0'):
            self.assertEqual(notes.stable_base(gh, '0.5.0', SOURCE), 'v0.4.0')
        self.assertEqual([call.args[0] for call in gh.tag_sha.call_args_list], ['v0.4.1', 'v0.4.0'])
        gh.api.assert_called_once_with('releases?per_page=100', '--paginate', '--slurp')

    def test_initial_release_and_missing_stable_tag(self):
        gh = SimpleNamespace(api=Mock(return_value=[[]]))
        self.assertIsNone(notes.stable_base(gh, '0.1.0', SOURCE))
        gh = SimpleNamespace(api=Mock(return_value=[[{'tag_name': 'v0.4.0', 'draft': False, 'prerelease': False}]]),
                             tag_sha=Mock(return_value=None))
        with self.assertRaisesRegex(ValueError, 'published stable release has no tag'):
            notes.stable_base(gh, '0.5.0', SOURCE)

    def test_invalid_source_and_diverged_explicit_base_fail(self):
        with self.assertRaisesRegex(ValueError, 'full commit SHAs'):
            notes.render_notes('fixture/yorozu', '0.5.0', '--all')
        with patch.object(notes, 'ancestor', return_value=False):
            with self.assertRaisesRegex(ValueError, 'ancestor'):
                notes.render_notes('fixture/yorozu', '0.5.0', SOURCE, BASE)
        with patch.object(notes.subprocess, 'run', return_value=SimpleNamespace(returncode=128)):
            with self.assertRaisesRegex(RuntimeError, 'complete Git history'):
                notes.ancestor(BASE, SOURCE)


if __name__ == '__main__':
    unittest.main()

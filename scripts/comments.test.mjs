import assert from 'node:assert/strict';
import { execFileSync, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const scanner = fileURLToPath(new URL('./comments.mjs', import.meta.url));

function fixtureRepo(t) {
  const cwd = mkdtempSync(join(tmpdir(), 'comments-test-'));
  t.after(() => rmSync(cwd, { recursive: true, force: true }));
  const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => !name.startsWith('GIT_')));
  const options = { cwd, env, encoding: 'utf8' };
  const git = (args) => execFileSync('git', args, options).trim();
  git(['init', '--quiet']);
  mkdirSync(join(cwd, 'scripts'));
  const write = (file, source) => {
    const path = join(cwd, file);
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, Array.isArray(source) ? source.join('\n') + '\n' : source);
  };
  const track = (files) => {
    for (const file of files) {
      const object = git(['hash-object', '-w', '--', file]);
      git(['update-index', '--add', '--cacheinfo', '100644', object, file]);
    }
  };
  const run = (...args) => {
    const result = spawnSync(process.execPath, [scanner, ...args], options);
    if (result.error) throw result.error;
    return result;
  };
  const ok = (...args) => {
    const result = run(...args);
    assert.equal(result.status, 0, result.stderr);
    return result.stdout;
  };
  return { git, write, track, run, ok, read: (file) => readFileSync(join(cwd, file), 'utf8') };
}

const lexerFixtures = [
  ['script.mjs', [
    'const a = "https://example.test/*literal*/", b = \'// literal\';',
    'const template = `// literal ${f(`/* literal */ ${x /* nested expression */}`)}`;',
    'const re = /[/*][//]a\\/[x]/gi; // regexp tail',
    'if (a) /[/*]/.test(a); // control regexp',
    'if (a) {} /[/*]/.test(a); // statement regexp',
    'const n = 24 / 3 /* division */ / 2;',
    'const m = obj.return / /* member division */ 2;',
    'const d = ({ value: 24 }) / 2; // object division',
    'const fn = function () {} / /* function division */ 2;',
    'async function f() {} /[/*]/.test(a); // after function',
    'const C = class {} / /* class division */ 2;',
    'class X {} /[/*]/.test(a); // after class',
  ], ['/* nested expression */', '// regexp tail', '// control regexp', '// statement regexp',
    '/* division */', '/* member division */', '// object division', '/* function division */',
    '// after function', '/* class division */', '// after class']],
  ['view.tsx', [
    'const id = <T,>(x: T) => x; // generic',
    'const other = <T extends string>(x: T) => x; // constrained generic',
    'const n = value! / /* non-null assertion division */ 2;',
    'const view = <><a title="/* literal */">don\'t count // text</a>{/* JSX */}',
    '<b>{(x: string) => `// literal ${x /* expression */}`}</b></>; // after JSX',
  ], ['// generic', '// constrained generic', '/* non-null assertion division */', '/* JSX */', '/* expression */', '// after JSX']],
  ['source.swift', [
    'let a = "escaped \\" and // literal" // escaped quote',
    'let b = "outer \\(f("/* literal */", 2 /* interpolation */)) // literal"',
    'let c = ###"literal "# // literal \\###(f(#"// literal"#))"### // raw string',
    'let d = """',
    '// literal',
    '\\(f("/* literal */"))',
    '""" // multiline string',
    'let e = ##"""',
    '/* literal */',
    '"""## // multiline raw string',
    'let r = /[/*][//]/ // bare regex',
    'let raw = ##/[/*]/ # // literal',
    '/## // raw regex',
    'let q = a / b /* division */',
    '/* outer /* nested */',
    '   end */',
  ], ['// escaped quote', '/* interpolation */', '// raw string', '// multiline string',
    '// multiline raw string', '// bare regex', '// raw regex', '/* division */', '/* outer /* nested */\n   end */']],
  ['source.rs', [
    '#![allow(dead_code)]',
    "fn run<'a>(x: &'a str) -> &'a str {",
    String.raw`let chars = ['a', '\n', '\'', '\u{1f60e}', '😎']; let byte = b'\x2f';`,
    'let raw = r"// literal"; let raw2 = br###"/* literal */ //"## still raw"###;',
    'let literal = "/* string */"; /* outer /* nested */ end */',
    "let _: &'static str = x; // lifetime tail",
    'x',
    '}',
  ], ['/* outer /* nested */ end */', '// lifetime tail']],
  ['config.jsonc', [
    '{"key": "// literal \\" /* literal */", /* actual */',
    ' "second": "// quote" // trailing',
    '}',
  ], ['/* actual */', '// trailing']],
  ['style.css', [
    'a::before { content: "/* literal */ // literal"; }',
    '// CSS text',
    "a::after { content: 'escaped \\' /* still literal */'; }",
    'a { background: url(https://example.test/*literal); }',
    'a { --value: \\/* escaped slash; } /* style */',
  ], ['/* style */']],
  ['page.astro', [
    '---',
    'const s = `// literal',
    '---',
    '`;',
    '// Frontmatter',
    '---',
    '<div title="<!-- literal -->">{/* Astro */}{`/* literal */`}</div>',
    '<!-- markup -->',
    '<SCRIPT type="module">const a = /[/*]/; // script',
    'const s = "/* literal */";</SCRIPT>',
    '<style>a { content: "/* literal */"; } /* style */</style>',
  ], ['// Frontmatter', '/* Astro */', '<!-- markup -->', '// script', '/* style */']],
  ['page.html', [
    '<div title="<!-- literal -->">{/* HTML text */}</div>',
    '<textarea><!-- literal --></textarea>',
    '<!-- real',
    '    <script>// in HTML comment</script> -->',
    '<script>const a = "`// literal"; /* script */</script>',
    '<style>/* CSS */ a { content: "// literal"; }</style>',
  ], ['<!-- real\n    <script>// in HTML comment</script> -->', '/* script */', '/* CSS */']],
  ['script.bash', [
    '#!/usr/bin/env bash',
    "printf '%s\\n' a#b $# \${#x} \${x#y} \${x//#/x} '# literal' $'escaped \\' # literal'",
    'echo "# literal $(echo x # inside substitution',
    ')" # shell tail',
    'echo \\#escaped;# after separator',
    'echo continued\\',
    '#part_of_word',
    'echo $((16#ff<<1)) # radix and shift',
    'cat <<EOF <<-\'TABS\' <<"DOUBLE"',
    '# first heredoc',
    'EOF',
    '\t# second heredoc',
    '\tTABS',
    '# third heredoc',
    'DOUBLE',
    "cat <<'SINGLE'",
    '# fourth heredoc',
    'SINGLE',
    'cat <<< "# literal" # here string tail',
  ], ['# inside substitution', '# shell tail', '# after separator', '# radix and shift', '# here string tail']],
  ['script.sh', ['echo a|# comment after a pipe', 'cat <<\\EOF', '# heredoc', 'EOF'], ['# comment after a pipe']],
  ['script.py', [
    '# -*- coding: utf-8 -*-',
    "a = r'# literal'; b = b\"escaped \\\" # literal\"",
    "c = '''",
    '# literal',
    "'''",
    'd = r"""# literal""" # triple tail',
    'e = fr"{call("## literal")} # literal {{ braces }} {num:#04x}"',
    'f = f"""{(num # f-expression',
    ')} # literal""" # f-string tail',
    '# noqa: E123',
  ], ['# triple tail', '# f-expression', '# f-string tail']],
  ['f-strings.py', [
    'match = re.search(',
    String.raw`        rf"/\* {re.escape(target)} \*/ = \{{[^}}]*isa = PBXNativeTarget;.*?buildPhases = \((.*?)\);",`,
    '        # Generated Tuist bundles live under Derived/; still scan them if present.',
    '        text,',
    ')',
    String.raw`a = fR"\{{ # literal \}} \"escaped" # raw f-string tail`,
    String.raw`b = Rb"\" # literal"; c = BR'\' # literal' # raw bytes tail`,
    String.raw`d = r"\\" # even backslashes`,
    String.raw`e = F"\{call("# literal")} {num:=#8x}" # f-string tail`,
    'f = RF"""{ {"}": f"""{call("# literal")}"""}["}"]:{width}}',
    '# literal',
    '""" # triple f-string tail',
  ], ['# Generated Tuist bundles live under Derived/; still scan them if present.',
    '# raw f-string tail', '# raw bytes tail', '# even backslashes', '# f-string tail', '# triple f-string tail']],
  ['script.ps1', [
    "#region helpers",
    "Write-Host 'can''t # literal'",
    'Write-Host "escaped `" # literal $("fake # again")" # double quote tail',
    '$literal = @"',
    '# literal',
    '<# literal #>',
    '"@',
    "$other = @'",
    '# literal',
    "'@",
    '<# first',
    'second #> # after block',
    '#endregion',
  ], ['# double quote tail', '<# first\nsecond #>', '# after block']],
  ['workflow.yml', [
    "value: 'can''t # literal' # YAML tail",
    'title: Can\'t "open # plain scalar comment',
    'url: https://example.test/#fragment',
    'jobs:',
    '  - run: | # scalar header',
    '      printf "%s" \'# literal\' \${x#y} \${#x}',
    '      cat <<\'EOF\'',
    '      # literal in workflow heredoc',
    '      EOF',
    '      # shell in YAML',
    '    shell: bash # after scalar',
    '  - run: >2-',
    '      echo a#literal;# folded scalar',
    '  - uses: owner/repo@0123456789abcdef0123456789abcdef01234567 # v2',
    '  - uses: owner/repo@main # unpinned',
  ], ['# YAML tail', '# plain scalar comment', '# scalar header', '# shell in YAML', '# after scalar',
    '# folded scalar', '# unpinned']],
  ['config.yaml', [
    'flow: {a: "literal # hash", b: \'can\'\'t # literal\'} # flow tail',
    'value: &value "quoted # hash" # anchored tail',
  ], ['# flow tail', '# anchored tail']],
  ['config.toml', [
    "first = 'single # literal' # first tail",
    'basic = "escaped \\" # literal"',
    'multi = """',
    '# literal',
    'ends with quote"""" # multi tail',
    "raw = '''",
    '# literal',
    "also ends with quote'''' # raw tail",
    "windows = 'C:\\temp\\' # literal backslash",
  ], ['# first tail', '# multi tail', '# raw tail', '# literal backslash']],
  ['shell', ['#! /usr/bin/env -S bash -e', 'printf \'# literal\' # extensionless shell'], ['# extensionless shell']],
  ['.hook', ['#!/bin/sh', 'echo ok # extensionless dotfile'], ['# extensionless dotfile']],
  ['python', ['#!/usr/bin/env -S python3.12 -u', 'x = "# literal" # extensionless python'], ['# extensionless python']],
];

test('tokenizes supported languages in tracked files and skips unrelated files', (t) => {
  const { write, track, ok } = fixtureRepo(t);
  for (const [file, source] of lexerFixtures) write('fixtures/' + file, source);
  const skipped = ['readme.md', 'data.json', 'image.png', 'app.plist', 'strings.xcstrings', 'launch.storyboard',
    'pnpm-lock.yaml', 'Cargo.lock', 'node-script', 'no-shebang'];
  for (const file of skipped) {
    write('fixtures/' + file, ['#!/usr/bin/env node python', '# invisible', '// invisible']);
  }
  write('fixtures/untracked.js', ['// invisible']);
  write('other.js', ['// outside selection']);
  write('apps/web/src/hero/kit/vendor.ts', ['// vendored comment']);
  track(['other.js', 'apps/web/src/hero/kit/vendor.ts',
    ...[...lexerFixtures.map(([file]) => file), ...skipped].map((file) => 'fixtures/' + file)]);

  const records = JSON.parse(ok('list', '--json', 'fixtures'));
  assert.deepEqual([...new Set(records.map(({ file }) => file))].sort(),
    lexerFixtures.map(([file]) => 'fixtures/' + file).sort());
  for (const [file, , expected] of lexerFixtures) {
    assert.deepEqual(records.filter((record) => record.file === 'fixtures/' + file).map(({ text }) => text),
      expected, file);
  }
  assert.equal(ok('list', 'apps/web/src/hero/kit'), '0 comments, 0 comment lines\n');
});

test('lists raw blocks and counts shared physical lines once', (t) => {
  const { write, track, ok } = fixtureRepo(t);
  const file = 'with spaces.ts';
  write(file, [
    '  // first',
    '    /// second',
    '',
    'let n = 1; // after code',
    '// independent',
    '/* a',
    ' b */ /* separate */',
    '/* empty first line',
    '*/',
  ].join('\r\n'));
  track([file]);
  assert.deepEqual(JSON.parse(ok('list', '--json', file)), [
    { file, line: 1, endLine: 2, lines: 2, text: '// first\r\n    /// second' },
    { file, line: 4, endLine: 4, lines: 1, text: '// after code' },
    { file, line: 5, endLine: 5, lines: 1, text: '// independent' },
    { file, line: 6, endLine: 7, lines: 2, text: '/* a\r\n b */' },
    { file, line: 7, endLine: 7, lines: 1, text: '/* separate */' },
    { file, line: 8, endLine: 9, lines: 2, text: '/* empty first line\r\n*/' },
  ]);
  assert.equal(ok('list', file), [
    file + ':1: // first', file + ':4: // after code', file + ':5: // independent',
    file + ':6: /* a', file + ':7: /* separate */', file + ':8: /* empty first line',
    '6 comments, 8 comment lines', '',
  ].join('\n'));
  assert.equal(ok('stats'), 'TypeScript: 6 comments, 8 comment lines, 0 directives\nTotal: 6 comments, 8 comment lines, 0 directives\n');
});

test('protects directives and Rust safety sections from the ratchet', (t) => {
  const { write, track, ok } = fixtureRepo(t);
  write('config.ts', [
    '#!/usr/bin/env node',
    '// Copyright 2026 Example',
    '// License header continuation',
    '',
    '/// <reference types="node" />',
    '// @ts-expect-error missing types',
    '// @ts-ignore',
    '// @ts-nocheck',
    '// @ts-check',
    '/* eslint-disable-next-line rule */',
    '/* eslint-enable */',
    '/* eslint-env browser */',
    '/* global process */',
    '/* @jsx h */',
    '/* @jsxImportSource preact */',
    '// prettier-ignore',
    '// biome-ignore rule: reason',
    '/* c8 ignore next */',
    '/* istanbul ignore next */',
    '/* v8 ignore next */',
    "const chunk = import(/* webpackChunkName: 'test' */ './module');",
    "const module = import(/* @vite-ignore */ './module');",
    '/* SPDX-License-Identifier: MIT */',
    '/** @license MIT */',
    'const x = 1;',
    '// Copyright is discussed here',
    '// region of code',
    '// <reference is ordinary text',
  ]);
  write('Package.swift', [
    '// swift-tools-version: 6.0', '// swiftlint:disable rule', '// swift-format-ignore', '// sourcery: Auto',
  ]);
  write('source.rs', [
    '// SAFETY: valid pointer',
    '// continuation',
    'unsafe { do_work(); }',
    '/// Normal docs.',
    '/// # Safety',
    '/// Caller owns the pointer.',
    '/// ## Preconditions',
    '/// Use a non-null pointer.',
    '/// # Examples',
    '/// Normal example.',
    'unsafe fn f() {}',
    '/**',
    ' * Before safety.',
    ' * # Safety',
    ' * A safety condition.',
    ' * # Examples',
    ' * After safety.',
    ' */',
    'unsafe fn g() {}',
  ]);
  write('script.sh', ['#!/bin/sh', '# shellcheck disable=SC2086', '# syntax=docker/dockerfile:1', 'echo done']);
  write('script.py', ['# -*- coding: utf-8 -*-', 'pass # type: ignore', 'pass # pragma: no cover', 'pass # noqa']);
  write('workflow.yaml', [
    '# yaml-language-server: $schema=schema.json',
    '- uses: owner/repo/path@0123456789abcdef0123456789abcdef01234567 # v1',
  ]);
  write('script.ps1', ['#region scripts', '#endregion']);
  track(['config.ts', 'Package.swift', 'source.rs', 'script.sh', 'script.py', 'workflow.yaml', 'script.ps1']);

  const listed = JSON.parse(ok('list', '--json'));
  assert.deepEqual(listed.map(({ file, line, lines }) => [file, line, lines]), [
    ['config.ts', 26, 3], ['source.rs', 4, 1], ['source.rs', 9, 2], ['source.rs', 12, 5],
  ]);
  assert.match(ok('stats'), /^Rust: 3 comments, 8 comment lines, 3 directives$/m);
  assert.match(ok('stats'), /^YAML: 0 comments, 0 comment lines, 2 directives$/m);
  assert.match(ok('stats'), /^Total: 4 comments, 11 comment lines, [1-9]\d+ directives$/m);
  ok('baseline');
  write('source.rs', [
    '// SAFETY: another valid pointer', 'unsafe { do_work(); }',
    '/// Normal docs.', '/// # Safety', '/// Updated precondition.', '/// # Examples', '/// Normal example.',
    'unsafe fn f() {}',
    '/**', ' * Before safety.', ' * # Safety', ' * Updated safety condition.', ' * # Examples', ' * After safety.', ' */',
    'unsafe fn g() {}',
  ]);
  assert.equal(ok('check'), 'comments: OK (4 baselined)\n');
});

test('baseline is stable and matches duplicate blocks by file and normalized text', (t) => {
  const { git, write, track, run, ok, read } = fixtureRepo(t);
  const path = 'scripts/comment-baseline.json';
  const a = 'a.ts';
  const b = 'b.ts';
  write(a, ['// zebra', '', '// same   text', '', '/** same text */']);
  write(b, ['// first', '  /// second']);
  track([a, b]);
  const withoutBaseline = git(['write-tree']);
  const missing = run('check');
  assert.equal(missing.status, 1);
  assert.deepEqual(missing.stderr.trim().split('\n').map((message) => message.split(':').slice(0, 2).join(':')),
    ['a.ts:1', 'a.ts:3', 'a.ts:5', 'b.ts:1']);
  ok('baseline');
  const stable = read(path);
  assert.equal(stable, JSON.stringify({
    version: 1,
    comments: { [a]: ['same text', 'same text', 'zebra'], [b]: ['first second'] },
  }, null, 2) + '\n');
  track([path]);
  const base = git(['write-tree']);
  assert.equal(ok('check', '--base', withoutBaseline), 'comments: OK (4 baselined)\n');

  write(a, ['const shifted = true;', '/** zebra */', '', '// same', '// text', '', '/* same text */']);
  assert.equal(ok('check', '--base', base), 'comments: OK (4 baselined)\n');
  ok('baseline');
  assert.equal(read(path), stable);

  write(a, ['// same text', '', '// same text', '', '// same text']);
  const changed = run('check', '--base', base);
  assert.equal(changed.status, 1);
  assert.match(changed.stderr, /^a\.ts:5: \/\/ same text$/m);
  assert.match(changed.stderr, /a\.ts: stale baseline entry "zebra"/);
  assert.match(changed.stderr, /node scripts\/comments\.mjs baseline to shrink it/);
  ok('baseline');
  const replaced = run('check', '--base', base);
  assert.equal(replaced.status, 1);
  assert.match(replaced.stderr, /baseline entry added since .*: "same text"/);

  write(b, ['// moved from a.ts']);
  write(a, ['// same text']);
  ok('baseline');
  const moved = run('check', '--base', base);
  assert.equal(moved.status, 1);
  assert.match(moved.stderr, /^b\.ts: baseline entry added since .*: "moved from a.ts"$/m);

  write(a, ['// same text', '', '// same text', '', '// zebra', '', '// added']);
  write(b, ['// first', '  /// second']);
  ok('baseline');
  const grew = run('check', '--base', base);
  assert.equal(grew.status, 1);
  assert.match(grew.stderr, /baseline entry added since .*: "added"/);

  write(a, ['// same text']);
  write(b, '');
  ok('baseline');
  assert.equal(ok('check', '--base', base), 'comments: OK (1 baselined)\n');
});


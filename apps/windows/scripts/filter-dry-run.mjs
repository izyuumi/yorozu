// Dry-runs the `on: push` path filters of every workflow against sample files, and fails if
// a Windows client path would start a release or deploy. Node built-ins only.
// Run from anywhere: node apps/windows/scripts/filter-dry-run.mjs
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), '..', '..', '..');
const workflowsDir = join(repoRoot, '.github', 'workflows');

const failures = [];
const check = (ok, message) => { if (!ok) failures.push(message); };

// --- GitHub's filter patterns -------------------------------------------------------------

// `**` any characters, `*` any except `/`, `?` one except `/`; the whole path must match.
function globToRegExp(glob) {
  let source = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*' && glob[i + 1] === '*') { source += '.*'; i++; }
    else if (c === '*') source += '[^/]*';
    else if (c === '?') source += '[^/]';
    else source += c.replace(/[\\^$.|+()[\]{}]/, '\\$&');
  }
  return new RegExp(`^${source}$`);
}

// Patterns apply in order, a leading `!` negates, and the last one that matches decides.
function included(patterns, value) {
  let result = false;
  for (const pattern of patterns) {
    const negated = pattern.startsWith('!');
    if (globToRegExp(negated ? pattern.slice(1) : pattern).test(value)) result = !negated;
  }
  return result;
}

// --- The `on:` block ----------------------------------------------------------------------

const unquote = (s) => {
  const t = s.trim();
  return /^'.*'$|^".*"$/.test(t) ? t.slice(1, -1) : t;
};
const indentOf = (line) => line.length - line.trimStart().length;
const isBlank = (line) => /^\s*(#.*)?$/.test(line);

// A list value: inline `['a', b]` after the key, or `- 'a'` lines below it.
function parseList(file, key, inline, childLines) {
  const fail = (why) => { throw new Error(`${file}: cannot parse \`${key}\` (${why})`); };
  if (inline) {
    const m = inline.match(/^\[(.*)\]\s*(#.*)?$/);
    if (!m) return [unquote(inline.replace(/\s+#.*$/, ''))]; // a single scalar
    return (m[1].match(/'[^']*'|"[^"]*"|[^,\s][^,]*/g) ?? []).map(unquote);
  }
  const items = childLines.map((line) => {
    const m = line.match(/^\s*-\s+(.*)$/);
    if (!m) fail(`unexpected line "${line.trim()}"`);
    const item = m[1].trim();
    return /^['"]/.test(item) ? unquote(item.replace(/(['"])\s+#.*$/, '$1')) : item.replace(/\s+#.*$/, '');
  });
  if (items.length === 0) fail('empty list');
  return items;
}

// Splits lines into `key: value` entries at their shallowest indent, each with its deeper lines.
function entries(file, lines) {
  const body = lines.filter((line) => !isBlank(line));
  if (body.length === 0) return [];
  const indent = indentOf(body[0]);
  const out = [];
  for (const line of body) {
    if (indentOf(line) > indent && out.length > 0) { out.at(-1).children.push(line); continue; }
    const m = line.match(/^\s*(['"]?)([A-Za-z_-]+)\1:\s*(.*)$/);
    if (indentOf(line) !== indent || !m) throw new Error(`${file}: cannot parse the \`on:\` block at "${line.trim()}"`);
    out.push({ key: m[2], value: m[3].replace(/^#.*$/, '').trim(), children: [] });
  }
  return out;
}

// Returns { name, push }, where push is null or { branches, tags, paths, pathsIgnore } (each a list or undefined).
function parseWorkflow(file) {
  const lines = readFileSync(join(workflowsDir, file), 'utf8').split(/\r?\n/);
  const name = unquote(lines.find((line) => /^name:/.test(line))?.slice(5) ?? file);
  const start = lines.findIndex((line) => /^(on|'on'|"on"):/.test(line));
  if (start < 0) throw new Error(`${file}: no top-level \`on:\` key`);

  const inline = lines[start].replace(/^[^:]+:/, '').replace(/\s+#.*$/, '').trim();
  if (inline) { // `on: push` or `on: [push, pull_request]`
    const events = parseList(file, 'on', inline, []);
    return { name, push: events.includes('push') ? {} : null };
  }

  let end = lines.findIndex((line, i) => i > start && !isBlank(line) && indentOf(line) === 0);
  if (end < 0) end = lines.length;
  const events = entries(file, lines.slice(start + 1, end));
  if (events.length === 0) throw new Error(`${file}: the \`on:\` block is empty`);

  const pushEvent = events.find((event) => event.key === 'push');
  if (!pushEvent) return { name, push: null };
  const push = {};
  const keys = { branches: 'branches', tags: 'tags', paths: 'paths', 'paths-ignore': 'pathsIgnore' };
  for (const { key, value, children } of entries(file, pushEvent.children)) {
    if (!(key in keys)) throw new Error(`${file}: unsupported \`push.${key}\` filter`);
    push[keys[key]] = parseList(file, `push.${key}`, value, children);
  }
  if (push.paths && push.pathsIgnore) throw new Error(`${file}: \`paths\` and \`paths-ignore\` together`);
  return { name, push };
}

// A push to main: no ref filter at all, or a `branches` filter that includes main.
const runsOnMain = (push) => (push.branches ? included(push.branches, 'main') : !push.tags);

// The workflow runs if any changed file passes its path filter; no filter passes every file.
function triggers(push, files) {
  if (push.paths) return files.some((file) => included(push.paths, file));
  if (push.pathsIgnore) return files.some((file) => !included(push.pathsIgnore, file));
  return true;
}

// --- Run ----------------------------------------------------------------------------------

let workflows;
try {
  workflows = readdirSync(workflowsDir).filter((file) => file.endsWith('.yml')).sort()
    .map(parseWorkflow).filter((workflow) => workflow.push && runsOnMain(workflow.push));
} catch (error) {
  console.error(`filter dry-run: FAIL\n  ${error.message}`);
  process.exit(1);
}

// e. The matcher itself.
check(globToRegExp('apps/**').test('apps/a/b/c'), 'glob: `apps/**` must match apps/a/b/c');
check(!globToRegExp('apps/*').test('apps/a/b'), 'glob: `apps/*` must not match apps/a/b');
check(globToRegExp('apps/*').test('apps/a'), 'glob: `apps/*` must match apps/a');
check(!globToRegExp('apps/**').test('xapps/a'), 'glob: `apps/**` must be anchored');
check(!globToRegExp('a.b').test('axb'), 'glob: `.` must be literal');
check(globToRegExp('a?c').test('abc') && !globToRegExp('a?c').test('a/c'), 'glob: `?` must match one character except /');
const ordered = ['apps/**', '!apps/windows/**', 'apps/windows/keep/**'];
check(included(ordered, 'apps/windows/keep/x'), 'order: a later include must win over an earlier `!`');
check(!included(ordered, 'apps/windows/x'), 'order: `!` must win over an earlier include');
check(included(ordered, 'apps/ios/x'), 'order: an unrelated path must stay included');
check(!included(['!apps/**'], 'apps/x') && !included(['apps/**'], 'docs/x'), 'order: nothing included without a positive match');

const isolated = ['apps/windows/core/src/lib.rs', 'apps/windows/app/src/main.tsx', 'apps/windows/README.md',
  'pnpm-workspace.yaml', 'pnpm-lock.yaml'];
const w0 = ['.github/workflows/checks.yml', '.github/workflows/release-mac.yml', 'apps/windows/Cargo.toml',
  'apps/windows/core/Cargo.toml', 'apps/windows/core/src/lib.rs', 'apps/windows/README.md',
  'apps/windows/scripts/filter-dry-run.mjs'];
const samples = [
  ...isolated.map((file) => ({ label: file, files: [file], expect: [] })),                            // a
  { label: '(the W0 change set)', files: w0, expect: [] },                                           // b
  { label: 'apps/ios/x.swift', files: ['apps/ios/x.swift'], runs: ['Release iOS', 'Release Mac'] },  // c
  { label: 'apps/relay/src/index.ts', files: ['apps/relay/src/index.ts'], runs: ['Deploy relay'] },  // d
  { label: 'apps/web/index.html', files: ['apps/web/index.html'], runs: ['Deploy website'] },
  { label: 'apps/mac/x.swift', files: ['apps/mac/x.swift'], runs: ['Release Mac'] },
  { label: 'apps/mcp/src/x.ts', files: ['apps/mcp/src/x.ts'], skips: ['Release Mac'] },
];

const names = workflows.map((workflow) => workflow.name);
for (const sample of samples) {
  sample.ran = workflows.filter((workflow) => triggers(workflow.push, sample.files)).map((workflow) => workflow.name);
  for (const name of [...(sample.runs ?? []), ...(sample.skips ?? [])]) {
    check(names.includes(name), `no push-to-main workflow is named "${name}" (needed for ${sample.label})`);
  }
  if (sample.expect) check(sample.ran.length === 0, `${sample.label} must trigger no push workflow, but triggers: ${sample.ran.join(', ')}`);
  for (const name of sample.runs ?? []) check(sample.ran.includes(name), `${sample.label} must trigger "${name}"`);
  for (const name of sample.skips ?? []) check(!sample.ran.includes(name), `${sample.label} must not trigger "${name}"`);
}

// --- Report -------------------------------------------------------------------------------

const table = (rows) => {
  const widths = rows[0].map((_, column) => Math.max(...rows.map((row) => row[column].length)));
  for (const [i, row] of rows.entries()) {
    console.log(row.map((cell, column) => cell.padEnd(widths[column])).join('  ').trimEnd());
    if (i === 0) console.log(widths.map((width) => '-'.repeat(width)).join('  '));
  }
};
const describe = (push) => [
  `branches: ${push.branches ? push.branches.join(', ') : '(all)'}`,
  push.paths ? `paths: ${push.paths.join(', ')}` : push.pathsIgnore ? `paths-ignore: ${push.pathsIgnore.join(', ')}` : 'paths: (every file)',
].join('; ');

console.log('Push-to-main workflows\n');
table([['workflow', 'push filter'], ...workflows.map((workflow) => [workflow.name, describe(workflow.push)])]);
console.log('\nSamples\n');
table([['changed file', ...names], ...samples.map((sample) => [sample.label, ...names.map((name) => (sample.ran.includes(name) ? 'run' : 'no run'))])]);
console.log(`\n(the W0 change set) = ${w0.join(', ')}\n`);

if (failures.length > 0) {
  console.error(`filter dry-run: FAIL\n${failures.map((failure) => `  - ${failure}`).join('\n')}`);
  process.exit(1);
}
console.log('filter dry-run: PASS');

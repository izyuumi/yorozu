import assert from 'node:assert/strict';
import { access, readFile } from 'node:fs/promises';
import test from 'node:test';

const web = new URL('../', import.meta.url);
const repo = new URL('../../', web);
const read = (path, base = web) => readFile(new URL(path, base), 'utf8');
const source = await read('public/llms.txt');
const links = [...source.matchAll(/\]\((\S+?)\)/g)].map(([, url]) => url);

test('/llms.txt and /llm.txt serve the same bytes as public/llms.txt', async () => {
  assert.equal(await read('dist/llms.txt'), source);
  assert.equal(await read('dist/llm.txt'), source);
});

test('llms.txt follows the llmstxt.org format, in plain English', () => {
  const lines = source.split('\n');
  assert.equal(lines[0], '# Yorozu');
  assert.ok(lines.some(line => line.startsWith('> ')));
  assert.ok(lines.some(line => line.startsWith('## ')));
  for (const line of lines.filter(line => line.includes(']('))) assert.match(line, /^- \[[^\]]+\]\(https:\/\/[^)\s]+\): \S/, line);
  assert.doesNotMatch(source, /http:\/\//);
  assert.doesNotMatch(source, /[^\x00-\x7f]/);
});

test('_headers serves both files as UTF-8 plain text', async () => {
  const headers = await read('dist/_headers');
  for (const path of ['/llms.txt', '/llm.txt']) assert.ok(headers.includes(`${path}\n  Content-Type: text/plain; charset=utf-8`), path);
});

test('every link points at a built page, a worker or redirect route, a repo file or a known URL', async () => {
  const worker = await read('worker.mjs');
  // The worker's own routes: `path === '/mcp'` checks and the `[...].includes(path)` list (/mac and the betas)
  const routes = [...worker.matchAll(/path === '([^']+)'/g), ...worker.match(/\[([^\]]+)\]\.includes\(path\)/)[1].matchAll(/'([^']+)'/g)]
    .map(([, route]) => route);
  const redirects = Object.fromEntries((await read('public/_redirects')).split('\n').map(line => line.split(' ')));
  const known = [redirects['/iphone'], 'https://github.com/izyuumi/yorozu'];
  for (const url of links) {
    if (url.startsWith('https://yorozu.yumi.to/')) {
      const path = new URL(url).pathname;
      if (routes.includes(path) || redirects[path]) continue;
      await access(new URL(`dist${path}${path.endsWith('/') ? 'index.html' : ''}`, web));
    } else if (url.startsWith('https://github.com/izyuumi/yorozu/blob/main/')) {
      await access(new URL(url.slice('https://github.com/izyuumi/yorozu/blob/main/'.length), repo));
    } else {
      assert.ok(known.includes(url), url);
    }
  }
});

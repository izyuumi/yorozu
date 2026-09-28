import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import test from 'node:test';

// Checks `astro build` output (run it first): what the Worker serves and what the CSP allows.
const dist = new URL('../dist/', import.meta.url);
const pages = (await readdir(dist, { recursive: true })).filter(file => file.endsWith('.html'));

test('the build keeps every public URL and the Cloudflare routing files', async () => {
  for (const file of ['index.html', 'privacy/index.html', 'terms/index.html', '_headers', '_redirects', 'copy.js', 'styles.css', 'pair/index.html', 'pair.js']) {
    await readFile(new URL(file, dist));
  }
});

test('pages carry no inline styles or scripts, which the CSP in _headers would block', async () => {
  assert.ok(pages.length > 0);
  for (const file of pages) {
    const html = await readFile(new URL(file, dist), 'utf8');
    assert.doesNotMatch(html, /<style|\sstyle=/i, file);
    for (const [tag] of html.matchAll(/<script\b[^>]*>/gi)) assert.match(tag, /\ssrc=/, `${file}: ${tag}`);
  }
});

test('the phone app claims the pairing page, and nothing broader', async () => {
  const association = JSON.parse(await readFile(new URL('.well-known/apple-app-site-association', dist), 'utf8'));
  const [details] = association.applinks.details;
  assert.deepEqual(details.appIDs, ['AN5KM8QGEF.to.yumi.yorozu.ios']);
  assert.deepEqual(details.components.map(component => component['/']), ['/pair', '/pair/']);
  // Served as JSON: without an extension, the default type would be a guess.
  assert.match(await readFile(new URL('_headers', dist), 'utf8'),
    /\/\.well-known\/apple-app-site-association\n\s+Content-Type: application\/json/);
});

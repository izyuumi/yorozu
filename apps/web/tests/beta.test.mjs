import assert from 'node:assert/strict';
import { afterEach, mock, test } from 'node:test';
import worker from '../worker.mjs';

const download = 'https://github.com/izyuumi/yorozu/releases/download/';
const tag = 'candidate-0.10.0-10042';
const manifest = {
  schema: 1, tag, version: '0.10.0', build: '10042', source_branch: 'main',
  source_sha: 'a'.repeat(40), mac: { asset: 'yorozu.dmg' },
};
function release(name = tag, branch = 'main') {
  return {
    tag_name: name, name: branch === 'main' ? `Yorozu Beta ${name}` : `Yorozu ${name}`,
    draft: false, prerelease: true,
    assets: ['candidate.json', 'appcast.xml', 'yorozu.dmg'].map(asset => ({
      name: asset, state: 'uploaded', browser_download_url: `${download}${name}/${asset}`,
    })),
  };
}
function upstream(pages, candidate = manifest) {
  const requests = [];
  mock.method(globalThis, 'fetch', async (url, options) => {
    requests.push(url);
    assert.equal(options.cf.cacheTtlByStatus['200-299'], 300);
    assert.equal(options.cf.cacheTtlByStatus['400-599'], 0);
    if (url.endsWith('/candidate.json')) return Response.json(candidate);
    return Response.json(pages[Number(new URL(url).searchParams.get('page')) - 1] ?? []);
  });
  return requests;
}
const request = (path, init) => worker.fetch(new Request(`https://yorozu.yumi.to${path}`, init), {
  ASSETS: { fetch: async () => new Response('static site') },
});
afterEach(() => mock.restoreAll());

test('both beta routes use newest numeric main candidate across all release pages', async () => {
  const first = [release('candidate-0.9.0-10041'), release('candidate-1.0.0-20000', 'release/1.0'),
    { ...release('candidate-2.0.0-30000'), draft: true },
    { ...release('candidate-3.0.0-40000'), prerelease: false }];
  while (first.length < 100) first.push({ tag_name: 'v0.1.0', draft: false, prerelease: false });
  const requests = upstream([first, [release()]]);
  const feed = await request('/beta/appcast.xml');
  assert.equal(feed.status, 302);
  assert.equal(feed.headers.get('location'), `${download}${tag}/appcast.xml`);
  assert.equal(feed.headers.get('cache-control'), 'public, max-age=60');
  assert.match(requests[1], /page=2$/);
  assert.equal(requests[2], `${download}${tag}/candidate.json`);
  const dmg = await request('/beta', { method: 'HEAD' });
  assert.equal(dmg.headers.get('location'), `${download}${tag}/yorozu.dmg`);
  assert.equal(await dmg.text(), '');
});

test('build breaks equal-version ties without relying on release ordering or timestamps', async () => {
  upstream([[release('candidate-0.10.0-9999'), release(), release('candidate-0.9.0-99999')]]);
  const response = await request('/beta/');
  assert.equal(response.headers.get('location'), `${download}${tag}/yorozu.dmg`);
});

test('versioned beta tag serves uppercase installer before legacy candidate', async () => {
  const beta = 'v0.5.0-beta';
  const current = { ...release(beta), name: `Yorozu ${beta}`,
    assets: ['candidate.json', 'appcast.xml', 'Yorozu.dmg'].map(asset => ({
      name: asset, state: 'uploaded', browser_download_url: `${download}${beta}/${asset}`,
    })) };
  upstream([[release(), current]], { ...manifest, tag: beta, version: '0.5.0', mac: { asset: 'Yorozu.dmg' } });
  assert.equal((await request('/beta')).headers.get('location'), `${download}${beta}/Yorozu.dmg`);
});

test('Mac download prefers uppercase installer and supports shipped lowercase stable asset', async () => {
  for (const names of [['yorozu.dmg'], ['yorozu.dmg', 'Yorozu.dmg']]) {
    mock.restoreAll();
    mock.method(globalThis, 'fetch', async () => Response.json({
      tag_name: 'v0.4.0', assets: names.map(name => ({
        name, state: 'uploaded', browser_download_url: `${download}v0.4.0/${name}`,
      })),
    }));
    const selected = names.at(-1);
    assert.equal((await request('/mac')).headers.get('location'), `${download}v0.4.0/${selected}`);
  }
});

test('newest candidate metadata must match its main identity; never silently fall back', async () => {
  for (const mismatch of [
    { source_branch: 'release/0.10' }, { source_sha: '../main' }, { tag: 'candidate-0.9.0-9999' },
    { version: '0.9.0' }, { build: 10042 }, { mac: { asset: 'https://attacker.invalid/download' } },
  ]) {
    mock.restoreAll();
    upstream([[release(), release('candidate-0.9.0-9999')]], { ...manifest, ...mismatch });
    const response = await request('/beta');
    assert.equal(response.status, 503);
    assert.equal(response.headers.get('location'), null);
    assert.equal(response.headers.get('retry-after'), '300');
    assert.equal(response.headers.get('cache-control'), 'no-store');
  }
});

test('missing or foreign assets cannot redirect users outside the fixed repository', async () => {
  for (const assets of [[], release().assets.map(asset => ({ ...asset, browser_download_url: 'https://attacker.invalid' }))]) {
    mock.restoreAll();
    const calls = upstream([[{ ...release(), assets }]]);
    assert.equal((await request('/beta')).status, 503);
    assert.equal(calls.length, 1);
  }
});

test('upstream failure or no main candidate leaves static website available', async () => {
  const cases = [
    async () => new Response('rate limited', { status: 403 }),
    async () => { throw new Error('network failure'); },
    async () => Response.json([release('candidate-1.0.0-10099', 'release/1.0')]),
  ];
  for (const fetcher of cases) {
    mock.restoreAll();
    mock.method(globalThis, 'fetch', fetcher);
    assert.equal((await request('/beta/appcast.xml')).status, 503);
    assert.equal(await (await request('/')).text(), 'static site');
  }
});

test('release discovery stops safely at its documented ceiling and methods are read-only', async () => {
  const page = Array.from({ length: 100 }, () => release());
  const calls = upstream(Array.from({ length: 20 }, () => page));
  assert.equal((await request('/beta')).status, 503);
  assert.equal(calls.length, 20);
  const unsupported = await request('/beta', { method: 'POST' });
  assert.equal(unsupported.status, 405);
  assert.equal(unsupported.headers.get('allow'), 'GET, HEAD');
  assert.equal(calls.length, 20);
});

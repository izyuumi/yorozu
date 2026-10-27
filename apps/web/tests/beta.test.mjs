import assert from 'node:assert/strict';
import { afterEach, mock, test } from 'node:test';
import worker from '../worker.mjs';

const download = 'https://github.com/izyuumi/yorozu/releases/download/';
const latest = (tag, names) => ({
  tag_name: tag,
  assets: names.map(name => ({ name, state: 'uploaded', browser_download_url: `${download}${tag}/${name}` })),
});
function upstream(release, stable = release) {
  const requests = [];
  mock.method(globalThis, 'fetch', async (url, options) => {
    requests.push(url);
    assert.equal(options.cf.cacheTtlByStatus['200-299'], 300);
    assert.equal(options.cf.cacheTtlByStatus['400-599'], 0);
    return Response.json(url.endsWith('/latest') ? stable : [release]);
  });
  return requests;
}
const request = (path, init) => worker.fetch(new Request(`https://yorozu.yumi.to${path}`, init), {
  ASSETS: { fetch: async () => new Response('static site') },
});
afterEach(() => mock.restoreAll());

test('the beta routes serve the newest release, prereleases included; /mac the latest stable one', async () => {
  const files = ['Yorozu.dmg', 'appcast.xml', 'candidate.json'];
  const requests = upstream(latest('v0.9.2-beta', files), latest('v0.9.1', files));
  const feed = await request('/beta/appcast.xml');
  assert.equal(feed.status, 302);
  assert.equal(feed.headers.get('location'), `${download}v0.9.2-beta/appcast.xml`);
  assert.equal(feed.headers.get('cache-control'), 'public, max-age=60');
  assert.equal(requests[0], 'https://api.github.com/repos/izyuumi/yorozu/releases?per_page=1');
  for (const path of ['/beta', '/beta/']) {
    assert.equal((await request(path, { method: 'HEAD' })).headers.get('location'), `${download}v0.9.2-beta/Yorozu.dmg`);
  }
  assert.equal((await request('/mac', { method: 'HEAD' })).headers.get('location'), `${download}v0.9.1/Yorozu.dmg`);
  assert.equal(requests.at(-1), 'https://api.github.com/repos/izyuumi/yorozu/releases/latest');
});

test('an empty release list is unavailable, not a crash', async () => {
  mock.method(globalThis, 'fetch', async () => Response.json([]));
  assert.equal((await request('/beta')).status, 503);
});

test('Mac download prefers uppercase installer and supports shipped lowercase stable asset', async () => {
  for (const names of [['yorozu.dmg'], ['yorozu.dmg', 'Yorozu.dmg']]) {
    mock.restoreAll();
    upstream(latest('v0.4.0', names));
    assert.equal((await request('/mac')).headers.get('location'), `${download}v0.4.0/${names.at(-1)}`);
  }
});

test('missing or foreign assets cannot redirect users outside the fixed repository', async () => {
  for (const assets of [[], latest('v0.9.1', ['Yorozu.dmg']).assets.map(asset => ({ ...asset, browser_download_url: 'https://attacker.invalid' }))]) {
    mock.restoreAll();
    upstream({ tag_name: 'v0.9.1', assets });
    const response = await request('/beta');
    assert.equal(response.status, 503);
    assert.equal(response.headers.get('location'), null);
    assert.equal(response.headers.get('cache-control'), 'no-store');
  }
});

test('upstream failure leaves static website available', async () => {
  for (const fetcher of [async () => new Response('rate limited', { status: 403 }), async () => { throw new Error('network failure'); }]) {
    mock.restoreAll();
    mock.method(globalThis, 'fetch', fetcher);
    assert.equal((await request('/beta/appcast.xml')).status, 503);
    assert.equal(await (await request('/')).text(), 'static site');
  }
});

test('methods are read-only', async () => {
  const calls = upstream(latest('v0.9.1', ['Yorozu.dmg']));
  const unsupported = await request('/beta', { method: 'POST' });
  assert.equal(unsupported.status, 405);
  assert.equal(unsupported.headers.get('allow'), 'GET, HEAD');
  assert.equal(calls.length, 0);
});

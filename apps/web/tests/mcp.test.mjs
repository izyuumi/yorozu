import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { afterEach, mock, test } from 'node:test';
import worker from '../worker.mjs';

const site = 'https://yorozu.yumi.to';
const assets = { fetch: async req => new Response(`asset ${new URL(req.url).pathname}`) };
const mcpHeaders = { 'Content-Type': 'application/json', Accept: 'application/json, text/event-stream', 'Mcp-Protocol-Version': '2025-06-18' };
let nextId = 0;

function rpc(ip, method, params = {}, headers = {}) {
  return worker.fetch(new Request(`${site}/mcp`, {
    method: 'POST',
    headers: { ...mcpHeaders, 'CF-Connecting-IP': ip, ...headers },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++nextId, method, params }),
  }), { ASSETS: assets });
}
const result = async response => {
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.error, undefined, JSON.stringify(body.error));
  return body.result;
};

// The help server answers from the bundle alone: any outbound fetch fails the test.
afterEach(() => mock.restoreAll());
const noNetwork = () => mock.method(globalThis, 'fetch', async url => assert.fail(`unexpected fetch to ${url}`));

test('/mcp answers initialize, tools/list, a tool call, resources and the setup prompt without network', async () => {
  const calls = noNetwork();
  const init = await result(await rpc('192.0.2.1', 'initialize', {
    protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '0' },
  }));
  assert.equal(init.serverInfo.name, 'yorozu-help');
  assert.ok(init.capabilities.tools && init.capabilities.resources && init.capabilities.prompts);

  const { tools } = await result(await rpc('192.0.2.1', 'tools/list'));
  assert.deepEqual(tools.map(tool => tool.name).sort(), ['changelog', 'explain_setting', 'get_permissions_needed',
    'get_setup_guide', 'latest_version', 'list_settings', 'search_docs', 'troubleshoot']);
  assert.ok(tools.every(tool => tool.annotations.readOnlyHint));

  const call = await result(await rpc('192.0.2.1', 'tools/call', { name: 'get_setup_guide', arguments: { platform: 'macos' } }));
  assert.ok(!call.isError);
  assert.match(call.content[0].text, /pair/i);

  const { resources } = await result(await rpc('192.0.2.1', 'resources/list'));
  assert.ok(resources.some(resource => resource.uri === 'yorozu://docs/help-mcp'));
  const prompt = await result(await rpc('192.0.2.1', 'prompts/get', { name: 'setup_yorozu', arguments: { platform: 'ios' } }));
  assert.match(prompt.messages[0].content.text, /iPhone or iPad/);
  assert.equal(calls.mock.callCount(), 0);
});

test('/healthz is up and read-only', async () => {
  const health = await worker.fetch(new Request(`${site}/healthz`), { ASSETS: assets });
  assert.equal(health.status, 200);
  assert.equal((await health.json()).status, 'ok');
  assert.equal((await worker.fetch(new Request(`${site}/healthz`, { method: 'POST' }), { ASSETS: assets })).status, 405);
});

test('past 60 requests a minute from one CF-Connecting-IP, /mcp answers 429 with Retry-After; other IPs are unaffected', async () => {
  for (let i = 0; i < 60; i++) assert.equal((await rpc('198.51.100.7', 'tools/list')).status, 200, `request ${i + 1}`);
  const limited = await rpc('198.51.100.7', 'tools/list');
  assert.equal(limited.status, 429);
  const wait = Number(limited.headers.get('Retry-After'));
  assert.ok(wait >= 1 && wait <= 60, `Retry-After ${wait}`);
  assert.equal((await limited.json()).error.message, 'Too many requests');
  assert.equal((await rpc('198.51.100.8', 'tools/list')).status, 200);
});

test('CORS: preflight and response headers for a browser client', async () => {
  const preflight = await worker.fetch(new Request(`${site}/mcp`, {
    method: 'OPTIONS',
    headers: { Origin: 'https://app.example', 'Access-Control-Request-Method': 'POST', 'Access-Control-Request-Headers': 'content-type, mcp-protocol-version' },
  }), { ASSETS: assets });
  assert.equal(preflight.status, 204);
  assert.equal(preflight.headers.get('Access-Control-Allow-Origin'), '*');
  assert.match(preflight.headers.get('Access-Control-Allow-Methods'), /POST/);
  assert.match(preflight.headers.get('Access-Control-Allow-Headers'), /Mcp-Protocol-Version/);
  const response = await rpc('192.0.2.2', 'tools/list', {}, { Origin: 'https://app.example' });
  assert.equal(response.headers.get('Access-Control-Allow-Origin'), '*');
  assert.match(response.headers.get('Access-Control-Expose-Headers'), /Mcp-Session-Id/);
});

test('/mcp is stateless: GET streams, bad JSON and oversized bodies are refused', async () => {
  const get = await worker.fetch(new Request(`${site}/mcp`, { headers: { 'CF-Connecting-IP': '192.0.2.3' } }), { ASSETS: assets });
  assert.equal(get.status, 405);
  const post = body => worker.fetch(new Request(`${site}/mcp`, { method: 'POST', headers: { ...mcpHeaders, 'CF-Connecting-IP': '192.0.2.3' }, body }), { ASSETS: assets });
  assert.equal((await post('{not json')).status, 400);
  assert.equal((await post('x'.repeat(70 * 1024))).status, 413);
});

test('only /mcp and /healthz reach the help server; every other path keeps its old route', async () => {
  for (const path of ['/mcp/', '/mcp/x', '/healthz/', '/appcast.xml', '/download/Yorozu.dmg', '/iphone', '/styles.css', '/ja/']) {
    assert.equal(await (await worker.fetch(new Request(`${site}${path}`), { ASSETS: assets })).text(), `asset ${path}`, path);
  }
  // Language detection still runs on the pages, untouched by the new routes.
  const home = await worker.fetch(new Request(`${site}/`, { headers: { 'Accept-Language': 'ja' } }), { ASSETS: assets });
  assert.equal(home.headers.get('Location'), '/ja/');
});

test('wrangler runs the worker first for /mcp and /healthz, alongside the existing worker routes', async () => {
  const config = JSON.parse((await readFile(new URL('../wrangler.jsonc', import.meta.url), 'utf8')).replace(/^\s*\/\/.*$/gm, ''));
  for (const path of ['/mcp', '/healthz', '/', '/pair', '/mac', '/beta', '/beta/*']) assert.ok(config.assets.run_worker_first.includes(path), path);
});

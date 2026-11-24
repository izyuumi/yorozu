import assert from 'node:assert/strict';
import { test } from 'node:test';
import { chromium } from 'playwright-core';
import { createServer } from 'vite';
import { fakeHost } from '../../../windows/conformance/host/fake-host.ts';

test('browser pairs, survives full browser restart, chats, waits for the offline Mac, and drops a revoked pairing', { timeout: 45_000 }, async (t) => {
  const host = await fakeHost();
  const thread = crypto.randomUUID();
  host.seed(thread, Array.from({length:65}, (_, i) => ({
    kind: i % 2 ? 'agent' : 'user', id: crypto.randomUUID(), seq: i+1, ts: Date.now(), text: 'History message ' + (i+1),
  })));
  t.after(() => host.stop());
  const relay = new URL(new URL(await host.link()).searchParams.get("relay"));
  process.env.VITE_YOROZU_TEST_RELAY = relay.href;
  const app = await createServer({ server: {host: '127.0.0.1', port: 0 } });
  await app.listen();
  t.after(() => app.close());
  const url = `http://127.0.0.1:${app.httpServer.address().port}`;
  const { mkdtemp, rm } = await import('node:fs/promises');
  const { tmpdir } = await import('node:os');
  const profile = await mkdtemp(`${tmpdir()}/yorozu-browser-`);
  t.after(() => rm(profile, { recursive: true, force: true }));
  let context;
  t.after(() => context?.close());
  const launch = () => chromium.launchPersistentContext(profile, {
    executablePath: process.env.YOROZU_CHROMIUM_PATH, args: ['--no-sandbox'],
  });
  async function open() {
    const page = context.pages()[0] ?? await context.newPage();
    await page.goto(url);
    return page;
  }
  const found = (page, text) => page.getByText(text, { exact: true }).first().waitFor({timeout: 8000});
  context = await launch();
  let page = await open();
  const link = await host.link();
  const input = page.getByLabel('Pairing link');
  const cont = page.getByRole('button',{name:'Continue'});
  await cont.click();
  await found(page,'Paste a pairing invitation first, or open the original invite link in Safari.');
  await input.fill('not an invite');
  await cont.click();
  await found(page,'This is not a valid browser invitation. Copy the entire original link and try again.');
  await input.fill(link + '&exp=1');
  await cont.click();
  await found(page,'This invitation expired. Ask for a new browser pairing link.');
  await input.fill('`' + link + '`');
  await cont.click();
  await page.getByRole('heading',{name:'Confirm host fingerprint'}).waitFor();
  await page.getByRole('button',{name:'Cancel'}).click();
  await page.goto(url + '/#pair=' + encodeURIComponent(link));
  await found(page, 'Pairing link ready.');
  assert.equal(new URL(page.url()).hash, '');
  assert.ok(!page.url().includes('token'));
  await page.getByRole('button', {name:'Continue'}).click();
  await page.getByRole('button', {name:'Pair', exact: true}).click();
  await found(page, 'Connected');
  assert.equal(host.devices.size, 1);
  await found(page, 'History message 65');
  assert.equal(await page.getByText('History message 1',{exact:true}).count(),0);
  assert.ok(await page.locator('#messages').evaluate(e=>e.scrollHeight>e.clientHeight), 'transcript scrolls independently');
  await page.getByRole('button',{name:'Earlier messages'}).click();
  await found(page, 'History message 1');
  await page.getByLabel('Message', { exact: true }).fill('Hello from a synthetic Windows client');
  await page.getByRole('button', {name:'Send'}).click();
  await found(page, 'echo: Hello from a synthetic Windows client');
  assert.equal(host.messages.length, 1);
  assert.deepEqual(await page.evaluate(async () => {
    const db = await new Promise((resolve) => {
      const req = indexedDB.open('yorozu-pairing');
      req.onsuccess = () => resolve(req.result);
    });
    const device = await new Promise((resolve) => {
      const req = db.transaction('devices').objectStore('devices').get('current');
      req.onsuccess = () => resolve(req.result);
    });
    db.close();
    return {
      privateKeysExportable: [device.identity.noisePrivate.extractable, device.identity.signingPrivate.extractable],
      token: Object.hasOwn(device, 'token'), secret: Object.hasOwn(device, 'secret'),
    };
  }), { privateKeysExportable: [false, false], token: false, secret: false });

  await context.close();
  await host.close();
  context = await launch();
  page = await open();
  await found(page, 'Mac is offline');
  await host.reconnect();
  await found(page, 'Connected');
  await found(page, 'echo: Hello from a synthetic Windows client');
  assert.equal(host.devices.size, 1, 'reopening the same profile does not pair a second time');
  await page.getByRole('button', {name:'Settings'}).click();
  await page.getByRole('dialog').waitFor();
  await page.getByRole('button', {name:'Close', exact: true}).click();
  await host.close();
  host.devices.clear();
  await host.reconnect();
  await found(page, 'This browser was removed from your Mac');
  await page.reload();
  await found(page, 'Connect to your Mac');

  await page.addInitScript(() => {
    const save = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function(value, key) {
      return save.call(this, this.transaction.db.name === 'yorozu-pairing' && key === 'current' ? null : value, key);
    };
  });
  await page.reload();
  await page.getByLabel('Pairing link').fill(await host.link());
  await page.getByRole('button', {name:'Continue'}).click();
  await page.getByRole('button', {name:'Pair', exact:true}).click();
  await found(page, 'Connected');
  await found(page, 'This browser couldn’t remember the pairing. It will work in this tab, but you’ll need a new link if you close it.');
  const devices = host.devices.size;
  await host.close();
  await found(page, 'Mac is offline');
  await host.reconnect();
  await found(page, 'Connected');
  assert.equal(host.devices.size, devices, 'tab-only browser reconnects without asking for an invite');
  await page.reload();
  await found(page, 'Connect to your Mac');
});

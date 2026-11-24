import assert from 'node:assert/strict';
import { test } from 'node:test';
import { chromium } from 'playwright-core';
import { createServer } from 'vite';
import { fakeHost } from '../../../windows/conformance/host/fake-host.ts';

test('browser pairs, survives full browser restart, chats, waits for the offline Mac, and drops a revoked pairing', { timeout: 45_000 }, async (t) => {
  const host = await fakeHost();
  const thread = crypto.randomUUID();
  const history = Array.from({length:65}, (_, i) => ({
    kind: i % 2 ? 'agent' : 'user', id: crypto.randomUUID(), seq: i+1, ts: Date.now(), text: 'History message ' + (i+1),
  }));
  host.seed(thread, history);
  host.update({convId:thread,title:'Demo history'});
  const other = crypto.randomUUID();
  host.seed(other, [{kind:'agent',id:crypto.randomUUID(),seq:1,ts:Date.now()-60_000,text:'Other chat message'}]);
  host.update({convId:other,title:'Other chat'});
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
  assert.equal(await page.getByText('openclaw yorozu pair-browser', {exact:true}).isVisible(), false);
  await page.getByText('Need a pairing link?', {exact:true}).click();
  assert.equal(await page.getByText('openclaw yorozu pair-browser', {exact:true}).isVisible(), true);
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
  const timeline = page.getByRole('region', {name:'Message history'});
  assert.ok(await timeline.evaluate(e=>e.scrollHeight>e.clientHeight), 'transcript scrolls independently');
  assert.equal(await page.getByRole('button', {name:'Send'}).isDisabled(), true, 'empty composer cannot send');
  const anchor = await timeline.evaluate(e => {
    e.scrollTop = 50;
    const row = Array.from(e.querySelectorAll('#messages li')).find(row => row.getBoundingClientRect().bottom > e.getBoundingClientRect().top);
    return [row.textContent, row.getBoundingClientRect().top];
  });
  await found(page, 'History message 1');
  const after = await timeline.evaluate((e, content) =>
    Array.from(e.querySelectorAll('#messages li')).find(row=>row.textContent === content).getBoundingClientRect().top, anchor[0]);
  assert.ok(Math.abs(after-anchor[1]) <= 2, 'loading earlier messages by scrolling preserves visible content');
  await page.getByRole('button', {name:'Jump to latest message'}).click();
  await page.getByRole('button', {name:'Jump to latest message'}).waitFor({state:'hidden'});
  const draft = page.getByLabel('Message', {exact:true});
  await draft.fill('Draft in the existing chat');
  await page.setViewportSize({width:390,height:720});
  await page.getByRole('button', {name:'Show chats'}).click();
  const drawer = page.getByRole('dialog', {name:'Chats'});
  await drawer.getByRole('button', {name:'New chat'}).click();
  await drawer.waitFor({state:'hidden'});
  assert.equal(await draft.inputValue(), '');
  await page.getByRole('button', {name:'Show chats'}).click();
  await drawer.getByRole('button', {name:'Demo history'}).click();
  assert.equal(await draft.inputValue(), 'Draft in the existing chat');
  const readingAnchor = await timeline.evaluate(e => {
    e.scrollTop = 450;
    const row = Array.from(e.querySelectorAll('#messages li')).find(row => row.getBoundingClientRect().bottom > e.getBoundingClientRect().top);
    return [row.textContent, row.getBoundingClientRect().top - e.getBoundingClientRect().top];
  });
  await page.getByRole('button', {name:'Show chats'}).click();
  await drawer.getByRole('button', {name:'Other chat'}).click();
  await found(page, 'Other chat message');
  const durable = {kind:'agent',id:crypto.randomUUID(),seq:66,ts:Date.now(),text:'History caught up while another chat was open'};
  const live = {kind:'agent',id:crypto.randomUUID(),seq:67,ts:Date.now(),text:'A live reply arrived before it was saved'};
  host.seed(thread,[...history,durable]);
  host.broadcast([{kind:'reply',data:{convId:thread,messageId:live.id,text:live.text,ts:live.ts}}]);
  host.update({convId:other,title:'Other chat updated'});
  await page.getByRole('heading',{name:'Other chat updated'}).waitFor();
  assert.equal(await page.getByText(live.text,{exact:true}).count(),0);
  await page.getByRole('button', {name:'Show chats'}).click();
  await drawer.getByRole('button', {name:'Demo history'}).click();
  await found(page, durable.text);
  await found(page, live.text);
  assert.equal(await draft.inputValue(), 'Draft in the existing chat');
  assert.equal(await page.getByText('History message 1',{exact:true}).count(),1, 'refresh keeps already-loaded older messages');
  const resumed = await timeline.evaluate((e, text) =>
    Array.from(e.querySelectorAll('#messages li')).find(row => row.textContent===text).getBoundingClientRect().top - e.getBoundingClientRect().top, readingAnchor[0]);
  assert.ok(Math.abs(resumed - readingAnchor[1]) <= 2, 'reopening a chat restores the visible reading anchor even after a new reply');
  await page.getByRole('button', {name:'Show chats'}).click();
  await drawer.getByRole('button', {name:'Other chat updated'}).click();
  const persisted = {kind:'agent',id:crypto.randomUUID(),seq:68,ts:Date.now(),text:'The live reply is now recorded'};
  host.seed(thread,[...history,durable,live,persisted]);
  await page.getByRole('button', {name:'Show chats'}).click();
  await drawer.getByRole('button', {name:'Demo history'}).click();
  await found(page, persisted.text);
  assert.equal(await page.getByText(live.text,{exact:true}).count(),1, 'a saved reply replaces its live row instead of duplicating it');
  await page.getByRole('button', {name:'Jump to latest message'}).click();
  const geometry = await page.evaluate(() => ({
    page: document.documentElement.scrollWidth, width: innerWidth,
    composer: document.getElementById('message').getBoundingClientRect().bottom, height: visualViewport.height,
  }));
  assert.equal(geometry.page, geometry.width, 'no horizontal scroll on iPhone-width view');
  assert.ok(geometry.composer <= geometry.height, 'composer stays inside visible viewport');
  await page.getByLabel('Message', { exact: true }).fill('Hello from a synthetic Windows client');
  await page.getByRole('button', {name:'Send'}).click();
  await found(page, 'echo: Hello from a synthetic Windows client');
  assert.equal(host.messages.length, 1);
  await page.evaluate(() => { document.documentElement.style.fontSize = '200%'; });
  await page.getByRole('button', {name:'Settings'}).press('Enter');
  const settingsDialog = page.getByRole('dialog', {name:'Settings'});
  await settingsDialog.waitFor();
  const target = await settingsDialog.getByRole('button', {name:'Forget this browser'}).boundingBox();
  assert.ok(target.height >= 44, 'forget has an adequate touch target at 200% text');
  assert.equal(await settingsDialog.evaluate(node => node.scrollWidth <= node.clientWidth + 1), true, 'Settings does not overflow horizontally with larger text');
  await page.keyboard.press('Escape');
  await settingsDialog.waitFor({state:'hidden'});
  await page.waitForFunction(() => document.activeElement?.getAttribute('aria-label') === 'Settings');
  await page.evaluate(() => { document.documentElement.style.removeProperty('font-size'); });
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
  await page.getByRole('button', {name:'Forget this browser'}).click();
  await page.getByRole('button', {name:'Forget pairing'}).waitFor();
  await page.getByRole('button', {name:'Cancel', exact:true}).click();
  assert.equal(host.devices.size, 1, 'cancelling forget leaves the pairing intact');
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

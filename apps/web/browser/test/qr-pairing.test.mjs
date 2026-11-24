import assert from 'node:assert/strict';
import { createCipheriv, createPublicKey, diffieHellman, generateKeyPairSync, hkdfSync, randomBytes } from 'node:crypto';
import { createServer as createHttpServer } from 'node:http';
import { createRequire } from 'node:module';
import { test } from 'node:test';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import jsQR from 'jsqr';
import qrcode from 'qrcode-generator';
import { chromium } from 'playwright-core';
import { createServer } from 'vite';

const { WebSocketServer } = createRequire(new URL('../../../relay/package.json', import.meta.url))('ws');

function sealLetter(invitation, receiveKey) {
  const receiver = Buffer.from(receiveKey, 'base64url');
  const { privateKey, publicKey } = generateKeyPairSync('x25519');
  const sender = publicKey.export({format:'der', type:'spki'}).subarray(-32);
  const publicReceiver = createPublicKey({
    key: Buffer.concat([Buffer.from('302a300506032b656e032100','hex'), receiver]), format:'der', type:'spki',
  });
  const shared = diffieHellman({ privateKey, publicKey: publicReceiver });
  const key = hkdfSync('sha256', shared, Buffer.concat([sender, receiver]), 'yorozu-device-code', 32);
  const nonce = randomBytes(12);
  const cipher = createCipheriv('chacha20-poly1305', new Uint8Array(key), nonce);
  return Buffer.concat([sender, nonce, cipher.update(invitation, 'utf8'), cipher.final(), cipher.getAuthTag()]).toString('base64url');
}

function grid(text) {
  const qr = qrcode(0, 'M');
  qr.addData(text);
  qr.make();
  return Array.from({length:qr.getModuleCount()}, (_, row) =>
    Array.from({length:qr.getModuleCount()}, (_, col) => qr.isDark(row,col)));
}

function qrPng(grid) {
  const canvas = document.createElement('canvas');
  const cell = 6, quiet = 4;
  canvas.width = canvas.height = (grid.length + quiet * 2) * cell;
  const ctx = canvas.getContext('2d');
  ctx.fillStyle = '#fff';
  ctx.fillRect(0,0,canvas.width,canvas.height);
  ctx.fillStyle = '#000';
  grid.forEach((row,y) => row.forEach((dark,x) => {
    if (dark) ctx.fillRect((x+quiet)*cell,(y+quiet)*cell,cell,cell);
  }));
  return canvas.toDataURL();
}

test('browser QR scans camera and image, rejects the native role, and decrypts reverse invitations only to fingerprint confirmation', {timeout:30_000}, async (t) => {
  const server = createHttpServer();
  const relay = new WebSocketServer({noServer:true});
  const boxes = new Map();
  server.on('upgrade', (request, socket, head) => {
    const box = request.url?.match(/^\/mailbox\/([\w-]{22})$/)?.[1];
    if (!box) { socket.destroy(); return; }
    relay.handleUpgrade(request, socket, head, connection => { boxes.set(box,connection); });
  });
  await new Promise(resolve => server.listen(0,'127.0.0.1',resolve));
  t.after(() => {
    for (const connection of boxes.values()) connection.terminate();
    relay.close();
    server.close();
  });
  const relayURL = 'ws://127.0.0.1:' + server.address().port + '/';
  process.env.VITE_YOROZU_TEST_RELAY = relayURL;
  const cacheDir = await mkdtemp(tmpdir() + '/yorozu-qr-test-');
  const app = await createServer({cacheDir,server:{host:'127.0.0.1',port:0}});
  t.after(() => rm(cacheDir,{recursive:true,force:true}));
  await app.listen();
  t.after(() => app.close());
  const browser = await chromium.launch({executablePath:process.env.YOROZU_CHROMIUM_PATH,args:['--no-sandbox']});
  t.after(() => browser.close());
  const page = await browser.newPage({viewport:{width:390,height:844}});
  const invite = (version, expires = Date.now()+90_000) => 'yorozu://pair?' + new URLSearchParams({
    v:String(version), relay:relayURL, key:randomBytes(32).toString('base64url'), room:randomBytes(32).toString('base64url'),
    token:randomBytes(32).toString('base64url'), secret:randomBytes(32).toString('base64url'), exp:String(expires),
  });
  const nativeInvite = invite(3), browserInvite = invite(4);
  const cameraPNG = await page.evaluate(qrPng,grid(browserInvite));
  await page.addInitScript(source => {
    window.cameraStops = 0;
    navigator.mediaDevices.getUserMedia = async () => {
      if (!window.cameraEnabled) throw new Error('Permission denied');
      const image = new Image();
      image.src = source;
      await image.decode();
      const canvas = document.createElement('canvas');
      canvas.width = image.width;
      canvas.height = image.height;
      const ctx = canvas.getContext('2d');
      if (!window.pauseFixtureCamera) ctx.drawImage(image,0,0);
      const stream = canvas.captureStream(10), track = stream.getVideoTracks()[0];
      const stop = track.stop.bind(track);
      track.stop = () => { window.cameraStops++; stop(); };
      setTimeout(() => { if (!window.pauseFixtureCamera) ctx.drawImage(image,0,0); }, 150);
      return stream;
    };
  },cameraPNG);
  await page.goto('http://127.0.0.1:' + app.httpServer.address().port);
  const scan = () => page.getByRole('button',{name:'Scan QR code'}).press('Enter');
  const back = () => page.getByRole('button',{name:'Paste invite link instead'}).click();
  const fingerprint = () => page.getByRole('heading',{name:'Confirm host fingerprint'});
  await scan();
  await page.waitForFunction(() => document.activeElement?.textContent === 'Scan QR code' && document.activeElement?.tagName === 'H1');
  await page.getByText('Camera access is unavailable. Choose a QR image or paste an invitation.').waitFor();
  const expiredPng = (await page.evaluate(qrPng,grid(invite(4, Date.now()-1)))).split(',')[1];
  await page.getByLabel('Choose QR image').setInputFiles({name:'expired.png',mimeType:'image/png',buffer:Buffer.from(expiredPng,'base64')});
  await page.getByText('This invitation expired. Ask for a new browser pairing link.').waitFor();
  const png = (await page.evaluate(qrPng,grid(nativeInvite))).split(',')[1];
  await page.getByLabel('Choose QR image').setInputFiles({name:'native.png',mimeType:'image/png',buffer:Buffer.from(png,'base64')});
  await page.getByText('This is not a valid browser invitation. Copy the entire original link and try again.').waitFor();
  assert.equal(await fingerprint().isVisible(),false);
  await back();
  await page.waitForFunction(() => document.activeElement?.id === 'pair-link');
  await page.evaluate(() => { window.cameraEnabled = true; window.pauseFixtureCamera = true; });
  await scan();
  await page.waitForFunction(() => Boolean(document.querySelector('video')?.srcObject));
  await page.evaluate(() => {
    Object.defineProperty(document,'hidden',{value:true,configurable:true});
    document.dispatchEvent(new Event('visibilitychange'));
  });
  await page.getByText('Camera paused. Reopen the scanner to use it, or choose a QR image.').waitFor();
  await page.waitForFunction(() => window.cameraStops === 1 && !document.querySelector('video')?.srcObject);
  await page.evaluate(() => { delete document.hidden; window.pauseFixtureCamera = false; });
  await back();
  await scan();
  await fingerprint().waitFor();
  await page.waitForFunction(() => window.cameraStops === 2);
  await page.getByRole('button',{name:'Cancel',exact:true}).click();
  await page.waitForFunction(() => document.activeElement?.id === 'pair-link');

  const show = () => page.getByRole('button',{name:'Show QR code'}).click();
  const code = page.getByRole('img',{name:'One-time QR pairing request'});
  async function displayedRequest() {
    await code.waitFor();
    await page.waitForFunction(() => {
      const canvas=document.querySelector('.device-qr');
      return canvas?.width > 90 && canvas.getContext('2d').getImageData(0,0,1,1).data[3] === 255;
    });
    const pixels = await code.evaluate((canvas) => ({
      width:canvas.width,height:canvas.height,data:[...canvas.getContext('2d').getImageData(0,0,canvas.width,canvas.height).data],
    }));
    const decoded = jsQR(Uint8ClampedArray.from(pixels.data),pixels.width,pixels.height);
    assert.ok(decoded);
    const url = new URL(decoded.data);
    assert.equal(url.origin,'https://yorozu.yumi.to');
    assert.equal(url.pathname,'/add');
    const fragment = new URLSearchParams(url.hash.slice(1));
    assert.equal(fragment.get('v'),'2');
    assert.equal(fragment.get('target'),'browser');
    assert.equal(fragment.get('relay'),relayURL);
    assert.equal(Buffer.from(fragment.get('box'),'base64url').length,16);
    return {box:fragment.get('box'),key:fragment.get('key')};
  }
  await show();
  const old = await displayedRequest();
  const small = await code.evaluate(canvas => canvas.width);
  await page.getByRole('button',{name:'Enlarge QR code'}).click();
  await page.waitForFunction(width=>document.querySelector('.device-qr')?.width > width, small);
  assert.deepEqual(await displayedRequest(), old, 'enlarging keeps the same live, decodable QR');
  const pixels = await code.evaluate(canvas => {
    const pixels=canvas.getContext('2d').getImageData(0,0,canvas.width,1).data;
    return {white:pixels.every(value=>value===255),width:canvas.width,density:devicePixelRatio,
      physical:canvas.getBoundingClientRect().width*devicePixelRatio};
  });
  assert.equal(pixels.white,true);
  assert.ok(Math.abs(pixels.physical-pixels.width) < 1, 'display aligns QR bitmap to physical pixels');
  const closed = new Promise(resolve => boxes.get(old.box).once('close',resolve));
  await back();
  await closed;
  await show();
  const wrong = await displayedRequest();
  assert.notEqual(wrong.box,old.box);
  assert.notEqual(wrong.key,old.key);
  boxes.get(wrong.box).send(sealLetter(nativeInvite,wrong.key));
  await page.getByText('This response is not a browser invitation. Use an updated Yorozu device and try a new code.').waitFor();
  assert.equal(await fingerprint().isVisible(),false);
  await page.getByRole('button',{name:'Get a new QR code'}).click();
  const invalid = await displayedRequest();
  assert.notEqual(invalid.box,wrong.box);
  const altered = Buffer.from(sealLetter(browserInvite,invalid.key),'base64url');
  altered[altered.length-1] ^= 1;
  boxes.get(invalid.box).send(altered.toString('base64url'));
  await page.getByText('Couldn’t complete the QR request. Try a new code or paste an invitation.').waitFor();
  assert.equal(await fingerprint().isVisible(),false);
  await page.getByRole('button',{name:'Get a new QR code'}).click();
  const correct = await displayedRequest();
  assert.notEqual(correct.box,invalid.box);
  boxes.get(correct.box).send(sealLetter(browserInvite,correct.key));
  await fingerprint().waitFor();
  assert.equal(await page.getByRole('button',{name:'Pair',exact:true}).isVisible(),true);
  assert.equal(await page.getByRole('heading',{name:'New chat'}).isVisible(),false);
});

import assert from 'node:assert/strict';
import { test } from 'node:test';
import { randomUUID } from 'node:crypto';
import { fakeHost } from '../../../windows/conformance/host/fake-host.ts';
import { connect } from '../src/connection.mjs';
import { fingerprint, parsePairing } from '../src/pairing.mjs';
import { makeIdentity } from '../src/wire.mjs';

const waitFor = async (read, description) => {
  const deadline = Date.now() + 8000;
  for (;;) {
    const value = read();
    if (value) return value;
    if (Date.now() > deadline) throw Error('Timed out: ' + description);
    await new Promise((resolve) => setTimeout(resolve, 20));
  }
};

test('existing plugin and relay accept browser Web Crypto pairing, encrypted chat, reconnect, and revocation', { timeout: 35_000 }, async () => {
  const host = await fakeHost();
  let connection;
  try {
    const url = await host.link();
    const relay = new URL(new URL(url).searchParams.get('relay')).href;
    assert.throws(() => parsePairing(url, undefined, true), /Unsupported relay/);
    assert.throws(() => parsePairing(url + '&token=second', relay, true), /Invalid link/);
    const device = { ...parsePairing(url, relay, true), identity: await makeIdentity() };
    assert.match(fingerprint(device.hostKey), /^(?:[A-F0-9]{4} ){3}[A-F0-9]{4}$/);
    assert.equal(device.identity.noisePrivate.extractable, false);
    assert.equal(device.identity.signingPrivate.extractable, false);
    await assert.rejects(crypto.subtle.exportKey('pkcs8', device.identity.noisePrivate));
    let saved, status, removed;
    const events = [];
    const hooks = {
      status: (s) => { status = s; },
      event: (e) => events.push(e),
      paired: (record) => { saved = structuredClone(record); },
      removed: (reason) => { removed = reason; },
    };
    connection = connect(device, hooks);
    await waitFor(() => status === 'Connected', 'initial browser pairing');
    assert.equal(host.devices.size, 1);
    assert.ok(saved);
    assert.equal(Object.hasOwn(saved, 'token'), false);
    assert.equal(Object.hasOwn(saved, 'secret'), false);
    const convId = randomUUID(), messageId = randomUUID(), text = 'browser conformance message';
    assert.equal(await connection.send('message', { convId, messageId, text }), true);
    const reply = await waitFor(() => events.find((e) => e.kind === 'reply'), 'encrypted reply');
    assert.equal(reply.data.text, 'echo: ' + text);
    assert.equal(host.messages.length, 1);

    connection.close();
    await host.close();
    connection = connect(saved, { ...hooks, paired: () => assert.fail('reopened without pairing') });
    await waitFor(() => status === 'Mac is offline', 'offline without forgetting');
    assert.equal(await connection.send('history', { convId }), false);
    await host.reconnect();
    await waitFor(() => status === 'Connected', 'automatic reconnect');
    assert.equal(host.devices.size, 1);
    assert.equal(await connection.send('history', { convId }), true);
    const history = await waitFor(() => events.find((e) => e.kind === 'history'), 'encrypted history after reconnect');
    assert.deepEqual(history.data.items.map((x) => x.text), [text, 'echo: ' + text]);
    await host.close();
    host.devices.clear();
    await host.reconnect();
    await waitFor(() => removed, 'host revocation');
    assert.equal(await connection.send('message', { convId, messageId: randomUUID(), text }), false);
  } finally {
    connection?.close();
    await host.stop();
  }
});

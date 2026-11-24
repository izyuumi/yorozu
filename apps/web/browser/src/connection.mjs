import { b64, beginHandshake, signText, unb64 } from './wire.mjs';

export function connect(device, hooks, { Socket = WebSocket, handshakeTimeout = 15_000 } = {}) {
  let closed = false, reconnect, attempt = 0, joined = !device.token, confirmed = !device.secret;
  let stop = () => {}, sendEvent = async () => false;

  function dial() {
    if (closed) return;
    hooks.status('Connecting');
    const target = new URL(device.relay);
    target.searchParams.set('room', device.room);
    const socket = new Socket(target.href);
    let alive = true, handshake, session, ready = false, auth = false, host = false;
    let authTimer, handshakeTimer, pongTimer;
    let lastFlow = 0n, flowFrames = 0;
    let serial = Promise.resolve();
    const active = () => alive && !closed && socket.readyState === 1;
    function send(data) {
      if (!active()) return false;
      socket.send(JSON.stringify(data));
      return true;
    }
    async function sendFrame(payload) {
      const sig = await signText(device.identity, payload);
      return send({ type: 'frame', payload, sig });
    }
    function enqueue(action) {
      const operation = serial.then(() => active() ? action() : false);
      serial = operation.catch(() => { if (active()) socket.close(4000, 'connection reset'); });
      return operation;
    }
    function resetSession() {
      ready = false;
      handshake = session = null;
      clearTimeout(handshakeTimer);
    }
    async function init() {
      if (!auth || !host || handshake || session) return;
      hooks.status('Connecting to Mac');
      handshake = await beginHandshake(device);
      if (!await sendFrame(handshake.init)) return;
      handshakeTimer = setTimeout(() => { if (active()) socket.close(4000, 'handshake timeout'); }, handshakeTimeout);
    }
    authTimer = setTimeout(() => socket.close(4000, 'connection timeout'), 20_000);
    const heartbeat = setInterval(() => {
      if (!active() || !auth || pongTimer) return;
      send({ type: 'ping' });
      pongTimer = setTimeout(() => { if (active()) socket.close(4000, 'heartbeat timeout'); }, 10_000);
    }, 25_000);
    const cleanup = () => {
      alive = false;
      clearTimeout(authTimer);
      clearTimeout(pongTimer);
      clearInterval(heartbeat);
      resetSession();
    };
    stop = () => { cleanup(); socket.close(); };
    sendEvent = (kind, data) => enqueue(() => {
      if (!ready || !session) return false;
      return sendFrame(session.seal({ kind, data }));
    }).catch(() => false);

    socket.addEventListener('message', (event) => {
      if (typeof event.data !== 'string' || event.data.length > 1024 * 1024) return;
      enqueue(async () => {
        let msg;
        try { msg = JSON.parse(event.data); } catch { return; }
        if (!msg || typeof msg !== 'object') return;
        if (msg.type === 'pong') {
          clearTimeout(pongTimer);
          pongTimer = null;
        } else if (msg.type === 'nonce' && !auth && typeof msg.nonce === 'string' && msg.nonce.length <= 128) {
          const token = joined ? undefined : device.token;
          const sig = await signText(device.identity, token ?? msg.nonce);
          send({ type: 'join', roomId: device.room, phonePubkey: b64(device.identity.signingPublic), sig, token });
        } else if (msg.type === 'joined' && !auth && msg.roomId === device.room) {
          auth = joined = true;
          clearTimeout(authTimer);
          host = msg.ownerOnline === true;
          if (host) await init();
          else hooks.status('Mac is offline');
        } else if (msg.type === 'owner' && auth && typeof msg.online === 'boolean') {
          host = msg.online;
          if (host) await init();
          else { resetSession(); hooks.status('Mac is offline'); }
        } else if (msg.type === 'frame' && auth) {
          if (typeof msg.flowBytes === 'string' && /^\d{1,19}$/.test(msg.flowBytes)) {
            const count = BigInt(msg.flowBytes);
            if (++flowFrames >= 16 || count - lastFlow >= 262144n) {
              send({ type: 'flowAck', bytes: msg.flowBytes });
              lastFlow = count;
              flowFrames = 0;
            }
          }
          if (!host || !handshake) return;
          let frame;
          try { frame = unb64(msg.payload); } catch { return; }
          if (!session) {
            session = await handshake.finish(frame);
            if (session) await sendFrame(session.seal({ kind: 'peer_info',
              data: { protocolMin: 3, protocolMax: 3, app: 'Web', name: 'Yorozu Web', capabilities: device.browser ? ['browser-ephemeral-v1'] : [] } }));
            return;
          }
          const box = session.open(frame);
          if (!box?.data || typeof box.data !== 'object') return;
          if (!ready && box.kind === 'peer_info') {
            if ((device.browser && !box.data.capabilities?.includes("browser-ephemeral-v1")) || box.data.protocolMin > 3 || box.data.protocolMax < 3 ||
                !Number.isInteger(box.data.protocolMin) || !Number.isInteger(box.data.protocolMax)) {
              closed = true;
              stop();
              hooks.status('Update the Yorozu plugin on your Mac');
              return;
            }
            if (!confirmed) {
              const saved = { relay: device.relay, room: device.room, browser: device.browser, hostKey: device.hostKey, identity: device.identity };
              await hooks.paired(saved);
              if (!active()) return;
              confirmed = true;
              delete device.secret;
              delete device.token;
            }
            clearTimeout(handshakeTimer);
            ready = true;
            attempt = 0;
            hooks.status('Connected');
            hooks.event(box);
            await sendFrame(session.seal({ kind: 'conv_list', data: {} }));
          } else if (ready) hooks.event(box);
        }
      }).catch(() => {});
    });

    socket.addEventListener('close', ({ code, reason }) => {
      if (!alive) return;
      cleanup();
      if (closed) return;
      const removed = code === 4001 && ['unknown device', 'revoked'].includes(reason);
      const expired = code === 4001 && ['unknown token', 'expired token'].includes(reason);
      if (removed || expired) {
        closed = true;
        hooks.removed(confirmed ? 'This browser was removed from your Mac' : 'Get a fresh pairing link from your Mac or iPhone');
      } else {
        hooks.status(code === 4011 ? 'Mac is offline' : 'Reconnecting');
        const delay = Math.min(30_000, 1000 * 2 ** Math.min(attempt++, 5));
        reconnect = setTimeout(dial, delay);
      }
    });
  }

  dial();
  return {
    send: (kind, data) => sendEvent(kind, data),
    close() { closed = true; clearTimeout(reconnect); stop(); },
  };
}

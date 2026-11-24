import './style.css';
import { connect } from './connection.mjs';
import { fingerprint, parsePairing } from './pairing.mjs';
import { makeIdentity } from './wire.mjs';
import { deviceStore } from './storage.mjs';

const $ = (id) => document.getElementById(id);
const store = deviceStore();
const history = new Map(), threads = new Map();
let connection, pairing, draftPairing, selected, hostName, historyRequest, lockRelease;
let generation = 0, pending = false, connected = false, sending = false;
let remember = true;
const newThread = 'new';

function notify(message = '') {
  $('notice').textContent = message;
  $('notice').hidden = !message;
}
function setStatus(value) {
  connected = value === 'Connected';
  $('connection').textContent = $('host-status').textContent = value;
  if (!connected) historyRequest = undefined;
  $('send').disabled = !connected || sending;
  $('threads').disabled = !connected;
  $('older').disabled = !connected || Boolean(historyRequest);
}
function showPairing() {
  $('onboarding').hidden = false;
  $('chat').hidden = $('settings-button').hidden = true;
  $('confirm').hidden = true;
  $('pair-form').hidden = false;
  $('settings').close();
}
function render() {
  if (!pairing || pending) return;
  $('onboarding').hidden = true;
  $('chat').hidden = $('settings-button').hidden = false;
  $('host-name').textContent = hostName || 'Mac';
  $('host-key').textContent = fingerprint(pairing.hostKey);
  $('storage-mode').textContent = remember ? 'This browser is remembered.' : 'This tab won’t remember the pairing after you leave.';
  const options = [new Option('New conversation', newThread)];
  for (const [id, row] of threads) options.push(new Option(row.title || 'Conversation', id));
  $('threads').replaceChildren(...options);
  $('threads').value = selected || newThread;
  const page = history.get(selected);
  $('older').hidden = !page?.more;
  $('messages').replaceChildren(...(page?.items ?? []).map((item) => {
    const element = document.createElement('li');
    const label = document.createElement('b');
    const text = document.createElement('p');
    label.textContent = item.kind === 'user' ? 'You' : 'Yorozu';
    text.textContent = item.text;
    element.append(label, text);
    return element;
  }));
}
function fetchHistory(before) {
  if (!connected || !selected || historyRequest) return;
  const request = historyRequest = { id: selected, before };
  $('older').disabled = true;
  const g = generation;
  connection.send('history', { convId: selected, before }).then((sent) => {
    if (generation === g && historyRequest === request && !sent) {
      historyRequest = undefined;
      $('older').disabled = !connected;
    }
  });
}
function receive({ kind, data }) {
  if (kind === 'peer_info') {
    hostName = typeof data.name === 'string' ? data.name : '';
    render();
  } else if (kind === 'conv_list' && Array.isArray(data.conversations)) {
    threads.clear();
    for (const row of data.conversations) {
      if (row && typeof row.convId === 'string' && row.convId !== newThread && !row.archived) {
        threads.set(row.convId, { title: typeof row.title === 'string' ? row.title : undefined });
      }
    }
    if (selected && !threads.has(selected)) selected = undefined;
    selected ??= threads.keys().next().value;
    render();
    fetchHistory();
  } else if (kind === 'history' && historyRequest?.id === data.convId && Array.isArray(data.items)) {
    const { id, before } = historyRequest;
    const previous = history.get(id)?.items ?? [];
    const items = data.items.filter((row) => row && ['agent', 'user'].includes(row.kind) &&
      typeof row.text === 'string' && typeof row.id === 'string' && Number.isSafeInteger(row.seq));
    const current = new Set(items.map(({id: itemId}) => itemId));
    const live = previous.filter((item) => !Number.isSafeInteger(item.seq) && !current.has(item.id));
    const merged = before === undefined ? [...items, ...live] : [...items, ...previous];
    const content = new Map(merged.map((item) => [item.id, item]));
    history.set(id, { items: [...content.values()], more: data.more === true,
      oldest: data.items.find((item) => Number.isSafeInteger(item?.seq))?.seq });
    historyRequest = undefined;
    $('older').disabled = !connected;
    render();
    if (selected !== id) fetchHistory();
  } else if (kind === 'reply' && typeof data.text === 'string' && typeof data.messageId === 'string' && data.convId === selected) {
    const page = history.get(selected) ?? { items: [], more: false };
    if (!page.items.some((item) => item.id === data.messageId)) page.items.push({ id: data.messageId, text: data.text, kind: 'agent' });
    history.set(selected, page);
    render();
  } else if (kind === 'run_started' && data.convId === selected) {
    if (!history.get(selected)?.items.some((item) => item.id === data.messageId)) fetchHistory();
  } else if (kind === 'conv_update' && typeof data.convId === 'string') {
    if (data.deleted || data.archived) {
      threads.delete(data.convId);
      history.delete(data.convId);
      if (selected === data.convId) selected = threads.keys().next().value;
      if (historyRequest?.id === data.convId) historyRequest = undefined;
    } else {
      threads.set(data.convId, { title: typeof data.title === 'string' ? data.title : undefined });
    }
    render();
  } else if (kind === 'error') {
    if (historyRequest && data.convId === historyRequest.id && !data.messageId) {
      historyRequest = undefined;
      $('older').disabled = !connected;
    }
    notify('Your Mac couldn’t complete the request.');
  }
}
async function forget(message) {
  generation++;
  connection?.close();
  connection = pairing = draftPairing = selected = hostName = historyRequest = undefined;
  pending = sending = false;
  $('pair-now').disabled = false;
  $('message').value = $('pair-link').value = '';
  threads.clear();
  history.clear();
  render();
  $('messages').replaceChildren();
  setStatus('');
  showPairing();
  notify(message);
  try { await store.clear(); }
  catch { notify('Could not erase site data. Clear Yorozu site data in your browser settings.'); }
}
function start(device, isPending) {
  pairing = device;
  pending = isPending;
  const g = ++generation;
  connection = connect(device, {
    status(value) { if (generation === g) setStatus(value); },
    event(event) { if (generation === g) receive(event); },
    removed(reason) { if (generation === g) void forget(reason); },
    async paired(saved) {
      if (generation !== g) return;
      if (remember) {
        try { await store.save(saved); }
        catch {
          remember = false;
          notify('Your browser couldn’t save the pairing. It will last only in this tab.');
        }
      }
      if (generation !== g) return;
      pending = false;
      pairing = saved;
      draftPairing = undefined;
      render();
    },
  });
  render();
}

$('pair-form').addEventListener('submit', (event) => {
  event.preventDefault();
  try {
    draftPairing = parsePairing($('pair-link').value, import.meta.env.DEV ? import.meta.env.VITE_YOROZU_TEST_RELAY : undefined);
    $('pair-link').value = '';
    remember = $('remember').checked;
    $('fingerprint').textContent = fingerprint(draftPairing.hostKey);
    $('pair-form').hidden = true;
    $('confirm').hidden = false;
    notify();
  } catch { notify('Paste a valid Yorozu link for the standard Yorozu relay.'); }
});
$('pair-now').addEventListener('click', async () => {
  const g = ++generation;
  $('pair-now').disabled = true;
  try {
    const identity = await makeIdentity();
    if (generation === g) start({ ...draftPairing, identity }, true);
  } catch {
    if (generation === g) {
      notify('Pairing is unavailable. On iPhone, use Safari on iOS 18.4 or newer. On Windows, update Edge or Chrome.');
      $('pair-now').disabled = false;
    }
  }
});
$('cancel').addEventListener('click', () => void forget('Pairing cancelled. If the Mac already accepted this browser, remove it from Devices.'));
$('settings-button').addEventListener('click', () => $('settings').showModal());
$('forget').addEventListener('click', () => void forget('This browser has forgotten the pairing.'));
$('older').addEventListener('click', () => {
  const oldest = history.get(selected)?.oldest;
  if (Number.isSafeInteger(oldest)) fetchHistory(oldest);
});
$('threads').addEventListener('change', () => {
  const value = $('threads').value;
  selected = value === newThread ? undefined : value;
  render();
  fetchHistory();
});
$('composer').addEventListener('submit', async (event) => {
  event.preventDefault();
  const input = $('message');
  const text = input.value.trim();
  if (!connected || sending || !text) return;
  const g = generation;
  sending = true;
  $('send').disabled = true;
  const id = selected ?? crypto.randomUUID(), messageId = crypto.randomUUID();
  const sent = await connection.send('message', { convId: id, messageId, text });
  if (generation !== g) return;
  sending = false;
  $('send').disabled = !connected;
  if (!sent) { notify('Not sent. Reconnect and try again.'); return; }
  if (input.value.trim() === text) input.value = '';
  selected ??= id;
  if (!threads.has(id)) threads.set(id, { title: text.slice(0, 60) });
  const page = history.get(id) ?? { items: [] };
  if (!page.items.some((item) => item.id === messageId)) page.items.push({ id: messageId, kind: 'user', text });
  history.set(id, page);
  render();
});

if (!navigator.locks) {
  notify('Use Safari on iOS 18.4 or newer, or a current version of Edge or Chrome.');
} else {
  navigator.locks.request('yorozu-device', async () => {
    try {
      notify();
      const saved = await store.load();
      if (saved) start(saved, false);
      else showPairing();
    } catch {
      showPairing();
      notify('This browser cannot read its saved pairing.');
    }
    await new Promise((resolve) => { lockRelease = resolve; });
  }).catch(() => notify('Yorozu couldn’t open on this browser.'));
  setTimeout(() => {
    if (!lockRelease) notify('Yorozu may be open in another tab. Close that tab to continue here.');
  }, 1200);
}

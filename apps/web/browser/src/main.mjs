import './style.css';
import { mountUI } from './presentation.jsx';
import { connect } from './connection.mjs';
import { fingerprint, parsePairing, officialRelay } from './pairing.mjs';
import { makeIdentity } from './wire.mjs';
import { deviceStore } from './storage.mjs';
import { listenForDeviceCode } from './device-code.mjs';

const $ = (id) => document.getElementById(id);
function takeInvitation() {
  if (!location.hash) return null;
  const hash = new URLSearchParams(location.hash.slice(1));
  window.history.replaceState(null, '', location.pathname);
  const values = hash.getAll('pair');
  const link = values.length === 1 ? values[0] : null;
  return link && link.length <= 4096 ? link : null;
}
let incoming = takeInvitation();
const { renderMessages, fitMessage, captureScroll, renderPairMethods } = mountUI();
const store = deviceStore();
const history = new Map(), threads = new Map(), drafts = new Map(), scrollPositions = new Map();
let connection, pairing, draftPairing, selected, hostName, historyRequest, lockRelease;
let generation = 0, pending = false, connected = false, sending = false;
let lastScroll = 0, initialSelectionDone = false;
let remember = true;
const newThread = 'new';
const qrRelay = import.meta.env.DEV && import.meta.env.VITE_YOROZU_TEST_RELAY || officialRelay;
let method = null, receiver = null, receiverError = '', receiverController;
function renderMethods() {
  renderPairMethods({
    mode: method, onMode: chooseMethod, onScan(value) {
      let reason;
      return acceptInvitation(value, false, message => { reason = message; }) || reason || false;
    },
    receiver, receiverError, restart: () => chooseMethod('show'),
    focusPaste: () => $('pair-link').focus(),
    scanHint: 'Scan the browser invitation QR code from your Mac. A native-client invite will not work here.',
    showHint: 'In Yorozu on an already-paired iPhone or iPad, open Settings → Devices → Add Device and scan this code. Use a version that supports browser pairing.',
  });
}
function closeReceiver() {
  receiverController?.abort();
  receiverController = undefined;
  receiver = null;
}
function chooseMethod(next) {
  closeReceiver();
  method = next;
  receiverError = '';
  $('pair-fields').hidden = Boolean(method);
  renderMethods();
  if (method !== 'show') return;
  const controller = receiverController = new AbortController();
  listenForDeviceCode(qrRelay, {
    signal: controller.signal,
    onReady(code) {
      if (receiverController !== controller) return;
      receiver = code;
      renderMethods();
    },
  }).then(invite => {
    if (receiverController !== controller) return;
    if (!acceptInvitation(invite, false)) {
      receiver = null;
      receiverError = 'This response is not a browser invitation. Use an updated Yorozu device and try a new code.';
      renderMethods();
    }
  }).catch(error => {
    if (receiverController !== controller) return;
    receiver = null;
    receiverError = error?.message?.includes('expired') ? 'This code expired.' :
      'Couldn’t complete the QR request. Try a new code or paste an invitation.';
    renderMethods();
  });
}

function notify(message = '') {
  $('notice').textContent = message;
  $('notice').hidden = !message;
}
function setPairProgress(value = "") {
  $("pair-progress").textContent = value;
  $("pair-progress").hidden = !value;
}
function setStatus(value) {
  if (pending) setPairProgress(value === "Connected" ? "" : value);
  connected = value === 'Connected';
  $('connection').textContent = $('host-status').textContent = value;
  if (!connected) {
    resetHistoryRequest();
    queuedLatest = undefined;
  }
  updateSend();
  syncHistoryControls();
  if (!connected) emptyState();
}
function showPairing() {
  $('onboarding').hidden = false;
  $('chat').hidden = true;
  $('entry-bar').hidden = false;
  $('mobile-chats').close();
  $('confirm').hidden = true;
  setPairProgress();
  $('pair-error').hidden = true;
  $('pair-form').hidden = false;
  $('pair-methods').hidden = false;
  chooseMethod(null);
  $('settings').close();
  if (incoming) {
    $('pair-link').value = incoming;
    $('pair-hint').textContent = 'Pairing link ready.';
    incoming = null;
  }
}
function render() {
  if (!pairing || pending) return;
  $('onboarding').hidden = true;
  $('chat').hidden = false;
  $('entry-bar').hidden = true;
  $('host-name').textContent = hostName || 'Mac';
  $('host-key').textContent = fingerprint(pairing.hostKey);
  $('storage-mode').textContent = remember ? 'This browser is remembered.' : 'This tab won’t remember the pairing after you leave.';
  $('chat-title').textContent = selected ? threads.get(selected)?.title || 'Untitled chat' : 'New chat';
  renderThreads();
  renderMessages(history.get(selected)?.items ?? [], selected, () => {
    syncHistoryControls();
    emptyState();
  }, scrollPositions.get(selected));
  updateJump();
  lastScroll = $('timeline').scrollTop;
}
function renderThreads() {
  const list = $('threads'), rows = [...threads.entries()];
  const existing = Array.from(list.children);
  if (existing.length !== rows.length || rows.some(([id, row], i) =>
      existing[i].firstChild.dataset.thread !== id || existing[i].firstChild.textContent !== (row.title || 'Untitled chat'))) {
    const focused = document.activeElement?.dataset?.thread;
    list.replaceChildren(...rows.map(([id, row]) => {
      const item = document.createElement('li'), button = document.createElement('button');
      button.type = 'button';
      button.dataset.thread = id;
      button.textContent = row.title || 'Untitled chat';
      button.title = button.textContent;
      item.append(button);
      return item;
    }));
    if (focused) Array.from(list.querySelectorAll('button')).find(button => button.dataset.thread === focused)?.focus();
  }
  for (const button of list.querySelectorAll('button')) button.setAttribute('aria-current', String(button.dataset.thread === selected));
  $('no-chats').hidden = rows.length > 0;
}
function updateSend() {
  $('send').disabled = !connected || sending || !$('message').value.trim();
}
function emptyState() {
  const page = history.get(selected);
  $('empty-chat').hidden = Boolean(page?.items.length);
  let title = selected ? (page ? 'No messages yet' : 'Loading messages…') : 'Start a chat';
  let detail = selected ? (page ? 'Write a message to continue this chat.' : '') : 'Write a message to your Yorozu assistant.';
  if (!connected && !page?.items.length) {
    title = 'Waiting for your Mac';
    detail = 'Your chats will be ready when it connects.';
  } else if (selected && !page && !historyRequest && failedHistory === selected) {
    title = 'Couldn’t load messages';
    detail = 'Choose this chat again to retry.';
  }
  $('chat-state-title').textContent = title;
  $('chat-state-description').textContent = detail;
}
function syncHistoryControls() {
  const page = history.get(selected);
  const button = $('older');
  const losingFocus = button === document.activeElement;
  button.hidden = !page?.more || !Number.isSafeInteger(page.oldest);
  if (button.hidden && losingFocus) $('timeline').focus({ preventScroll: true });
  button.disabled = !connected || Boolean(historyRequest);
  button.textContent = historyRequest?.before !== undefined ? 'Loading earlier messages…' : 'Load earlier messages';
}
function updateJump() {
  const timeline = $('timeline');
  $('latest').hidden = timeline.scrollHeight - timeline.clientHeight - timeline.scrollTop < 140;
}
function selectChat(id, fromNavigation = false) {
  if (selected !== id) {
    drafts.set(selected ?? newThread, $('message').value);
    if (selected) scrollPositions.set(selected, captureScroll());
    selected = id;
    $('message').value = drafts.get(id ?? newThread) ?? '';
    fitMessage();
    updateSend();
  }
  initialSelectionDone = true;
  render();
  if (id) {
    if (historyRequest) queuedLatest = id;
    else fetchHistory();
  }
  if (fromNavigation && $('mobile-chats').open) $('mobile-chats').close();
}
let historyTimer, failedHistory, queuedLatest;
function drainHistory(previousId) {
  const refresh = selected && (selected !== previousId || selected === queuedLatest);
  queuedLatest = undefined;
  if (refresh) fetchHistory();
}
function resetHistoryRequest() {
  clearTimeout(historyTimer);
  historyRequest = undefined;
}
function fetchHistory(before) {
  if (!connected || !selected || historyRequest) return;
  const request = historyRequest = { id: selected, before };
  failedHistory = undefined;
  syncHistoryControls();
  emptyState();
  const g = generation;
  const failed = () => {
    if (generation !== g || historyRequest !== request) return;
    failedHistory = request.id;
    resetHistoryRequest();
    syncHistoryControls();
    emptyState();
    if (selected === request.id) notify(before === undefined ? 'Couldn’t load this chat. Choose it again to retry.' : 'Couldn’t load earlier messages. Try again.');
    drainHistory(request.id);
  };
  historyTimer = setTimeout(failed, 12_000);
  connection.send('history', { convId: selected, before }).then((sent) => {
    if (!sent) failed();
  }).catch(failed);
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
    if (!initialSelectionDone || (selected && !threads.has(selected))) selectChat(threads.keys().next().value);
    else render();
    fetchHistory();
  } else if (kind === 'history' && historyRequest?.id === data.convId && historyRequest.before === data.before && Array.isArray(data.items)) {
    const { id, before } = historyRequest;
    const prior = history.get(id), previous = prior?.items ?? [];
    const items = data.items.filter((row) => row && ['agent', 'user'].includes(row.kind) &&
      typeof row.text === 'string' && typeof row.id === 'string' && Number.isSafeInteger(row.seq));
    const current = new Set(items.map(({id: itemId}) => itemId));
    const live = previous.filter((item) => !Number.isSafeInteger(item.seq) && !current.has(item.id));
    const oldest = Number.isSafeInteger(data.browserOldest) ? data.browserOldest : data.items.find((item) => Number.isSafeInteger(item?.seq))?.seq;
    const previousNewest = previous.findLast(item => Number.isSafeInteger(item.seq))?.seq;
    const keepsEarlier = before === undefined && Number.isSafeInteger(oldest) &&
      Number.isSafeInteger(prior?.oldest) && Number.isSafeInteger(previousNewest) &&
      prior.oldest <= oldest && previousNewest >= oldest - 1;
    const earlier = keepsEarlier ? previous.filter(item => Number.isSafeInteger(item.seq) && item.seq < oldest) : [];
    const merged = before === undefined ? [...earlier, ...items, ...live] : [...items, ...previous];
    const content = new Map(merged.map((item) => [item.id, item]));
    history.set(id, { items: [...content.values()], more: keepsEarlier && prior.oldest < oldest ? prior.more : data.more === true,
      oldest: keepsEarlier ? prior.oldest : (oldest ?? prior?.oldest) });
    resetHistoryRequest();
    render();
    drainHistory(id);
  } else if (kind === 'reply' && typeof data.text === 'string' && typeof data.messageId === 'string' &&
      typeof data.convId === 'string' && (data.convId === selected || threads.has(data.convId))) {
    const page = history.get(data.convId) ?? { items: [], more: false };
    if (!page.items.some((item) => item.id === data.messageId)) page.items.push({ id: data.messageId, text: data.text, kind: 'agent' });
    history.set(data.convId, page);
    if (data.convId === selected) render();
  } else if (kind === 'run_started' && data.convId === selected) {
    if (!history.get(selected)?.items.some((item) => item.id === data.messageId)) fetchHistory();
  } else if (kind === 'conv_update' && typeof data.convId === 'string') {
    if (data.deleted || data.archived) {
      threads.delete(data.convId);
      history.delete(data.convId);
      drafts.delete(data.convId);
      scrollPositions.delete(data.convId);
      if (historyRequest?.id === data.convId) resetHistoryRequest();
      if (selected === data.convId) selectChat(threads.keys().next().value);
    } else {
      threads.set(data.convId, { title: typeof data.title === 'string' ? data.title : undefined });
    }
    render();
  } else if (kind === 'error') {
    if (historyRequest && data.convId === historyRequest.id && !data.messageId) {
      failedHistory = historyRequest.id;
      resetHistoryRequest();
      syncHistoryControls();
      emptyState();
      drainHistory(data.convId);
    }
    notify('Your Mac couldn’t complete the request.');
  }
}
async function forget(message, restoreFocus = false) {
  generation++;
  connection?.close();
  resetHistoryRequest();
  connection = pairing = draftPairing = selected = hostName = undefined;
  initialSelectionDone = false;
  failedHistory = queuedLatest = undefined;
  pending = sending = false;
  $('pair-now').disabled = false;
  $('message').value = $('pair-link').value = '';
  threads.clear();
  history.clear();
  drafts.clear();
  scrollPositions.clear();
  fitMessage();
  render();
  renderMessages([]);
  setStatus('');
  showPairing();
  if (restoreFocus) $('pair-link').focus();
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
          notify('This browser couldn’t remember the pairing. It will work in this tab, but you’ll need a new link if you close it.');
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

function continuePairing(event) {
  event.preventDefault();
  const input = $('pair-link');
  const error = $('pair-error');
  const setError = (message) => {
    error.textContent = message;
    error.hidden = !message;
    input.setAttribute('aria-invalid', message ? 'true' : 'false');
  };
  setError('');
  if (!input.value.trim()) {
    setError('Paste a pairing invitation first, or open the original invite link in Safari.');
    input.focus();
    return;
  }
  acceptInvitation(input.value, import.meta.env.DEV, setError);
}
function acceptInvitation(value, allowLegacy, setError) {
  try {
    draftPairing = parsePairing(value, qrRelay, allowLegacy);
  } catch (error) {
    setError?.(error.code === 'expired'
      ? 'This invitation expired. Ask for a new browser pairing link.'
      : 'This is not a valid browser invitation. Copy the entire original link and try again.');
    return false;
  }
  const input = $('pair-link');
  input.value = '';
  $('pair-hint').textContent = '';
  remember = $('remember').checked;
  $('fingerprint').textContent = fingerprint(draftPairing.hostKey);
  chooseMethod(null);
  $('pair-methods').hidden = $('pair-form').hidden = true;
  $('confirm').hidden = false;
  input.blur();
  $('confirm-heading').focus();
  $('confirm').scrollIntoView({block:'nearest'});
  notify();
  return true;
}
$('pair-form').addEventListener('submit', continuePairing);
$('continue').addEventListener('click', continuePairing);
$('pair-link').addEventListener('paste', (event) => {
  const text = event.clipboardData?.getData('text/plain');
  if (!text) return;
  event.preventDefault();
  $('pair-link').value = text;
});
$('pair-now').addEventListener('click', async () => {
  const g = ++generation;
  $('pair-now').disabled = true;
  setPairProgress('Checking this device…');
  try {
    const identity = await makeIdentity(draftPairing.browser);
    if (generation === g) start({ ...draftPairing, identity }, true);
  } catch {
    if (generation === g) {
      notify('Pairing is unavailable. On iPhone, use Safari on iOS 18.4 or newer. On Windows, update Edge or Chrome.');
      $('pair-now').disabled = false;
      setPairProgress();
    }
  }
});
$('cancel').addEventListener('click', () => void forget('Pairing cancelled. If the Mac already accepted this browser, remove it from Devices.', true));
$('settings-button').addEventListener('click', () => $('settings').showModal());
$('chats-button').addEventListener('click', () => {
  $('mobile-chats').append($('chat-nav'));
  $('mobile-chats').showModal();
});
$('mobile-chats').addEventListener('close', () => {
  $('desktop-chats').append($('chat-nav'));
  if ($('chats-button').getClientRects().length && !$('chat').hidden) $('chats-button').focus();
});
matchMedia('(max-width: 45rem)').addEventListener('change', ({ matches }) => {
  if (!matches && $('mobile-chats').open) $('mobile-chats').close();
});
$('new-chat').addEventListener('click', () => selectChat(undefined, true));
$('threads').addEventListener('click', ({ target }) => {
  const button = target.closest('button[data-thread]');
  if (button) selectChat(button.dataset.thread, true);
});
function showForgetConfirmation(show) {
  $('forget-confirmation').hidden = !show;
  $('forget-action').hidden = show;
}
$('forget').addEventListener('click', () => {
  showForgetConfirmation(true);
  $('keep-pairing').focus();
});
$('keep-pairing').addEventListener('click', () => {
  showForgetConfirmation(false);
  $('forget').focus();
});
$('settings').addEventListener('close', () => showForgetConfirmation(false));
$('confirm-forget').addEventListener('click', () => void forget('This browser has forgotten the pairing.', true));
function loadEarlier() {
  const page = history.get(selected);
  if (page?.more && Number.isSafeInteger(page.oldest)) fetchHistory(page.oldest);
}
$('older').addEventListener('click', loadEarlier);
$('timeline').addEventListener('scroll', () => {
  const top = $('timeline').scrollTop;
  if (top < lastScroll && top < 80) loadEarlier();
  lastScroll = top;
  updateJump();
}, { passive: true });
$('latest').addEventListener('click', () => {
  $('timeline').scrollTop = $('timeline').scrollHeight;
  $('timeline').focus({ preventScroll: true });
});
$('message').addEventListener('input', updateSend);
function adaptViewport() {
  const viewport = window.visualViewport;
  if (viewport && viewport.scale === 1) {
    document.documentElement.style.setProperty('--viewport-height', viewport.height + 'px');
  } else document.documentElement.style.removeProperty('--viewport-height');
}
window.visualViewport?.addEventListener('resize', adaptViewport);
adaptViewport();
$('composer').addEventListener('submit', async (event) => {
  event.preventDefault();
  const input = $('message');
  const text = input.value.trim();
  if (!connected || sending || !text) return;
  const g = generation;
  sending = true;
  $('send').disabled = true;
  const origin = selected;
  const id = origin ?? crypto.randomUUID(), messageId = crypto.randomUUID();
  const sent = await connection.send('message', { convId: id, messageId, text });
  if (generation !== g) return;
  sending = false;
  updateSend();
  if (!sent) { notify('Not sent. Reconnect and try again.'); return; }
  if (selected === origin) {
    if (input.value.trim() === text) input.value = '';
    fitMessage();
    selected = id;
  } else if (drafts.get(origin ?? newThread)?.trim() === text) drafts.delete(origin ?? newThread);
  updateSend();
  if (!threads.has(id)) threads.set(id, { title: text.slice(0, 60) });
  const page = history.get(id) ?? { items: [] };
  if (!page.items.some((item) => item.id === messageId)) page.items.push({ id: messageId, kind: 'user', text });
  history.set(id, page);
  render();
});

$('boot-hint').hidden = true;
window.addEventListener('pagehide', () => { if (method) chooseMethod(null); });
window.addEventListener('hashchange', () => {
  const link = takeInvitation();
  if (!link || pairing || pending) return;
  incoming = link;
  if (lockRelease) showPairing();
});

if (!navigator.locks) {
  notify('Use Safari on iOS 18.4 or newer, or a current version of Edge or Chrome.');
} else {
  navigator.locks.request('yorozu-device', async () => {
    try {
      notify();
      const saved = await store.load();
      if (saved && (saved.browser || import.meta.env.DEV)) start(saved, false);
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

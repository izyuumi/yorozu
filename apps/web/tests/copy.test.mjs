import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const script = await readFile(new URL('../public/copy.js', import.meta.url), 'utf8');

// Exercise the script's browser-facing contract: click, clipboard, selection and status.
function browser(writeText) {
  const classes = new Set();
  const source = { textContent: 'Read the setup guide.' };
  const status = { textContent: '' };
  const timers = new Map();
  let nextTimer = 0;
  let click;
  let selected;
  const button = {
    hidden: true,
    textContent: 'Copy',
    dataset: { copy: 'agent-prompt' },
    classList: { add: value => classes.add(value), remove: value => classes.delete(value) },
    addEventListener: (_, listener) => { click = listener; },
  };
  vm.runInNewContext(script, {
    document: {
      querySelectorAll: () => [button],
      getElementById: id => id === 'agent-prompt' ? source : status,
      createRange: () => ({ selectNodeContents: node => { selected = node.textContent; } }),
    },
    navigator: { clipboard: { writeText } },
    getSelection: () => ({ removeAllRanges() {}, addRange() {} }),
    setTimeout: callback => { const id = ++nextTimer; timers.set(id, callback); return id; },
    clearTimeout: id => timers.delete(id),
  });
  return { button, status, classes, timers, click: () => click(), selected: () => selected };
}

test('copy writes the prompt and announces success without changing the selection', async () => {
  let copied;
  const page = browser(async text => { copied = text; });
  assert.equal(page.button.hidden, false);
  await page.click();
  assert.equal(copied, 'Read the setup guide.');
  assert.equal(page.button.textContent, 'Copied');
  assert.equal(page.status.textContent, 'Prompt copied.');
  assert.equal(page.selected(), undefined);
  [...page.timers.values()][0]();
  assert.equal(page.button.textContent, 'Copy');
  assert.equal(page.status.textContent, 'Prompt copied.');
});

test('denied clipboard selects the prompt and explains how to copy it manually', async () => {
  const page = browser(async () => { throw new Error('Permission denied'); });
  await page.click();
  assert.equal(page.selected(), 'Read the setup guide.');
  assert.match(page.status.textContent, /Couldn’t copy automatically.*Copy command/);
  assert.equal(page.button.textContent, 'Copy');
});

test('a failed retry clears the previous success state and pending reset', async () => {
  let fail = false;
  const page = browser(async () => { if (fail) throw new Error('Permission denied'); });
  await page.click();
  fail = true;
  await page.click();
  assert.equal(page.button.textContent, 'Copy');
  assert.equal(page.classes.has('done'), false);
  assert.equal(page.timers.size, 0);
  assert.match(page.status.textContent, /Couldn’t copy automatically/);
});

test('a delayed earlier failure cannot replace a newer successful copy', async () => {
  const pending = [];
  const page = browser(() => new Promise((resolve, reject) => pending.push({ resolve, reject })));
  const earlier = page.click();
  const latest = page.click();
  pending[1].resolve();
  await latest;
  pending[0].reject(new Error('Delayed denial'));
  await earlier;
  assert.equal(page.status.textContent, 'Prompt copied.');
  assert.equal(page.button.textContent, 'Copied');
  assert.equal(page.selected(), undefined);
  assert.equal(page.timers.size, 1);
});

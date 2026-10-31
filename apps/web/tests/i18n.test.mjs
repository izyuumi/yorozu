import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';
import worker, { chooseLocale, securityHeaders } from '../worker.mjs';
import { cookieLocale, detectLocale, localePath, locales, matchTag, pages } from '../src/i18n/locales.mjs';
import { strings } from '../src/i18n/strings.mjs';

const dist = new URL('../dist/', import.meta.url);
const site = 'https://yorozu.yumi.to';
const translated = locales.filter(locale => locale.code !== 'en');
const distFile = url => new URL(`.${url}index.html`, dist);

test('Accept-Language tags map to the nine site languages, with English as the fallback', () => {
  const cases = {
    'zh-TW': 'zh-Hant', 'zh-HK': 'zh-Hant', 'zh-MO': 'zh-Hant', 'zh-Hant': 'zh-Hant', 'zh-Hant-CN': 'zh-Hant',
    zh: 'zh-Hans', 'zh-CN': 'zh-Hans', 'zh-SG': 'zh-Hans', 'zh-Hans': 'zh-Hans',
    pt: 'pt-BR', 'pt-PT': 'pt-BR', 'pt-BR': 'pt-BR',
    ja: 'ja', 'ja-JP': 'ja', 'ko-KR': 'ko', 'es-419': 'es', 'fr-CA': 'fr', 'de-AT': 'de', 'en-GB': 'en',
    it: null, '': null, 'x-klingon': null,
  };
  for (const [tag, code] of Object.entries(cases)) assert.equal(matchTag(tag), code, tag);

  assert.equal(detectLocale('ja,en-US;q=0.9,en;q=0.8'), 'ja');
  assert.equal(detectLocale('en-US,en;q=0.9,ja;q=0.8'), 'en');
  assert.equal(detectLocale('it-IT,it;q=0.9,de;q=0.7'), 'de', 'skips languages the site lacks');
  assert.equal(detectLocale('fr;q=0.5, ko;q=0.8'), 'ko', 'orders by q, not position');
  assert.equal(detectLocale('ja;q=0, de'), 'de', 'q=0 means not acceptable');
  assert.equal(detectLocale('*'), 'en');
  assert.equal(detectLocale('it'), 'en');
  assert.equal(detectLocale(''), 'en');
  assert.equal(detectLocale(null), 'en');
});

test('only a known code in the switcher cookie counts', () => {
  assert.equal(cookieLocale('yorozu_lang=ja'), 'ja');
  assert.equal(cookieLocale('a=1; yorozu_lang=pt-BR; b=2'), 'pt-BR');
  assert.equal(cookieLocale('yorozu_lang=xx'), null);
  assert.equal(cookieLocale('yorozu_lang=constructor'), null);
  assert.equal(cookieLocale('other=ja'), null);
  assert.equal(cookieLocale(null), null);
});

function request(path, headers = {}, method = 'GET') {
  return new Request(`${site}${path}`, { method, headers });
}

const assets = { fetch: async req => new Response(`asset ${new URL(req.url).pathname}`, { headers: { 'Content-Type': 'text/html', Vary: 'Accept-Encoding' } }) };

test('the worker sends a first visit to the visitor\'s language and keeps the query string', async () => {
  for (const [header, location] of [['ja', '/ja/'], ['de-DE,de;q=0.9', '/de/'], ['zh-TW', '/zh-hant/'], ['pt', '/pt-br/'], ['zh-CN', '/zh-hans/']]) {
    const response = await worker.fetch(request('/', { 'Accept-Language': header }), { ASSETS: assets });
    assert.equal(response.status, 302, header);
    assert.equal(response.headers.get('Location'), location, header);
    assert.match(response.headers.get('Vary'), /Accept-Language/);
    assert.match(response.headers.get('Cache-Control'), /private/);
  }
  for (const [path, location] of [['/pair', '/ja/pair/'], ['/pair/?v=1', '/ja/pair/?v=1'], ['/add?x=1&y=2', '/ja/add/?x=1&y=2'], ['/terms', '/ja/terms/']]) {
    const response = await worker.fetch(request(path, { 'Accept-Language': 'ja' }), { ASSETS: assets });
    assert.equal(response.headers.get('Location'), location, path);
  }
});

test('English, crawlers, the cookie and links within the site get the page they asked for', async () => {
  const english = [
    {},
    { 'Accept-Language': 'en-US,en;q=0.9' },
    { 'Accept-Language': 'it' },
    { 'Accept-Language': 'ja', 'User-Agent': 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)' },
    { 'Accept-Language': 'ja', 'User-Agent': 'Slackbot-LinkExpanding 1.0' },
    { 'Accept-Language': 'ja', Cookie: 'yorozu_lang=en' },
    { 'Accept-Language': 'ja', 'Sec-Fetch-Site': 'same-origin' },
    { 'Accept-Language': 'ja', Referer: `${site}/ja/privacy/` },
  ];
  for (const headers of english) {
    const response = await worker.fetch(request('/', headers), { ASSETS: assets });
    assert.equal(response.status, 200, JSON.stringify(headers));
    assert.equal(await response.text(), 'asset /');
    assert.match(response.headers.get('Vary'), /Accept-Encoding, Accept-Language, Cookie/);
    for (const [name, value] of Object.entries(securityHeaders)) assert.equal(response.headers.get(name), value);
  }
  assert.equal(chooseLocale(request('/', { 'Accept-Language': 'en', Cookie: 'yorozu_lang=ko' })), 'ko', 'the cookie beats Accept-Language');
  assert.equal(chooseLocale(request('/', { 'Accept-Language': 'ja', 'Sec-Fetch-Site': 'cross-site' })), 'ja');
  assert.equal(chooseLocale(request('/', { 'Accept-Language': 'ja', Referer: 'https://www.google.com/' })), 'ja');
  const post = await worker.fetch(request('/', { 'Accept-Language': 'ja' }, 'POST'), { ASSETS: assets });
  assert.equal(post.status, 200);
});

test('the worker leaves prefixed pages and files to the static assets', async () => {
  for (const path of ['/ja/', '/de/pair/', '/styles.css', '/lang.js', '/.well-known/apple-app-site-association']) {
    const response = await worker.fetch(request(path, { 'Accept-Language': 'ja' }), { ASSETS: assets });
    assert.equal(await response.text(), `asset ${path}`);
  }
});

test('the worker adds the same security headers as the /* block of _headers', async () => {
  const headers = await readFile(new URL('../public/_headers', import.meta.url), 'utf8');
  const block = headers.split(/\n(?=\S)/).find(section => section.startsWith('/*\n'));
  const parsed = Object.fromEntries(block.split('\n').slice(1).filter(Boolean)
    .map(line => line.trim().match(/^([^:]+):\s*(.*)$/).slice(1)));
  assert.deepEqual(securityHeaders, parsed);
});

test('the worker runs first for every unprefixed page, in both slash forms', async () => {
  const config = JSON.parse((await readFile(new URL('../wrangler.jsonc', import.meta.url), 'utf8')).replace(/^\s*\/\/.*$/gm, ''));
  const first = config.assets.run_worker_first;
  for (const page of pages) {
    assert.ok(first.includes(page), page);
    if (page !== '/') assert.ok(first.includes(page.slice(0, -1)), page.slice(0, -1));
  }
});

function shape(value) {
  if (Array.isArray(value)) return value.map(shape);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, shape(item)]));
  return typeof value;
}

function markup(text) {
  return [...String(text).matchAll(/<(\/?[a-z0-9]+)|href="([^"]*)"|<code>([^<]*)<\/code>/g)].map(match => match.slice(1).find(Boolean)).sort();
}

function texts(value, path = '') {
  if (typeof value === 'string') return [[path, value]];
  if (value && typeof value === 'object') return Object.entries(value).flatMap(([key, item]) => texts(item, `${path}.${key}`));
  return [];
}

test('every translation has the English text\'s shape, links, tags and code, and is actually translated', () => {
  const en = strings.en;
  // Words that are the same in a language: names, and "Notifications" in French or "Support" in German.
  const same = new Set(['.name', '.footer.copyright', '.home.og.title', '.home.mac.title']);
  const sameIn = { fr: ['.home.moreFacts.2.0'], de: ['.nav.support', '.support.title'] };
  // The Japanese name already says よろず, so its lede drops the kana aside.
  const dropped = { ja: { '.home.lede': ['span', '/span'] } };
  for (const { code } of translated) {
    const t = strings[code];
    assert.deepEqual(shape({ ...t, governs: null }), shape(en), code);
    assert.match(t.governs, /href="@en"/, code);
    const source = new Map(texts(en));
    for (const [path, text] of texts(t)) {
      if (path === '.governs') continue;
      const expected = markup(source.get(path)).filter(item => !dropped[code]?.[path]?.includes(item));
      assert.deepEqual(markup(text), expected, `${code}${path}`);
      if (!same.has(path) && !sameIn[code]?.includes(path)) assert.notEqual(text, source.get(path), `${code}${path} is still English`);
    }
    assert.notEqual(t.privacy.effective, en.privacy.effective, code);
  }
  assert.equal(strings.ja.name, 'よろず Yorozu');
});

test('every page is built in every language, with its lang, canonical and hreflang alternates', async () => {
  for (const page of pages) {
    for (const { code } of locales) {
      const url = localePath(code, page);
      const html = await readFile(distFile(url), 'utf8');
      assert.match(html, new RegExp(`<html lang="${code}"`), url);
      assert.match(html, new RegExp(`<link rel="canonical" href="${site}${url}"`), url);
      for (const other of locales) {
        assert.ok(html.includes(`<link rel="alternate" hreflang="${other.code}" href="${site}${localePath(other.code, page)}">`), `${url} → ${other.code}`);
      }
      assert.ok(html.includes(`<link rel="alternate" hreflang="x-default" href="${site}${page}">`), `${url} x-default`);
      assert.ok(html.includes('<script src="/lang.js" defer></script>'), `${url} lang.js`);
      for (const other of locales) {
        assert.ok(html.includes(`href="${localePath(other.code, page)}"`), `${url} switcher → ${other.code}`);
      }
      assert.match(html, new RegExp(`aria-current="(true|page)"[^>]*data-locale="${code}"|data-locale="${code}"[^>]*aria-current`), `${url} marks its own language`);
    }
  }
});

test('translated pages carry localized titles, descriptions and Open Graph text', async () => {
  for (const { code } of translated) {
    const t = strings[code];
    const home = await readFile(distFile(localePath(code, '/')), 'utf8');
    const escape = text => text.replaceAll('&', '&amp;').replaceAll('"', '&quot;');
    assert.ok(home.includes(`<title>${t.home.title.replaceAll('&', '&amp;')}</title>`), code);
    assert.ok(home.includes(`<meta name="description" content="${escape(t.home.description)}">`), code);
    assert.ok(home.includes(`<meta property="og:description" content="${escape(t.home.og.description)}">`), code);
    assert.ok(home.includes(`<meta property="og:locale" content="${code.replace('-', '_')}">`), code);
    for (const kind of ['privacy', 'terms']) {
      const html = await readFile(distFile(localePath(code, `/${kind}/`)), 'utf8');
      assert.ok(html.includes('class="translation-note"'), `${code} ${kind}`);
      assert.ok(html.includes(`href="/${kind}/"`), `${code} ${kind} links the English version`);
    }
    for (const [page, internal] of [['/', '/terms/'], ['/privacy/', '/']]) {
      const html = await readFile(distFile(localePath(code, page)), 'utf8');
      assert.ok(html.includes(`href="${localePath(code, internal)}"`), `${code}${page} links ${internal} in its language`);
      assert.ok(!html.includes('href="@'), `${code}${page}`);
    }
  }
});

test('pairing and add-a-Mac pages work the same in every language', async () => {
  for (const { code } of locales) {
    const pair = await readFile(distFile(localePath(code, '/pair/')), 'utf8');
    assert.ok(pair.includes('<script src="/pair.js" defer></script>'), code);
    assert.match(pair, /id="open-in-app"[^>]*hidden/, code);
    assert.ok(pair.includes('<meta name="robots" content="noindex">'), code);
    const add = await readFile(distFile(localePath(code, '/add/')), 'utf8');
    assert.ok(add.includes('<meta name="robots" content="noindex">'), code);
  }
});

test('choosing a language remembers it and keeps the pairing code in the #fragment', async () => {
  const script = await readFile(new URL('../public/lang.js', import.meta.url), 'utf8');
  let click;
  const link = { href: 'https://yorozu.yumi.to/de/pair/', dataset: { locale: 'de' }, addEventListener: (_, listener) => { click = listener; } };
  const document = { cookie: '', querySelectorAll: selector => selector === 'a[data-locale]' ? [link] : [] };
  vm.runInNewContext(script, { document, location: { search: '?v=1', hash: '#yorozu-pair-code' } });
  click();
  assert.equal(link.href, 'https://yorozu.yumi.to/de/pair/?v=1#yorozu-pair-code');
  assert.match(document.cookie, /^yorozu_lang=de; Path=\/; Max-Age=31536000; SameSite=Lax; Secure$/);
  assert.equal(cookieLocale(document.cookie.split(';')[0]), 'de');
});

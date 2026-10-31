import { cookieLocale, detectLocale, localePath, pages } from './src/i18n/locales.mjs';

const repository = 'izyuumi/yorozu';
const downloads = `https://github.com/${repository}/releases/download/`;

// _headers does not reach responses the worker makes, so the pages it answers carry the same headers.
// tests/i18n.test.mjs checks that these match the /* block of public/_headers.
export const securityHeaders = {
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Content-Security-Policy': "default-src 'self'; img-src 'self'; style-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
  'Strict-Transport-Security': 'max-age=31536000; includeSubDomains; preload',
  'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
};

// Search engines and link previews get the page they asked for, never a language redirect.
const crawler = /bot|crawl|spider|slurp|facebookexternalhit|embedly|preview|whatsapp|telegram|discord|slack|lighthouse/i;

async function latestRelease(beta) {
  const response = await fetch(`https://api.github.com/repos/${repository}/releases${beta ? '?per_page=1' : '/latest'}`, {
    headers: { 'User-Agent': 'Yorozu-Updates', Accept: 'application/vnd.github+json' },
    cf: { cacheEverything: true, cacheTtlByStatus: { '200-299': 300, '400-599': 0 } },
  });
  if (!response.ok) throw new Error('GitHub unavailable');
  const json = await response.json();
  return beta ? json[0] : json;
}

async function latestAsset(beta, names) {
  const release = await latestRelease(beta);
  const base = `${downloads}${release?.tag_name}/`;
  for (const name of names) {
    if (release?.assets?.some(asset => asset.name === name && asset.state === 'uploaded'
      && asset.browser_download_url === `${base}${name}`)) return `${base}${name}`;
  }
  throw new Error('Release asset unavailable');
}

/** The English page a path without a language prefix names ('/pair' and '/pair/' are '/pair/'), or null. */
function englishPage(path) {
  const page = path.endsWith('/') ? path : `${path}/`;
  return pages.includes(page) ? page : null;
}

/** Whether the visitor followed a link on this site, such as "English version" on a translated policy. */
function fromThisSite(request) {
  const site = request.headers.get('Sec-Fetch-Site');
  if (site) return site === 'same-origin';
  try {
    return new URL(request.headers.get('Referer') ?? '').origin === new URL(request.url).origin;
  } catch {
    return false;
  }
}

/**
 * The language for a visit: the switcher's cookie first, then Accept-Language on arrival from elsewhere.
 * Crawlers and links followed within the site get the English page they asked for.
 */
export function chooseLocale(request) {
  const saved = cookieLocale(request.headers.get('Cookie'));
  if (saved) return saved;
  if (crawler.test(request.headers.get('User-Agent') ?? '') || fromThisSite(request)) return 'en';
  return detectLocale(request.headers.get('Accept-Language'));
}

const vary = 'Accept-Language, Cookie, Sec-Fetch-Site';

async function page(request, env, english) {
  const locale = ['GET', 'HEAD'].includes(request.method) ? chooseLocale(request) : 'en';
  if (locale !== 'en') {
    // The query string is kept here; browsers keep the #fragment (the pairing code) across a redirect themselves.
    const location = localePath(locale, english) + new URL(request.url).search;
    return new Response(null, { status: 302, headers: {
      ...securityHeaders, Location: location, Vary: vary, 'Cache-Control': 'private, no-cache',
    } });
  }
  const asset = await env.ASSETS.fetch(request);
  const response = new Response(asset.body, asset);
  for (const [name, value] of Object.entries(securityHeaders)) response.headers.set(name, value);
  response.headers.append('Vary', vary);
  return response;
}

export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    const english = englishPage(path);
    if (english) return page(request, env, english);
    if (!['/mac', '/beta', '/beta/', '/beta/appcast.xml'].includes(path)) return env.ASSETS.fetch(request);
    if (!['GET', 'HEAD'].includes(request.method)) {
      return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
    }
    try {
      const location = await latestAsset(path !== '/mac',
        path.endsWith('appcast.xml') ? ['appcast.xml'] : ['Yorozu.dmg', 'yorozu.dmg']);
      return new Response(null, { status: 302, headers: { Location: location, 'Cache-Control': 'public, max-age=60' } });
    } catch {
      return new Response(request.method === 'HEAD' ? null : 'Downloads temporarily unavailable. Please try again later.', {
        status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'Cache-Control': 'no-store', 'Retry-After': '300' },
      });
    }
  },
};

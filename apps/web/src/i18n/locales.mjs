// The website's languages: the app's own nine (apps/ios/Resources/Localizable.xcstrings).
// Plain JavaScript, so the worker, the Astro pages and the tests share one list.

/** code: BCP 47 tag for lang and hreflang; path: URL prefix ('' is English at /); label: the language's own name. */
export const locales = [
  { code: 'en', path: '', label: 'English' },
  { code: 'ja', path: 'ja', label: '日本語' },
  { code: 'zh-Hans', path: 'zh-hans', label: '简体中文' },
  { code: 'zh-Hant', path: 'zh-hant', label: '繁體中文' },
  { code: 'ko', path: 'ko', label: '한국어' },
  { code: 'es', path: 'es', label: 'Español' },
  { code: 'fr', path: 'fr', label: 'Français' },
  { code: 'de', path: 'de', label: 'Deutsch' },
  { code: 'pt-BR', path: 'pt-br', label: 'Português (Brasil)' },
];

export const defaultLocale = 'en';

/** The pages every language has, as English paths. */
export const pages = ['/', '/pair/', '/add/', '/support/', '/privacy/', '/terms/'];

/** The cookie the language switcher sets. It holds only a locale code. */
export const cookieName = 'yorozu_lang';

export const byCode = Object.fromEntries(locales.map(locale => [locale.code, locale]));

/** The URL of an English page path in a language: localePath('ja', '/pair/') is '/ja/pair/'. */
export function localePath(code, page) {
  const { path } = byCode[code];
  return path ? `/${path}${page}` : page;
}

/** One language tag, such as zh-TW or pt, to one of our locale codes, or null. */
export function matchTag(tag) {
  const parts = tag.trim().toLowerCase().split(/[-_]/);
  const [language] = parts;
  if (language === 'zh') {
    if (parts.includes('hant') || parts.some(part => ['tw', 'hk', 'mo'].includes(part))) return 'zh-Hant';
    return 'zh-Hans';
  }
  if (language === 'pt') return 'pt-BR';
  return ['en', 'ja', 'ko', 'es', 'fr', 'de'].includes(language) ? language : null;
}

/** The best locale for an Accept-Language header, by q value then order; English if nothing matches. */
export function detectLocale(header) {
  const ranges = String(header ?? '').split(',').map((range, index) => {
    const [tag, ...params] = range.split(';');
    const q = params.map(param => param.trim().match(/^q=([0-9.]+)$/i)).find(Boolean);
    return { tag: tag.trim(), q: q ? Number(q[1]) : 1, index };
  }).filter(range => range.tag && range.tag !== '*' && range.q > 0)
    .sort((a, b) => b.q - a.q || a.index - b.index);
  for (const { tag } of ranges) {
    const code = matchTag(tag);
    if (code) return code;
  }
  return defaultLocale;
}

/** The locale saved by the language switcher, or null when there is none or it is not one of ours. */
export function cookieLocale(header) {
  for (const pair of String(header ?? '').split(';')) {
    const [name, ...value] = pair.trim().split('=');
    if (name === cookieName) {
      const code = value.join('=');
      return Object.hasOwn(byCode, code) ? code : null;
    }
  }
  return null;
}

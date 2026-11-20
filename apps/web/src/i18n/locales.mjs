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

export const pages = ['/', '/pair/', '/add/', '/support/', '/privacy/', '/terms/'];

export const cookieName = 'yorozu_lang';

export const byCode = Object.fromEntries(locales.map(locale => [locale.code, locale]));

export function localePath(code, page) {
  const { path } = byCode[code];
  return path ? `/${path}${page}` : page;
}

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

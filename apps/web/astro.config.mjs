import { defineConfig } from 'astro/config';
import { locales } from './src/i18n/locales.mjs';

export default defineConfig({
  site: 'https://yorozu.yumi.to',
  trailingSlash: 'always',
  build: { inlineStylesheets: 'never' },
  // English stays at /; the others are under /ja/, /zh-hans/ and so on. The worker picks one for visitors.
  i18n: {
    locales: locales.map(({ code, path }) => (path && path !== code ? { path, codes: [code] } : code)),
    defaultLocale: 'en',
    routing: { prefixDefaultLocale: false, redirectToDefaultLocale: false },
  },
});

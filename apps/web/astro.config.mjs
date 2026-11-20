import { defineConfig } from 'astro/config';
import react from '@astrojs/react';
import { locales } from './src/i18n/locales.mjs';

export default defineConfig({
  site: 'https://yorozu.yumi.to',
  trailingSlash: 'always',
  integrations: [react()],
  build: { inlineStylesheets: 'never' },
  i18n: {
    locales: locales.map(({ code, path }) => (path && path !== code ? { path, codes: [code] } : code)),
    defaultLocale: 'en',
    routing: { prefixDefaultLocale: false, redirectToDefaultLocale: false },
  },
});

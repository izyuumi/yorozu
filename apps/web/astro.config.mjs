import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://yorozu.yumi.to',
  trailingSlash: 'always',
  // The CSP in public/_headers allows only same-origin stylesheets.
  build: { inlineStylesheets: 'never' },
  // Unprefixed English keeps today's URLs; add a locale here and it gets its own /<locale>/ pages.
  i18n: { locales: ['en'], defaultLocale: 'en', routing: { prefixDefaultLocale: false } },
});

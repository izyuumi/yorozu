import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://yorozu.yumi.to',
  trailingSlash: 'always',
  build: { inlineStylesheets: 'never' },
  i18n: { locales: ['en'], defaultLocale: 'en', routing: { prefixDefaultLocale: false } },
});

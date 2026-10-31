import { locales } from '../i18n/locales.mjs';

/** getStaticPaths for src/pages/[locale]/: every language except English, which lives at /. */
export function localeRoutes() {
  return locales.filter(({ path }) => path).map(({ code, path }) => ({ params: { locale: path }, props: { locale: code } }));
}

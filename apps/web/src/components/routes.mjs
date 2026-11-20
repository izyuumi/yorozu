import { locales } from '../i18n/locales.mjs';

export function localeRoutes() {
  return locales.filter(({ path }) => path).map(({ code, path }) => ({ params: { locale: path }, props: { locale: code } }));
}

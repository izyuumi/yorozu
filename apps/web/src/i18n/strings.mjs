import { localePath } from './locales.mjs';
import en from './en.mjs';
import ja from './ja.mjs';
import zhHans from './zh-hans.mjs';
import zhHant from './zh-hant.mjs';
import ko from './ko.mjs';
import es from './es.mjs';
import fr from './fr.mjs';
import de from './de.mjs';
import ptBR from './pt-br.mjs';

export const strings = { en, ja, 'zh-Hans': zhHans, 'zh-Hant': zhHant, ko, es, fr, de, 'pt-BR': ptBR };

/** Point href="@/page/" links in translated HTML at that page in the same language. */
export function localize(html, code) {
  return html.replace(/href="@(\/[^"]*)"/g, (_, page) => `href="${localePath(code, page)}"`);
}

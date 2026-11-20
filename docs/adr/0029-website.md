# 0029. Website: worker, languages, pairing links and hero demo

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

The website (`apps/web`, Astro behind a Cloudflare Worker) serves the app's nine languages, is the landing page for pairing QR codes when the app is not installed, and hosts the help MCP server.

## Decision

- Security headers: `_headers` does not reach responses the worker makes, so the worker's pages carry the same headers. `tests/i18n.test.mjs` checks that they match the `/*` block of `public/_headers`.
- Languages:
  - The site's languages are the app's own nine (`apps/ios/Resources/Localizable.xcstrings`), in plain JavaScript so the worker, the Astro pages and the tests share one list.
  - English stays at `/`; the others are under `/ja/`, `/zh-hans/` and so on.
  - Pages without a language prefix run the worker first, which picks the visitor's language: the switcher's cookie first, then Accept-Language on arrival from elsewhere. Crawlers and link previews get the page they asked for, never a language redirect, and so do links followed within the site.
  - The switcher's cookie holds only a locale code. The switcher remembers the visitor's choice so the worker never overrides it.
- Pairing links: the pages a pairing or add-a-Mac QR code opens when Yorozu is not installed carry the code in the `#fragment`. The worker's redirect keeps the query string, and browsers keep the fragment across a redirect themselves. The language switcher keeps the query and fragment when the same page opens in another language.
- Translations:
  - English is the source text. `@/page/` links point at that page in the reader's language.
  - Each translation follows the app's `Localizable.xcstrings` and its App Store text. Register: French "vous", German "du" (as the app), Spanish "tú", Brazilian Portuguese "você", Traditional Chinese with Taiwan usage.
  - Italic and tight tracking suit Latin type, not Chinese, Japanese or Korean, so `:lang()` rules turn them off there.
  - Legal pages: support, privacy and terms are text pages. Translations of the privacy policy and terms say the English version governs. The i18n test checks, per language: the age rule (17, the App Store rating) in privacy and terms, the controller statement, the relay's 30-day room deletion, that pairing survives it (no 180-day device expiry any more), and the old "continuing to use means you accept" sentence, which the terms replaced with 30 days' notice.
  - The "Set up with your AI agent" prompt stays in English, which agents follow most reliably and which the help server answers in; a translated page adds one line asking the agent to reply in the page's language.
- Hero demo:
  - React compiles the hero's phone demo (`src/hero`), a client-only module script; no islands.
  - `mount.tsx` draws it into `#hero-demo` with the page's own strings. It is bundled to external files so the CSP (`script-src` and `style-src 'self'`) holds.
  - Its stylesheet (`hero.css`, every style in the kit's import order) is linked from `mount.tsx`, so only the home page loads it: CSS imported from the components would be added to every page.
  - `yorozu-hero.css` imitates the iOS chat (`Chat.swift`, `Palette.swift`, `Metrics.swift`): Vermilion bubbles at 16 pt corners, agent cards on `secondarySystemBackground` at 14 pt, a glass composer. Light and dark follow the page.
  - The demo's box is held at the stage's size before the script draws it, so nothing shifts; it sits beside the copy on wide screens and under it on narrow ones.
  - Site colours are the app's: system backgrounds, the Vermilion accent (`AccentColor.colorset`, `Accent.vermilion`) and the app icon's paper and slate (`AppIcon.icon`).

## Consequences

- Pairing codes never reach the server: the fragment stays in the browser.

## Where in the code

- `apps/web/worker.mjs` — `securityHeaders`, `crawler`, `chooseLocale`, `page()`
- `apps/web/src/i18n/locales.mjs` — `locales`, `cookieName`
- `apps/web/src/i18n/*.mjs` — translations
- `apps/web/astro.config.mjs` — `i18n`, `integrations`
- `apps/web/wrangler.jsonc` — `assets.run_worker_first`
- `apps/web/src/components/Code.astro`, `apps/web/src/components/Legal.astro`
- `apps/web/public/lang.js`, `apps/web/public/styles.css`
- `apps/web/src/agent-prompt.mjs`
- `apps/web/src/hero/mount.tsx`, `hero.css`, `yorozu-hero.css`
- `apps/web/tests/i18n.test.mjs` — `legal`

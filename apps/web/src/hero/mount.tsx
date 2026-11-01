// Draws the hero's phone demo into #hero-demo, with the page's own strings.
// A module script from Home.astro, bundled to external files so the CSP
// (script-src and style-src 'self') holds. Its stylesheet is linked from here,
// so only the home page loads it (see hero.css).
import { createRoot } from 'react-dom/client'
import css from './hero.css?url'
import YorozuHero, { type HeroStrings } from './YorozuHero'

const el = document.getElementById('hero-demo')
if (el?.dataset.strings) {
  const strings = JSON.parse(el.dataset.strings) as HeroStrings
  const link = Object.assign(document.createElement('link'), { rel: 'stylesheet', href: css })
  link.addEventListener('load', () => createRoot(el).render(<YorozuHero strings={strings} />), { once: true })
  document.head.append(link)
}

// Draws the hero's phone demo into #hero-demo, with the page's own strings.
// A module script from Home.astro: bundled to an external file, so the CSP
// (script-src and style-src 'self') holds.
import { createRoot } from 'react-dom/client'
import YorozuHero, { type HeroStrings } from './YorozuHero'

const el = document.getElementById('hero-demo')
if (el?.dataset.strings) createRoot(el).render(<YorozuHero strings={JSON.parse(el.dataset.strings) as HeroStrings} />)

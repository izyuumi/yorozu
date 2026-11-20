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

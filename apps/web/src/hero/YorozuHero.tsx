import { useEffect, useState } from 'react'
import { ArrowUp, ChevronLeft, LoaderCircle, SquarePen, Wrench } from 'lucide-react'
import { Stage, type Act } from './kit/stage'
import { Phone } from './kit/phone'
import { Thread, Bubble } from './kit/messages'
import { Collapse } from './kit/motion/Collapse'
import './yorozu-hero.css'

// A Yorozu conversation on iPhone, as the app draws it: vermilion bubbles for
// you, gray cards for the agent, a glass composer. Beats: a question is typed
// and sent; the read mark lands; the agent runs two tools on the computer; the
// typing capsule grows into its answer. Plays once in view; the poster is the
// answered thread.

export type HeroStrings = {
  label: string
  title: string
  earlier: [string, string][]
  ask: string
  tools: string
  answer: string
  placeholder: string
}


type S = { draft: string; sent: boolean; read: boolean; tools: 'off' | 'running' | 'done'; typing: boolean; answer: boolean }
const initial: S = { draft: '', sent: false, read: false, tools: 'off', typing: false, answer: false }
const poster: S = { draft: '', sent: true, read: true, tools: 'done', typing: false, answer: true }

function script(t: HeroStrings) {
  return async (a: Act<S>) => {
    await a.wait(900)
    await a.type('draft', t.ask, { interval: 45 })
    await a.wait(350)
    await a.set({ sent: true, draft: '' })
    await a.wait(700)
    await a.set({ read: true })
    await a.wait(500)
    await a.set({ tools: 'running' })
    await a.wait(1500)
    await a.set({ tools: 'done', typing: true })
    await a.wait(1300)
    await a.set({ typing: false, answer: true })
    await a.wait(2000)
  }
}

function usePrefersDark() {
  const query = '(prefers-color-scheme: dark)'
  const [dark, setDark] = useState(() => typeof matchMedia !== 'undefined' && matchMedia(query).matches)
  useEffect(() => {
    const m = matchMedia(query)
    const on = () => setDark(m.matches)
    m.addEventListener('change', on)
    return () => m.removeEventListener('change', on)
  }, [])
  return dark
}

// Two overlapping filled checks: read on the computer
function ReadMark({ show }: { show: boolean }) {
  const check = 'M8 1.25a6.75 6.75 0 1 1 0 13.5 6.75 6.75 0 0 1 0-13.5Zm3 4.3-.95-.8-3.3 3.95-1.85-1.8-.85.9 2.8 2.75Z'
  return (
    <span className="yz-mark" data-show={show || undefined} aria-hidden>
      <svg viewBox="0 0 16 16"><path d={check} fill="currentColor" fillRule="evenodd" /></svg>
      <svg viewBox="0 0 16 16"><path d={check} fill="currentColor" fillRule="evenodd" /></svg>
    </span>
  )
}

export default function YorozuHero({ strings }: { strings: HeroStrings }) {
  const t = strings
  const dark = usePrefersDark()
  return (
    <div className="yz" role="img" aria-label={t.label}>
      <Stage
        width={440}
        height={700}
        compact={{ below: 440, width: 358, height: 679 }}
        initial={initial}
        poster={poster}
        script={script(t)}
        play="once"
        theme={dark ? 'dark' : 'light'}
        fidelity="realistic"
      >
        {(s, _rect, layout) => (
          <Phone width={layout === 'compact' ? 300 : 310} dark={dark} className="yz-phone">
            <div className="yz-screen">
              <div className="yz-nav">
                <span className="yz-circle"><ChevronLeft size={22} strokeWidth={2.25} /></span>
                <span className="yz-title">{t.title}</span>
                <span className="yz-circle yz-circle--accent"><SquarePen size={19} strokeWidth={2.1} /></span>
              </div>
              <Thread app="chat" className="yz-thread">
                {t.earlier.flatMap(([q, r], i) => [
                  <Bubble key={`q${i}`} from="me" className="yz-me">{q}<ReadMark show /></Bubble>,
                  <Bubble key={`r${i}`} from="them">{r}</Bubble>,
                ])}
                {s.sent && <Bubble from="me" source="draft" className="yz-me">{t.ask}<ReadMark show={s.read} /></Bubble>}
                {s.tools !== 'off' && (
                  <div className="yz-tools-row">
                    <Collapse open reveal="drop" from="below">
                      <span className="yz-tools" data-running={s.tools === 'running' || undefined}>
                        <span className="yz-tools__icon">
                          <LoaderCircle className="yz-spin" size={16} strokeWidth={2} />
                          <Wrench className="yz-wrench" size={16} strokeWidth={2} />
                        </span>
                        {t.tools}
                      </span>
                    </Collapse>
                  </div>
                )}
                {(s.typing || s.answer) && <Bubble from="them" typing={s.typing}>{t.answer}</Bubble>}
              </Thread>
              <div className="yz-compose">
                <span className="yz-field">
                  <span className="yz-field__text" data-target="draft">
                    {s.draft}
                    {s.draft && <i className="yz-caret" />}
                  </span>
                  <span className="yz-field__ph" data-hide={s.draft ? '' : undefined}>{t.placeholder}</span>
                  <span className="yz-send" data-on={s.draft ? '' : undefined}><ArrowUp size={18} strokeWidth={2.6} /></span>
                </span>
              </div>
            </div>
          </Phone>
        )}
      </Stage>
    </div>
  )
}

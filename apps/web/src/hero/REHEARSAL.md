# Hero phone demo: rehearsal

The home page hero's phone (`YorozuHero.tsx`), built with the stageshow kit
(`kit/`, a subset of the MIT-licensed kit; see `kit/LICENSE`).

- **Placement:** the landing hero, beside the copy on wide screens (440x700
  stage) and under it on phones (358x679 compact stage).
- **Focal object:** a Yorozu chat on iPhone, drawn the way the app draws it
  (Chat.swift): vermilion bubbles, gray agent cards, read marks, the
  "N tool calls" row and the glass composer.
- **Action:** a question is typed and sent from the composer; the read mark
  lands; the tool row spins, then settles; the typing capsule grows into the
  answer.
- **Payoff / poster:** the answered thread. It plays once when scrolled into
  view; with reduced motion it shows the poster and never animates.
- **Strings:** `home.demo` in every `src/i18n/*.mjs`, passed in through
  `data-strings`. Demo content only, no personal data.

## Film (stageshow `film.mjs --gate`)

- 1280 wide: rehearsal passed. Remaining lines are expected: the caret moving
  as it types, and the composer text changing while typed.
- 390 wide: one `fat row` line, a false positive. The detector treats a wrapped
  paragraph in a single span as one line, so a three-line agent card reads as
  "75px tall for one 17px line".

## Local change to the kit

The kit components here don't import their own CSS. `hero.css` collects those
styles, and `mount.tsx` links it at runtime. Astro adds CSS imported from a page
script to every page of the site, and this keeps it to the home page.

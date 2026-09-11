# Tickets: Yorozu v1

Out-of-box personal AI assistant for macOS, remote-controlled from iOS through a blind E2E relay. Source spec: `docs/spec-v1.html` (grill session 2026-09-12).

Work the **frontier**: any ticket whose blockers are all done. Tracer-bullet order: one message from phone to model and back first, then widen.

## Monorepo scaffold

**What to build:** A repo where every workspace builds and CI passes with placeholder targets, so every later ticket lands into a green tree.

**Blocked by:** None — can start immediately

- [ ] Workspaces exist for mac app, ios app, relay, runtime, shared
- [ ] CI builds Swift and TypeScript targets on push
- [ ] MIT license, README with one-paragraph pitch and spec link

## Runtime loop + OpenAI-compatible adapter

**What to build:** A CLI harness where a typed message goes through the runtime's own agent loop to an OpenAI-compatible endpoint, the model can call one dummy tool, and the reply streams back.

**Blocked by:** Monorepo scaffold

- [ ] Loop owns messages, tool dispatch, streaming; adapter exposes only `stream` and `auth`
- [ ] Dummy tool round-trips through the loop
- [ ] Base URL and key configurable; `/models` listed

## Blind relay

**What to build:** A single-binary websocket relay two CLI clients can pair through and exchange opaque bytes, with the relay unable to read anything.

**Blocked by:** Monorepo scaffold

- [ ] Room ID derived from Mac public key; registration requires signed challenge
- [ ] Join requires one-time token; unsigned frames dropped
- [ ] Ciphertext buffered per room for 24h with size cap; drained on reconnect
- [ ] Per-room rate limit
- [ ] Dockerfile; runs with one command

## Shared protocol + crypto

**What to build:** Swift and TypeScript implementations of the same event schema and key exchange that can encrypt on one side and decrypt on the other.

**Blocked by:** Monorepo scaffold

- [ ] Event types: message, thought, tool call, tool result, approval card, approval answer, thread create/list/archive, sync request/delta
- [ ] Key exchange and symmetric encryption interoperate across Swift and TS in a cross-language test
- [ ] QR payload format: Mac public key + join token + relay URL

## Mac app shell + QR + relay client

**What to build:** A menu bar app that spawns the bundled runtime, connects to the relay, and shows a pairing QR.

**Blocked by:** Runtime loop + OpenAI-compatible adapter, Blind relay, Shared protocol + crypto

- [ ] Menu bar icon with status
- [ ] Runtime sidecar starts and stops with the app
- [ ] QR displayed; relay connection state visible

## iOS app: pair + one thread chat

**What to build:** Scan the QR, type a message, see the model's reply. First end-to-end demo.

**Blocked by:** Shared protocol + crypto, Mac app shell + QR + relay client

- [ ] QR scan pairs and persists keys
- [ ] Single thread chat view, streaming reply
- [ ] "Mac offline" state shown when relay buffers

## Claude + Codex adapters + provider cards

**What to build:** Onboarding shows three provider cards; Claude and Codex go green by detecting installed CLIs or running their login in an embedded terminal; failures fall through the configured chain.

**Blocked by:** Runtime loop + OpenAI-compatible adapter, Mac app shell + QR + relay client

- [ ] Detects `claude` and `codex` on PATH and logged-in state
- [ ] Embedded login flow for each
- [ ] Primary model + fallback chain in settings; auth or rate-limit failure advances chain
- [ ] Any one green card unlocks the app

## TCC onboarding wizard + never-sleep

**What to build:** A step-by-step wizard that walks Accessibility, Screen Recording, Full Disk Access, Automation, and Input Monitoring, verifying each grant before moving on, then offers never-sleep.

**Blocked by:** Mac app shell + QR + relay client

- [ ] Each step verifies the actual grant, retries on denial
- [ ] Never-sleep applied with consent, reversible in settings
- [ ] Wizard re-runnable from settings

## Native tools: shell, fs, AX screen, screenshot, input

**What to build:** The agent can run a command, read and write files, read the frontmost window as an accessibility tree, fall back to a screenshot, and click or type on an element.

**Blocked by:** TCC onboarding wizard + never-sleep

- [ ] `screen.read` returns element tree with stable IDs and bounds
- [ ] `screen.capture` used automatically when tree is empty
- [ ] `input` acts on element ID or coordinates
- [ ] Demo: agent opens System Settings and reads a value

## Browser tool + picker

**What to build:** The agent drives a browser over CDP in its own profile; settings let the user choose bundled Chromium or an installed Chromium-family browser.

**Blocked by:** TCC onboarding wizard + never-sleep

- [ ] Bundled Chromium downloads on first use
- [ ] Installed browsers detected; launched with separate profile dir
- [ ] Agent never touches user tabs; closes what it opens
- [ ] Safari or Firefox choice routes to AX tool

## Calendar, reminders, mail, fetch, search

**What to build:** Agent can read and write calendar and reminders, read and send mail, fetch a URL as readable text, and search the web.

**Blocked by:** Native tools: shell, fs, AX screen, screenshot, input, Browser tool + picker

- [ ] EventKit for calendar and reminders
- [ ] Mail via AppleScript
- [ ] Fetch with readability extraction
- [ ] Provider-native search when available, Chromium search fallback otherwise

## Agents as markdown + delegate + skills

**What to build:** Main agent delegates to specialists defined as markdown files; specialists inherit everything unless restricted; AgentSkills load by name.

**Blocked by:** Claude + Codex adapters + provider cards

- [ ] Agent frontmatter: optional `model`, `tools`, `memory`; absent means inherit
- [ ] `delegate(agent, task, background?)`; depth 2 enforced
- [ ] Background completion arrives as event in same thread
- [ ] User interrupt cancels main and all children
- [ ] Existing SKILL.md directories load unchanged

## Subagent events + phone drill-down

**What to build:** When a specialist runs, the thread shows an inline card; tapping opens a live trace of that specialist's thoughts, tool calls, and output.

**Blocked by:** iOS app: pair + one thread chat, Agents as markdown + delegate + skills

- [ ] Every event tagged with agent ID and parent ID
- [ ] Inline card with running/done state
- [ ] Drill-down page streams live

## Threads: list, create, Home, archive, delta sync

**What to build:** Phone shows a thread list with a pinned Home, creates threads with +, archives, and reads history offline from an encrypted local cache synced by delta.

**Blocked by:** iOS app: pair + one thread chat

- [ ] Home thread pinned and never archives
- [ ] Per-thread last-seen event ID drives delta sync
- [ ] Cache encrypted at rest
- [ ] Multiple devices see same threads

## Memory: markdown + SQLite index + remember tool

**What to build:** Agent stores durable facts as markdown with provenance; a SQLite full-text and vector index is rebuilt from the files and used for recall.

**Blocked by:** Runtime loop + OpenAI-compatible adapter

- [ ] `remember(fact, kind)` writes a markdown file with date and thread
- [ ] Index rebuildable from files alone
- [ ] Local embeddings default; provider embeddings when key present
- [ ] Recall injected into main agent context

## Scheduler tool + nightly consolidation

**What to build:** Agent can schedule one-shot or cron-style instructions that fire as new turns; a nightly job consolidates the day's transcripts into memory.

**Blocked by:** Memory: markdown + SQLite index + remember tool

- [ ] `schedule(when, instruction)` with cron syntax and one-shot
- [ ] Fires as a turn in the originating thread
- [ ] Nightly consolidation dedupes and promotes with provenance
- [ ] No heartbeat polling anywhere

## Approval engine + card

**What to build:** Every external action carries a class; code checks the floor and the decision log before the agent may ask; the phone shows Yes / No / Never / Discuss; Never is permanent.

**Blocked by:** iOS app: pair + one thread chat, Memory: markdown + SQLite index + remember tool

- [ ] Onboarding sets money threshold and irreversible-delete rule
- [ ] Decision log append-only; consistent precedent acts without asking
- [ ] Never writes a class-level rule (target-level only when user names a target); never re-asks
- [ ] Discuss keeps action pending, agent explains, card re-presented
- [ ] Typed yes/no also accepted

## Model catalog + auto-assign

**What to build:** Client fetches a model catalog from GitHub Releases daily; a button or cron lets the default model assign a model to each agent file, shown as a revertible diff; research mode lets the model search current pricing into a local overlay.

**Blocked by:** Agents as markdown + delegate + skills, Scheduler tool + nightly consolidation

- [ ] Catalog cached daily; bundled fallback offline
- [ ] Auto-assign writes `model:` frontmatter, diff shown, revert works
- [ ] Runs on demand or on user-chosen cron
- [ ] Research mode writes overlay, never overwrites catalog

## Mac local chat UI

**What to build:** The same thread list and chat views as iOS, running locally in the Mac app with no relay hop.

**Blocked by:** Threads: list, create, Home, archive, delta sync

- [ ] Shared SwiftUI views compile for both platforms
- [ ] Local transport bypasses relay
- [ ] Subagent drill-down and approval cards work on Mac

## Distribution: sign, notarize, Sparkle, TestFlight

**What to build:** A stranger downloads the DMG, opens it, completes onboarding, installs the iOS app from a TestFlight link, and is chatting in ten minutes.

**Blocked by:** TCC onboarding wizard + never-sleep, Mac local chat UI

- [ ] Developer ID signed and notarized DMG on GitHub Releases
- [ ] Sparkle update feed
- [ ] Runtime and Chromium download on first run, not in DMG
- [ ] Public TestFlight link in README
- [ ] Fresh-Mac walkthrough timed under ten minutes

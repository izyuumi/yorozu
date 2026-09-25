# Start.md — agent guide for setting up Yorozu

You are an AI agent helping a person set up **Yorozu** on their devices. Read this whole file
before you say anything to them. It tells you what Yorozu is, what can be configured, what to
ask, and what to never do.

Yorozu is a menu bar app for macOS plus an iPhone app. The Mac runs the agents (OpenClaw, and
optionally Claude Code and Codex); the phone remote-controls it through a blind, end-to-end
encrypted relay. Site: <https://yorozu.yumi.to>. Source: <https://github.com/izyuumi/yorozu>.

## How to run this guide

1. **Learn their situation first** (section 1). Run the probe commands where you can; ask
   only what you cannot find out yourself.
2. **Choose a path** (section 2): host Mac, client Mac, or iPhone. One device at a time.
3. **Walk the path** (sections 3–5). Every configurable item has a question attached — ask
   it, explain the trade-off in one or two sentences, act on the answer. Do not pick for them.
4. **Verify** (section 6) and hand off with a summary of what was configured.

Rules that apply throughout:

- Keep their answers as context for every later step. "Wants email help" decides Contacts,
  Mail automation and Full Disk Access later; do not re-ask.
- Everything on the permissions page is optional. Recommend from what they said they want to
  do; never push a grant they have no use for.
- You may open panes and run probe commands, but **the person clicks Allow**. macOS grants
  cannot be scripted and you must not try (`tccutil`, editing `TCC.db`, etc.).
- Never read, print, or ask for provider credentials, API keys, the OpenClaw device token, or
  the contents of `~/Library/Application Support/Yorozu`. You do not need them.
- Pairing codes are secrets while they are valid. Don't echo them into logs or summaries.
- Speak plainly. If they are not technical, skip the terminal. The iPhone source-build route
  is for developers; without an internal testing invitation, offer Mac-only setup for now.

## 1. Learn their situation

### 1a. Probe what you can

Run on the Mac you are helping with (skip if you have no shell):

```sh
sw_vers -productVersion                       # needs macOS 15+
uname -m                                       # arm64 = Apple silicon (required)
ls /Applications/Yorozu.app 2>/dev/null        # installed?
defaults read to.yumi.yorozu onboardingCompleted 2>/dev/null   # 1 = wizard already finished
command -v openclaw claude codex node          # which agents/tools are on PATH
openclaw --version 2>/dev/null
claude auth status --json 2>/dev/null          # {"loggedIn":true} is what Yorozu checks
codex login status 2>&1                        # prints "logged in" / "not logged in"
ls ~/Projects 2>/dev/null                      # folders coding agents can start in
```

Yorozu's own state lives in `~/Library/Application Support/Yorozu` (keys, threads, devices,
settings). Its existence tells you the sidecar has run before. Do not open the files.

### 1b. Ask what you cannot probe

Ask these in one short message, adapted to what you already know. Skip anything answered.

| Ask | Why it matters |
| --- | --- |
| Which devices? (one Mac; Mac + iPhone; several Macs; a Mac mini/server plus a laptop) | Decides who is **host** vs **client** (section 2). |
| Is this Mac always on and with you, or a machine that stays home? | Decides Start at Login, Keep Running, Never Sleep, and how important the phone path is. |
| What do you want the agent to do? (email, calendar, files, browsing, coding, controlling apps, general chat) | Maps directly to which macOS permissions to grant (section 3d). |
| Do you already use OpenClaw? Claude Code? Codex? Which provider accounts do you have? | OpenClaw is **required** on a host. The other two are optional native agents. |
| Comfortable in a terminal, or GUI only? | Chooses which route you give for each step. |
| Any reason to keep traffic on your own network (Tailscale, corporate policy)? | Decides whether to self-host the relay (section 3e). Default relay is fine for almost everyone. |
| How much do you want to be asked before the agent acts? | Decides YOLO mode (section 3f). Default: off. Strongly prefer off. |

Write down their answers. Refer back to them for every choice below.

## 2. Choose the path

A Mac is one of two things:

- **Host** — runs OpenClaw, the sidecar, and owns the conversation. Everything else pairs
  with it. Exactly one per household/setup. Needs macOS 15+, Apple silicon, and OpenClaw.
- **Client** — a second Mac that pairs with the host exactly like a phone does. Runs no agent.
  Needs only the app and a pairing code.

An **iPhone** (iOS 18+) is always a client of a host. Install it from the public TestFlight
link or build from source (section 5). Mac-only setup remains available.

Decision:

| Their setup | Do |
| --- | --- |
| One Mac only | Host. Section 3, skip 3c. |
| Mac + iPhone | Host (section 3), then iPhone (section 5). |
| Several Macs | The always-on / most capable one is host (section 3). Each other Mac is a client (section 4). |
| Mac mini at home + laptop | Mini = host with Start at Login, Keep Running, Never Sleep all on. Laptop = client. |

Do the host first. Nothing else can pair until it exists.

## 3. Host Mac

### 3a. Install

Download the DMG from <https://yorozu.yumi.to/mac>, drag **Yorozu** to Applications, launch
it. It is a **menu bar app** — tell them to look in the status bar, not the Dock.

Terminal alternative for people who prefer it: none required; the DMG is the install.

If `onboardingCompleted` was already `1` in the probe, the wizard won't reappear. Every step
below is also reachable from the menu bar icon → **Settings**, so continue from there.

### 3b. Role

The wizard's first screen: **Host Yorozu on this Mac** vs **Connect to another Mac**. Choose
**Host**. (Changeable later in Settings → General → "This Mac".)

### 3c. Pair devices (skippable)

The wizard now shows a pairing QR and code. Three ways to deliver it to a phone or client Mac:

1. Scan the QR from the iPhone app.
2. Copy the code and paste it into the other device's "Enter code manually" / "Paste pairing
   code" field.
3. Message the `yorozu://` link to themselves and tap it on the phone.

Ask: **"Do you have the other device with you now?"** If not, click **Skip for now** — it can
be redone any time from Settings → **Devices** → **Pair Another Device…**. **New code**
regenerates if one expires or was exposed.

Codes are single-use secrets. Don't paste one anywhere that persists.

### 3d. Permissions (all optional — ask per group)

The wizard's "Choose what Yorozu can do" page lists every macOS grant. Each row deep-links to
the exact System Settings pane and re-checks itself. Same list is always in Settings →
**Permissions**.

Use what they told you they want to do. Propose a set, explain each in one line, let them
strike any. Then have them click through; you watch the row turn green.

| If they want… | Recommend | Notes |
| --- | --- | --- |
| Chat only, no Mac control | nothing | Valid choice. OpenClaw still works. |
| Calendar / reminders | Calendars, Reminders | Also Automation → Calendar, Reminders if they want the apps driven. |
| Email, "who is X" | Contacts, Automation → Mail | Reading Mail data itself needs **Full Disk Access**. |
| Files on the Mac | Files & Folders | macOS asks once per folder (Desktop, Documents, Downloads, iCloud, each cloud drive). |
| Anything under `~/Library`, Safari/Mail data | Full Disk Access | The only grant with **no prompt API** — the app can only open the pane; they must add Yorozu themselves. |
| See and act on the screen / control apps | Accessibility, then Input Monitoring; Screen Recording as fallback | Screen Recording is used only when a window has no accessibility tree. |
| Drive Finder, Safari, Mail, Messages, Notes, Music… | Automation | One prompt **per app**; apps that weren't open get launched and quit again. Warn them so ten prompts don't surprise them. |
| Photos / music playback | Photos, Music | |
| Location-aware answers (weather, travel time) | Location | |
| Camera / mic on request | Camera, Microphone | Never used without an explicit ask in chat. |

Two rows on the same page are Yorozu settings, not macOS grants:

- **Start at Login** — recommend **on** for any host, mandatory-feeling for a machine that
  stays home. Read back from macOS, so revoking it in System Settings is honoured.
- **Never Sleep** — a `caffeinate` child the app owns; dies with the app. Recommend **on** for
  a home Mac that the phone must reach; **off** for a laptop that travels on battery. Ask.

Click **Finish**. Grants can be added later at any time; the agent can also ask for one
mid-conversation and macOS will prompt then.

### 3e. Settings → General (host)

Open menu bar icon → Settings → **General**. Walk these, asking each:

| Setting | Default | Ask / recommend |
| --- | --- | --- |
| **Relay URL** | `wss://relay.yumi.to` | Keep the default unless they said they want traffic on their own network. The relay is blind either way (it sees ciphertext, lengths, timing — nothing else). Self-host options below. Restart the app to apply a change. |
| **Start at login** | on | Same as 3d. |
| **Keep Yorozu running** | on | A LaunchAgent watchdog that relaunches the app within a minute if it dies. Quitting from the menu is still a real quit. Recommend on for any host. |
| **Never sleep** | off | Same as 3d. |
| **Automatic updates** | on | Sparkle; checks hourly, installs when the app is not frontmost. State survives updates. Recommend on. |
| **YOLO mode** | off | See 3f. |

Self-hosting the relay (only if they asked for it — they need Node 26+ and the repo):

```sh
git clone https://github.com/izyuumi/yorozu && cd yorozu && pnpm install
pnpm --filter @yorozu/relay build
./scripts/install-relay-launchagent.sh     # LaunchAgent to.yumi.yorozu.relay, PORT=8787
# logs: ~/Library/Logs/yorozu-relay.log ; stop: launchctl bootout gui/$(id -u)/to.yumi.yorozu.relay
```

Then set Relay URL to `ws://<tailscale-ip>:8787` on the host **and** on every client/phone
(re-pair after changing it). Docker (`apps/relay/Dockerfile`) and Cloudflare Workers
(`apps/relay/wrangler.toml`) are the other two routes; see `docs/releasing.md` → "Hosting the
relay". Put it behind Tailscale, not a forwarded port.

### 3f. YOLO mode — handle with care

Settings → General → **"YOLO mode — skip all approvals"**. Also on the iPhone under Settings →
Approvals. Same switch, stored by the runtime.

What it does: Claude Code and Codex threads run **every** tool call without asking —
purchases, messages, shell commands, deletes. (`yorozu` threads are governed by OpenClaw's own
permission settings regardless of this toggle.)

Default is off. Only turn it on if they explicitly ask, and confirm once, in plain words,
that they understand the sentence above. Do not recommend it.

### 3g. OpenClaw (required on a host)

Yorozu's default `yorozu` threads are answered by the **OpenClaw Gateway** on loopback
(`ws://127.0.0.1:18789`). Providers, credentials, models, tools, permissions, browser,
scheduling and memory all live in OpenClaw — Yorozu holds none of it.

If the probe found no `openclaw` on PATH:

1. Install and onboard OpenClaw per its own docs (this guide does not own that). Have them
   configure at least one provider there and confirm the Gateway runs.
2. Yorozu must be able to find the binary. If `openclaw` isn't on the app's PATH, set
   `OPENCLAW_BIN` to its full path (advanced; most installs put it on PATH).
3. On first use, the sidecar runs `openclaw qr --setup-code-only` to pair itself with the
   Gateway as an operator client and stores a device token (`0600`) in the state dir. If
   OpenClaw asks to approve a new device named **Yorozu**, that is this — approve it.

Verify: open a new thread on the Mac (default agent), send "hello". A reply proves the whole
chain: app → sidecar → Gateway → provider.

### 3h. Claude Code and Codex (optional native agents)

Threads can also be created with agent **claude-code** or **codex**. Each runs in-process,
one session per thread, inside a folder the user picks under `~/Projects` (override with
`YOROZU_PROJECTS_DIR`). Approvals and questions from those agents arrive as cards in the
chat — and on the phone.

Ask: **"Do you want to use Claude Code or Codex from Yorozu?"** For each yes:

- Claude Code: install the `claude` CLI and log in. Yorozu checks `claude auth status --json`
  → `loggedIn: true`.
- Codex: install the `codex` CLI and log in. Yorozu checks `codex login status`.
- Make sure `~/Projects` exists and holds the folders they'd want to work in. Empty or
  missing → the folder picker offers nothing.

Neither is needed for the default `yorozu` agent.

### 3i. Devices tab

Settings → **Devices** lists every paired phone and client Mac. **Pair Another Device…**
generates a fresh code; a device can be removed here. Show them once so they know where it is.

## 4. Client Mac

Second Mac, no agent of its own. Needs the app and a code from the host.

1. Install the DMG (3a).
2. Wizard → **Connect to another Mac**.
3. On the **host**: Settings → Devices → Pair Another Device… → copy the code.
4. On the client: paste into "Paste pairing code" → **Connect**. "Connected" screen → Open.
5. Settings → General on a client shows only role, connection state, relay URL, YOLO, version,
   updates. If the host uses a custom relay, set the same URL here **before** pairing.

Threads, replies and approval cards all sync from the host. Unpair from the same tab
(wipes local keys and cached chats).

## 5. iPhone

Needs iOS 18+ and the Yorozu iOS app. **The iPhone app is a public TestFlight beta; there is
no App Store release yet.** Establish an installation path before pairing:

- **TestFlight (default):** open <https://yorozu.yumi.to/iphone> on the iPhone, install
  TestFlight if prompted, then install Yorozu.
- **Developer building from source:** follow [Development](README.md#development) for the
  required tools and workspace setup. From the repository root, run
  `tuist generate --no-open --path apps/ios`, then open `apps/ios/Yorozu.xcworkspace` in Xcode.
  Configure their own signing team and provisioning for the app and its extensions, select
  the **YorozuIOS** scheme and their connected iPhone, and run. The README's unsigned
  simulator build does not install the app on a physical phone.
- **Neither path fits:** continue with the Mac app and skip phone pairing for now. Do not
  send them back to the website looking for an iPhone download.

Once the app is installed:

1. Open the app. It shows "Your Mac's agent, in your pocket." with **Scan pairing code**,
   **Enter code manually**, and **Try the demo** (a reviewer demo — not a real connection).
2. On the host Mac: Settings → Devices → Pair Another Device… (or the wizard's pairing step).
3. Scan the QR, or paste the code, or tap the `yorozu://` link the user messaged themselves.
4. iOS will ask for **Notifications**. Recommend **Allow**: approval cards arrive as pushes
   with **Allow** / **Don't allow** buttons on the lock screen, and the relay is blind to their
   content. Without it they must open the app to see approvals.
5. Settings (gear) → **Mac** shows status, relay, paired-since; **Approvals** holds the same
   YOLO toggle (3f applies); **Unpair** wipes keys and cached threads.

If the host uses a custom relay, the phone must reach that URL (Tailscale on the phone, etc.)
— the relay URL rides in the pairing code, so pair *after* the host's relay is set.

## 6. Verify and hand off

Run through with them, on each device:

- [ ] Host: menu bar icon present; a message in a `yorozu` thread gets a reply.
- [ ] Host: Settings → Permissions shows green for every grant they chose; nothing they
      didn't choose is on.
- [ ] Host: Start at Login / Keep Running / Never Sleep match what they decided.
- [ ] If native agents: a `claude-code` or `codex` thread in a project folder answers
      (an "is not on PATH" / "not logged in" reply means the CLI step in 3h is incomplete).
- [ ] Each client Mac / iPhone: appears in host Settings → Devices; a message sent from it
      shows up on the host and gets a reply.
- [ ] iPhone: an approval card (from a native-agent thread) arrives as a push if they allowed
      notifications.
- [ ] YOLO is **off** unless they explicitly chose otherwise.

Finish with a short written summary: role of each device, permissions granted, settings
chosen, and what they skipped (with where to turn it on later). Don't include pairing codes.

## 7. Troubleshooting

| Symptom | Likely cause → fix |
| --- | --- |
| No menu bar icon after launch | It's a status-bar app; check the top-right. Hidden by a menu bar manager? |
| Wizard never appeared | `onboardingCompleted` already set. Use Settings instead — every step is there. |
| `yorozu` thread never replies | OpenClaw Gateway not running / not on PATH / device not approved. Check `openclaw` works standalone first; then `OPENCLAW_BIN`. |
| "claude-code could not answer: claude is not on PATH" / "not logged in" | Install / log in to the CLI (3h). Same for codex. |
| Folder picker empty for coding agent | `~/Projects` missing or has no subfolders (`YOROZU_PROJECTS_DIR` to move it). |
| Pairing code "invalid or expired" | Generate a **New code** on the host; codes are single-use and short-lived. |
| "Couldn't connect" on a client | Relay URL mismatch between host and client, or client can't reach a self-hosted relay. Set URL first, then re-pair. |
| Permission row stays red after Allow | Quit and relaunch Yorozu; some grants (Accessibility, Input Monitoring, Screen Recording) apply on next launch. Full Disk Access needs Yorozu added manually in the pane. |
| Automation launched a bunch of apps | Expected: one probe per app, then they're quit again. |
| Mac sleeps and the phone can't reach it | Never Sleep off, or the app isn't running (Start at Login / Keep Running). |
| Relay changed, phone stopped working | Re-pair; the URL is baked into the pairing. |
| Approval push shows only "Open" | Not quick-approvable (e.g. purchase-class); open the card. By design. |

Dev-build users: a bare `swift run` binary has no bundle ID, so TCC forgets grants on every
rebuild. Use `./scripts/dev-bundle.sh` (bundle `to.yumi.yorozu.beta`) instead. See README.

## Reference: environment variables (advanced, host only)

Set on the sidecar; normal users never touch these.

| Variable | Default |
| --- | --- |
| `YOROZU_STATE_DIR` | `~/Library/Application Support/Yorozu` |
| `YOROZU_RELAY_URL` | `wss://relay.yumi.to` (Settings → General writes this) |
| `OPENCLAW_BIN` | `openclaw` on PATH |
| `YOROZU_PROJECTS_DIR` | `~/Projects` |
| `YOROZU_RUNTIME_CMD` | set by the app; the bundled sidecar |

Deeper reading: `README.md` (install), `docs/architecture.md` (pairing, relay, approvals),
`docs/releasing.md` (self-hosting the relay).

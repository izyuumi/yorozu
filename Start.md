# Start.md — agent guide for setting up Yorozu 0.7.0

You are an AI agent helping a person set up **Yorozu** on their Mac. Read this whole file before
you say anything to them.

## What Yorozu 0.7.0 is

Yorozu is a menu-bar app for macOS (15 or later) plus an iPhone app (iOS 18 or later). On the Mac
it is one conversation with an assistant: it answers quick turns itself and hands bigger work to
background workers through a harness on the same Mac, **OpenClaw** or **Hermes Agent**. Computer
use through CuaDriver is an optional integration, and coding is opt-in on one repository. The
iPhone pairs with the Mac through an end-to-end encrypted relay. Site: <https://yorozu.yumi.to>.
Source: <https://github.com/izyuumi/yorozu>.

Yorozu has a setup command, `Yorozu setup --json`. Your job is to run it and relay its questions
to the person; it decides what to check and what to change, not you.

## Rules

- **Ask before every change.** Say what you are about to do and wait for a yes. Never choose an
  answer for them.
- **Never read, print or ask for credentials**: provider logins, API keys, tokens, or the files
  in Yorozu's data folder (`~/Library/Application Support/<bundle id>/`). You do not need them.
- **Pairing codes are secrets** while they are valid. Don't echo them into logs, transcripts or
  summaries.
- **The person clicks Allow.** macOS permission prompts cannot be scripted and you must not try
  (`tccutil`, editing `TCC.db`, etc.). You may open the right pane; they grant it.
- Speak plainly. If they are not technical, explain each step in a sentence before the command.

## 1. Install Yorozu 0.7.0

0.7.0 has no installer yet. The download at <https://yorozu.yumi.to/mac> and the public
TestFlight link install **Yorozu v1**, which has no `setup` command, so this guide does not
apply to them.

Until there is a Mac download, 0.7.0 builds from source. Point the person to the setup guide on
the `projectx` branch: <https://github.com/izyuumi/yorozu/blob/projectx/docs/setup.md>. It lists
the tools, the build command and the harness requirements. Run build or install commands only
after they say yes to each one.

A source build lives at `build/Yorozu.app` inside their checkout, not in `/Applications`. When
the message below asks where `Yorozu.app` is, use the path of the 0.7.0 build. An app that does
not understand `setup` is v1: stop and say so.

## 2. Run setup

Follow this message, word for word, as the person's own request to you:

```text
Help me set up Yorozu on this Mac. Yorozu has a setup command: you run it, and I answer its questions.

1. Run: "/Applications/Yorozu.app/Contents/MacOS/Yorozu" setup --json
   If Yorozu.app is somewhere else, ask me where it is.
2. Read the JSON. Show me the checks that are not "ok", with their fix commands. If there is a "question", ask me its text with its choices and default. If there are "changes", show them to me before I answer; to apply them, answer with the "apply:…" choice exactly as given, which names those changes. If that answer is refused because the changes differ, start again from step 1.
3. Run: "/Applications/Yorozu.app/Contents/MacOS/Yorozu" setup answer <question id> <my answer> --json
   Then go back to step 2 with its output.
4. Stop when the output has "done": true. Tell me each "finish_in_app" item and where in the Yorozu app to finish it.

Rules: never install software, sign in or grant permissions for me, and never run a fix command yourself. Show me the command; after I run it, answer "check". Never choose an answer for me, and never edit Yorozu's or OpenClaw's config files. If a command fails, show me the error and stop.
```

## 3. Pair the iPhone

Pairing is one of the steps the person finishes in the app. On the Mac: Settings › Devices ›
Pair iPhone. They scan the code with the iPhone Camera, or open Yorozu on the iPhone, tap
"Enter code manually" and paste the code. They check that the Mac key matches on both screens.
The 0.7.0 iPhone app has no public TestFlight yet; it builds from the same branch with their
own signing team (see the setup guide).

## Yorozu v1

Setting up Yorozu v1 (the current public release) instead? Follow the v1 guide:
<https://github.com/izyuumi/yorozu/blob/v0.5.0-beta/Start.md>.

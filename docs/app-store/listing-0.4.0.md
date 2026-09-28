# App Store listing — Yorozu 0.4.0 (iOS)

English (U.S.) copy for version 0.4.0, App Store build 10. Capabilities verified
against that build's source commit `5aea5016c906aba37047682e382619d5bbc3ee77`,
including the release-tag features from `v0.4.0`.

## Name

Yorozu

## Subtitle

Your Mac's AI agents, anywhere

## Promotional text

Your Mac's AI agents, wherever you are. Start tasks, follow progress, review approvals and keep conversations moving from iPhone or iPad.

## Description

Keep your Mac's AI agents close, even when you're away from your desk. Yorozu connects your iPhone or iPad to OpenClaw, Claude Code and Codex running on your own Mac.

• Start tasks anywhere: send a message to your assistant, or start a coding session in a project folder on your Mac.
• Follow the work: read streaming replies, check progress and answer questions as your agents work.
• Review approvals: see what an agent wants to do before you allow it. Answer eligible quick approvals from notifications after unlocking your device, or open the app for a closer look.
• Keep threads organized: search conversations, pin the ones you need and archive finished work. Pick up the same thread on your Mac or mobile device.
• Share context: send text, links and photos, including from the iOS share sheet.
• Stay in control of updates: with a matching Yorozu Mac app, see when your Mac has an update queued and postpone it for an hour from your phone.
• Advanced terminal access: interact with shell sessions running on a compatible Mac host when optional terminal access is enabled.
• End-to-end encrypted: messages between your devices are sealed before they reach the relay. Yorozu's relay cannot read them.
• No Yorozu account: pair with a QR code or pairing link. Your agents and provider credentials stay on your Mac.

Requires iOS or iPadOS 18 or later and the free Yorozu app for Mac (macOS 15 or later, Apple silicon), with OpenClaw installed and configured. Download the Mac app at yorozu.yumi.to/mac. Claude Code and Codex require their own setup on your Mac. Yorozu does not provide AI models or include provider usage.

Want to look around first? Tap "Try the demo" on the pairing screen. No Mac or sign-in is needed for the sample conversations.

Important: Anthropic and OpenAI set their own rules for using their subscriptions with third-party tools. Driving Claude Code or Codex through Yorozu with a subscription login may put that account at risk. See yorozu.yumi.to/terms.

Yorozu is open source under the MIT license. It is not affiliated with OpenClaw, Anthropic or OpenAI.

## Keywords

AI agent,remote,Mac,assistant,coding,approvals,encrypted,automation,companion,tasks

## What's new

• Improved pairing flow, including clearer connection progress and easier switching from QR scanning to manual code entry.

With the matching Yorozu Mac app:
• See queued Mac updates and restart progress on your iPhone or iPad, with a "Postpone 1 hour" option.
• Mac updates wait for Yorozu-managed work to finish. Drafts and pending messages are preserved across update restarts.
• New conversations get automatic titles using your Mac's on-device model when available. This requires macOS 26 and Apple Intelligence; other Macs use the opening words of your message.
• Optional terminal access lets you interact with shell sessions on a compatible Mac host.

## Support URL

https://github.com/izyuumi/yorozu/issues

## Marketing URL

https://yorozu.yumi.to

## Privacy policy URL

https://yorozu.yumi.to/privacy/

## Review notes

Yorozu is a remote for AI agents running on the user's own Mac. A live session requires the free Yorozu Mac app, distributed outside the Mac App Store at https://yorozu.yumi.to/mac, and the user's own configured agent software. No Yorozu account or sign-in is required.

To review without a Mac, tap "Try the demo" on the first screen. The demo is available in this release build and needs no account, pairing code or network connection. It opens sample threads:

• "Invoices": sample conversation.
• "Fix the flaky relay test": Claude Code thread with a pending approval card.
• "Tidy the icon script": Codex thread with a progress card.
• "Kyoto in April": question card.

Sending a message in the demo returns an explanatory reply. Demo approvals do not execute commands; the demo does not connect to a real Mac. Live push notifications, Mac update status and terminal sessions require a paired, compatible Mac and are not simulated in the demo.

To pair a real Mac, install Yorozu for Mac, choose to host on that Mac, and configure OpenClaw. On the Mac, open Settings → Devices → Pair Another Device. On iPhone or iPad, choose "Scan pairing code" or "Enter code manually". Pairing codes expire after 10 minutes, so we provide the built-in demo instead of a static code. Claude Code and Codex sessions require those tools to be configured on the Mac.

Terminal access is an optional advanced developer feature, off by default. After pairing with a compatible Mac, open Yorozu's Settings on iPhone or iPad. Under "Advanced developer settings", enable "Terminal access" and acknowledge the warning, then use "Open terminal" from a chat's menu. Shell commands execute on the user's Mac, not on iOS. This feature requires trust in all paired devices and is unavailable in the demo.

Only eligible quick approvals offer Allow/Don't allow notification actions, which require device authentication. Other approvals open the app for review. Encryption uses Apple's CryptoKit. Source code: https://github.com/izyuumi/yorozu

## Submission settings

- Locale: en-US.
- Primary category: Productivity.
- Secondary category: Developer Tools.
- Price: Free. Availability: all countries and regions the account already allows.
- Copyright: 2026 Yumi Izumi.
- Version release: Manually release this version.
- Sign-in required: No.
- Review contact: Yumi Izumi, contact@yumi.to (phone: use the one already on the account).
- Screenshots: docs/app-store/screenshots/iphone-6.9/*.png and docs/app-store/screenshots/ipad-13/*.png, in file-name order.

## Release-source evidence

All paths below refer to build 10 source commit
`5aea5016c906aba37047682e382619d5bbc3ee77`, not uncommitted worktree changes.

- Agent backends and Mac requirements: `README.md`; disclosures align with `apps/web/public/terms/index.html`.
- iOS 18 minimum and text/link/image sharing: `apps/ios/Project.swift`.
- Pairing improvements, demo entry and sample threads: `apps/ios/Sources/YorozuIOS/PairingFlowView.swift`, `apps/ios/Sources/YorozuIOS/RootView.swift`, and `packages/shared-swift/Sources/YorozuShared/ChatModel.swift`.
- Authenticated quick approval actions: `apps/ios/Sources/YorozuIOS/PushDelegate.swift`.
- Remote update status, postponement and restart persistence: `docs/queued-updates.md` and `packages/shared-swift/Sources/YorozuShared/UpdateStatus.swift`.
- On-device titles and fallback: `packages/runtime/src/title.ts` and `apps/mac/Sources/YorozuNative/main.swift`.
- Optional host terminal access: `packages/shared-swift/Sources/YorozuShared/TerminalSheet.swift`, `packages/shared-swift/Sources/YorozuShared/TerminalAccessSettings.swift`, `apps/ios/Sources/YorozuIOS/SettingsView.swift`, and `packages/runtime/src/serve.ts`.

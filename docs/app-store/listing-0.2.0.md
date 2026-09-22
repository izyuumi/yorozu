# App Store listing — Yorozu 0.2.0 (iOS)

Source of truth for what is entered in App Store Connect. English (U.S.) only for this release.

## App information

- Name: Yorozu
- Subtitle (≤30): Your Mac's AI agents, anywhere
- Primary category: Productivity
- Secondary category: Developer Tools
- Content rights: does not contain, show or access third-party content it doesn't have rights to
  (the app shows only what the user's own agents produce).
- Privacy policy URL: https://yorozu.yumi.to/privacy/
- Age rating: answer the questionnaire honestly. The app displays unfiltered AI-generated text
  produced by the user's own agents, has no in-app web browser, no user-to-user messaging
  between different people, no gambling, no ads, no purchases, no contests, no medical or
  treatment information. If the questionnaire asks about AI/chatbot or user-generated content,
  answer yes and accept the resulting rating.

## Pricing and availability

- Price: Free. Availability: all countries and regions the account already allows.

## Version 0.2.0

- Promotional text (≤170):
  Start tasks, answer approvals from the lock screen, and follow progress from your iPhone while OpenClaw, Claude Code or Codex work on your Mac.
- Description:

  Yorozu connects your iPhone to the AI agents running on your own Mac, OpenClaw, Claude Code and Codex, so you can start a task from the couch, approve a command from the lock screen, and pick the thread up again at your desk.

  • End-to-end encrypted: messages are sealed on your devices. Yorozu's relay only passes ciphertext it has no key for.
  • Approvals on the lock screen: when an agent needs a yes or no, answer from the notification.
  • Threads that follow you: conversations stay in sync between your Mac and iPhone, with search, pinning and archive.
  • Coding agents too: start a Claude Code or Codex session in a project folder on your Mac and watch it work.
  • No Yorozu account: pair once with a QR code. Your agents, models and credentials stay on your Mac.

  Yorozu needs the free Yorozu app for Mac (macOS 15 or later, Apple silicon) with OpenClaw installed: yorozu.yumi.to. To look around first, tap "Try the demo" on the pairing screen.

  Important: Anthropic and OpenAI set their own rules for using their subscriptions with third-party tools. Driving Claude Code or Codex through Yorozu with a subscription login may put that account at risk. See yorozu.yumi.to/terms.

  Yorozu is open source under the MIT license. It is not affiliated with OpenClaw, Anthropic or OpenAI.

- Keywords (≤100, no third-party trademarks): AI agent,remote,Mac,assistant,coding,approvals,encrypted,automation,companion,tasks
- Support URL: https://github.com/izyuumi/yorozu/issues
- Marketing URL: https://yorozu.yumi.to
- Copyright: 2026 Yumi Izumi
- Version release: Manually release this version.
- Screenshots: docs/app-store/screenshots/iphone-6.9/*.png and docs/app-store/screenshots/ipad-13/*.png, in file-name order.

## App Privacy (nutrition label)

- Data collected: Identifiers → Device ID (the Apple push token the relay stores to wake the app).
  Used for App Functionality. Not linked to the user's identity. Not used for tracking.
- Nothing else is collected. Message content is end-to-end encrypted and unreadable by the developer.

## App Review information

- Sign-in required: No.
- Contact: Yumi Izumi, mail@yumi.to (phone: use the one already on the account).
- Notes:

  Yorozu is a remote for AI agents that run on the user's own Mac, so a real session needs the free Yorozu Mac app, which is distributed outside the Mac App Store at https://yorozu.yumi.to/mac. To review without a Mac, tap "Try the demo" on the first screen. It opens sample threads, including a Claude Code and a Codex thread, a pending approval card, a progress card and a question card. Sending a message in the demo returns an explanatory reply. No account or sign-in is needed. Pairing with a real Mac uses a one-time code that expires after 10 minutes, which is why we provide the demo instead of a code. Encryption uses Apple's CryptoKit only. Source code: https://github.com/izyuumi/yorozu

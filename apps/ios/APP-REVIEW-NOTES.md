# App Review notes

Yorozu is a native chat client for an OpenClaw Gateway. Live use requires a paired Gateway running the Yorozu channel plugin. The app itself runs no AI model.

## Demo access

An on-device demo substitutes for a demo account and needs no credentials or host:

1. On the pairing screen, enter `YOROZU-DEMO` in **Pairing link**, then tap **Pair**. The code is case-sensitive; surrounding whitespace is ignored. Scanning a QR code containing that text with **Scan QR Code** also works.
2. Browse the sample conversations. Open **Ship a small improvement** (titles are in Japanese when Japanese is the device's first language) to inspect formatted messages and a collapsed tool row.
3. Send a message. A typing indicator and a sample tool row precede a delayed, scripted whole reply; responses do not come from a live model.
4. Open **Automations** to inspect sample schedules and try **Edit in Chat**. Replies are scripted; no real job is changed.
5. Open **Settings** and inspect **Paired Devices**: **Demo Device** is a fictional, read-only current device. It is not paired with a host and cannot be removed or used to add another device.
6. In Settings, choose **Exit Demo** to discard the sample session and return to the normal app (the pairing screen if unpaired).

Demo mode is marked **Demo** in the conversation list and in Settings. Conversations and changes exist only in memory. It does not connect to a Gateway, create an account, upload files, send notifications or perform real host or device administration. Attachments are unavailable. Existing pairing credentials are preserved when entering through the code.

This document explicitly discloses the demo entry code and simulated functionality. It contains no live review-host credentials. The live review host remains the primary review path and must be configured and checked separately before submission. This limited offline preview is not a substitute for full review access; using a built-in demo instead of a demo account requires Apple's prior approval under guideline 2.1(a).

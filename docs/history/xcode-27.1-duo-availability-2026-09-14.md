# Xcode 27.1 and iPhone Duo simulator availability — 2026-09-14

## Verdict

Apple's current first-party material says **Xcode 27.1 is downloadable and includes an iPhone Duo simulator in DeviceHub**. The earlier conclusion that Xcode 27.1 and the Duo simulator were “coming later this month” was wrong.

The phrase **“Coming later this month”** on Apple's iPhone Duo landing page applies to **iPhone Duo Workshops**, not to Xcode or the simulator.

Apple's public releases index has not caught up: as checked on 2026-09-14, its newest Xcode entry is **Xcode 27 RC (27A266a), dated September 9, 2026**. The public Xcode 27.1 release-notes URL also returns HTTP 404. Consequently, Apple's public unauthenticated pages confirm version **27.1** and Duo simulator availability, but do not expose a trustworthy Xcode 27.1 build number or explicitly label it “beta.” Do not infer either value.

## Evidence

1. Apple's “Prepare your app for iPhone Duo” Tech Talk says:
   - “Download Xcode 27.1 and run your app in the iPhone Duo simulator using DeviceHub.”
   - Its final chapter again says to “Download Xcode 27.1, simulate with DeviceHub.”
   - The page declares publication date `2026-09-09` in its first-party metadata.
   - Source: https://developer.apple.com/videos/play/tech-talks/111461/

2. Apple's iPhone Duo landing page places “Coming later this month” directly under **iPhone Duo Workshops**: “Join us around the world for hands-on workshops…”. It does not attach that timing to Xcode 27.1 or the simulator.
   - Source: https://developer.apple.com/iphone-duo/

3. Apple's public releases page currently lists **Xcode 27 RC (27A266a)** on **September 9, 2026** as its newest Xcode item. No Xcode 27.1 item appears in the public index as checked on 2026-09-14.
   - Source: https://developer.apple.com/news/releases/
   - Entry permalink: https://developer.apple.com/news/releases/?id=09092026h

4. Apple's current Xcode 27 release notes identify the published document as **“Xcode 27 RC Release Notes”**. The likely public Xcode 27.1 release-notes path returned HTTP 404 at check time, so it cannot establish a 27.1 build number.
   - Xcode 27 RC notes: https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes
   - Checked 27.1 path: https://developer.apple.com/documentation/xcode-release-notes/xcode-27_1-release-notes

## Practical conclusion

Use Apple's authenticated Developer Downloads page to obtain Xcode 27.1, then verify its build number from the downloaded app's `Contents/version.plist`. Based on Apple’s explicit instructions, Duo simulation should be available through DeviceHub in that release.

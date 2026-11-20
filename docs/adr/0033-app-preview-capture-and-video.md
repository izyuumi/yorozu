# 0033. App preview capture and video

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

The App Store app preview is recorded from the real app in a simulator, then composed into a video. The capture must be repeatable, touch nothing real, and stay out of release builds.

## Decision

- Scripted takes in the app (`PreviewScene`):
  - Debug builds only: `--preview-scene NAME` (implies `--demo`) plays one scripted take through the real UI and the real send path. Release builds contain none of it (App Review Guideline 2.5.19).
  - Times are take seconds. The app writes `Caches/preview-ready` once it is active, since a first launch on a fresh boot takes seconds longer; the capture script starts recording `lead` (2.5 s) later. Lock Screen takes wait 6 s more while the app goes home and the device locks.
  - `needsYou` replays the Lock Screen take with "Tidy up Downloads" already needing the owner: a locked simulator suspends the app, so the preview dissolves from one take to the other instead of the app changing the row while locked.
  - `--preview-epoch UNIX`: both Lock Screen takes date their rows from it, so they match across the dissolve.
  - The talk take's recording "says" `PreviewScene.transcript`; the capture script speaks it into `preview-voice.wav` with `say`, and the recorder plays that clip instead of the microphone (permission is treated as granted).
  - The throwaway simulator's settings: the mic button only in the talk take; the Live Activity off until turned on.
- Capture (`scripts/app_preview_capture.sh [en-US] [ja] [-- SCENE...]`):
  - A throwaway iPhone 17 Pro Max simulator on the newest installed iOS runtime that runs this device type (some, such as a device-specific beta, don't) runs a Debug build per locale and scene, and `simctl io recordVideo` writes `apps/preview/footage/<locale>/<scene>.mp4`. The simulator is deleted at the end unless `KEEP_SIM=1`. It touches no other simulator, no pairing and no Gateway, and never launches the Mac app.
  - Each locale starts on a fresh boot in the locale's system language: the Lock Screen and the widget follow it, not the app's arguments. Lock Screen takes go last because they leave the device locked.
  - simctl has no lock verb, so AXe presses the buttons, headless. The app goes home first, because ActivityKit starts an activity only while the app is still visible; then the device locks. The boot's first activity asks "Allow Live Activities from Yorozu?" seconds after the lock, and the script answers it before any take.
  - A fresh boot can come up locked or with the app relaunched in the background, so each take starts from the Home Screen and launches again if the app never becomes active.
  - simctl writes variable frame rate and stops at the last change on screen, so footage is re-encoded at a constant 30 fps with the last frame held to the full length, keeping the timeline's in and out points.
- Video (`apps/preview`):
  - 886×1920 serves the 6.9" and 6.5" iPhone slots; 870 frames at 30 fps is 29.0 s (App Store Connect allows 15–30 s).
  - Fonts follow the website's text stack, with Hiragino Sans for Japanese.
  - The caption band stays up across back-to-back captions and leaves only at the dissolves. A `\n` in a caption is a line break, since Japanese has no spaces to wrap at.
  - `render.ts` renders per locale and finishes to App Store Connect's spec: `artifacts/app-preview/<locale>/yorozu-preview-886x1920.mp4` and `poster-5s.png` (frame 150, ASC's default poster).

## Consequences

- The preview can be re-recorded at any time without touching the owner's devices or Gateway.

## Where in the code

- `apps/ios/Sources/Client/PreviewScene.swift` — `PreviewScene`, `needsYou`, `epoch`, `transcript`, `markReady()`, `play(model:)`, `lockscreen(_:)`
- `apps/ios/Sources/YorozuIOS/VoiceInput.swift` — permission check
- `scripts/app_preview_capture.sh` — `lead`, `locked_lead`, `scenes`, `runtime`, `boot()`, `lock()`, `record()`, `epoch`
- `apps/preview/src/Root.tsx`, `apps/preview/src/AppPreview.tsx`, `apps/preview/scripts/render.ts`

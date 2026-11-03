# App Store app preview

Yorozu's 29.0 s iPhone app preview (886x1920, 30 fps, 870 frames; one file serves the 6.9" and 6.5" slots), in
en-US and ja: Simulator takes of the real app in demo mode, captioned in Remotion, finished with ffmpeg. Captions,
the app icon and the end name are the only drawn graphics; the footage is full-bleed at normal speed, trimmed by
in-points only, with 0.4 s dissolves between takes. Uploading to App Store Connect is a separate, manual step.

## Make it

```sh
scripts/app_preview_capture.sh                  # takes → apps/preview/footage/{en-US,ja}/<scene>.mp4
pnpm install
pnpm --filter @yorozu/preview render            # → artifacts/app-preview/{en-US,ja}/yorozu-preview-886x1920.mp4 + poster-5s.png
scripts/app_preview_check.sh artifacts/app-preview/en-US/yorozu-preview-886x1920.mp4
scripts/app_preview_check.sh artifacts/app-preview/ja/yorozu-preview-886x1920.mp4
```

- **Capture** creates a throwaway iPhone 17 Pro Max simulator on the newest installed iOS runtime, sets the status
  bar to 9:41 with full bars and battery and light appearance, builds the Debug app for it (generated with
  `TUIST_VOICE_INPUT=0`, as simulator builds need), and per locale and scene launches the app with
  `--preview-scene NAME` and records `simctl io recordVideo --codec=h264`. Each locale starts on a fresh boot, with
  `lockscreen` last because it leaves the device locked. `KEEP_SIM=1` keeps the simulator; arguments pick locales
  and scenes: `scripts/app_preview_capture.sh ja -- talk`. Footage, renders and clips are gitignored.
- **Render** renders the `AppPreview` composition per locale (`{ locale: 'en-US' | 'ja' }`) and finishes it: H.264
  High 4.0, CBR 11 Mbps, yuv420p, 30 fps, a silent stereo AAC 256 kbps 48 kHz track (`aac_at` when ffmpeg has it),
  `+faststart`, and frame 150 (5.0 s, App Store Connect's default poster) as `poster-5s.png`.
  `pnpm --filter @yorozu/preview studio` opens Remotion Studio for tuning.
- **Check** fails unless the file is 886x1920, H.264 High at level ≤ 4.0, 30/1 fps, 10–12 Mbps video, one stereo
  AAC track at 44.1 or 48 kHz, 15.0–29.5 s long and under 500 MB.

Captions, beat timings and each take's in-point are in `src/timeline/en-US.json` and `ja.json` (composition
seconds). If a take's events land early or late, move its `inPoint`, not the captions.

## Scenes

`--preview-scene NAME` exists only in Debug builds: every line of it is inside `#if DEBUG`
(`apps/ios/Sources/Client/PreviewScene.swift` and its call sites), so a Release build ignores the argument
(Guideline 2.5.19). It implies `--demo` and plays through the real UI and send path: it fills the composer and
presses its send and mic buttons. Only under the flag does demo mode stretch its reply pauses, seed the
"Tidy up Downloads" conversation, answer "backup", "go ahead" and "remind" (ja: バックアップ, お願い, リマインド)
with the website demo's copy, allow the Live Activity, and hide TipKit tips. All of it is fictional demo content.

Take times count from the recording's start, 2.0 s after launch (`PreviewScene.lead`); expect ±0.3 s.

| Scene | Take | Events (take seconds) | In-point | In the preview |
| --- | --- | --- | --- | --- |
| `hook` | 7 s | New chat with the backup question in the composer; sent 0.4, delivered ~1.0, tool row spins 2.0–3.6, answer 3.9 | 0.0 | 0.0–5.8 |
| `lockscreen` | 9 s | Locked 1 s before recording, Live Activity: Tidy up Downloads and A weekend in Kyoto working, A calmer start to the day done; Tidy up Downloads needs you at ~4.2 | 0.0 | 5.4–12.6 (flip ~9.6) |
| `approve` | 6 s | Tidy up Downloads open on the agent's question, "Go ahead" in the composer; sent 0.5, tool row 1.1–2.3, reply 2.5 | 0.0 | 12.2–16.8 |
| `talk` | 10 s | New chat; mic pressed 0.8, recording to 4.6, "Transcribing…" bubble, message 5.2, tool row 5.8–7.0, reply 7.2 | 0.0 | 16.4–24.8 |
| `list` | 6 s | The conversation list (demo conversations), still | 0.5 | 24.4–29.0 |

### Talk: the mic-button path, with a supplied transcript

The take uses the brief's fallback: a fresh chat whose composer mic button is pressed (the same action as a tap),
not Control Center, which a script can't open or populate in the Simulator; so the caption is "Talk instead of
typing" / 「打たずに、話しかける」. The recording bar is the app's own, unchanged. Under the flag, in Debug only:

- voice input counts as on, supported and ready (a fresh simulator has no speech model), and the microphone
  permission check is skipped;
- the recorder plays `Library/Caches/preview-voice.wav` (16 kHz, made by the capture script with `say`; silence if
  absent) in place of the microphone, so the waveform and timer move as they would;
- the transcriber is skipped: after 0.6 s the transcript is the scene's sentence, "Remind me to water the plants at
  6" / 「6時に植物に水をやるようリマインドして」, which then goes out as a message.

### Lock Screen

`simctl` has no lock verb, so the capture script uses Simulator.app's Device › Lock through System Events. Grant
the terminal Accessibility access (System Settings › Privacy & Security › Accessibility) first; without it the
script asks you to lock the simulator by hand. The flag keeps the app running 15 s in the background to flip the
row. If iOS asks on the Lock Screen whether to allow Yorozu's Live Activities, the script can't answer it; check the
take. The Lock Screen's large clock shows
the Mac's time; the status bar override doesn't reach it, and the caption band covers most of it.

## Licence

Remotion is free for individuals and companies of up to 3 people ([remotion.dev/license](https://www.remotion.dev/license));
this package is private and never published.

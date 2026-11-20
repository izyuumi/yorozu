# 0023. Voice input in the app

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

Voice input records in the composer and transcribes on the device. Models are large downloads, transcription can fail, and recording runs on an audio thread.

## Decision

- Model download (`VoiceModel`):
  - `VoiceCatalog.swift` in `packages/YorozuVoice` pins each model's files.
  - iPhone and iPad get each model as an Apple-hosted asset pack (built by `scripts/voice_asset_pack.sh`), so no third party sees the download. Apple-hosted asset packs need iOS 26. The `YorozuAssets` downloader extension only has to exist; the app asks for the pack on demand. The Info.plist's `BAAppGroupID` names the App Group.
  - The Mac downloads from Hugging Face into Application Support, resumable, excluded from backup, and checked against the pinned hashes.
  - LFM3-Audio's files sit at the top of the folder, as they always have; every other model has a subfolder of its own, on disk and inside its pack.
  - `start(cellular:)` starts or resumes the download, and does nothing while one runs or once the model is ready. Without consent it holds on cellular, hotspots and Low Data Mode and resumes on Wi-Fi; `cellular` allows expensive and Low Data Mode networks for this download.
- Engine choice (`VoiceSetup`):
  - The engine is picked in Settings › Voice Input › Model. Until then Apple's is the default where it runs, and an owner who already downloaded LFM3-Audio keeps it, even once Apple's is installed.
  - `refresh` picks again after the owner chose an engine or a download finished; a language the engine lacks becomes Automatic.
  - Simulator builds leave out llama.cpp, so `compiled` reports LFM3-Audio as absent there.
  - The owner's voice dictionary is kept as JSON in this device's settings only.
- Dictation (`VoiceSession`):
  - One dictation records, then transcribes into the field or straight into a message. The clip is kept until a transcript is delivered or the owner cancels, so a failure can be retried.
  - The engine loads while the owner speaks, so only the transcription is left after ✓.
  - The transcript is in the chosen language with the voice dictionary applied; an empty one counts as a failure.
  - `sendVoice` clears the composer at once; the transcript, after any typed draft, goes out with what was staged.
- Voice sends (`VoiceSends`):
  - Each shows as a "Transcribing…" bubble in its conversation until the transcript goes out. A failure keeps the clip on the bubble for Retry.
  - The engine load is kept for Retry once it succeeded, and dropped after it failed so Retry loads again.
  - Only the current attempt of a message still listed may finish it: a discard or a newer attempt wins.
- Recording: `VoiceRecorder.tap` is built outside the main actor because the engine calls it on its own audio thread.
- Transcription on the device (`Transcriber`): LFM3-Audio-2B through llama.cpp's multimodal library (`mtmd`). It blocks and is not thread-safe: create and use it inside one background task. The long-clip strategy is in [0025](0025-lfm3-audio-long-clip-transcription.md).
- llama.cpp's xcframework has no iOS Simulator slice, so `TUIST_VOICE_INPUT=0 tuist generate` leaves it out for simulator builds, which have no voice input.

## Consequences

- No third party sees iPhone and iPad model downloads.
- A failed transcription never loses the recording.

## Where in the code

- `apps/ios/Sources/YorozuIOS/VoiceModel.swift` — `VoiceModel`, `appleHosting`, `start(cellular:)`, Mac download session
- `apps/ios/Sources/YorozuAssets/DownloaderExtension.swift`
- `apps/ios/Sources/YorozuIOS/VoiceSetup.swift` — `VoiceSetup`, `compiled(_:)`, `refresh()`, engine choice migration
- `apps/ios/Sources/YorozuIOS/VoiceSettings.swift` — `stored`
- `apps/ios/Sources/YorozuIOS/VoiceInput.swift` — `VoiceSession`, `VoiceClip.transcribe()`, `VoiceSends`, `VoiceSends.Item.loading`
- `apps/ios/Sources/YorozuIOS/Chat.swift` — `sendVoice(_:)`
- `apps/ios/Sources/YorozuIOS/VoiceRecorder.swift` — `tap`
- `apps/ios/Sources/YorozuIOS/Transcriber.swift` — `Transcriber`, simulator stub
- `apps/ios/Project.swift` — `voiceInput`, `BAAppGroupID`

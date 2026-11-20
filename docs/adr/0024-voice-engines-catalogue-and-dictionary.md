# 0024. Voice engines, model catalogue, dictionary and asset packs

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

Voice input supports several on-device engines behind one interface. Their model files are pinned and shipped as Apple-hosted asset packs, and the owner's vocabulary must be applied the same way to every engine's output.

## Decision

- Packages:
  - `packages/Llama` wraps llama.cpp's Apple build. b11954 is the first release that runs LFM3-Audio. It has no iOS Simulator slice, so the app builds for devices and the Mac only.
  - `packages/YorozuVoice` holds the model catalogue, the voice dictionary and the engine choice (`VoiceText`, no dependencies), and the Whisper and Nemotron runtimes plus Apple's SpeechAnalyzer behind one interface (`SpeechEngines`). FluidAudio's TTS, diarizer and text-normalization traits are off: Yorozu only transcribes.
- Engines:
  - Whisper runs on CoreML through WhisperKit, from a folder holding the model and its tokenizer; it never downloads. Hints go in as Whisper's "initial prompt": earlier text the decoder continues from, which steers spelling.
  - Nemotron's prompt keys are mostly region-qualified; nil picks its automatic prompt. Its languages are the ones NVIDIA lists as supported; the model takes more prompts, unevaluated.
- Catalogue:
  - `VoiceEngineID` lists engines in the order Settings › Voice Input › Model shows them. `name` is the product name, the same in every language.
  - `minimumMemory`: devices sold as 6 GB report a little under 6 GiB, 4 GB ones under 4 GiB.
  - `VoiceModelSpec` pins each model's files by Hugging Face revision and SHA-256 and names the asset pack iPhone and iPad get it from. `folder` is empty for LFM, whose files sit at the top.
  - LFM3-Audio-2B (GGUF, llama.cpp): its pack, `VoiceModel`, is already in App Store Connect; keep it as is.
  - Nemotron 3.5 ASR Streaming 0.6B, FluidInference's CoreML build (multilingual, 2.24 s chunks): the encoder and the fused decoder only, since FluidAudio computes the spectrogram itself.
- Choice: `VoiceEngineChoice.resolve` keeps the engine the owner picked while the device can run it. Otherwise: LFM3-Audio when its model is already downloaded (an owner from before engines could be picked keeps it, with no new download), then Apple's, then a downloaded model, then any engine the device can run; nil when it can run none. `usable` is in display order.
- `VoiceLanguage`'s raw value is stored in settings and is the English name LFM3-Audio's prompt takes.
- Dictionary:
  - Terms voice input should get right, each with what an engine tends to write instead (`heardAs`; empty means the term itself, in any case). Engines that take hints get the terms; every transcript then goes through `apply(to:)`. It stays on the device with the other voice settings and is never logged.
  - `apply` rewrites in one left-to-right pass (a replacement is never matched again), longest match first; equal lengths keep the owner's order (stable sort). Matching ignores case and full- or half-width forms. In scripts written with spaces a match must be a whole word; in Japanese, Chinese, Thai and other scripts without spaces it can sit anywhere. The term keeps its own spelling, except that an all-lowercase term takes a capital where the matched text had one at its start.
- Asset packs (`scripts/voice_asset_pack.sh <pack ID> <output directory>`):
  - Pack IDs: `VoiceModel` (LFM3-Audio-2B, already uploaded: leave it), `VoiceWhisperTurbo`, `VoiceWhisperSmall`, `VoiceNemotron`.
  - The script's file list (pack, path in the pack, bytes, SHA-256, pinned source) mirrors `VoiceCatalog.swift`; `VoiceTextTests` fails when they differ.
  - Upload with `xcrun altool --upload-asset-pack` ([docs/release.md](../release.md)). A pack is not available in the app until App Store Connect has it.
  - The model's license travels with its weights; OpenMDW-1.1 requires it for Nemotron.

## Consequences

- Adding a model means editing the catalogue and the pack script together.

## Where in the code

- `packages/Llama/Package.swift`, `packages/YorozuVoice/Package.swift`
- `packages/YorozuVoice/Sources/SpeechEngines/NemotronSpeechEngine.swift` — `prompt`
- `packages/YorozuVoice/Sources/SpeechEngines/WhisperSpeechEngine.swift` — `WhisperSpeechEngine`, `transcribe`
- `packages/YorozuVoice/Sources/VoiceText/VoiceCatalog.swift` — `VoiceEngineID`, `name`, `minimumMemory`, `VoiceModelSpec`, `folder`, `lfm`, `nemotron`
- `packages/YorozuVoice/Sources/VoiceText/VoiceDictionary.swift` — `VoiceDictionary`, `Entry.heardAs`, `apply`, `rules`
- `packages/YorozuVoice/Sources/VoiceText/VoiceEngineChoice.swift` — `resolve`
- `packages/YorozuVoice/Sources/VoiceText/VoiceLanguage.swift` — `VoiceLanguage`, `VoiceEngineID.languages`
- `scripts/voice_asset_pack.sh`

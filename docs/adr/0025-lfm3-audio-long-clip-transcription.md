# 0025. LFM3-Audio long-clip transcription and its measured constants

- Status: Accepted
- Date: 2026-11-21 (recorded from code comments)

## Context

LFM3-Audio silently skips stretches of long audio, sometimes stops a window early, and can loop or read hints back on audio it can't make out. None of these failures signal themselves. The constants below come from measurements.

## Decision

- Windowing (`AudioWindowPlan`):
  - Each decode must fit LFM3-Audio's context: the audio's tokens, the prompt around them and the transcript's budget. No window is longer than `preferredWindowSeconds`. A clip within both is decoded whole; a longer one in windows of at most that length, each cut at a pause and overlapping the next a little, so a word cut at the seam is heard whole by one of the two.
  - `preferredWindowSeconds`: the context fits about 178 s, but LFM3-Audio silently skips stretches of long windows, not quite the same from run to run. On 10-minute English and Japanese readings, a 177 s window came back with a third of its speech; 115–120 s windows were mixed (Japanese 233–348 s skipped about 50 s on every run, while its halves and 233–323 s were complete); every 90 s span tried, seven of them, was complete. Shorter isn't always safer (one 60 s span lost a fifth), so a window that still comes back sparse is decoded again in halves.
  - `audioTokensPerSecond`: one audio token per 80 ms, measured with mtmd's tokenizer and the pinned LFM3-Audio-2B files, the same for English and Japanese, from 33 s (418 tokens) to 597 s (7,468 tokens).
  - `promptReserve`: the prompt around the audio measured 17 tokens; the rest is margin for hints and rounding.
  - `contextTokens` is the decoder's context (`Transcriber.contextTokens`).
  - A cut is late enough that the next window, starting `overlap` earlier, still moves forward.
- Budget (`TranscriptBudget`): speech yields only a few tokens a second, so a decode that outruns the budget is looping and stops there instead of running to the end of the context.
  - `tokensPerSecond` is above the fastest real speech measured on an M4 Mac mini: 10.4 tokens/s for letters and digits read at 380 words a minute in Japanese. Ordinary English and Japanese speech gave 3 to 6; English at 380 words a minute 8.2.
  - `safetyFactor` gives headroom so fast or dense speech is never cut off. `minimum` leaves a short clip room for a few sentences.
- Decoding (`Transcriber.decode`): 16 kHz mono PCM, greedy, at most `maxTokens`. It stops early when the task is cancelled. Audio that leaves no room for `maxTokens` in the context is not decoded but reported as `reachedLimit`, never truncated silently; one that doesn't fit (a long hint list) counts as cut short, so `transcribe` retries or fails. `Decoded` reports whether the decode was still writing when the budget or context ran out, which speech never needs.
- Degeneration (`TranscriptDegeneration`): with hints the model can loop or read the vocabulary back instead of transcribing. A third repeat in a row is a loop ("no no" is speech). A transcript is "mostly hints" when two or more different hint terms cover more than half its letters and digits; one term alone may be all someone said ("Yorozu"), or said twice. Such a transcript is replaced by one decoded without hints; if that is no better, the decode failed. A decode that outruns the window's budget is a loop too.
- Sparse windows (`TranscriptDensity`): a window the model partly skipped is short for its speech with no other sign. A clip's windows share speaker and language, so a window far less dense than the others' median is decoded again in halves. A window needs `minimumSpeechSeconds` of speech to be judged.
- Tail probe (`TranscriptTail`): the model sometimes stops a window early, repeating an earlier sentence and ending seconds before the audio does; the lost sentence is too short for density to notice. So the end of a long window is decoded on its own, and a window whose transcript doesn't end with what the probe says is decoded again in halves. Windows shorter than `minimumWindowSeconds` are not probed, so a short dictation doesn't pay a second decode. `minimumCoverage` is the share of the probe's words or CJK characters the transcript's end must hold; measured: a window that stopped 12 s early scored 0.29, 15 complete English and Japanese windows 0.86–1.00. `reachesEnd` is true when the window isn't probed or the probe's decode fails.
- Seams (`TranscriptSeam`): each window hears the last second of the one before, so words there can come out twice. The repeat at each seam is dropped as long as the speech in that overlap could have said it. The cut is usually in a pause, so an overlap often holds no speech, and then a repeat across the seam is what was said ("言った" + "言ったことを…"). `shortestOverlap` is the shortest repeat dropped, since one word said twice ("that that") may be what was said. `shortestCJKOverlap` is the same for an all-Chinese or Japanese repeat, counted in characters: two ("本当") are often one word. An epsilon keeps a measured 0.30000000000000004 s at 3 characters, not 4. Only consecutive windows share audio; one skipped as silent between two parts leaves none.
- Voice activity (`VoiceActivity`): which 0.1 s frames hold speech, by loudness alone. It mirrors WhisperKit's `EnergyVAD` (argmax-oss-swift 1.1.1), which `WhisperSpeechEngine` uses through `chunkingStrategy: .vad`: the RMS energy of each frame against a threshold. `VoiceText` has no dependencies, so the approach is copied, not imported. WhisperKit's threshold is a fixed 0.02; here it follows the clip, a fraction of its loud frames, so a quiet recording still shows its pauses. `floor` is a quarter of 0.02, so a clip of room noise counts as silence whatever the microphone level. `frameSeconds` is WhisperKit's default.
- Clip loop (`Transcriber.transcribe`):
  - Windows are decoded one by one, silent ones skipped. A clip decoded whole is decoded even when it seems silent, as before windows existed.
  - A window with speech that fails, or one of a longer clip that comes back empty despite `emptySpeechSeconds` of speech (the model sometimes ends a window early without a word), or stops before its end, is decoded again in two halves, up to `splitDepth` times. The misses are occasional, and a part decoded on its own usually comes out whole. Only a part that can't be split further fails the clip, rather than leave a hole; a silent window recognized nothing.
  - A sparse window is decoded again in halves once, and their transcript kept only if it says clearly more; a half that fails keeps the window's own.
  - A half's decode stops on cancellation without throwing, so cancellation is checked after the halves.
  - `progress` hears each window before it is decoded: its index, the window count and the window, or the part a retry decodes.

## Consequences

- Long dictations come back complete in practice; the cost is extra decodes for suspicious windows.
- Changing the model or llama.cpp means measuring these constants again.

## Where in the code

- `packages/YorozuVoice/Sources/VoiceText/AudioWindowPlan.swift` — `AudioWindowPlan`, `preferredWindowSeconds`, `audioTokensPerSecond`, `promptReserve`, `contextTokens`, `start`
- `packages/YorozuVoice/Sources/VoiceText/TranscriptBudget.swift` — `TranscriptBudget`, `tokensPerSecond`, `safetyFactor`, `minimum`
- `packages/YorozuVoice/Sources/VoiceText/TranscriptDegeneration.swift` — `TranscriptDegeneration`, `repeatLimit`, `mostlyHints`
- `packages/YorozuVoice/Sources/VoiceText/TranscriptDensity.swift` — `TranscriptDensity`, `minimumSpeechSeconds`
- `packages/YorozuVoice/Sources/VoiceText/TranscriptSeam.swift` — `TranscriptSeam`, `shortestOverlap`, `shortestCJKOverlap`, `caps`
- `packages/YorozuVoice/Sources/VoiceText/TranscriptTail.swift` — `TranscriptTail`, `minimumWindowSeconds`, `minimumCoverage`
- `packages/YorozuVoice/Sources/VoiceText/VoiceActivity.swift` — `VoiceActivity`, `frameSeconds`, `floor`
- `apps/ios/Sources/YorozuIOS/Transcriber.swift` — `Decoded`, `decode`, `emptySpeechSeconds`, `transcribe` (clip and window), `reachesEnd`, `transcript(_:language:hints:)`

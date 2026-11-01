# Voice input licenses

What voice input (Settings › Voice Input › Model) ships or downloads, and under which terms. The model files
are pinned by Hugging Face revision and SHA-256 in `packages/YorozuVoice/Sources/VoiceText/VoiceCatalog.swift`;
the iPhone and iPad asset packs built by `scripts/voice_asset_pack.sh` carry the model's license file next to
its weights.

## Models (downloaded on request)

| Model | Files | License |
| --- | --- | --- |
| LFM3-Audio-2B (Liquid AI) | `LiquidAI/LFM3-Audio-2B-GGUF` | [LFM Open License v1.0](https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/blob/main/LICENSE) |
| Whisper large-v3-turbo (OpenAI) | CoreML build `DictionLabs/whisperkit-coreml`, folder `dictionlabs_whisper-large-v3-turbo-q6q8` (MIT); tokenizer from `openai/whisper-large-v3-turbo` (MIT) | MIT, [Whisper-MIT.txt](Whisper-MIT.txt) |
| Whisper small (OpenAI) | CoreML build `DictionLabs/whisperkit-coreml`, folder `openai_whisper-small` (MIT); tokenizer from `openai/whisper-small` (Apache-2.0 on Hugging Face; the original weights and code are MIT) | MIT, [Whisper-MIT.txt](Whisper-MIT.txt) |
| Nemotron 3.5 ASR Streaming 0.6B (NVIDIA) | CoreML build `FluidInference/nemotron-3.5-asr-streaming-0.6b-coreml`, folder `multilingual/2240ms`, of `nvidia/nemotron-3.5-asr-streaming-0.6b` | [OpenMDW-1.1](OpenMDW-1.1.txt): free to use, change and redistribute; a copy of the agreement and the notices of origin travel with every redistribution |

Apple Speech (SpeechAnalyzer) is part of iOS, iPadOS and macOS 26 and later; the system installs its
language models.

## Runtimes (in the app)

| Package | Version | License |
| --- | --- | --- |
| WhisperKit (`argmaxinc/argmax-oss-swift`) | 1.1.1 | MIT, [argmax-oss-swift-MIT.txt](argmax-oss-swift-MIT.txt); includes code from Hugging Face swift-transformers under Apache-2.0, [argmax-oss-swift-NOTICES.txt](argmax-oss-swift-NOTICES.txt) |
| FluidAudio (`FluidInference/FluidAudio`) | 0.18.0, traits off (no TTS, diarizer or NeMo text normalization) | Apache-2.0, [FluidAudio-Apache-2.0.txt](FluidAudio-Apache-2.0.txt); links fastcluster, BSD-2-Clause, [fastcluster-BSD-2-Clause.txt](fastcluster-BSD-2-Clause.txt) |
| llama.cpp (`packages/Llama`, for LFM3-Audio) | b11954 | MIT |

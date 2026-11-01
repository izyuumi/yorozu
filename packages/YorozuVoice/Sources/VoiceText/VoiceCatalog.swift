import Foundation

/// The speech engines voice input can use, in the order Settings › Voice Input › Model lists them.
public enum VoiceEngineID: String, CaseIterable, Codable, Sendable, Identifiable {
    case apple
    case lfm
    case whisperTurbo = "whisper-large-v3-turbo"
    case whisperSmall = "whisper-small"
    case nemotron = "nemotron-3.5-asr"

    public var id: Self { self }

    /// The product name, the same in every language.
    public var name: String {
        switch self {
        case .apple: "Apple Speech"
        case .lfm: "LFM3-Audio-2B"
        case .whisperTurbo: "Whisper Large v3 Turbo"
        case .whisperSmall: "Whisper Small"
        case .nemotron: "Nemotron 3.5 ASR"
        }
    }

    public var maker: String {
        switch self {
        case .apple: "Apple"
        case .lfm: "Liquid AI"
        case .whisperTurbo, .whisperSmall: "OpenAI"
        case .nemotron: "NVIDIA"
        }
    }

    /// The downloaded model; nil for Apple's, which the system installs per language.
    public var model: VoiceModelSpec? {
        switch self {
        case .apple: nil
        case .lfm: .lfm
        case .whisperTurbo: .whisperTurbo
        case .whisperSmall: .whisperSmall
        case .nemotron: .nemotron
        }
    }

    /// Physical memory the device needs. Devices sold as 6 GB report a little under 6 GiB, 4 GB ones under 4 GiB.
    public var minimumMemory: UInt64 {
        switch self {
        case .apple: 0
        case .lfm, .whisperTurbo: 5 << 30
        case .whisperSmall, .nemotron: 3 << 30
        }
    }

    /// How many spoken languages the model handles; nil for Apple's, which depends on the system.
    public var languageCount: Int? {
        switch self {
        case .apple: nil
        case .lfm: 18
        case .whisperTurbo, .whisperSmall: 99
        case .nemotron: 8
        }
    }

    /// Whether the model is built to transcribe audio as it arrives.
    public var streaming: Bool {
        switch self {
        case .apple, .nemotron: true
        case .lfm, .whisperTurbo, .whisperSmall: false
        }
    }

    /// The model's license and where to read it; nil for Apple's, which is part of the system.
    public var license: (name: String, url: URL)? {
        switch self {
        case .apple: nil
        case .lfm: ("LFM Open License v1.0", URL(string: "https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/blob/main/LICENSE")!)
        case .whisperTurbo, .whisperSmall: ("MIT", URL(string: "https://github.com/openai/whisper/blob/main/LICENSE")!)
        case .nemotron: ("OpenMDW-1.1", URL(string: "https://openmdw.ai/license/1-1/")!)
        }
    }
}

/// One downloadable model: its files pinned by Hugging Face revision and SHA-256, and the Apple-hosted asset
/// pack iPhone and iPad get it from. `scripts/voice_asset_pack.sh` builds each pack from the same list (a test
/// keeps the two in sync).
public struct VoiceModelSpec: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        /// The path inside the model's folder.
        public let path: String
        public let repo: String
        public let revision: String
        public let remotePath: String
        public let bytes: Int64
        public let sha256: String

        init(_ path: String, _ repo: String, _ revision: String, _ remotePath: String, _ bytes: Int64, _ sha256: String) {
            (self.path, self.repo, self.revision, self.remotePath, self.bytes, self.sha256) = (path, repo, revision, remotePath, bytes, sha256)
        }

        public var url: URL { URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(remotePath)")! }
    }

    public let packID: String
    /// The folder the files live in, on disk and inside the pack; empty for LFM, whose files sit at the top.
    public let folder: String
    public let files: [File]

    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    /// The path a file has inside the asset pack and under the app's model directory.
    public func location(of file: File) -> String { folder.isEmpty ? file.path : folder + "/" + file.path }

    static let lfmRevision = "fcfae9027c00a6f3f872c48a841cfeb77e2b5a1c"

    /// LFM3-Audio-2B (GGUF, llama.cpp). Its pack, `VoiceModel`, is already in App Store Connect: keep it as is.
    public static let lfm = VoiceModelSpec(
        packID: "VoiceModel", folder: "",
        files: [
            File("LFM3-Audio-2B-Q4_K_M.gguf", "LiquidAI/LFM3-Audio-2B-GGUF", lfmRevision, "LFM3-Audio-2B-Q4_K_M.gguf", 1_099_626_016,
                "9a773289bd321ed879cd3a76545f6aca506e403851a45fb315420aee45625be2"),
            File("mmproj-LFM3-Audio-2B-Q8_0.gguf", "LiquidAI/LFM3-Audio-2B-GGUF", lfmRevision, "mmproj-LFM3-Audio-2B-Q8_0.gguf", 337_862_080,
                "26601e904245a85bd8f3cf320a629e897cfc01c1d09369e8b4fd951f13024d3e"),
        ])

    /// Whisper large-v3-turbo, Diction Labs' CoreML build (6-bit encoder, 8-bit decoder) for WhisperKit.
    public static let whisperTurbo = VoiceModelSpec(
        packID: "VoiceWhisperTurbo", folder: "whisper-large-v3-turbo",
        files: [
            File("AudioEncoder.mlmodelc/analytics/coremldata.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/AudioEncoder.mlmodelc/analytics/coremldata.bin", 243, "6e5efaeeb5662c931459be0cbd148ce98927eccfef498a7ac91ae0bd16b04464"),
            File("AudioEncoder.mlmodelc/coremldata.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/AudioEncoder.mlmodelc/coremldata.bin", 409, "61a5aab1dc988770dde6730b3d567114aa2e1f062dabfeefd000f76f2c7bae16"),
            File("AudioEncoder.mlmodelc/metadata.json", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/AudioEncoder.mlmodelc/metadata.json", 2_020, "7e248407a3868e5db793408546708183d14565615b29347f7fbba643d21e4787"),
            File("AudioEncoder.mlmodelc/model.mil", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/AudioEncoder.mlmodelc/model.mil", 9_791_744, "dfbda56da934249da0b4c6849583ee64257f1bebf4354fbd85ea283defd4561e"),
            File("AudioEncoder.mlmodelc/weights/weight.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/AudioEncoder.mlmodelc/weights/weight.bin", 480_821_248, "b429ac850d20c15cec552d48ca770dec2f842fa9afc4833f7586d624e49f510f"),
            File("MelSpectrogram.mlmodelc/analytics/coremldata.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243, "5a539ca31d3c561a2dd6a6a3c0261da93337546fa3a8c8a32320ed29842e466b"),
            File("MelSpectrogram.mlmodelc/coremldata.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/MelSpectrogram.mlmodelc/coremldata.bin", 390, "dd9727e5cd44a53343444789871eae2fbd583f1fd286fd6fa28f45982ea032af"),
            File("MelSpectrogram.mlmodelc/metadata.json", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/MelSpectrogram.mlmodelc/metadata.json", 1_949, "3aacfbba1d38c01ff76cb8d8eed66ba84fc6e6007b5403b3150b3054f52a1ad7"),
            File("MelSpectrogram.mlmodelc/model.mil", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/MelSpectrogram.mlmodelc/model.mil", 10_143, "9b926b119b5a54765a095f42b3f66380543497923483efdaf76502d45e9bd868"),
            File("MelSpectrogram.mlmodelc/weights/weight.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/MelSpectrogram.mlmodelc/weights/weight.bin", 373_376, "009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49"),
            File("TextDecoder.mlmodelc/analytics/coremldata.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/TextDecoder.mlmodelc/analytics/coremldata.bin", 243, "9b3762f848be11b02a07f4f0c5e35ae721e0204a0f1dd27413707ab80b9a9d69"),
            File("TextDecoder.mlmodelc/coremldata.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/TextDecoder.mlmodelc/coremldata.bin", 694, "28f041e44d2aeda4fd3f370472ce043df8a294f5d78047c0eac80629058e6486"),
            File("TextDecoder.mlmodelc/metadata.json", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/TextDecoder.mlmodelc/metadata.json", 4_951, "e733dfd63893c38ca991ff4a993e6f576d25ffcc19883bdd79c1cbad87f653bf"),
            File("TextDecoder.mlmodelc/model.mil", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/TextDecoder.mlmodelc/model.mil", 141_703, "b5fcd6ee065c2ac021f6d802ff0923112bc8d1835dbeeedb6ffff11f6bbc09d8"),
            File("TextDecoder.mlmodelc/weights/weight.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/TextDecoder.mlmodelc/weights/weight.bin", 245_652_212, "4a6390ad632486dd542f630550b656b1dcb3802cb80edb8098a8e5362431648c"),
            File("config.json", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/config.json", 1_149, "f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1"),
            File("generation_config.json", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "dictionlabs_whisper-large-v3-turbo-q6q8/generation_config.json", 2_767, "7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6"),
            File("tokenizer.json", "openai/whisper-large-v3-turbo", "41f01f3fe87f28c78e2fbf8b568835947dd65ed9", "tokenizer.json", 2_710_337, "297b13372ac43916285644fb9687add3cc62ee2a1adb60da3dc25cc94c1871fd"),
            File("tokenizer_config.json", "openai/whisper-large-v3-turbo", "41f01f3fe87f28c78e2fbf8b568835947dd65ed9", "tokenizer_config.json", 282_843, "844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389"),
        ])

    /// Whisper small, Diction Labs' CoreML build for WhisperKit.
    public static let whisperSmall = VoiceModelSpec(
        packID: "VoiceWhisperSmall", folder: "whisper-small",
        files: [
            File("AudioEncoder.mlmodelc/analytics/coremldata.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/AudioEncoder.mlmodelc/analytics/coremldata.bin", 243, "63f3daf56b73dee3f019513d68549b65ee1273661ef158db81df53cbf147f65b"),
            File("AudioEncoder.mlmodelc/coremldata.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/AudioEncoder.mlmodelc/coremldata.bin", 408, "beab8662c616661ddb4106205b33fbfe8f0430ea830e4171b74fc47a32c61a34"),
            File("AudioEncoder.mlmodelc/metadata.json", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/AudioEncoder.mlmodelc/metadata.json", 1_916, "1991c30c501317181d65f9e09ebead153a4fce616383cbd717922fa0a6be3e65"),
            File("AudioEncoder.mlmodelc/model.mil", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/AudioEncoder.mlmodelc/model.mil", 2_236_845, "91a89fdc750b8a4c7940adaba38aaaf95c0f5357484f4e96e78e021be8952418"),
            File("AudioEncoder.mlmodelc/weights/weight.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/AudioEncoder.mlmodelc/weights/weight.bin", 176_323_456, "60b20a7f3655647a932bf99af3b86a8e6011162e39ceea2f7d16805449efdd2f"),
            File("MelSpectrogram.mlmodelc/analytics/coremldata.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/MelSpectrogram.mlmodelc/analytics/coremldata.bin", 243, "d894dbee0f91be20fdf522594fc499e96dff3d62d606d2c32fb528ae9bc05af4"),
            File("MelSpectrogram.mlmodelc/coremldata.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/MelSpectrogram.mlmodelc/coremldata.bin", 389, "24a861fa45a5542841af595b651d4f822b6b9766f4115ae4615717326f96972b"),
            File("MelSpectrogram.mlmodelc/metadata.json", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/MelSpectrogram.mlmodelc/metadata.json", 1_947, "d9eeae745f667887f2e8d5f0eb07639a32bb46c6e3a3c973c19498bdd3936573"),
            File("MelSpectrogram.mlmodelc/model.mil", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/MelSpectrogram.mlmodelc/model.mil", 10_132, "cbd174733d72ad299fe427d1963116490f081999ded0b9fddc168f844bb51d6f"),
            File("MelSpectrogram.mlmodelc/weights/weight.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/MelSpectrogram.mlmodelc/weights/weight.bin", 354_080, "801024dbc7a89c677be1f8b285de3409e35f7d1786c9c8d9d0d6842ac57a1c83"),
            File("TextDecoder.mlmodelc/analytics/coremldata.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/TextDecoder.mlmodelc/analytics/coremldata.bin", 243, "0d62d98d2743526ff7c20c2e0b53516d05efb3b1bf2d772163a329e8471c2229"),
            File("TextDecoder.mlmodelc/coremldata.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/TextDecoder.mlmodelc/coremldata.bin", 694, "3577d9aa102ce0b2d7d3fc4a16487c3048189128e6ca3108ec4d9a6a53cbd143"),
            File("TextDecoder.mlmodelc/metadata.json", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/TextDecoder.mlmodelc/metadata.json", 4_856, "37865b0a1eed76fd6fb7dbccc48d56ba5dde0fc8221f87b69185961c014d9bc2"),
            File("TextDecoder.mlmodelc/model.mil", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/TextDecoder.mlmodelc/model.mil", 367_298, "06092e2c72412ccdbcaa80093b7c45376bc142ffe322179cbb8c18b23077edd2"),
            File("TextDecoder.mlmodelc/weights/weight.bin", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/TextDecoder.mlmodelc/weights/weight.bin", 307_287_346, "0f8eae40e08ccfed9613d821f6fc3f0a8aa46ebb9aca85fbcf7f2d555030d286"),
            File("config.json", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/config.json", 1_456, "12f8d45c3e5da28148d88d257684e77296e4d922009e1bc5289b05b756859422"),
            File("generation_config.json", "DictionLabs/whisperkit-coreml", "c281d38c90f1fbfd307b328444480810c2e2bd10", "openai_whisper-small/generation_config.json", 2_779, "169e76633bb28ac383cdfaad2527e662d0d532a15f8437ce94c02c10bc713b71"),
            File("tokenizer.json", "openai/whisper-small", "973afd24965f72e36ca33b3055d56a652f456b4d", "tokenizer.json", 2_480_466, "27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566"),
            File("tokenizer_config.json", "openai/whisper-small", "973afd24965f72e36ca33b3055d56a652f456b4d", "tokenizer_config.json", 282_683, "2a4c4281cf9f51ac6ccc406fdc711a087afe6530f671fa7b80953edc498275ce"),
        ])

    /// Nemotron 3.5 ASR Streaming 0.6B, FluidInference's CoreML build (multilingual, 2.24 s chunks): the encoder and
    /// the fused decoder only, since FluidAudio computes the spectrogram itself.
    public static let nemotron = VoiceModelSpec(
        packID: "VoiceNemotron", folder: "nemotron-3.5-asr",
        files: [
            File("decoder_joint.mlmodelc/analytics/coremldata.bin", "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML", "1a41b75758b0337ff67db7d5408280aaaf23074e", "multilingual/2240ms/decoder_joint.mlmodelc/analytics/coremldata.bin", 243, "8a8e98a54ed1f16c3d5125816a002b991e167d620beb8fcc557f26d9a1c092f8"),
            File("decoder_joint.mlmodelc/coremldata.bin", "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML", "1a41b75758b0337ff67db7d5408280aaaf23074e", "multilingual/2240ms/decoder_joint.mlmodelc/coremldata.bin", 454, "6404b542fb5d5faa79648fc96a79a0b981cbd087df0378adefd1f45ae56dd86e"),
            File("decoder_joint.mlmodelc/model.mil", "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML", "1a41b75758b0337ff67db7d5408280aaaf23074e", "multilingual/2240ms/decoder_joint.mlmodelc/model.mil", 15_801, "62144df8c1928d571c1df508a576f2d574a6bd6b1f2dba7f3f15cf9605805d6a"),
            File("decoder_joint.mlmodelc/weights/weight.bin", "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML", "1a41b75758b0337ff67db7d5408280aaaf23074e", "multilingual/2240ms/decoder_joint.mlmodelc/weights/weight.bin", 48_782_272, "01f21eb747fbc53bd0ed7efebea1bf0aa655ebf2816f21d0bb6554c9b7fcfc0b"),
            File("encoder.mlmodelc/analytics/coremldata.bin", "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML", "1a41b75758b0337ff67db7d5408280aaaf23074e", "multilingual/2240ms/encoder.mlmodelc/analytics/coremldata.bin", 243, "af569fd95237bdf8b91d38094691bfc990fcf3534316fa615bac5964c02809e4"),
            File("encoder.mlmodelc/coremldata.bin", "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML", "1a41b75758b0337ff67db7d5408280aaaf23074e", "multilingual/2240ms/encoder.mlmodelc/coremldata.bin", 573, "d5471a4edf55ce02dab51e5d01c86b419a7659bcdd6aac216ba6f0b795eae8bf"),
            File("encoder.mlmodelc/model.mil", "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML", "1a41b75758b0337ff67db7d5408280aaaf23074e", "multilingual/2240ms/encoder.mlmodelc/model.mil", 1_010_788, "3ee65463908bbc06c92691ea9172499aea3f7ae4ba619d39783c4a639936fae5"),
            File("encoder.mlmodelc/weights/weight.bin", "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML", "1a41b75758b0337ff67db7d5408280aaaf23074e", "multilingual/2240ms/encoder.mlmodelc/weights/weight.bin", 565_336_640, "2e00be98049a22e095452c020f183d2b23728e145cc814ba031436931b4f2e8f"),
            File("metadata.json", "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML", "1a41b75758b0337ff67db7d5408280aaaf23074e", "multilingual/2240ms/metadata.json", 3_005, "070ae181941003ff3e7d7ff8e5c5d47aebd026e8458549cef0c9a6803dbec004"),
            File("tokenizer.json", "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML", "1a41b75758b0337ff67db7d5408280aaaf23074e", "multilingual/2240ms/tokenizer.json", 284_969, "fb70c8fcb6472cda2bdb799b156a8941e72762344a7c636d3b1275f1d53c4a6b"),
        ])
}

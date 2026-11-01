#!/bin/sh
# Builds one of the Apple-hosted asset packs iPhone and iPad download voice models from:
#   scripts/voice_asset_pack.sh <pack ID> <output directory>   e.g. VoiceWhisperTurbo ./out -> ./out/VoiceWhisperTurbo/VoiceWhisperTurbo.aar
# Pack IDs: VoiceModel (LFM3-Audio-2B, already uploaded: leave it), VoiceWhisperTurbo, VoiceWhisperSmall, VoiceNemotron.
# The file list below (pack, path in the pack, bytes, SHA-256, pinned source) mirrors VoiceCatalog.swift in
# packages/YorozuVoice; VoiceTextTests fails when they differ. Upload the result with
# xcrun altool --upload-asset-pack (docs/release.md); a pack is not available in the app until App Store Connect has it.
set -eu
PACK=${1:?usage: scripts/voice_asset_pack.sh <pack ID> <output directory>}
OUT=${2:?usage: scripts/voice_asset_pack.sh <pack ID> <output directory>}
LICENSES=$(cd "$(dirname "$0")/../docs/voice-licenses" && pwd)
mkdir -p "$OUT/$PACK/files"
cd "$OUT/$PACK"
SELECTORS=""
FOUND=0
while read -r pack path bytes sha url; do
    [ "$pack" = "$PACK" ] || continue
    FOUND=1
    SELECTORS="$SELECTORS${SELECTORS:+,
}        { \"file\": \"$path\" }"
    [ "$(shasum -a 256 "files/$path" 2>/dev/null | cut -d' ' -f1)" = "$sha" ] && continue
    mkdir -p "$(dirname "files/$path")"
    curl -fL -C - -o "files/$path" "$url"
    [ "$(wc -c < "files/$path" | tr -d ' ')" = "$bytes" ] || { echo "Size mismatch: $path" >&2; exit 1; }
    [ "$(shasum -a 256 "files/$path" | cut -d' ' -f1)" = "$sha" ] || { echo "SHA-256 mismatch: $path" >&2; exit 1; }
done <<FILES
VoiceModel LFM3-Audio-2B-Q4_K_M.gguf 1099626016 9a773289bd321ed879cd3a76545f6aca506e403851a45fb315420aee45625be2 https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/resolve/fcfae9027c00a6f3f872c48a841cfeb77e2b5a1c/LFM3-Audio-2B-Q4_K_M.gguf
VoiceModel mmproj-LFM3-Audio-2B-Q8_0.gguf 337862080 26601e904245a85bd8f3cf320a629e897cfc01c1d09369e8b4fd951f13024d3e https://huggingface.co/LiquidAI/LFM3-Audio-2B-GGUF/resolve/fcfae9027c00a6f3f872c48a841cfeb77e2b5a1c/mmproj-LFM3-Audio-2B-Q8_0.gguf
VoiceWhisperTurbo whisper-large-v3-turbo/AudioEncoder.mlmodelc/analytics/coremldata.bin 243 6e5efaeeb5662c931459be0cbd148ce98927eccfef498a7ac91ae0bd16b04464 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/AudioEncoder.mlmodelc/analytics/coremldata.bin
VoiceWhisperTurbo whisper-large-v3-turbo/AudioEncoder.mlmodelc/coremldata.bin 409 61a5aab1dc988770dde6730b3d567114aa2e1f062dabfeefd000f76f2c7bae16 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/AudioEncoder.mlmodelc/coremldata.bin
VoiceWhisperTurbo whisper-large-v3-turbo/AudioEncoder.mlmodelc/metadata.json 2020 7e248407a3868e5db793408546708183d14565615b29347f7fbba643d21e4787 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/AudioEncoder.mlmodelc/metadata.json
VoiceWhisperTurbo whisper-large-v3-turbo/AudioEncoder.mlmodelc/model.mil 9791744 dfbda56da934249da0b4c6849583ee64257f1bebf4354fbd85ea283defd4561e https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/AudioEncoder.mlmodelc/model.mil
VoiceWhisperTurbo whisper-large-v3-turbo/AudioEncoder.mlmodelc/weights/weight.bin 480821248 b429ac850d20c15cec552d48ca770dec2f842fa9afc4833f7586d624e49f510f https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/AudioEncoder.mlmodelc/weights/weight.bin
VoiceWhisperTurbo whisper-large-v3-turbo/MelSpectrogram.mlmodelc/analytics/coremldata.bin 243 5a539ca31d3c561a2dd6a6a3c0261da93337546fa3a8c8a32320ed29842e466b https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/MelSpectrogram.mlmodelc/analytics/coremldata.bin
VoiceWhisperTurbo whisper-large-v3-turbo/MelSpectrogram.mlmodelc/coremldata.bin 390 dd9727e5cd44a53343444789871eae2fbd583f1fd286fd6fa28f45982ea032af https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/MelSpectrogram.mlmodelc/coremldata.bin
VoiceWhisperTurbo whisper-large-v3-turbo/MelSpectrogram.mlmodelc/metadata.json 1949 3aacfbba1d38c01ff76cb8d8eed66ba84fc6e6007b5403b3150b3054f52a1ad7 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/MelSpectrogram.mlmodelc/metadata.json
VoiceWhisperTurbo whisper-large-v3-turbo/MelSpectrogram.mlmodelc/model.mil 10143 9b926b119b5a54765a095f42b3f66380543497923483efdaf76502d45e9bd868 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/MelSpectrogram.mlmodelc/model.mil
VoiceWhisperTurbo whisper-large-v3-turbo/MelSpectrogram.mlmodelc/weights/weight.bin 373376 009d9fb8f6b589accfa08cebf1c712ef07c3405229ce3cfb3a57ee033c9d8a49 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/MelSpectrogram.mlmodelc/weights/weight.bin
VoiceWhisperTurbo whisper-large-v3-turbo/TextDecoder.mlmodelc/analytics/coremldata.bin 243 9b3762f848be11b02a07f4f0c5e35ae721e0204a0f1dd27413707ab80b9a9d69 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/TextDecoder.mlmodelc/analytics/coremldata.bin
VoiceWhisperTurbo whisper-large-v3-turbo/TextDecoder.mlmodelc/coremldata.bin 694 28f041e44d2aeda4fd3f370472ce043df8a294f5d78047c0eac80629058e6486 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/TextDecoder.mlmodelc/coremldata.bin
VoiceWhisperTurbo whisper-large-v3-turbo/TextDecoder.mlmodelc/metadata.json 4951 e733dfd63893c38ca991ff4a993e6f576d25ffcc19883bdd79c1cbad87f653bf https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/TextDecoder.mlmodelc/metadata.json
VoiceWhisperTurbo whisper-large-v3-turbo/TextDecoder.mlmodelc/model.mil 141703 b5fcd6ee065c2ac021f6d802ff0923112bc8d1835dbeeedb6ffff11f6bbc09d8 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/TextDecoder.mlmodelc/model.mil
VoiceWhisperTurbo whisper-large-v3-turbo/TextDecoder.mlmodelc/weights/weight.bin 245652212 4a6390ad632486dd542f630550b656b1dcb3802cb80edb8098a8e5362431648c https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/TextDecoder.mlmodelc/weights/weight.bin
VoiceWhisperTurbo whisper-large-v3-turbo/config.json 1149 f01d83dd891791d6f12421c05d3ed8ebbe70866f10d6c9a7a7e80b558ce5a0f1 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/config.json
VoiceWhisperTurbo whisper-large-v3-turbo/generation_config.json 2767 7fbb053a023be11fbeccd8421811610308143daa93d9617c52aab4a0fa1491c6 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/dictionlabs_whisper-large-v3-turbo-q6q8/generation_config.json
VoiceWhisperTurbo whisper-large-v3-turbo/tokenizer.json 2710337 297b13372ac43916285644fb9687add3cc62ee2a1adb60da3dc25cc94c1871fd https://huggingface.co/openai/whisper-large-v3-turbo/resolve/41f01f3fe87f28c78e2fbf8b568835947dd65ed9/tokenizer.json
VoiceWhisperTurbo whisper-large-v3-turbo/tokenizer_config.json 282843 844b642c73a91359722f47b35705f7174686df33d252695d8572cf9ac03a6389 https://huggingface.co/openai/whisper-large-v3-turbo/resolve/41f01f3fe87f28c78e2fbf8b568835947dd65ed9/tokenizer_config.json
VoiceWhisperSmall whisper-small/AudioEncoder.mlmodelc/analytics/coremldata.bin 243 63f3daf56b73dee3f019513d68549b65ee1273661ef158db81df53cbf147f65b https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/AudioEncoder.mlmodelc/analytics/coremldata.bin
VoiceWhisperSmall whisper-small/AudioEncoder.mlmodelc/coremldata.bin 408 beab8662c616661ddb4106205b33fbfe8f0430ea830e4171b74fc47a32c61a34 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/AudioEncoder.mlmodelc/coremldata.bin
VoiceWhisperSmall whisper-small/AudioEncoder.mlmodelc/metadata.json 1916 1991c30c501317181d65f9e09ebead153a4fce616383cbd717922fa0a6be3e65 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/AudioEncoder.mlmodelc/metadata.json
VoiceWhisperSmall whisper-small/AudioEncoder.mlmodelc/model.mil 2236845 91a89fdc750b8a4c7940adaba38aaaf95c0f5357484f4e96e78e021be8952418 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/AudioEncoder.mlmodelc/model.mil
VoiceWhisperSmall whisper-small/AudioEncoder.mlmodelc/weights/weight.bin 176323456 60b20a7f3655647a932bf99af3b86a8e6011162e39ceea2f7d16805449efdd2f https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/AudioEncoder.mlmodelc/weights/weight.bin
VoiceWhisperSmall whisper-small/MelSpectrogram.mlmodelc/analytics/coremldata.bin 243 d894dbee0f91be20fdf522594fc499e96dff3d62d606d2c32fb528ae9bc05af4 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/MelSpectrogram.mlmodelc/analytics/coremldata.bin
VoiceWhisperSmall whisper-small/MelSpectrogram.mlmodelc/coremldata.bin 389 24a861fa45a5542841af595b651d4f822b6b9766f4115ae4615717326f96972b https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/MelSpectrogram.mlmodelc/coremldata.bin
VoiceWhisperSmall whisper-small/MelSpectrogram.mlmodelc/metadata.json 1947 d9eeae745f667887f2e8d5f0eb07639a32bb46c6e3a3c973c19498bdd3936573 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/MelSpectrogram.mlmodelc/metadata.json
VoiceWhisperSmall whisper-small/MelSpectrogram.mlmodelc/model.mil 10132 cbd174733d72ad299fe427d1963116490f081999ded0b9fddc168f844bb51d6f https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/MelSpectrogram.mlmodelc/model.mil
VoiceWhisperSmall whisper-small/MelSpectrogram.mlmodelc/weights/weight.bin 354080 801024dbc7a89c677be1f8b285de3409e35f7d1786c9c8d9d0d6842ac57a1c83 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/MelSpectrogram.mlmodelc/weights/weight.bin
VoiceWhisperSmall whisper-small/TextDecoder.mlmodelc/analytics/coremldata.bin 243 0d62d98d2743526ff7c20c2e0b53516d05efb3b1bf2d772163a329e8471c2229 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/TextDecoder.mlmodelc/analytics/coremldata.bin
VoiceWhisperSmall whisper-small/TextDecoder.mlmodelc/coremldata.bin 694 3577d9aa102ce0b2d7d3fc4a16487c3048189128e6ca3108ec4d9a6a53cbd143 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/TextDecoder.mlmodelc/coremldata.bin
VoiceWhisperSmall whisper-small/TextDecoder.mlmodelc/metadata.json 4856 37865b0a1eed76fd6fb7dbccc48d56ba5dde0fc8221f87b69185961c014d9bc2 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/TextDecoder.mlmodelc/metadata.json
VoiceWhisperSmall whisper-small/TextDecoder.mlmodelc/model.mil 367298 06092e2c72412ccdbcaa80093b7c45376bc142ffe322179cbb8c18b23077edd2 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/TextDecoder.mlmodelc/model.mil
VoiceWhisperSmall whisper-small/TextDecoder.mlmodelc/weights/weight.bin 307287346 0f8eae40e08ccfed9613d821f6fc3f0a8aa46ebb9aca85fbcf7f2d555030d286 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/TextDecoder.mlmodelc/weights/weight.bin
VoiceWhisperSmall whisper-small/config.json 1456 12f8d45c3e5da28148d88d257684e77296e4d922009e1bc5289b05b756859422 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/config.json
VoiceWhisperSmall whisper-small/generation_config.json 2779 169e76633bb28ac383cdfaad2527e662d0d532a15f8437ce94c02c10bc713b71 https://huggingface.co/DictionLabs/whisperkit-coreml/resolve/c281d38c90f1fbfd307b328444480810c2e2bd10/openai_whisper-small/generation_config.json
VoiceWhisperSmall whisper-small/tokenizer.json 2480466 27fc476bfe7f17299480be2273fc0608e4d5a99aba2ab5dec5374b4482d1a566 https://huggingface.co/openai/whisper-small/resolve/973afd24965f72e36ca33b3055d56a652f456b4d/tokenizer.json
VoiceWhisperSmall whisper-small/tokenizer_config.json 282683 2a4c4281cf9f51ac6ccc406fdc711a087afe6530f671fa7b80953edc498275ce https://huggingface.co/openai/whisper-small/resolve/973afd24965f72e36ca33b3055d56a652f456b4d/tokenizer_config.json
VoiceNemotron nemotron-3.5-asr/decoder_joint.mlmodelc/analytics/coremldata.bin 243 8a8e98a54ed1f16c3d5125816a002b991e167d620beb8fcc557f26d9a1c092f8 https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/resolve/1a41b75758b0337ff67db7d5408280aaaf23074e/multilingual/2240ms/decoder_joint.mlmodelc/analytics/coremldata.bin
VoiceNemotron nemotron-3.5-asr/decoder_joint.mlmodelc/coremldata.bin 454 6404b542fb5d5faa79648fc96a79a0b981cbd087df0378adefd1f45ae56dd86e https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/resolve/1a41b75758b0337ff67db7d5408280aaaf23074e/multilingual/2240ms/decoder_joint.mlmodelc/coremldata.bin
VoiceNemotron nemotron-3.5-asr/decoder_joint.mlmodelc/model.mil 15801 62144df8c1928d571c1df508a576f2d574a6bd6b1f2dba7f3f15cf9605805d6a https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/resolve/1a41b75758b0337ff67db7d5408280aaaf23074e/multilingual/2240ms/decoder_joint.mlmodelc/model.mil
VoiceNemotron nemotron-3.5-asr/decoder_joint.mlmodelc/weights/weight.bin 48782272 01f21eb747fbc53bd0ed7efebea1bf0aa655ebf2816f21d0bb6554c9b7fcfc0b https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/resolve/1a41b75758b0337ff67db7d5408280aaaf23074e/multilingual/2240ms/decoder_joint.mlmodelc/weights/weight.bin
VoiceNemotron nemotron-3.5-asr/encoder.mlmodelc/analytics/coremldata.bin 243 af569fd95237bdf8b91d38094691bfc990fcf3534316fa615bac5964c02809e4 https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/resolve/1a41b75758b0337ff67db7d5408280aaaf23074e/multilingual/2240ms/encoder.mlmodelc/analytics/coremldata.bin
VoiceNemotron nemotron-3.5-asr/encoder.mlmodelc/coremldata.bin 573 d5471a4edf55ce02dab51e5d01c86b419a7659bcdd6aac216ba6f0b795eae8bf https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/resolve/1a41b75758b0337ff67db7d5408280aaaf23074e/multilingual/2240ms/encoder.mlmodelc/coremldata.bin
VoiceNemotron nemotron-3.5-asr/encoder.mlmodelc/model.mil 1010788 3ee65463908bbc06c92691ea9172499aea3f7ae4ba619d39783c4a639936fae5 https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/resolve/1a41b75758b0337ff67db7d5408280aaaf23074e/multilingual/2240ms/encoder.mlmodelc/model.mil
VoiceNemotron nemotron-3.5-asr/encoder.mlmodelc/weights/weight.bin 565336640 2e00be98049a22e095452c020f183d2b23728e145cc814ba031436931b4f2e8f https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/resolve/1a41b75758b0337ff67db7d5408280aaaf23074e/multilingual/2240ms/encoder.mlmodelc/weights/weight.bin
VoiceNemotron nemotron-3.5-asr/metadata.json 3005 070ae181941003ff3e7d7ff8e5c5d47aebd026e8458549cef0c9a6803dbec004 https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/resolve/1a41b75758b0337ff67db7d5408280aaaf23074e/multilingual/2240ms/metadata.json
VoiceNemotron nemotron-3.5-asr/tokenizer.json 284969 fb70c8fcb6472cda2bdb799b156a8941e72762344a7c636d3b1275f1d53c4a6b https://huggingface.co/FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML/resolve/1a41b75758b0337ff67db7d5408280aaaf23074e/multilingual/2240ms/tokenizer.json
FILES
[ "$FOUND" = 1 ] || { echo "Unknown pack: $PACK" >&2; exit 1; }
# The model's license travels with its weights (OpenMDW-1.1 requires it for Nemotron).
case "$PACK" in
    VoiceWhisperTurbo) cp "$LICENSES/Whisper-MIT.txt" files/whisper-large-v3-turbo/LICENSE.txt ;;
    VoiceWhisperSmall) cp "$LICENSES/Whisper-MIT.txt" files/whisper-small/LICENSE.txt ;;
    VoiceNemotron) cp "$LICENSES/OpenMDW-1.1.txt" files/nemotron-3.5-asr/LICENSE.txt ;;
esac
for license in files/*/LICENSE.txt; do
    [ -f "$license" ] && SELECTORS="$SELECTORS,
        { \"file\": \"${license#files/}\" }"
done
cat > Manifest.json <<JSON
{
    "assetPackID": "$PACK",
    "downloadPolicy": { "onDemand": {} },
    "fileSelectors": [
$SELECTORS
    ],
    "platforms": ["iOS"],
    "sourceRoot": "files"
}
JSON
xcrun ba-package Manifest.json -o "$PWD/$PACK.aar"
echo "$PWD/$PACK.aar"

import Foundation
import Testing
@testable import VoiceText

struct VoiceEngineChoiceTests {
    @Test func keepsTheStoredEngineWhileUsable() {
        #expect(VoiceEngineChoice.resolve(stored: .whisperSmall, usable: [.apple, .whisperSmall], downloaded: []) == .whisperSmall)
    }

    @Test func defaultsToApple() {
        #expect(VoiceEngineChoice.resolve(stored: nil, usable: [.apple, .lfm, .whisperTurbo], downloaded: []) == .apple)
    }

    @Test func anOwnerWithLFMDownloadedKeepsIt() {
        #expect(VoiceEngineChoice.resolve(stored: nil, usable: [.apple, .lfm], downloaded: [.lfm]) == .lfm)
    }

    @Test func fallsBackWhenTheStoredEngineIsGone() {
        #expect(VoiceEngineChoice.resolve(stored: .nemotron, usable: [.apple, .nemotron], downloaded: []) == .nemotron)
        #expect(VoiceEngineChoice.resolve(stored: .nemotron, usable: [.apple], downloaded: [.nemotron]) == .apple)
        #expect(VoiceEngineChoice.resolve(stored: .apple, usable: [.lfm, .whisperSmall], downloaded: [.whisperSmall]) == .whisperSmall)
        #expect(VoiceEngineChoice.resolve(stored: .apple, usable: [.lfm, .whisperSmall], downloaded: []) == .lfm)
        #expect(VoiceEngineChoice.resolve(stored: .apple, usable: [], downloaded: [.lfm]) == nil)
    }
}

struct VoiceCatalogTests {
    private let models: [VoiceModelSpec] = VoiceEngineID.allCases.compactMap(\.model)

    @Test func lfmIsUnchanged() {
        #expect(VoiceModelSpec.lfm.packID == "VoiceModel")
        #expect(VoiceModelSpec.lfm.folder.isEmpty)
        #expect(VoiceModelSpec.lfm.files.map(\.path) == ["LFM3-Audio-2B-Q4_K_M.gguf", "mmproj-LFM3-Audio-2B-Q8_0.gguf"])
        #expect(VoiceModelSpec.lfm.totalBytes == 1_437_488_096)
    }

    @Test func everyFileIsPinned() {
        for model in models {
            #expect(Set(model.files.map(\.path)).count == model.files.count)
            for file in model.files {
                #expect(file.revision.count == 40 && file.revision.allSatisfy(\.isHexDigit))
                #expect(file.sha256.count == 64 && file.sha256.allSatisfy(\.isHexDigit))
                #expect(file.bytes > 0)
            }
        }
        #expect(Set(models.map(\.packID)).count == models.count)
        #expect(Set(models.map(\.folder)).count == models.count)
    }

    /// scripts/voice_asset_pack.sh builds the packs from its own copy of the file list.
    @Test func packScriptMatchesTheCatalogue() throws {
        let script = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../../scripts/voice_asset_pack.sh").standardized
        let text = try String(contentsOf: script, encoding: .utf8)
        guard let start = text.range(of: "<<FILES\n"), let end = text.range(of: "\nFILES\n") else {
            Issue.record("No file list in \(script.path)")
            return
        }
        let lines = text[start.upperBound..<end.lowerBound].split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
        let expected = models.flatMap { model in
            model.files.map { [model.packID, model.location(of: $0), String($0.bytes), $0.sha256, $0.url.absoluteString] }
        }
        #expect(lines == expected)
    }
}

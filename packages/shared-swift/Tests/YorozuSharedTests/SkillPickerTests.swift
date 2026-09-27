import Foundation
import Testing

@testable import YorozuShared

private let skills = [
    SkillOption(name: "prepare", description: ""),
    SkillOption(name: "release-notes", description: "", argumentHint: "[version]"),
    SkillOption(name: "Review", description: ""),
    SkillOption(name: "summarize", description: ""),
]

@Test(arguments: [
    ("/", ["prepare", "release-notes", "Review", "summarize"]),
    ("/re", ["release-notes", "Review", "prepare"]),
    ("/REV", ["Review"]),
    ("/zz", []),
    ("/Review ", []),
    ("/re\n", []),
    ("see /re", []),
    (" /re", []),
    ("", []),
])
func aDraftThatIsOneSlashCommandOffersTheSkillsItNames(draft: String, names: [String]) {
    #expect(skillMatches(for: draft, in: skills).map(\.name) == names)
}

#if os(macOS)
    import AppKit

    @Test func thePickerTakesOnlyItsOwnUnmodifiedKeys() {
        #expect(skillPickerKey(keyCode: 126, flags: [.numericPad, .function], composing: false) == .up)
        #expect(skillPickerKey(keyCode: 125, flags: [.numericPad, .function], composing: false) == .down)
        #expect(skillPickerKey(keyCode: 36, flags: [], composing: false) == .select)
        #expect(skillPickerKey(keyCode: 48, flags: [], composing: false) == .select)
        #expect(skillPickerKey(keyCode: 53, flags: [], composing: false) == .dismiss)
        // ⌘Return is still Send's, ⇧Tab still moves focus, and an input method keeps its keys.
        #expect(skillPickerKey(keyCode: 36, flags: .command, composing: false) == nil)
        #expect(skillPickerKey(keyCode: 48, flags: .shift, composing: false) == nil)
        #expect(skillPickerKey(keyCode: 36, flags: [], composing: true) == nil)
        #expect(skillPickerKey(keyCode: 0, flags: [], composing: false) == nil)
    }
#endif

import SwiftUI
import VoiceText

enum Diagnostics {
    static let subsystem = "to.yumi.yorozu"
}

struct VoiceInputSection: View {
    var body: some View { EmptyView() }
}

extension VoiceDictionary {
    static var stored: VoiceDictionary { VoiceDictionary() }
}

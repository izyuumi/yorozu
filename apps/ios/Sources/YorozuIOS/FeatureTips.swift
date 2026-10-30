import SwiftUI
import TipKit

/// One-time TipKit hints that point at a new feature where it lives; each goes away once the feature is used.
enum FeatureTips {
    static func configure() {
        try? Tips.configure([.displayFrequency(.daily)])
    }
}

struct VoiceInputTip: Tip {
    var title: Text { Text("Speak a message") }
    var message: Text? { Text("Tap the mic and talk. Stop to edit the text first, or send it right away.") }
    var image: Image? { Image(systemName: "mic") }
    var options: [any TipOption] { [MaxDisplayCount(1)] }
}

struct VoiceSetupTip: Tip {
    var title: Text { Text("Voice input") }
    var message: Text? { Text("Turn it on in Settings to speak messages. Speech is transcribed on this device.") }
    var image: Image? { Image(systemName: "waveform") }
    var options: [any TipOption] { [MaxDisplayCount(1)] }
}

struct ReactTip: Tip {
    var title: Text { Text("React to a reply") }
    var message: Text? { Text("Add an emoji to a message. The agent sees it on its next turn.") }
    var image: Image? { Image(systemName: "face.smiling") }
    var options: [any TipOption] { [MaxDisplayCount(1)] }
}

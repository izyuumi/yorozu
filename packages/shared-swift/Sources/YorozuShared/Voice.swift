import AVFoundation
import SwiftUI

/// Reads replies aloud using the system voice. Composer dictation is provided by the system
/// keyboard, so this module does not access speech recognition or microphone APIs.

/// Reads a reply aloud. One utterance at a time, app-wide: a second Listen replaces the first
/// rather than talking over it.
@MainActor
@Observable
public final class Speaker {
    public static let shared = Speaker()

    /// The id of the message being read, or nil. What draws the chip on the bubble.
    public private(set) var speakingId: String?

    private let synthesizer = AVSpeechSynthesizer()
    private let relay = Relay()

    private init() {
        synthesizer.delegate = relay
        relay.onEnd = { [weak self] in self?.speakingId = nil }
    }

    public func speak(_ text: String, id: String) {
        stop()
        let utterance = AVSpeechUtterance(string: spoken(text))
        // The system voice for whatever the reader reads in, which is the one they have already
        // chosen in Settings and the only one guaranteed to be installed.
        utterance.voice = AVSpeechSynthesisVoice(
            language: Locale.preferredLanguages.first ?? Locale.current.identifier
        )
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        speakingId = id
        synthesizer.speak(utterance)
    }

    public func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speakingId = nil
    }

    /// Markdown read aloud is a stream of asterisks and backticks, so the markers come out
    /// before it is spoken. The words are all the synthesiser was ever going to use.
    private func spoken(_ text: String) -> String {
        String(text.unicodeScalars.filter { !"*_`#>|~".unicodeScalars.contains($0) })
    }

    /// `AVSpeechSynthesizer` wants an `NSObject` delegate, which an `@Observable` class is not.
    /// Kept here rather than exposed: it exists only to say "it stopped".
    @MainActor
    private final class Relay: NSObject, AVSpeechSynthesizerDelegate {
        var onEnd: (() -> Void)?

        nonisolated func speechSynthesizer(
            _: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance
        ) {
            Task { @MainActor in self.onEnd?() }
        }

        nonisolated func speechSynthesizer(
            _: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance
        ) {
            Task { @MainActor in self.onEnd?() }
        }
    }
}

/// The chip on a bubble that is being read aloud: what is happening, and the way to stop it.
public struct SpeakingChip: View {
    public init() {}

    public var body: some View {
        Button {
            Speaker.shared.stop()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "waveform")
                    .symbolEffect(.variableColor.iterative, options: .repeating)
                Text("Speaking")
                Image(systemName: "stop.fill")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minHeight: 28)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .background(.tint.opacity(0.12), in: Capsule())
        .accessibilityLabel("Stop reading aloud")
    }
}

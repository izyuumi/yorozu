#if canImport(Speech)
import AVFoundation
import Foundation
import Speech

@available(iOS 26, macOS 26, *)
public final class AppleSpeechEngine: SpeechEngine {
    private let locale: Locale

    public init(locale: Locale) async throws {
        guard await AppleSpeech.status(for: locale) == .installed else { throw SpeechEngineError.languageUnavailable }
        self.locale = locale
    }

    public func transcribe(_ samples: [Float], language: String?, hints: [String]) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !hints.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = hints
            try await analyzer.setContext(context)
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let buffer = Self.buffer(samples, in: format) else { throw SpeechEngineError.modelUnavailable }
        let collected = Task {
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        let (input, feed) = AsyncStream<AnalyzerInput>.makeStream()
        feed.yield(AnalyzerInput(buffer: buffer))
        feed.finish()
        do {
            if let end = try await analyzer.analyzeSequence(input) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collected.cancel()
            throw error
        }
        return try await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func buffer(_ samples: [Float], in format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty, let source = AVAudioFormat(standardFormatWithSampleRate: Double(speechSampleRate), channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if format == source { return input }
        guard let converter = AVAudioConverter(from: source, to: format) else { return nil }
        let capacity = AVAudioFrameCount((Double(samples.count) * format.sampleRate / source.sampleRate).rounded(.up)) + 1_024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .endOfStream
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return input
        }
        return error == nil ? output : nil
    }
}

@available(iOS 26, macOS 26, *)
public enum AppleSpeech {
    public enum Status: Equatable, Sendable {
        case unsupported, notInstalled, downloading, installed
    }

    public static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    public static func locale(for code: String?) async -> Locale? {
        await SpeechTranscriber.supportedLocale(equivalentTo: code.map { Locale(identifier: $0) } ?? Locale.current)
    }

    public static func languageCodes() async -> Set<String> {
        Set(await SpeechTranscriber.supportedLocales.compactMap { $0.language.languageCode?.identifier })
    }

    public static func status(for locale: Locale) async -> Status {
        switch await AssetInventory.status(forModules: [SpeechTranscriber(locale: locale, preset: .transcription)]) {
        case .installed: .installed
        case .downloading: .downloading
        case .supported: .notInstalled
        default: .unsupported
        }
    }

    public static func install(_ locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        let modules = [SpeechTranscriber(locale: locale, preset: .transcription)]
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { item, _ in
            progress(item.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
    }
}
#endif

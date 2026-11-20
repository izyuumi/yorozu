import Foundation
import Observation
import SpeechEngines
import VoiceText

@MainActor @Observable
final class VoiceSetup {
    static let shared = VoiceSetup()

    private(set) var engine: VoiceEngineID?
    let apple = AppleSpeechAssets()

    private init() {
        engine = resolve()
        Task { await apple.refresh() }
    }

    static func compiled(_ engine: VoiceEngineID) -> Bool {
        switch engine {
        case .lfm: Transcriber.available
        case .apple, .whisperTurbo, .whisperSmall, .nemotron: true
        }
    }

    static func unsupportedReason(_ engine: VoiceEngineID) -> String? {
        if engine == .apple {
            guard #available(iOS 26, macOS 26, *) else {
                #if os(iOS)
                return String(localized: "Needs iOS 26 or later.")
                #else
                return String(localized: "Needs macOS 26 or later.")
                #endif
            }
            return AppleSpeech.isAvailable ? nil : String(localized: "Not available on this device.")
        }
        if !VoiceModel.appleHosting { return String(localized: "Needs iOS 26 or later.") }
        #if !arch(arm64)
        if engine == .nemotron { return String(localized: "Needs a Mac with Apple silicon.") }
        #endif
        if ProcessInfo.processInfo.physicalMemory < engine.minimumMemory {
            return String(localized: "Needs a device with \(engine.memoryGB ?? 0) GB of memory or more.")
        }
        return nil
    }

    static func usable(_ engine: VoiceEngineID) -> Bool { compiled(engine) && unsupportedReason(engine) == nil }

    static var listed: [VoiceEngineID] { VoiceEngineID.allCases.filter(compiled) }

    static var supported: Bool {
        #if DEBUG
        if PreviewScene.transcript != nil { return true }
        #endif
        return VoiceEngineID.allCases.contains(where: usable)
    }

    var model: VoiceModel? { engine.flatMap { VoiceModel.all[$0] } }

    var ready: Bool {
        #if DEBUG
        if PreviewScene.transcript != nil { return true }
        #endif
        guard let engine else { return false }
        return engine == .apple ? apple.state == .ready : model?.state == .ready
    }

    func refresh() {
        engine = resolve()
        let defaults = UserDefaults.standard
        let language = VoiceLanguage(rawValue: defaults.string(forKey: VoiceModel.languageKey) ?? "") ?? .automatic
        if let languages = engine?.languages, !languages.contains(language) {
            defaults.set(VoiceLanguage.automatic.rawValue, forKey: VoiceModel.languageKey)
        }
        Task { await apple.refresh() }
    }

    func prepare(cellular: Bool = false) {
        if engine == .apple {
            Task {
                await apple.refresh()
                apple.install()
            }
        } else {
            model?.start(cellular: cellular)
        }
    }

    func pause() { model?.pause() }

    func load() -> Task<any SpeechEngine, Error> {
        let language = VoiceLanguage(rawValue: UserDefaults.standard.string(forKey: VoiceModel.languageKey) ?? "") ?? .automatic
        switch engine {
        case .lfm?:
            let model = VoiceModel.all[.lfm]!
            let (weights, projector) = (model.url(of: model.spec.files[0]), model.url(of: model.spec.files[1]))
            return Task.detached(priority: .userInitiated) { try Transcriber(model: weights, projector: projector) }
        case .whisperTurbo?, .whisperSmall?:
            let folder = model!.folderURL
            return Task.detached(priority: .userInitiated) { try await WhisperSpeechEngine(folder: folder) }
        case .nemotron?:
            let folder = model!.folderURL
            return Task.detached(priority: .userInitiated) { try await NemotronSpeechEngine(folder: folder) }
        case .apple?:
            return Task.detached(priority: .userInitiated) {
                guard #available(iOS 26, macOS 26, *), let locale = await AppleSpeech.locale(for: language.code) else {
                    throw SpeechEngineError.languageUnavailable
                }
                return try await AppleSpeechEngine(locale: locale)
            }
        case nil:
            return Task { throw VoiceModel.Failure(String(localized: "Voice input isn’t available on this device.")) }
        }
    }

    private func resolve() -> VoiceEngineID? {
        let stored = UserDefaults.standard.string(forKey: VoiceModel.engineKey).flatMap(VoiceEngineID.init(rawValue:))
        let usable = VoiceEngineID.allCases.filter(Self.usable)
        let downloaded = Set(usable.filter { VoiceModel.all[$0]?.state == .ready })
        let choice = VoiceEngineChoice.resolve(stored: stored, usable: usable, downloaded: downloaded)
        if stored == nil, choice == .lfm { UserDefaults.standard.set(VoiceEngineID.lfm.rawValue, forKey: VoiceModel.engineKey) }
        return choice
    }
}

@MainActor @Observable
final class AppleSpeechAssets {
    enum State: Equatable {
        case unknown
        case unsupported
        case absent
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var state = State.unknown
    private(set) var languages: Set<String> = []
    private(set) var automaticName = ""

    func refresh() async {
        guard #available(iOS 26, macOS 26, *), AppleSpeech.isAvailable else { return state = .unsupported }
        if case .downloading = state { return }
        if languages.isEmpty { languages = await AppleSpeech.languageCodes() }
        if let locale = await AppleSpeech.locale(for: nil) {
            automaticName = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        }
        guard let locale = await AppleSpeech.locale(for: Self.language.code) else { return state = .unsupported }
        state = switch await AppleSpeech.status(for: locale) {
        case .installed: .ready
        case .downloading: .downloading(0)
        case .notInstalled: .absent
        case .unsupported: .unsupported
        }
    }

    func install() {
        guard #available(iOS 26, macOS 26, *) else { return }
        switch state {
        case .absent, .failed: break
        default: return
        }
        state = .downloading(0)
        Task {
            do {
                guard let locale = await AppleSpeech.locale(for: Self.language.code) else { return state = .unsupported }
                try await AppleSpeech.install(locale) { fraction in
                    Task { @MainActor in if case .downloading = self.state { self.state = .downloading(fraction) } }
                }
                state = .absent
                await refresh()
            } catch {
                state = .failed(String(localized: "The language couldn’t be downloaded. Try again."))
            }
        }
    }

    private static var language: VoiceLanguage {
        VoiceLanguage(rawValue: UserDefaults.standard.string(forKey: VoiceModel.languageKey) ?? "") ?? .automatic
    }
}

extension SpeechEngineError: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .modelUnavailable: String(localized: "The voice model could not be loaded.")
        case .languageUnavailable: String(localized: "Apple Speech can’t transcribe this language on this device yet. Pick another language or model in Settings › Voice Input.")
        case .unsupportedHardware: String(localized: "Needs a Mac with Apple silicon.")
        }
    }
}

#if DEBUG
import AVFoundation
import Foundation
import YorozuWire
#if os(iOS)
import UIKit
#endif

/// Debug builds only: `--preview-scene NAME` (implies `--demo`) plays one scripted take of the App Store app preview
/// (`apps/preview`) through the real UI and the real send path. Release builds contain none of it (Guideline 2.5.19).
/// Times are take seconds: the app writes `Caches/preview-ready` once it is active, and
/// `scripts/app_preview_capture.sh` starts recording `lead` seconds later (the Lock Screen
/// takes: 6 s more, while the app goes home and the device locks).
enum PreviewScene: String {
    case hook, lockscreen, approve, talk, list
    /// The lockscreen take again with Tidy up Downloads already needing you: a locked simulator suspends the app,
    /// so the preview dissolves from one take to the other instead of the app changing the row while locked.
    case needsYou = "needs-you"

    /// The Lock Screen takes, which start a Live Activity in demo mode.
    var locked: Bool { self == .lockscreen || self == .needsYou }

    static let current: PreviewScene? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--preview-scene"), arguments.indices.contains(index + 1) else { return nil }
        return PreviewScene(rawValue: arguments[index + 1])
    }()

    /// `--preview-epoch UNIX`: both Lock Screen takes date their rows from it, so they match across the dissolve.
    private static let epoch: Date = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--preview-epoch"), arguments.indices.contains(index + 1),
              let seconds = TimeInterval(arguments[index + 1]) else { return Date() }
        return Date(timeIntervalSince1970: seconds)
    }()

    static let lead: Double = 2.5
    static let readyFile = "preview-ready"
    private static var caches: URL? { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first }
    /// The composer's mic and send buttons, pressed by the scene.
    static let tapMic = Notification.Name("PreviewScene.tapMic")
    static let tapSend = Notification.Name("PreviewScene.tapSend")

    private static let ja = Locale.preferredLanguages.first?.hasPrefix("ja") == true

    /// DemoTransport's pauses (delivered, tool running, tool done, reply), stretched so each beat reads in the take.
    var pauses: [Duration] {
        self == .hook
            ? [.milliseconds(600), .milliseconds(1_000), .milliseconds(1_600), .milliseconds(300)]
            : [.milliseconds(300), .milliseconds(300), .milliseconds(1_200), .milliseconds(200)]
    }

    // MARK: Demo content (fictional)

    static let tidyID = "d0000000-0000-4000-8000-000000000005"
    static var tidyTitle: String { ja ? "ダウンロードの整理" : "Tidy up Downloads" }
    static var tidy: [(HistoryItem.Kind, String)] {
        ja ? [(.user, "ダウンロードフォルダを整理して"), (.agent, "ダウンロードに重複したフォルダが 3 つありました。ゴミ箱に移しますか？")]
            : [(.user, "Tidy up my Downloads folder"), (.agent, "I found 3 duplicate folders in Downloads. Move them to the Trash?")]
    }

    private static var ask: String { ja ? "昨夜のバックアップは終わった？" : "Did last night’s backup finish?" }
    private static var goAhead: String { ja ? "お願い" : "Go ahead" }
    /// What the talk take's recording "says": the capture script speaks it into `preview-voice.wav` with `say`.
    static var transcript: String? {
        current == .talk ? (ja ? "6時に植物に水をやるようリマインドして" : "Remind me to water the plants at 6") : nil
    }

    static func reply(to text: String) -> String? {
        let replies: [(keywords: [String], text: String)] = ja ? [
            (["バックアップ"], "はい。午前 3:12 に終わり、変更された 4,812 個のファイルを外付けドライブにコピーしました。空き容量はまだ 212 GB あります。"),
            (["お願い"], "完了しました。3 つのフォルダをゴミ箱に移しました。"),
            (["リマインド"], "わかりました。午後 6:00 にお知らせします。"),
        ] : [
            (["backup"], "Yes. It finished at 3:12 AM and copied 4,812 changed files to the external drive. 212 GB is still free."),
            (["go ahead"], "Done. Moved 3 folders to the Trash."),
            (["remind"], "Okay. I’ll remind you at 6:00 PM."),
        ]
        let text = text.lowercased()
        return replies.first { $0.keywords.contains { text.contains($0) } }?.text
    }

    /// The talk take's microphone: 16 kHz mono float samples from `Caches/preview-voice.wav`, else silence.
    static func voiceClip() -> [Float] {
        guard let caches,
              let file = try? AVAudioFile(forReading: caches.appending(path: "preview-voice.wav")),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil, let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    /// Tells the capture script the app is up: a first launch on a fresh boot takes seconds longer.
    private static func markReady() {
        guard let caches else { return }
        FileManager.default.createFile(atPath: caches.appending(path: readyFile).path(), contents: Data())
    }

    // MARK: The scenes

    @MainActor func play(model: AppModel) {
        func tap(_ button: Notification.Name) { NotificationCenter.default.post(name: button, object: nil) }
        // The throwaway simulator's setting: the mic button only in the talk take.
        UserDefaults.standard.set(self == .talk, forKey: VoiceModel.enabledKey)
        Task { @MainActor in
            #if os(iOS)
            while UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .milliseconds(50)) }
            #endif
            let launched = ContinuousClock.now
            Self.markReady()
            func at(_ seconds: Double) async {
                try? await Task.sleep(until: launched + .seconds(Self.lead + seconds), clock: .continuous)
            }
            switch self {
            case .hook:
                let convId = WireEvent.newId()
                model.textDrafts[convId] = Self.ask
                model.requestedConversation = convId
                await at(1.2)
                tap(Self.tapSend)
            case .approve:
                model.textDrafts[Self.tidyID] = Self.goAhead
                model.requestedConversation = Self.tidyID
                await at(1.0)
                tap(Self.tapSend)
            case .talk:
                model.requestedConversation = WireEvent.newId()
                await at(0.6)
                tap(Self.tapMic)
                await at(4.0)
                tap(Self.tapSend)
            case .lockscreen, .needsYou:
                #if os(iOS)
                await lockscreen(at)
                #else
                break
                #endif
            case .list:
                break
            }
        }
    }

    #if os(iOS)
    /// Two Working rows and a Done one (needs-you: Tidy up Downloads needs you); the app goes home, where the
    /// activity starts, and the device locks.
    @MainActor private func lockscreen(_ at: (Double) async -> Void) async {
        WidgetStore.defaults?.set(true, forKey: WidgetStore.previewsKey)
        await at(-0.5)
        while YorozuActivities.shared == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let activities = YorozuActivities.shared else { return }
        let titles = DemoData.titles
        let epoch = Self.epoch
        activities.upsert(self == .needsYou ? YorozuJob(kind: .needsYou, startedAt: epoch.addingTimeInterval(-10))
                : YorozuJob(kind: .turn, steps: 3, startedAt: epoch.addingTimeInterval(-130)),
            convId: Self.tidyID, title: Self.tidyTitle)
        activities.upsert(YorozuJob(kind: .turn, steps: 1, startedAt: epoch.addingTimeInterval(-65)),
            convId: DemoData.travelID, title: titles[DemoData.travelID])
        activities.upsert(YorozuJob(kind: .turn, state: .done, startedAt: epoch.addingTimeInterval(-300), finishedAt: epoch.addingTimeInterval(-20)),
            convId: DemoData.welcomeID, title: titles[DemoData.welcomeID])
    }
    #endif
}
#endif

import AppKit
import Sparkle
import SwiftUI
import YorozuKeepalive
import YorozuShared

/// Sparkle, whole. The feed URL and the public EdDSA key live in `Info.plist`, written by
/// `scripts/build-mac.sh`; a build without them (`swift run`, the dev bundle) has no feed
/// to check, so the updater is not started and the menu item is not shown rather than
/// greeting the user with Sparkle's "update feed URL is not set" alert.
@MainActor
enum Updates {
    /// Marks that this build has already forced the automatic-update preferences on. Sparkle
    /// persists those in the host's user defaults, so a Mac that answered "no" to the older
    /// build's "check for updates automatically?" prompt would otherwise keep answering no
    /// forever — the Info.plist keys only supply an initial value, and there already is one.
    private static let configuredKey = "YorozuUpdatesConfigured"
    private static let betaKey = "YorozuBetaUpdates"
    static let betaFeedURL = "https://yorozu.yumi.to/beta/appcast.xml"

    static let controller: SPUStandardUpdaterController? = {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return nil }
        let controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: delegate)
        if !UserDefaults.standard.bool(forKey: configuredKey) {
            controller.updater.automaticallyChecksForUpdates = true
            controller.updater.automaticallyDownloadsUpdates = true
            controller.updater.updateCheckInterval = 3600
            UserDefaults.standard.set(true, forKey: configuredKey)
        }
        return controller
    }()

    private static let delegate = UpdaterDelegate()
    static let pending = PendingUpdate()
    static let checkResult = UpdateCheckResult()

    /// Set while Sparkle is installing and about to relaunch us. Quitting for an update is not
    /// the user quitting, so it must not pause the watchdog — see ``AppDelegate``.
    static var installing = false

    /// Touches `controller`, which is what starts the updater and its hourly schedule, and
    /// starts saying in the log what that schedule is actually doing.
    static func start() {
        _ = controller
        logStatus()
        // Sparkle's own scheduling is opaque from the outside: this Mac was three releases
        // behind with a last-check time eight hours old and nothing anywhere said why. An
        // hourly line is what turns "it stopped updating" into a thing that can be read.
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            MainActor.assumeIsolated { logStatus() }
        }
    }

    /// One line: whether a check can run, when the last one did, and if it cannot, why not.
    /// A check that is overdue by more than an interval is also nudged — the log is there to
    /// explain the silence, not to keep a tidy record of it.
    static func logStatus() {
        guard let updater = controller?.updater else {
            Log.write("updates: no SUFeedURL in this build, updater not started")
            return
        }
        let last = updater.lastUpdateCheckDate
        let age = last.map { "\(Int(Date().timeIntervalSince($0)))s ago" } ?? "never"
        Log.write(
            "updates: canCheck=\(updater.canCheckForUpdates) checks=\(updater.automaticallyChecksForUpdates) "
                + "downloads=\(updater.automaticallyDownloadsUpdates) "
                + "interval=\(Int(updater.updateCheckInterval))s lastCheck=\(age)"
        )
        guard updater.canCheckForUpdates else {
            Log.write(
                "updates: no check now — "
                    + (updater.sessionInProgress ? "one is already running" : "the updater is not ready")
            )
            return
        }
        guard updater.automaticallyChecksForUpdates else {
            Log.write("updates: no check now — automatic checks are turned off")
            return
        }
        let overdue = last.map { Date().timeIntervalSince($0) > updater.updateCheckInterval * 2 } ?? true
        if overdue {
            Log.write("updates: last check is overdue, checking now")
            updater.checkForUpdatesInBackground()
        }
    }

    /// The Settings toggle. Reading and writing Sparkle's own property rather than a second
    /// preference of ours: Sparkle persists it, and two places to store one fact is one place
    /// too many.
    static var automatic: Bool {
        get { controller?.updater.automaticallyDownloadsUpdates ?? false }
        set {
            controller?.updater.automaticallyChecksForUpdates = newValue
            controller?.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    static var beta: Bool {
        get { UserDefaults.standard.bool(forKey: betaKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: betaKey)
            if controller?.updater.canCheckForUpdates == true {
                controller?.updater.checkForUpdatesInBackground()
            }
        }
    }
}

@MainActor @Observable
final class PendingUpdate {
    private(set) var status = UpdateStatusData(phase: .none)
    private(set) var failure: String?
    private var handler: (() -> Void)?
    private var timer: Timer?
    private var requestId: String?
    private var cancellationId: String?
    private var cancellationRequestId: String?
    private var lastTick = Date.distantPast
    private var preparing = false
    private var installStarted = false
    private var postponedUntil: Double {
        get { UserDefaults.standard.double(forKey: "updatePostponedUntil") }
        set { UserDefaults.standard.set(newValue, forKey: "updatePostponedUntil") }
    }

    func queue(version: String, handler: @escaping () -> Void) {
        if status.phase == .none {
            status = UpdateStatusData(phase: .unknown, updateId: UUID().uuidString, version: version)
        }
        self.handler = handler
        startTimer()
        tick()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let session = MacChatSession.shared
        if session.role != .host { cancellationId = nil; cancellationRequestId = nil }
        if let cancellationId, session.role == .host {
            guard session.model.state == .paired && session.model.ownerOnline else { return }
            cancellationRequestId = session.model.updateControl(.cancel, updateId: cancellationId)
            return
        }
        guard handler != nil, !preparing else { return }
        let now = Date()
        defer { lastTick = now }
        if session.role == .host {
            guard session.model.state == .paired && session.model.ownerOnline else {
                status.phase = .unknown
                status.deadline = nil
                requestId = nil
                return
            }
            requestId = session.model.updateControl(.queue, updateId: status.updateId, version: status.version)
        } else {
            if postponedUntil > now.timeIntervalSince1970 * 1000 {
                status.phase = .postponed
                status.postponedUntil = postponedUntil
                return
            }
            if status.phase != .countdown || now.timeIntervalSince(lastTick) > 3 {
                status.phase = .countdown
                status.deadline = (now.timeIntervalSince1970 + 10) * 1000
            }
            if now.timeIntervalSince1970 * 1000 >= (status.deadline ?? .infinity) { install() }
        }
    }

    func receive(_ status: UpdateStatusData, from model: ChatModel) {
        guard MacChatSession.shared.role == .host, model === MacChatSession.shared.model,
              model.state == .paired && model.ownerOnline else { return }
        if cancellationId != nil, status.phase == .none, status.requestId == cancellationRequestId {
            cancellationId = nil
            cancellationRequestId = nil
            if handler == nil { timer?.invalidate() }
            else { tick() }
            return
        }
        guard cancellationId == nil, status.updateId == self.status.updateId, handler != nil else { return }
        self.status = status
        if let until = status.postponedUntil { postponedUntil = until }
        if status.phase == .installing, status.requestId == requestId,
           model.state == .paired && model.ownerOnline { install() }
    }

    func postpone() {
        guard status.phase != .installing else { return }
        if MacChatSession.shared.role == .host {
            MacChatSession.shared.model.updateControl(.postpone)
        } else {
            postponedUntil = (Date().timeIntervalSince1970 + 3600) * 1000
            status.phase = .postponed
            status.deadline = nil
            status.postponedUntil = postponedUntil
        }
    }

    private func install() {
        guard !preparing, !installStarted, handler != nil else { return }
        preparing = true
        defer { preparing = false }
        do {
            try MacChatSession.shared.saveForRestart()
            UserDefaults.standard.set(!HostWindowMode.active && WindowPresence.isOpen,
                forKey: "restoreChatAfterUpdate")
            if HostWindowMode.active {
                UserDefaults.standard.set(true, forKey: HostWindowMode.updateRelaunchKey)
            }
            status.phase = .installing
            Updates.installing = true
            installStarted = true
            failure = nil
            timer?.invalidate()
            handler?()
        } catch {
            retryAfterSnapshotFailure(error)
        }
    }

    func retryAfterSnapshotFailure(_ error: Error) {
        let version = status.version ?? ""
        let retryHandler = handler
        cancel()
        failure = "Update waiting: could not save drafts. \(error.localizedDescription)"
        Log.write(failure!)
        if let retryHandler { queue(version: version, handler: retryHandler) }
    }

    func cancel() {
        if cancellationId == nil, MacChatSession.shared.role == .host, let updateId = status.updateId { cancellationId = updateId }
        timer?.invalidate()
        timer = nil
        handler = nil
        requestId = nil
        status = UpdateStatusData(phase: .none)
        Updates.installing = false
        installStarted = false
        if cancellationId != nil { startTimer(); tick() }
    }
}

@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool) -> Bool {
        !HostWindowMode.active
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if HostWindowMode.active {
            Updates.checkResult.message = "Update \(update.displayVersionString) available"
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        Updates.beta ? Updates.betaFeedURL : nil
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        Updates.beta ? ["beta"] : []
    }

    func updater(
        _ updater: SPUUpdater,
        shouldProceedWithUpdate item: SUAppcastItem,
        updateCheck: SPUUpdateCheck
    ) throws {
        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard ReleaseVersion.allowsUpdate(from: installed, to: item.displayVersionString) else {
            throw NSError(
                domain: "to.yumi.yorozu.updates", code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "Update \(item.displayVersionString) cannot replace installed version \(installed ?? "unknown"). "
                    + "Older or invalid release versions are not installed."])
        }
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        Updates.pending.queue(version: item.displayVersionString, handler: immediateInstallationBlock)
        return true
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        if Updates.installing { return false }
        Updates.pending.queue(version: item.displayVersionString, handler: installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Updates.checkResult.message = "Update \(item.displayVersionString) available"
        Log.write("updates: found \(item.displayVersionString) (build \(item.versionString))")
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Updates.checkResult.message = error.localizedDescription
        Log.write("updates: none available — \(error.localizedDescription)")
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        Updates.pending.cancel()
        Log.write("updates: aborted — \(error.localizedDescription)")
    }
}

@MainActor @Observable
final class UpdateCheckResult {
    var message: String?
}

struct CheckForUpdatesButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if let controller = Updates.controller {
            Button("Check for Updates…") {
                if HostWindowMode.active {
                    SettingsPaneRouter.shared.selection = "updates"
                    openSettings()
                    Updates.checkResult.message = "Checking for updates…"
                    controller.updater.checkForUpdatesInBackground()
                } else {
                    controller.updater.checkForUpdates()
                }
            }
        }
    }
}

struct UpdatesSettingsView: View {
    @State private var checkResult = Updates.checkResult
    @State private var pending = Updates.pending

    var body: some View {
        Form {
            UpdatesSettingsSection()
            Section("Status") {
                if let message = checkResult.message { Text(message) }
                if pending.status.phase != .none { Text(pending.status.label()) }
                if let failure = pending.failure { Text(failure).foregroundStyle(.red) }
                if checkResult.message == nil && pending.status.phase == .none && pending.failure == nil {
                    Text("Updates check quietly in the background.").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// The automatic-updates toggle, next to the button that checks right now. Hidden with the
/// button in a build that has no feed. Its caption is the Updates section footer in ``GeneralView``.
struct AutomaticUpdatesToggle: View {
    @State private var automatic = Updates.automatic

    var body: some View {
        if Updates.controller != nil {
            Toggle("Update automatically", isOn: $automatic)
                .onChange(of: automatic) { Updates.automatic = automatic }
        }
    }
}

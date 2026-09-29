import AppKit
import Foundation
import SwiftUI
import UserNotifications
import YorozuKeepalive
import YorozuShared

enum MacNotificationPreference {
    static let enabled = "macNotificationsEnabled"
    static let answers = "macNotifyAnswers"
    static let requests = "macNotifyRequests"
    static let failures = "macNotifyFailures"
    static let sound = "macNotificationSound"
    static let previews = "macNotificationPreviews"
    static let attentionIndicator = "macAttentionIndicator"

    static func value(_ key: String, default fallback: Bool = false) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }
}

@MainActor
struct MacAttentionItem: Identifiable {
    let id: String
    let threadID: String
    let eventID: String?
    let kind: MacAttentionKind
    let label: String
    var hostID: HostID? = nil

    static func pending(in model: ChatModel) -> [Self] {
        model.threads.sorted { $0.lastActivity > $1.lastActivity }.flatMap { thread -> [Self] in
            let events = model.events[thread.id] ?? []
            var items: [Self] = []
            if thread.awaitingApproval == true {
                let approvals = events.filter { event in
                    guard case .approvalCard(let card) = event.payload,
                          !model.answered.contains(card.actionId),
                          model.approvalOutcomes[card.actionId] != .expired,
                          model.approvalOutcomes[card.actionId] != .noLongerNeeded else { return false }
                    return true
                }
                for (index, event) in approvals.enumerated() {
                    let suffix = approvals.count > 1 ? " \(index + 1) of \(approvals.count)" : ""
                    items.append(Self(id: "approval:\(thread.id):\(event.id)", threadID: thread.id, eventID: event.id,
                        kind: .approval, label: "\(thread.displayTitle) · Approval\(suffix)"))
                }
            }
            if thread.awaitingQuestion == true {
                let questions = events.filter { event in
                    guard case .questionCard(let card) = event.payload,
                          !model.answeredQuestions.contains(card.questionId) else { return false }
                    return true
                }
                for (index, event) in questions.enumerated() {
                    let suffix = questions.count > 1 ? " \(index + 1) of \(questions.count)" : ""
                    items.append(Self(id: "question:\(thread.id):\(event.id)", threadID: thread.id, eventID: event.id,
                        kind: .question, label: "\(thread.displayTitle) · Question\(suffix)"))
                }
            }
            if thread.needsAttention == true || thread.interruptedTurnId != nil {
                items.append(Self(id: "failure:\(thread.id)", threadID: thread.id, eventID: nil, kind: .failure,
                    label: "\(thread.displayTitle) · Needs attention"))
            }
            return items
        }
    }
}

/// Mac-local presentation only. The runtime and paired devices keep every event independently.
@MainActor @Observable
final class LocalNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotifications()
    private let center = UNUserNotificationCenter.current()
    var toast: MacAttentionItem?

    func start() {
        center.delegate = self
    }

    func requestAuthorization() async -> String? {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
            return nil
        } catch {
            Log.write("notifications: authorization failed — \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    func statusChanged(_ threadID: String, to status: ThreadStatus,
                       presentation: ChatModel.ThreadNotificationPresentation, from model: ChatModel) {
        let session = MacChatSession.shared
        let hostID = session.hosts.sessions.first { $0.model === model }?.id
        guard session.role == .host && model === session.model || session.role == .client && hostID != nil else { return }
        let kind: MacAttentionKind
        let body: String
        let preference: String
        switch status {
        case .doneUnread:
            kind = .answer
            body = "New answer"
            preference = MacNotificationPreference.answers
        case .needsApproval:
            kind = .approval
            body = "Your approval is needed."
            preference = MacNotificationPreference.requests
        case .needsInput:
            kind = .question
            body = "Your answer is needed."
            preference = MacNotificationPreference.requests
        case .failed:
            kind = .failure
            body = "This task needs attention."
            preference = MacNotificationPreference.failures
        case .working, .idle: return
        }
        guard MacNotificationPreference.value(MacNotificationPreference.enabled),
              MacNotificationPreference.value(preference, default: true) else { return }
        let event = model.events[threadID]?.last { event in
            switch event.payload {
            case .message(let message):
                return kind == .answer && message.role == .agent && message.done == true && event.parentAgentId == nil
            case .approvalCard(let card):
                return kind == .approval && !model.answered.contains(card.actionId)
                    && model.approvalOutcomes[card.actionId] != .expired
                    && model.approvalOutcomes[card.actionId] != .noLongerNeeded
            case .questionCard(let card): return kind == .question && !model.answeredQuestions.contains(card.questionId)
            default: return false
            }
        }
        let id = UUID().uuidString
        let eventID = event?.id
        if presentation == .toast || session.hosts.sessions.contains(where: { $0.model.foreground }) {
            toast = MacAttentionItem(id: id, threadID: threadID, eventID: eventID, kind: kind,
                label: "\(model.title(of: threadID)) · \(body)", hostID: hostID)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = model.title(of: threadID)
        if MacNotificationPreference.value(MacNotificationPreference.previews),
           case .message(let message) = event?.payload {
            content.body = String(message.text.prefix(240))
        } else { content.body = body }
        if MacNotificationPreference.value(MacNotificationPreference.sound) { content.sound = .default }
        content.userInfo = ["threadID": threadID, "eventID": eventID ?? "", "kind": kind.rawValue]
        if let hostID { content.userInfo["hostID"] = hostID }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            do { try await center.add(request) }
            catch { Log.write("notifications: delivery failed — \(error.localizedDescription)") }
        }
    }

    func open(threadID: String, eventID: String?, kind: MacAttentionKind?, hostID: HostID?) {
        toast = nil
        if HostWindowMode.active {
            HostWindowMode.routeQuickChat(threadID: threadID, eventID: eventID, kind: kind)
        } else {
            ChatWindowRouter.shared.hostID = hostID
            ChatWindowRouter.shared.threadID = threadID
            OnboardingWindow.openChat?()
            NSApp.activate()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let threadID = info["threadID"] as? String
        let eventID = info["eventID"] as? String
        let hostID = info["hostID"] as? String
        let kind = (info["kind"] as? String).flatMap(MacAttentionKind.init(rawValue:))
        completionHandler()
        if let threadID {
            Task { @MainActor in self.open(threadID: threadID,
                eventID: eventID?.isEmpty == false ? eventID : nil, kind: kind, hostID: hostID) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let content = notification.request.content
        let threadID = content.userInfo["threadID"] as? String
        let hostID = content.userInfo["hostID"] as? String
        let eventID = content.userInfo["eventID"] as? String
        let kind = (content.userInfo["kind"] as? String).flatMap(MacAttentionKind.init(rawValue:))
        let label = "\(content.title) · \(content.body)"
        let id = notification.request.identifier
        let completion = PresentationCompletion(callback: completionHandler)
        Task { @MainActor in
            let session = MacChatSession.shared
            let model = hostID.flatMap { session.hosts.session(for: $0)?.model } ?? session.model
            if let threadID, model.isReading(threadID) {
                completion.callback([])
            } else if model.foreground || session.hosts.sessions.contains(where: { $0.model.foreground }) {
                if let threadID, let kind {
                    self.toast = MacAttentionItem(id: id, threadID: threadID, eventID: eventID,
                        kind: kind, label: label, hostID: hostID)
                }
                completion.callback([])
            } else {
                var options: UNNotificationPresentationOptions = [.banner, .list]
                if MacNotificationPreference.value(MacNotificationPreference.sound) { options.insert(.sound) }
                completion.callback(options)
            }
        }
    }
}

/// Apple supplies this one-shot completion for asynchronous delegate use. It is called once,
/// on the main actor, after reading the current visible thread.
private struct PresentationCompletion: @unchecked Sendable {
    let callback: (UNNotificationPresentationOptions) -> Void
}

struct ThreadNotificationToast: View {
    @State private var notifications = LocalNotifications.shared

    var body: some View {
        if let toast = notifications.toast {
            HStack {
                Text(toast.label).lineLimit(2)
                Button("Open thread") {
                    notifications.open(threadID: toast.threadID, eventID: toast.eventID,
                        kind: toast.kind, hostID: toast.hostID)
                }
                Button("Dismiss", systemImage: "xmark") { notifications.toast = nil }
                    .labelStyle(.iconOnly)
            }
            .padding()
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LayoutMetrics.cardRadius))
            .padding()
            .task(id: toast.id) {
                AccessibilityNotification.Announcement(toast.label).post()
                try? await Task.sleep(for: .seconds(8))
                if !Task.isCancelled, notifications.toast?.id == toast.id { notifications.toast = nil }
            }
        }
    }
}

struct MacNotificationsView: View {
    @AppStorage(MacNotificationPreference.enabled) private var enabled = false
    @AppStorage(MacNotificationPreference.answers) private var answers = true
    @AppStorage(MacNotificationPreference.requests) private var requests = true
    @AppStorage(MacNotificationPreference.failures) private var failures = true
    @AppStorage(MacNotificationPreference.sound) private var sound = false
    @AppStorage(MacNotificationPreference.previews) private var previews = false
    @AppStorage(MacNotificationPreference.attentionIndicator) private var attentionIndicator = true
    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var authorizationError: String?
    @State private var authorizationRequest = UUID()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section("On this Mac") {
                Toggle("Enable notifications on this Mac", isOn: $enabled)
                Text(authorizationLabel).foregroundStyle(authorization == .denied ? .red : .secondary)
            }
            Section("Notify me about") {
                Toggle("Answers and completed tasks", isOn: $answers)
                Toggle("Questions and approvals", isOn: $requests)
                Toggle("Failures needing attention", isOn: $failures)
            }
            Section("Presentation") {
                Toggle("Play a sound", isOn: $sound)
                Toggle("Show message previews", isOn: $previews)
                Toggle("Show menu-bar attention indicator", isOn: $attentionIndicator)
            }
            Text("These choices affect this Mac only. Paired devices keep their own notifications, and all tasks and questions remain available in Quick Chat.")
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task { await refreshAuthorization() }
        .onChange(of: enabled) { _, value in
            let request = UUID()
            authorizationRequest = request
            authorizationError = nil
            Task {
                let error = value ? await LocalNotifications.shared.requestAuthorization() : nil
                guard authorizationRequest == request else { return }
                authorizationError = error
                await refreshAuthorization()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshAuthorization() } }
        }
    }

    private var authorizationLabel: String {
        if let authorizationError { return "macOS could not enable notifications: \(authorizationError)" }
        return switch authorization {
        case .authorized, .provisional, .ephemeral: "Allowed by macOS"
        case .denied: "Denied by macOS. Allow Yorozu in System Settings → Notifications."
        case .notDetermined: enabled
            ? "Notifications are not active yet. Turn this setting off and on to retry."
            : "macOS will ask when you enable notifications."
        @unknown default: "Check macOS notification settings."
        }
    }

    private func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if authorization != .notDetermined {
            authorizationError = nil
        }
    }
}

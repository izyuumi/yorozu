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
    let label: String

    static func pending(in model: ChatModel) -> [Self] {
        visibleThreads(model.threads).flatMap { thread -> [Self] in
            let events = model.events[thread.id] ?? []
            var items: [Self] = []
            if thread.awaitingApproval == true,
               let event = events.last(where: {
                   if case .approvalCard(let card) = $0.payload {
                       return !model.answered.contains(card.actionId)
                   }
                   return false
               }) {
                items.append(Self(id: "approval:\(thread.id)", threadID: thread.id, eventID: event.id,
                    label: "\(thread.displayTitle) · Approval"))
            }
            if thread.awaitingQuestion == true,
               let event = events.last(where: {
                   if case .questionCard(let card) = $0.payload {
                       return !model.answeredQuestions.contains(card.questionId)
                   }
                   return false
               }) {
                items.append(Self(id: "question:\(thread.id)", threadID: thread.id, eventID: event.id,
                    label: "\(thread.displayTitle) · Question"))
            }
            if thread.needsAttention == true || thread.interruptedTurnId != nil {
                items.append(Self(id: "failure:\(thread.id)", threadID: thread.id, eventID: nil,
                    label: "\(thread.displayTitle) · Needs attention"))
            }
            return items
        }
    }
}

/// Mac-local presentation only. The runtime and paired devices keep every event independently.
@MainActor
final class LocalNotifications: NSObject, UNUserNotificationCenterDelegate {
    static let shared = LocalNotifications()
    private let center = UNUserNotificationCenter.current()
    private let launchTime = Date().timeIntervalSince1970 * 1000
    private var announced = Set<String>()
    private var previousAttention = Set<String>()

    func start() {
        center.delegate = self
        previousAttention = Set(MacAttentionItem.pending(in: MacChatSession.shared.model)
            .filter { $0.id.hasPrefix("failure:") }.map(\.threadID))
    }

    func requestAuthorization() async {
        do { _ = try await center.requestAuthorization(options: [.alert, .sound]) }
        catch { Log.write("notifications: authorization failed — \(error.localizedDescription)") }
    }

    func received(_ event: YorozuEvent, from model: ChatModel) {
        guard HostWindowMode.active, model === MacChatSession.shared.model,
              Double(event.ts) >= launchTime else { return }
        let kind: String
        let body: String
        let preference: String
        switch event.payload {
        case .message(let message) where message.role == .agent && message.done == true && event.parentAgentId == nil:
            kind = "answer"
            body = String(message.text.prefix(240))
            preference = MacNotificationPreference.answers
        case .approvalCard:
            kind = "approval"
            body = "Your approval is needed."
            preference = MacNotificationPreference.requests
        case .questionCard:
            kind = "question"
            body = "Your answer is needed."
            preference = MacNotificationPreference.requests
        default: return
        }
        guard announced.insert(event.id).inserted else { return }
        post(id: event.id, threadID: event.threadId, eventID: event.id, kind: kind,
            body: body, preference: preference, model: model)
    }

    func threadsChanged(_ model: ChatModel) {
        guard MacChatSession.shared.role == .host,
              model === MacChatSession.shared.model else { return }
        let current = Set(MacAttentionItem.pending(in: model)
            .filter { $0.id.hasPrefix("failure:") }.map(\.threadID))
        defer { previousAttention = current }
        guard HostWindowMode.active else { return }
        for thread in model.threads where current.contains(thread.id)
            && !previousAttention.contains(thread.id) && thread.lastActivity >= launchTime {
            post(id: "failure:\(thread.id):\(Int(thread.lastActivity))", threadID: thread.id,
                eventID: nil, kind: "failure", body: "This task needs attention.",
                preference: MacNotificationPreference.failures, model: model)
        }
    }

    private func post(id: String, threadID: String, eventID: String?, kind: String,
                      body: String, preference: String, model: ChatModel) {
        guard MacNotificationPreference.value(MacNotificationPreference.enabled),
              MacNotificationPreference.value(preference, default: true),
              !(model.foreground && model.openThread == threadID) else { return }
        let content = UNMutableNotificationContent()
        content.title = model.title(of: threadID)
        content.body = MacNotificationPreference.value(MacNotificationPreference.previews) ? body
            : kind == "answer" ? "New answer" : body
        if MacNotificationPreference.value(MacNotificationPreference.sound) { content.sound = .default }
        content.userInfo = ["threadID": threadID, "eventID": eventID ?? "", "kind": kind]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            do { try await center.add(request) }
            catch { Log.write("notifications: delivery failed — \(error.localizedDescription)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let threadID = info["threadID"] as? String
        let eventID = info["eventID"] as? String
        let kind = info["kind"] as? String
        completionHandler()
        if let threadID {
            Task { @MainActor in HostWindowMode.routeQuickChat(threadID: threadID,
                eventID: eventID?.isEmpty == false ? eventID : nil, kind: kind) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let threadID = notification.request.content.userInfo["threadID"] as? String
        let completion = PresentationCompletion(callback: completionHandler)
        Task { @MainActor in
            let model = MacChatSession.shared.model
            if model.foreground && model.openThread == threadID {
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

struct MacNotificationsView: View {
    @AppStorage(MacNotificationPreference.enabled) private var enabled = false
    @AppStorage(MacNotificationPreference.answers) private var answers = true
    @AppStorage(MacNotificationPreference.requests) private var requests = true
    @AppStorage(MacNotificationPreference.failures) private var failures = true
    @AppStorage(MacNotificationPreference.sound) private var sound = false
    @AppStorage(MacNotificationPreference.previews) private var previews = false
    @AppStorage(MacNotificationPreference.attentionIndicator) private var attentionIndicator = true
    @State private var authorization: UNAuthorizationStatus = .notDetermined
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
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task { await refreshAuthorization() }
        .onChange(of: enabled) { _, value in
            Task {
                if value { await LocalNotifications.shared.requestAuthorization() }
                await refreshAuthorization()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshAuthorization() } }
        }
    }

    private var authorizationLabel: String {
        switch authorization {
        case .authorized, .provisional, .ephemeral: "Allowed by macOS"
        case .denied: "Denied by macOS. Allow Yorozu in System Settings → Notifications."
        case .notDetermined: "macOS will ask when you enable notifications."
        @unknown default: "Check macOS notification settings."
        }
    }

    private func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}

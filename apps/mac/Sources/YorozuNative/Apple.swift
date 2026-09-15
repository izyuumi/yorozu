/// Calendar, reminders and mail: the three tools that need frameworks only a Mac app can
/// reach. Calendar and reminders go through EventKit, mail through AppleScript, because Mail
/// has no framework and its scripting dictionary is the only way in.
///
/// Every failure comes back as `{"ok":false,"error":…}` like the rest of the protocol. A
/// failure that is really a missing grant also carries `permission`, naming it, so the
/// runtime can ask for it rather than making the user go and find it. The two that matter
/// here are EventKit refusing full access, and `-1743`: TCC refusing to deliver an Apple
/// event because Automation was never granted for the target app.
/// See docs/spec-v1.html section 3.

import EventKit
import Foundation
import YorozuPermissions

/// A reminder flattened to values. `EKReminder` is a non-Sendable class, so it cannot leave
/// the queue EventKit hands it to us on; this can. At file scope rather than nested inside
/// `Apple` so that it carries no actor isolation of its own.
struct ReminderRow: Sendable {
    let id: String
    let title: String
    let list: String
    let due: Date?
    let notes: String?
    let completed: Bool

    init(_ reminder: EKReminder) {
        id = reminder.calendarItemIdentifier
        title = reminder.title ?? ""
        list = reminder.calendar?.title ?? ""
        due = reminder.dueDateComponents?.date
        notes = reminder.notes
        completed = reminder.isCompleted
    }
}

@MainActor
enum Apple {
    /// One store for the process: EventKit caches behind it, and the access grants are
    /// per-store.
    ///
    /// `nonisolated(unsafe)` because `fetchReminders` answers on a queue of EventKit's own
    /// and the store has to reach that callback. The helper serves one command at a time, so
    /// there is no second caller to race with.
    nonisolated(unsafe) static let store = EKEventStore()

    /// A week is what "what's on my calendar" means when the model does not say.
    static let defaultWindow: TimeInterval = 7 * 24 * 60 * 60

    // MARK: - Dates

    static let isoOut: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    static func iso(_ date: Date?) -> String { date.map { isoOut.string(from: $0) } ?? "" }

    /// Models write dates every way a human does. A string without a zone is the user's own
    /// local time — that is what someone typing "2026-09-12T14:00" means.
    static func parseDate(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
        ] {
            iso.formatOptions = options
            if let date = iso.date(from: text) { return date }
        }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: text) { return date }
        }
        return nil
    }

    static func date(_ request: [String: Any], _ key: String) throws -> Date {
        guard let text = request[key] as? String else { throw Failure("\(key) is required") }
        guard let date = parseDate(text) else { throw Failure("\(key): not a date: \(text)") }
        return date
    }

    static func optionalDate(_ request: [String: Any], _ key: String) throws -> Date? {
        guard request[key] != nil else { return nil }
        return try date(request, key)
    }

    static func string(_ request: [String: Any], _ key: String) throws -> String {
        guard let text = request[key] as? String, !text.isEmpty else {
            throw Failure("\(key) is required")
        }
        return text
    }

    // MARK: - Access

    /// The macOS 14+ full-access APIs: write needs them, and asking for less would make
    /// every create and update fail later instead of here.
    ///
    /// A `false` here is not always the user saying no — until this helper carried its own
    /// Info.plist, TCC denied the request outright because it could not find
    /// `NSCalendarsFullAccessUsageDescription` in the calling binary, and nothing was ever
    /// shown to the user. Either way the answer is the same: name the grant and let the
    /// runtime ask for it again through request_permission.
    static func requireAccess(_ entity: EKEntityType) async throws {
        let permission: Permission = entity == .event ? .calendars : .reminders
        let granted =
            entity == .event
            ? try await store.requestFullAccessToEvents()
            : try await store.requestFullAccessToReminders()
        guard granted else {
            throw Failure("\(permission.title) access is not granted", permission: permission)
        }
    }

    /// A calendar by title, else the one new items belong in. Matching by title is what the
    /// model has: calendar identifiers are UUIDs it never sees unless it listed them first.
    static func calendar(named name: String?, for entity: EKEntityType) throws -> EKCalendar {
        let calendars = store.calendars(for: entity)
        if let name, !name.isEmpty {
            guard
                let match = calendars.first(where: {
                    $0.title.caseInsensitiveCompare(name) == .orderedSame
                }) ?? calendars.first(where: { $0.calendarIdentifier == name })
            else { throw Failure("no calendar named \(name)") }
            return match
        }
        let fallback =
            entity == .event
            ? store.defaultCalendarForNewEvents : store.defaultCalendarForNewReminders()
        guard let fallback else { throw Failure("no default calendar to write to") }
        return fallback
    }

    // MARK: - Calendar

    static func calendarList() async throws -> [String: Any] {
        try await requireAccess(.event)
        return [
            "calendars": store.calendars(for: .event).map {
                [
                    "id": $0.calendarIdentifier,
                    "title": $0.title,
                    "writable": $0.allowsContentModifications,
                ]
            }
        ]
    }

    static func eventJSON(_ event: EKEvent) -> [String: Any] {
        var result: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "start": iso(event.startDate),
            "end": iso(event.endDate),
            "calendar": event.calendar?.title ?? "",
            "allDay": event.isAllDay,
        ]
        if let location = event.location, !location.isEmpty { result["location"] = location }
        if let notes = event.notes, !notes.isEmpty { result["notes"] = notes }
        return result
    }

    static func calendarEvents(_ request: [String: Any]) async throws -> [String: Any] {
        try await requireAccess(.event)
        let from = try optionalDate(request, "from") ?? Date()
        let to = try optionalDate(request, "to") ?? from.addingTimeInterval(defaultWindow)
        guard to > from else { throw Failure("to must be after from") }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        return ["events": events.map(eventJSON), "from": iso(from), "to": iso(to)]
    }

    /// The event that ID names, loudly when it is gone: an identifier the model held on to
    /// across an edit or a delete is the usual way this fails.
    static func event(_ id: String) throws -> EKEvent {
        guard let event = store.event(withIdentifier: id) else {
            throw Failure("no event with id \(id)")
        }
        return event
    }

    static func calendarCreate(_ request: [String: Any]) async throws -> [String: Any] {
        try await requireAccess(.event)
        let event = EKEvent(eventStore: store)
        event.calendar = try calendar(named: request["calendar"] as? String, for: .event)
        event.title = try string(request, "title")
        event.startDate = try date(request, "start")
        event.endDate = try date(request, "end")
        if let notes = request["notes"] as? String { event.notes = notes }
        if let location = request["location"] as? String { event.location = location }
        guard event.endDate > event.startDate else { throw Failure("end must be after start") }
        try store.save(event, span: .thisEvent, commit: true)
        return ["event": eventJSON(event)]
    }

    static func calendarUpdate(_ request: [String: Any]) async throws -> [String: Any] {
        try await requireAccess(.event)
        let event = try event(try string(request, "id"))
        if let title = request["title"] as? String { event.title = title }
        if let start = try optionalDate(request, "start") { event.startDate = start }
        if let end = try optionalDate(request, "end") { event.endDate = end }
        if let notes = request["notes"] as? String { event.notes = notes }
        if let location = request["location"] as? String { event.location = location }
        if let name = request["calendar"] as? String {
            event.calendar = try calendar(named: name, for: .event)
        }
        guard event.endDate > event.startDate else { throw Failure("end must be after start") }
        try store.save(event, span: .thisEvent, commit: true)
        return ["event": eventJSON(event)]
    }

    /// `.thisEvent`, not `.futureEvents`: deleting one occurrence of a series is recoverable,
    /// deleting the tail of it is not, and the model asked for one event.
    static func calendarDelete(_ request: [String: Any]) async throws -> [String: Any] {
        try await requireAccess(.event)
        let event = try event(try string(request, "id"))
        let title = event.title ?? ""
        try store.remove(event, span: .thisEvent, commit: true)
        return ["deleted": title]
    }

    // MARK: - Reminders

    static func reminderJSON(_ row: ReminderRow) -> [String: Any] {
        var result: [String: Any] = [
            "id": row.id,
            "title": row.title,
            "list": row.list,
            "completed": row.completed,
        ]
        if let due = row.due { result["due"] = iso(due) }
        if let notes = row.notes, !notes.isEmpty { result["notes"] = notes }
        return result
    }

    /// `fetchReminders` is the one EventKit read still stuck on a completion handler, and it
    /// answers on a queue of its own. The whole fetch is therefore `nonisolated`: it reads
    /// the store itself rather than being handed it, so no main-actor value is sent into the
    /// callback, and it returns `Sendable` rows rather than the reminders themselves.
    ///
    /// Undated reminders sort last — a due date is what makes one actionable now.
    nonisolated static func remindersRows(list name: String?) async throws -> [ReminderRow] {
        var calendars: [EKCalendar]?
        if let name, !name.isEmpty {
            let all = store.calendars(for: .reminder)
            guard
                let match = all.first(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame })
                    ?? all.first(where: { $0.calendarIdentifier == name })
            else { throw Failure("no reminder list named \(name)") }
            calendars = [match]
        }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: nil,
            calendars: calendars
        )
        // Flattened inside the callback: what leaves the continuation has to be Sendable,
        // and the reminders themselves are not.
        let rows: [ReminderRow] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: (reminders ?? []).map(ReminderRow.init))
            }
        }
        return rows.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    static func remindersList(_ request: [String: Any]) async throws -> [String: Any] {
        try await requireAccess(.reminder)
        let rows = try await remindersRows(list: request["list"] as? String)
        return ["reminders": rows.map(reminderJSON)]
    }

    static func remindersCreate(_ request: [String: Any]) async throws -> [String: Any] {
        try await requireAccess(.reminder)
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = try calendar(named: request["list"] as? String, for: .reminder)
        reminder.title = try string(request, "title")
        if let notes = request["notes"] as? String { reminder.notes = notes }
        if let due = try optionalDate(request, "due") {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
        }
        try store.save(reminder, commit: true)
        return ["reminder": reminderJSON(ReminderRow(reminder))]
    }

    static func remindersComplete(_ request: [String: Any]) async throws -> [String: Any] {
        try await requireAccess(.reminder)
        let id = try string(request, "id")
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else {
            throw Failure("no reminder with id \(id)")
        }
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
        return ["reminder": reminderJSON(ReminderRow(reminder))]
    }

    // MARK: - Mail

    /// `errAEEventNotPermitted`: TCC refused to deliver the Apple event. The same code the
    /// onboarding wizard's Automation probe looks for.
    static let automationDenied = Permission.automationDeniedCode

    static func quote(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Runs one script and returns its result as text. NSAppleScript needs the main thread,
    /// which is where the whole helper already runs.
    static func applescript(_ source: String) throws -> String {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "AppleScript failed"
            if code == automationDenied {
                throw Failure(
                    "Automation is not granted for Mail (-1743)",
                    permission: .automation
                )
            }
            throw Failure("Mail: \(message) (\(code))")
        }
        guard let result else { throw Failure("Mail: AppleScript would not compile") }
        return result.stringValue ?? ""
    }

    /// Tab-separated fields, one message per line: the smallest thing AppleScript can return
    /// that survives a subject containing anything at all except a tab.
    static func messageRows(_ text: String) -> [[String: Any]] {
        text.split(separator: "\n").compactMap { line in
            let fields = line.components(separatedBy: "\t")
            guard fields.count >= 4 else { return nil }
            return [
                "id": fields[0], "sender": fields[1], "subject": fields[2], "date": fields[3],
            ]
        }
    }

    static func mailUnread(_ request: [String: Any]) throws -> [String: Any] {
        let limit = max(1, min((request["limit"] as? Int) ?? 10, 100))
        let text = try applescript(
            """
            tell application "Mail"
                set output to ""
                set found to (messages of inbox whose read status is false)
                repeat with i from 1 to (count of found)
                    if i > \(limit) then exit repeat
                    set m to item i of found
                    set output to output & (id of m) & tab & (sender of m) & tab & ¬
                        (subject of m) & tab & ((date received of m) as string) & linefeed
                end repeat
                return output
            end tell
            """
        )
        return ["messages": messageRows(text)]
    }

    static func mailRead(_ request: [String: Any]) throws -> [String: Any] {
        guard let id = Int(try string(request, "id")), id > 0 else {
            throw Failure("id must be a positive message number")
        }
        let text = try applescript(
            """
            tell application "Mail"
                set m to first message of inbox whose id is \(id)
                return ((id of m) as string) & tab & (sender of m) & tab & (subject of m) & tab & ¬
                    ((date received of m) as string) & linefeed & (content of m)
            end tell
            """
        )
        // First line is the header row, everything after it is the body.
        let split = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard var message = messageRows(String(split.first ?? "")).first else {
            throw Failure("no message with id \(id) in the inbox")
        }
        message["body"] = split.count > 1 ? String(split[1]) : ""
        return ["message": message]
    }

    static func mailSend(_ request: [String: Any]) throws -> [String: Any] {
        let recipients =
            (request["to"] as? [String])
            ?? (request["to"] as? String ?? "")
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
        let addresses = recipients.filter { !$0.isEmpty }
        guard !addresses.isEmpty else { throw Failure("to is required") }
        let subject = request["subject"] as? String ?? ""
        let body = request["body"] as? String ?? ""
        let makeRecipients = addresses
            .map {
                "    make new to recipient at end of to recipients with properties {address:\(quote($0))}"
            }
            .joined(separator: "\n")
        _ = try applescript(
            """
            tell application "Mail"
                set m to make new outgoing message with properties ¬
                    {subject:\(quote(subject)), content:\(quote(body)), visible:false}
                tell m
            \(makeRecipients)
                end tell
                send m
            end tell
            """
        )
        return ["sent": addresses]
    }

    // MARK: - Protocol

    /// The commands this file owns. `nil` means "not mine", so `Native.handle` can go on.
    static func handle(_ cmd: String, _ request: [String: Any]) async throws -> [String: Any]? {
        switch cmd {
        case "calendar.list": return try await calendarList()
        case "calendar.events": return try await calendarEvents(request)
        case "calendar.create": return try await calendarCreate(request)
        case "calendar.update": return try await calendarUpdate(request)
        case "calendar.delete": return try await calendarDelete(request)
        case "reminders.list": return try await remindersList(request)
        case "reminders.create": return try await remindersCreate(request)
        case "reminders.complete": return try await remindersComplete(request)
        case "mail.unread": return try mailUnread(request)
        case "mail.read": return try mailRead(request)
        case "mail.send": return try mailSend(request)
        default: return nil
        }
    }
}

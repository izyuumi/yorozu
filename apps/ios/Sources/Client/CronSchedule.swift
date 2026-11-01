import Foundation
import YorozuWire

/// The schedules the plugin's `describeSchedule` names in words, so the app can name them in its own language.
struct CronSchedule: Equatable, Sendable {
    enum Unit: Equatable, Sendable { case day, hour, minute, second }

    enum Kind: Equatable, Sendable {
        case once
        case every(Int, Unit)
        case hourly(minute: Int)
        case daily(hour: Int, minute: Int)
        case weekdays(hour: Int, minute: Int)
        /// `weekday` 0 is Sunday.
        case weekly(weekday: Int, hour: Int, minute: Int)
        case monthly(day: Int, hour: Int, minute: Int)
        case onExit
        case stream
    }

    var kind: Kind
    var timeZone: String?

    static func parse(_ schedule: JSONValue) -> CronSchedule? {
        guard case .object(let fields) = schedule, case .string(let kind)? = fields["kind"] else { return nil }
        switch kind {
        case "at": return CronSchedule(kind: .once)
        case "every":
            guard case .number(let ms)? = fields["everyMs"], ms > 0, ms < 1e15, ms == ms.rounded() else { return nil }
            let units: [(Int64, Unit)] = [(86_400_000, .day), (3_600_000, .hour), (60_000, .minute), (1_000, .second)]
            guard let unit = units.first(where: { Int64(ms) % $0.0 == 0 }) else { return nil }
            return CronSchedule(kind: .every(Int(Int64(ms) / unit.0), unit.1))
        case "cron":
            guard case .string(let expr)? = fields["expr"], let parsed = cron(expr) else { return nil }
            guard case .string(let tz)? = fields["tz"], !tz.isEmpty else { return CronSchedule(kind: parsed) }
            return CronSchedule(kind: parsed, timeZone: tz)
        case "on-exit": return CronSchedule(kind: .onExit)
        case "stream": return CronSchedule(kind: .stream)
        default: return nil
        }
    }

    private static func cron(_ expr: String) -> Kind? {
        let fields = expr.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { return nil }
        let (min, hour, dom, month, dow) = (fields[0], fields[1], fields[2], fields[3], fields[4])
        func digits(_ s: String) -> Bool { !s.isEmpty && s.allSatisfy { $0.isASCII && $0.isNumber } }
        func num(_ s: String) -> Int? { s.count <= 2 && digits(s) ? Int(s) : nil }
        let rest = [hour, dom, month, dow]
        if min.hasPrefix("*/"), rest.allSatisfy({ $0 == "*" }) {
            let step = String(min.dropFirst(2))
            guard digits(step), let n = Int(step), n > 0 else { return nil }
            return .every(n, .minute)
        }
        if let m = num(min), rest.allSatisfy({ $0 == "*" }) { return m < 60 ? .hourly(minute: m) : nil }
        guard let m = num(min), let h = num(hour), month == "*" else { return nil }
        guard m < 60, h < 24 else { return nil }
        if dom == "*" && dow == "*" { return .daily(hour: h, minute: m) }
        if dom == "*" && (dow == "1-5" || dow == "MON-FRI") { return .weekdays(hour: h, minute: m) }
        if dom == "*", dow.count == 1, let d = num(dow), d <= 7 { return .weekly(weekday: d % 7, hour: h, minute: m) }
        if let d = num(dom), dow == "*" { return (1...31).contains(d) ? .monthly(day: d, hour: h, minute: m) : nil }
        return nil
    }

    var localizedText: String {
        let text = localizedKind
        guard let timeZone else { return text }
        return String(localized: "\(text) (\(timeZone))", comment: "Automation schedule followed by its time zone, e.g. “Daily at 9:00 (Asia/Tokyo)”.")
    }

    private var localizedKind: String {
        switch kind {
        case .once: String(localized: "Once", comment: "Automation schedule: runs one time.")
        case .every(1, .day): String(localized: "Every day", comment: "Automation schedule.")
        case .every(1, .hour): String(localized: "Every hour", comment: "Automation schedule.")
        case .every(1, .minute): String(localized: "Every minute", comment: "Automation schedule.")
        case .every(1, .second): String(localized: "Every second", comment: "Automation schedule.")
        case .every(let n, .day): String(localized: "Every \(n) days", comment: "Automation schedule.")
        case .every(let n, .hour): String(localized: "Every \(n) hours", comment: "Automation schedule.")
        case .every(let n, .minute): String(localized: "Every \(n) minutes", comment: "Automation schedule.")
        case .every(let n, .second): String(localized: "Every \(n) seconds", comment: "Automation schedule.")
        case .hourly(let minute):
            String(localized: "Hourly at :\(String(format: "%02d", minute))", comment: "Automation schedule: every hour at this two-digit minute, e.g. “Hourly at :05”.")
        case .daily(let h, let m): String(localized: "Daily at \(Self.time(h, m))", comment: "Automation schedule; the argument is a time of day.")
        case .weekdays(let h, let m): String(localized: "Weekdays at \(Self.time(h, m))", comment: "Automation schedule: Monday to Friday; the argument is a time of day.")
        case .weekly(let day, let h, let m): Self.weekly(day, Self.time(h, m))
        case .monthly(let day, let h, let m):
            String(localized: "Monthly on day \(day) at \(Self.time(h, m))", comment: "Automation schedule: the day of the month, then a time of day.")
        case .onExit: String(localized: "When a command exits", comment: "Automation schedule: runs when a watched command exits.")
        case .stream: String(localized: "On command output", comment: "Automation schedule: runs when a watched command prints output.")
        }
    }

    private static func weekly(_ day: Int, _ time: String) -> String {
        switch day {
        case 1: String(localized: "Mondays at \(time)", comment: "Automation schedule: every Monday; the argument is a time of day.")
        case 2: String(localized: "Tuesdays at \(time)", comment: "Automation schedule: every Tuesday; the argument is a time of day.")
        case 3: String(localized: "Wednesdays at \(time)", comment: "Automation schedule: every Wednesday; the argument is a time of day.")
        case 4: String(localized: "Thursdays at \(time)", comment: "Automation schedule: every Thursday; the argument is a time of day.")
        case 5: String(localized: "Fridays at \(time)", comment: "Automation schedule: every Friday; the argument is a time of day.")
        case 6: String(localized: "Saturdays at \(time)", comment: "Automation schedule: every Saturday; the argument is a time of day.")
        default: String(localized: "Sundays at \(time)", comment: "Automation schedule: every Sunday; the argument is a time of day.")
        }
    }

    /// The hour belongs to the schedule's own time zone, so it is formatted in GMT to keep the device's zone out of it.
    private static func time(_ hour: Int, _ minute: Int) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
        style.timeZone = .gmt
        return Date(timeIntervalSince1970: TimeInterval(hour * 3600 + minute * 60)).formatted(style)
    }
}

extension CronJob {
    var localizedScheduleText: String { CronSchedule.parse(schedule)?.localizedText ?? scheduleText }
}

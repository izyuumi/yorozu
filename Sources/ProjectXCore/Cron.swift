import Foundation

/// A problem with a cron expression, as one plain-language reason.
public struct CronError: Error, LocalizedError, Sendable, Equatable {
    public var reason: String
    public var errorDescription: String? { reason }
}

/// One 5-field cron expression: minute (0-59), hour (0-23), day of month (1-31), month (1-12), day of week (0-7, 0 and 7
/// are Sunday). A field is `*` or a comma list of `n`, `a-b`, `*/s`, `a-b/s` or `a/s` (a to the field's end). Names
/// (`mon`, `jan`) and `@daily`-style macros are not supported. When both day fields are restricted a day matches
/// either one (POSIX); a day field starting with `*` (such as `*/2`) counts as unrestricted, as in Vixie cron.
public struct CronExpression: Sendable, Equatable {
    public let text: String
    let minutes: UInt64, hours: UInt64, days: UInt64, months: UInt64, weekdays: UInt64
    let anyDay, anyWeekday: Bool

    public init(_ text: String) throws {
        let fields = text.split(whereSeparator: \.isWhitespace)
        guard fields.count == 5 else { throw CronError(reason: "\"\(text)\": expected 5 fields (minute hour day-of-month month day-of-week), found \(fields.count)") }
        self.text = text
        minutes = try Self.field(fields[0],0...59,"minute",text)
        hours = try Self.field(fields[1],0...23,"hour",text)
        days = try Self.field(fields[2],1...31,"day of month",text)
        months = try Self.field(fields[3],1...12,"month",text)
        let week = try Self.field(fields[4],0...7,"day of week",text)
        weekdays = (week | week >> 7) & 0x7f
        anyDay = fields[2].hasPrefix("*"); anyWeekday = fields[4].hasPrefix("*")
        if !anyDay && anyWeekday, !(1...12).contains(where: { m in months & 1 << m != 0 && (1...Self.longest[m]).contains { days & 1 << $0 != 0 } }) {
            throw CronError(reason: "\"\(text)\": that day of month never occurs in those months")
        }
    }

    /// The first minute strictly after `date` that matches, in `calendar`'s time zone (Gregorian rules), searching about
    /// 5 years ahead. A local time a daylight-saving change skips is skipped; a repeated local time matches once, at
    /// its first occurrence.
    public func next(after date: Date, calendar: Calendar = Cron.calendar()) -> Date? {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = calendar.timeZone
        let units: Set<Calendar.Component> = [.year,.month,.day,.hour,.minute]
        let start = cal.dateComponents(units,from: date)
        guard var y = start.year, var m = start.month, var d = start.day, let h0 = start.hour, let m0 = start.minute else { return nil }
        var first = true
        let end = y + 5
        while y <= end {
            if months & 1 << m != 0, dayMatches(d,weekday: Self.weekday(y,m,d)) {
                for h in 0...23 where hours & 1 << h != 0 && (!first || h >= h0) {
                    for mi in 0...59 where minutes & 1 << mi != 0 && (!first || h > h0 || mi >= m0) {
                        guard let t = cal.date(from: DateComponents(year: y,month: m,day: d,hour: h,minute: mi)), t > date else { continue }
                        let back = cal.dateComponents(units,from: t)
                        guard back.year == y, back.month == m, back.day == d, back.hour == h, back.minute == mi else { continue } // skipped by DST
                        return t
                    }
                }
                d += 1
            } else {
                d = months & 1 << m != 0 ? d + 1 : 32 // a month that never matches is skipped whole
            }
            first = false
            if d > Self.length(y,m) { d = 1; m += 1; if m > 12 { m = 1; y += 1 } }
        }
        return nil
    }

    func dayMatches(_ day: Int, weekday: Int) -> Bool {
        let d = days & 1 << day != 0, w = weekdays & 1 << weekday != 0
        return anyDay || anyWeekday ? d && w : d || w
    }

    static let longest = [0,31,29,31,30,31,30,31,31,30,31,30,31]
    static func length(_ y: Int, _ m: Int) -> Int { m == 2 && (y % 4 != 0 || y % 100 == 0 && y % 400 != 0) ? 28 : longest[m] }
    /// 0 = Sunday (Sakamoto).
    static func weekday(_ y: Int, _ m: Int, _ d: Int) -> Int {
        let t = [0,3,2,5,0,3,5,1,4,6,2,4], y = m < 3 ? y - 1 : y
        return (y + y / 4 - y / 100 + y / 400 + t[m - 1] + d) % 7
    }
    static func field(_ text: Substring, _ range: ClosedRange<Int>, _ name: String, _ whole: String) throws -> UInt64 {
        func bad() -> CronError { CronError(reason: "\"\(whole)\": bad \(name) field \"\(text)\"; expected \(range.lowerBound)-\(range.upperBound), a-b, */n, a-b/n, a comma list or *") }
        func number(_ s: Substring) throws -> Int {
            guard !s.isEmpty, s.count <= 2, s.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(s), range.contains(n) else { throw bad() }
            return n
        }
        var bits: UInt64 = 0
        for part in text.split(separator: ",",omittingEmptySubsequences: false) {
            let pieces = part.split(separator: "/",omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { throw bad() }
            var step = 1
            if pieces.count == 2 { guard pieces[1].allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(pieces[1]), n > 0, n <= range.upperBound else { throw bad() }; step = n }
            var low = range.lowerBound, high = range.upperBound
            if pieces[0] != "*" {
                let ends = pieces[0].split(separator: "-",omittingEmptySubsequences: false)
                guard ends.count <= 2 else { throw bad() }
                low = try number(ends[0])
                high = ends.count == 2 ? try number(ends[1]) : pieces.count == 2 ? range.upperBound : low
                guard low <= high else { throw bad() }
            }
            for v in stride(from: low,through: high,by: step) { bits |= 1 << v }
        }
        return bits
    }
}

/// Yorozu's own cron evaluator (#319): a job's `schedule` is a list of expressions, and a slot fires when any matches.
public enum Cron {
    /// Gregorian in the Mac's current time zone. After `NSSystemTimeZoneDidChange`, call `TimeZone.resetSystemTimeZone()`
    /// (or `NSTimeZone.resetSystemTimeZone()`) first so `TimeZone.current` is fresh.
    public static func calendar() -> Calendar { var cal = Calendar(identifier: .gregorian); cal.timeZone = .current; return cal }
    /// nil when valid, else the reason.
    public static func problem(_ expression: String) -> String? {
        do { _ = try CronExpression(expression); return nil } catch { return (error as? CronError)?.reason ?? "\(error)" }
    }
    /// The earliest next fire strictly after `date` over all expressions; invalid expressions are ignored. nil when
    /// none fires within about 5 years. Only the time zone of `calendar` is used.
    public static func next(after date: Date, expressions: [String], calendar: Calendar = Cron.calendar()) -> Date? {
        expressions.compactMap { try? CronExpression($0).next(after: date,calendar: calendar) }.min()
    }
}

import Testing
import YorozuWire

@Suite struct CronScheduleTests {
    private func cron(_ expr: String, tz: String? = nil) -> CronSchedule? {
        var fields: [String: JSONValue] = ["kind": .string("cron"), "expr": .string(expr)]
        if let tz { fields["tz"] = .string(tz) }
        return CronSchedule.parse(.object(fields))
    }

    private func every(_ ms: Double) -> CronSchedule? {
        CronSchedule.parse(.object(["kind": .string("every"), "everyMs": .number(ms)]))
    }

    @Test func simpleKinds() {
        #expect(CronSchedule.parse(.object(["kind": .string("at"), "at": .string("2026-11-01T09:00:00Z")])) == CronSchedule(kind: .once))
        #expect(CronSchedule.parse(.object(["kind": .string("on-exit")])) == CronSchedule(kind: .onExit))
        #expect(CronSchedule.parse(.object(["kind": .string("stream")])) == CronSchedule(kind: .stream))
    }

    @Test func everyPicksTheLargestWholeUnit() {
        #expect(every(86_400_000)?.kind == .every(1, .day))
        #expect(every(172_800_000)?.kind == .every(2, .day))
        #expect(every(7_200_000)?.kind == .every(2, .hour))
        #expect(every(1_800_000)?.kind == .every(30, .minute))
        #expect(every(90_000)?.kind == .every(90, .second))
    }

    @Test(arguments: [1_500, 0, -60_000, 0.5])
    func everyWithOddMillisecondsFallsBack(_ ms: Double) {
        #expect(every(ms) == nil)
    }

    @Test func cronShapes() {
        #expect(cron("*/15 * * * *")?.kind == .every(15, .minute))
        #expect(cron("5 * * * *")?.kind == .hourly(minute: 5))
        #expect(cron("0 9 * * *")?.kind == .daily(hour: 9, minute: 0))
        #expect(cron("  30 8 * * 1-5 ")?.kind == .weekdays(hour: 8, minute: 30))
        #expect(cron("30 8 * * MON-FRI")?.kind == .weekdays(hour: 8, minute: 30))
        #expect(cron("0 10 * * 3")?.kind == .weekly(weekday: 3, hour: 10, minute: 0))
        #expect(cron("0 7 15 * *")?.kind == .monthly(day: 15, hour: 7, minute: 0))
    }

    @Test(arguments: ["0", "7"])
    func zeroAndSevenAreSunday(_ dow: String) {
        #expect(cron("0 9 * * \(dow)")?.kind == .weekly(weekday: 0, hour: 9, minute: 0))
    }

    @Test func keepsTheTimeZone() {
        #expect(cron("0 9 * * *", tz: "Asia/Tokyo") == CronSchedule(kind: .daily(hour: 9, minute: 0), timeZone: "Asia/Tokyo"))
        #expect(cron("0 9 * * *", tz: "")?.timeZone == nil)
    }

    @Test(arguments: [
        "0 9 * * 1,3", "0 9 1 1 *", "0 9 1 * 1", "0 */2 * * *", "*/0 * * * *", "*/5 9 * * *",
        "0 9 * *", "0 9 * * * *", "123 9 * * *", "0 24 * * *", "60 * * * *", "0 9 0 * *", "0 9 * * 8", "@daily",
    ])
    func unsupportedCronFallsBack(_ expr: String) {
        #expect(cron(expr) == nil)
    }

    @Test func unknownShapesFallBack() {
        #expect(CronSchedule.parse(.object(["kind": .string("webhook")])) == nil)
        #expect(CronSchedule.parse(.object(["kind": .string("cron")])) == nil)
        #expect(CronSchedule.parse(.object(["kind": .string("every"), "everyMs": .string("60000")])) == nil)
        #expect(CronSchedule.parse(.string("cron")) == nil)
    }
}

import Foundation
import Testing

@testable import YorozuShared

/// A Wednesday lunchtime, so "this week" has days behind it and the weekend is last week. Fixed
/// calendar and time zone: the grouping is about the calendar's idea of a day, and a test that
/// moved with the machine's would pass in London and fail in Auckland.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
}()

private let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 9, hour: 12))!

private func at(_ day: Int, _ hour: Int = 9) -> Date {
    calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
}

@Test(arguments: [
    // Wednesday the 9th is "now": earlier the same day, and later the same day too — a phone
    // whose clock is a minute fast is not a section of its own.
    (at(9, 9), ThreadSection.Group.today),
    (at(9, 23), .today),
    (at(8), .yesterday),
    // The week began on Monday the 7th, so Monday and Tuesday are this week…
    (at(7), .thisWeek),
    // …and Sunday the 6th, the day before it, is already earlier.
    (at(6), .earlier),
    (at(1), .earlier),
    (calendar.date(from: DateComponents(year: 2025, month: 12, day: 31))!, .earlier),
])
func everyThreadFallsUnderTheHeadingItsDateEarns(date: Date, group: ThreadSection.Group) {
    #expect(threadGroup(for: date, now: now, calendar: calendar) == group)
}

private func thread(_ id: String, _ date: Date, pinned: Bool = false, archived: Bool = false)
    -> ThreadSummary
{
    ThreadSummary(
        id: id,
        title: id,
        archived: archived,
        lastActivity: date.timeIntervalSince1970 * 1000,
        pinned: pinned
    )
}

@Test func theListIsPinnedThenDatedSectionsThenTheArchive() {
    let groups = ThreadGroups(
        [
            thread("earlier", at(1)),
            thread("today-old", at(9, 2)),
            thread("pinned", at(1), pinned: true),
            thread("today-new", at(9, 11)),
            thread("yesterday", at(8)),
            thread("monday", at(7)),
            thread("filed", at(9, 10), archived: true),
        ],
        now: now,
        calendar: calendar
    )

    #expect(groups.pinned.map(\.id) == ["pinned"])
    #expect(groups.sections.map(\.title) == ["Today", "Yesterday", "This week", "Earlier"])
    // Newest first inside a section, and a pinned thread is only ever in the pinned one.
    #expect(groups.sections.first?.threads.map(\.id) == ["today-new", "today-old"])
    #expect(groups.sections.last?.threads.map(\.id) == ["earlier"])
    #expect(groups.archived.map(\.id) == ["filed"])

    // Empty sections are left out rather than drawn as headings with nothing under them.
    let quiet = ThreadGroups([thread("t", at(9))], now: now, calendar: calendar)
    #expect(quiet.sections.map(\.title) == ["Today"])
    #expect(ThreadGroups([], now: now, calendar: calendar).sections.isEmpty)
}

@Test func threadTimesStayCompactWithoutAgo() {
    let cases: [(TimeInterval, String)] = [
        (30, "now"),
        (29 * 60, "29m"),
        (5 * 3_600, "5h"),
        (3 * 86_400, "3d"),
        (2 * 604_800, "2w"),
        (3 * 2_629_800, "3mo"),
    ]
    for (seconds, expected) in cases {
        #expect(compactThreadTime(now.addingTimeInterval(-seconds), now: now) == expected)
    }
}

@Test func searchResultPreviewShowsTheMatchingPart() {
    let text = "Opening sentence.\n\nThe butcher closes at 19:00 on weekdays. Final sentence."
    let excerpt = searchExcerpt(in: text, matching: "butcher", limit: 42)
    #expect(excerpt?.contains("butcher closes at 19:00") == true)
    #expect(excerpt?.contains("\n") == false)
    #expect(searchExcerpt(in: text, matching: "missing") == nil)
}

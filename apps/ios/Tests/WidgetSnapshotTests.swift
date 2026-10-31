import Foundation
import Testing
import YorozuWire

private func item(_ id: String, _ kind: ChatItem.Kind, _ text: String, at ts: Int64) -> ChatItem {
    ChatItem(id: id, kind: kind, text: text, ts: ts)
}

private func conversation(_ id: String, title: String? = nil, items: [ChatItem], read: Int64? = nil, pinnedAt: Int64? = nil, archived: Bool? = nil) -> Conversation {
    var conversation = Conversation(id: id, createdAt: 0, updatedAt: items.map(\.ts).max() ?? 0, items: items)
    conversation.title = title
    conversation.pinnedAt = pinnedAt
    conversation.archived = archived
    if let read, let last = items.last(where: { $0.ts <= read }) {
        conversation.read = ReadCursor(convId: id, messageId: last.id, ts: read, unread: false)
    }
    return conversation
}

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "WidgetSnapshot-\(UUID().uuidString).json")
}

private let fixtures = [
    conversation("trip", title: "Trip planning", items: [
        item("u1", .user, "Plan a weekend in Kyoto", at: 1_000),
        item("a1", .agent, "Here is a plan.\nDay one: temples", at: 2_000),
        item("a2", .agent, "Booked the ryokan.", at: 3_000),
    ], read: 2_000),
    conversation("groceries", title: "Groceries", items: [
        item("u2", .user, "Add milk", at: 1_500),
        item("a3", .agent, "Added.", at: 1_600),
    ], read: 1_600, pinnedAt: 10),
    conversation("old", title: "Archived", items: [item("a4", .agent, "Done", at: 500)], archived: true),
]

@Suite struct WidgetSnapshotTests {
    @Test func unreadMathMatchesTheBadge() {
        let snapshot = WidgetSnapshot(conversations: fixtures, previews: false, accent: nil, live: true)
        #expect(snapshot.rows.first { $0.id == "trip" }?.unread == 1)
        #expect(snapshot.rows.first { $0.id == "groceries" }?.unread == 0)
        // Archived conversations leave the rows but still count, as on the app icon's badge.
        #expect(!snapshot.rows.contains { $0.id == "old" })
        #expect(snapshot.unread == fixtures.reduce(0) { $0 + $1.unreadCount })
        #expect(snapshot.unread == 2)
    }

    @Test func pinnedFirstThenRecent() {
        let snapshot = WidgetSnapshot(conversations: fixtures, previews: false, accent: nil, live: true)
        #expect(snapshot.rows.map(\.id) == ["groceries", "trip"])
        let many = (0..<20).map { conversation("c\($0)", items: [item("m\($0)", .agent, "x", at: Int64($0) * 10)]) }
        let capped = WidgetSnapshot(conversations: many, previews: false, accent: nil, live: true)
        #expect(capped.rows.count == WidgetSnapshot.rowLimit)
        #expect(capped.rows.first?.id == "c19")
    }

    @Test func previewsAreLeftOutUnlessTurnedOn() throws {
        let off = WidgetSnapshot(conversations: fixtures, previews: false, accent: nil, live: true)
        #expect(off.preview == nil)
        let encoded = try #require(WidgetStore.encode(off))
        let json = try #require(String(data: encoded, encoding: .utf8))
        for text in ["Booked the ryokan", "Day one", "Plan a weekend in Kyoto", "Added."] {
            #expect(!json.contains(text))
        }
        let on = WidgetSnapshot(conversations: fixtures, previews: true, accent: nil, live: true)
        #expect(on.preview == WidgetSnapshot.Preview(convId: "trip", text: "Booked the ryokan."))
    }

    @Test func previewIsOneClippedLine() {
        #expect(WidgetSnapshot.clip("\n  First line  \nSecond") == "First line")
        let long = WidgetSnapshot.clip(String(repeating: "a", count: 500))
        #expect(long.count == WidgetSnapshot.previewLimit)
        #expect(long.hasSuffix("…"))
    }

    @Test func encodingRoundTrips() throws {
        let snapshot = WidgetSnapshot(conversations: fixtures, previews: true, accent: "teal", live: false, seen: ["e1"])
        let data = try #require(WidgetStore.encode(snapshot))
        #expect(try JSONDecoder().decode(WidgetSnapshot.self, from: data) == snapshot)
        #expect(WidgetStore.encode(snapshot) == data)
    }

    @Test func writeSkipsWhenUnchanged() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = WidgetSnapshot(conversations: fixtures, previews: false, accent: nil, live: true)
        #expect(WidgetStore.write(snapshot, to: url))
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        #expect(!WidgetStore.write(snapshot, to: url))
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date == modified)
        var changed = snapshot
        changed.accent = "blue"
        #expect(WidgetStore.write(changed, to: url))
        #expect(WidgetStore.read(from: url) == changed)
        #expect(WidgetStore.remove(at: url))
        #expect(!WidgetStore.remove(at: url))
    }

    @Test func notificationCountsAReplyOnce() {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        // No snapshot (unpaired or demo mode): the notification service writes nothing.
        let wrote = WidgetStore.update(at: url) { snapshot in
            snapshot.receive(convId: "trip", title: nil, body: "x", event: "e1", at: .now, previews: true)
        }
        #expect(!wrote)
        #expect(WidgetStore.read(from: url) == nil)

        WidgetStore.write(WidgetSnapshot(conversations: fixtures, previews: false, accent: nil, live: false), to: url)
        let reply = { (event: String, previews: Bool) in
            WidgetStore.update(at: url) { snapshot in
                snapshot.receive(convId: "trip", title: "Trip planning", body: "All set.\nDetails", event: event, at: .now, previews: previews)
            }
        }
        let first = reply("e1", false)
        let again = reply("e1", false)
        #expect(first)
        #expect(!again)
        var snapshot = WidgetStore.read(from: url)
        #expect(snapshot?.unread == 3)
        #expect(snapshot?.rows.first { $0.id == "trip" }?.unread == 2)
        #expect(snapshot?.preview == nil)

        let withPreview = reply("e2", true)
        #expect(withPreview)
        snapshot = WidgetStore.read(from: url)
        #expect(snapshot?.preview == WidgetSnapshot.Preview(convId: "trip", text: "All set."))
    }

    @Test func appInFrontOwnsTheCounts() {
        var snapshot = WidgetSnapshot(conversations: fixtures, previews: false, accent: nil, live: true)
        let changed = snapshot.receive(convId: "trip", title: nil, body: "x", event: "e1", at: .now, previews: false)
        #expect(!changed)
        #expect(snapshot.unread == 2)
    }

    @Test func newConversationFromAPushJoinsTheRows() {
        var snapshot = WidgetSnapshot(conversations: fixtures, previews: false, accent: nil, live: false)
        let changed = snapshot.receive(convId: "fresh", title: "", body: "Hi", event: "e9", at: Date(timeIntervalSince1970: 10), previews: false)
        #expect(changed)
        #expect(snapshot.rows.map(\.id) == ["groceries", "fresh", "trip"])
        #expect(snapshot.latest?.id == "fresh")
    }

    @Test func seenEventsAreBounded() {
        var snapshot = WidgetSnapshot(live: false)
        for index in 0..<40 { _ = snapshot.receive(convId: "c", title: nil, body: "", event: "e\(index)", at: .now, previews: false) }
        #expect(snapshot.seen.count == WidgetSnapshot.seenLimit)
        #expect(snapshot.unread == 40)
    }
}

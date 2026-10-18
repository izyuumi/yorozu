import Foundation
import YorozuWire

/// The App Review demo's host (OWNER_DECISIONS.md, App Review), behind the code `YOROZU-DEMO`: a made-up OpenClaw host
/// on this device. It answers the client's requests as the plugin would, from seeded conversations, automations and
/// devices, and replies to every message with a scripted reply in parts. Everything lives in memory and goes with it.
actor DemoTransport: Transport {
    static let code = "YOROZU-DEMO"

    /// A pairing with nobody, never saved: the Settings host rows read it.
    static var pairing: V3Pairing {
        let hostKey = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 * 37 + 11) })
        let none = Data()
        return V3Pairing(
            pairing: QrPayload(v: 3, relayUrl: "wss://relay.example.com", macPubkey: hostKey.base64URLEncodedString(),
                token: "", roomId: "demo"),
            identity: PhoneIdentity(signingPrivateKey: none, signingPublicKey: none, sessionPrivateKey: none, sessionPublicKey: none),
            relayKnows: true, paired: true, pairedAt: Date(timeIntervalSinceNow: -41 * day))
    }

    private struct Conv {
        let id: String
        var title: String?
        var archived: Bool?
        var items: [V3HistoryItem] = []
        var read: V3ReadCursor?
        var rev: Int { items.last?.seq ?? 0 }
        var updatedAt: Int64 { items.last?.ts ?? 0 }
    }

    private enum Turn {
        case user(String)
        case agent(String)
        /// The tool calls of the run answering the user turn before it.
        case tools([String])
    }

    private var continuation: AsyncStream<V3Connection.Update>.Continuation?
    private var threads: [Conv] = []
    private var jobs: [V3CronJob] = []
    private var devices: [V3DeviceInfo] = []
    private var runs: [Task<Void, Never>] = []
    private var seq = 0

    init() {
        let now = Self.now
        let minute: Int64 = 60_000
        let hour = 60 * minute
        // Seeded newest first; each conversation's last turn is `ago` before now, its turns a few minutes apart.
        var seq = 0
        threads = [
            Self.seed("Weekend in the mountains", ago: 12 * minute, unread: 1, Self.mountains, seq: &seq),
            Self.seed("Morning briefing", ago: 3 * hour, unread: 1, Self.briefing, seq: &seq),
            Self.seed("Code review: retry helper", ago: 26 * hour, Self.review, seq: &seq),
            Self.seed("Sourdough schedule", ago: 2 * 24 * hour, Self.sourdough, seq: &seq),
            Self.seed("Leggy tomato seedlings", ago: 4 * 24 * hour, Self.seedlings, seq: &seq),
            Self.seed("Bike commute", ago: 6 * 24 * hour, Self.commute, seq: &seq),
            Self.seed("Moving checklist", ago: 23 * 24 * hour, archived: true, Self.moving, seq: &seq),
        ]
        self.seq = seq
        let briefing = threads[1].id
        jobs = [
            V3CronJob(id: "morning-briefing", name: "Morning briefing", enabled: true,
                schedule: .object(["kind": .string("cron"), "expr": .string("30 7 * * *")]),
                scheduleText: "Every day at 07:30", nextRunAt: now + 21 * hour, lastRunAt: now - 3 * hour, lastStatus: "ok",
                delivery: .init(channel: "yorozu", threadId: briefing)),
            V3CronJob(id: "water-seedlings", name: "Water the seedlings", enabled: true,
                schedule: .object(["kind": .string("cron"), "expr": .string("0 18 * * 1,3,5")]),
                scheduleText: "Monday, Wednesday and Friday at 18:00", nextRunAt: now + 7 * hour,
                lastRunAt: now - 41 * hour, lastStatus: "ok"),
            V3CronJob(id: "grocery-list", name: "Weekly grocery list", enabled: true,
                schedule: .object(["kind": .string("cron"), "expr": .string("0 10 * * 0")]),
                scheduleText: "Every Sunday at 10:00", nextRunAt: now + 3 * 24 * hour, lastRunAt: now - 4 * 24 * hour,
                lastStatus: "skipped"),
            V3CronJob(id: "photo-backup", name: "Photo backup check", enabled: true,
                schedule: .object(["kind": .string("every"), "everyMs": .number(21_600_000)]),
                scheduleText: "Every 6 hours", nextRunAt: now + 2 * hour, lastRunAt: now - 4 * hour, lastStatus: "error",
                lastError: "The backup drive wasn’t connected, so no photos were copied."),
            V3CronJob(id: "budget-review", name: "Quarterly budget review", enabled: false,
                schedule: .object(["kind": .string("cron"), "expr": .string("0 9 1 */3 *")]),
                scheduleText: "First day of every quarter at 09:00", lastRunAt: now - 60 * 24 * hour, lastStatus: "ok"),
        ]
        devices = [
            V3DeviceInfo(id: "demo-this-device", name: DeviceModel.name, pairedAt: now - 41 * 24 * hour, push: true, current: true),
            V3DeviceInfo(id: "demo-ipad", name: "iPad Air", pairedAt: now - 30 * 24 * hour, push: true, current: false),
            V3DeviceInfo(id: "demo-laptop", name: "MacBook Air", pairedAt: now - 12 * 24 * hour, push: false, current: false),
        ]
    }

    // MARK: Transport

    func updates() -> AsyncStream<V3Connection.Update> {
        let (stream, continuation) = AsyncStream<V3Connection.Update>.makeStream()
        self.continuation = continuation
        return stream
    }

    func start() {
        var host = V3PeerInfo(app: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
            name: "Studio Mac", capabilities: [V3Devices.capability])
        host.agent = "assistant"
        host.hostVersion = "2026.10.1"
        continuation?.yield(.state(.ready))
        continuation?.yield(.sessionOpen(host))
    }

    func reconnect() {}

    func stop() {
        for run in runs { run.cancel() }
        runs = []
        continuation?.finish()
        continuation = nil
    }

    func registerPush(deviceToken: String) {}

    func send(_ message: V3Message) -> Bool {
        guard continuation != nil, V3Event.isId(message.convId) else { return false }
        let index = threads.firstIndex { $0.id == message.convId } ?? {
            threads.insert(Conv(id: message.convId), at: 0)
            return 0
        }()
        threads[index].items.append(item(.user, id: message.messageId, ts: Self.now, text: message.text))
        runs.append(Task { await run(message) })
        return true
    }

    func send(_ event: V3Event) -> Bool {
        guard continuation != nil else { return false }
        switch event {
        case .convList(let request) where request.conversations == nil:
            let summaries = threads.filter { !$0.items.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }.map {
                V3ConvSummary(convId: $0.id, updatedAt: $0.updatedAt, rev: $0.rev, title: $0.title, archived: $0.archived)
            }
            emit(.convList(V3ConvList(conversations: summaries)))
            // As the plugin does on a new session: every stored read cursor.
            for cursor in threads.compactMap(\.read) { emit(.readCursor(cursor)) }
        case .historyRequest(let request):
            let items = request.before != nil ? [] : threads.first { $0.id == request.convId }?.items
                .filter { $0.seq > (request.after ?? -1) } ?? []
            let rev = threads.first { $0.id == request.convId }?.rev ?? 0
            emit(.history(V3History(convId: request.convId, before: request.before, after: request.after, items: items,
                more: false, rev: rev)))
        case .readCursor(let cursor):
            if let index = threads.firstIndex(where: { $0.id == cursor.convId }) { threads[index].read = cursor }
            emit(.readCursor(cursor))
        case .convPatch(let patch):
            guard let index = threads.firstIndex(where: { $0.id == patch.convId }) else { break }
            if patch.deleted == true {
                threads.remove(at: index)
                emit(.convUpdate(V3ConvUpdate(convId: patch.convId, deleted: true)))
                break
            }
            if let title = patch.title { threads[index].title = title.isEmpty ? nil : title }
            if let archived = patch.archived { threads[index].archived = archived ? true : nil }
            emit(.convUpdate(V3ConvUpdate(convId: patch.convId, title: threads[index].title, archived: threads[index].archived)))
        case .cronList(let request) where request.jobs == nil:
            emit(.cronList(V3CronList(jobs: jobs)))
        case .deviceList(let request) where request.devices == nil:
            emit(.deviceList(V3DeviceList(devices: devices)))
        case .devicePatch(let patch):
            if patch.removed == true {
                devices.removeAll { $0.id == patch.id && !$0.current }
            } else if let push = patch.push, let index = devices.firstIndex(where: { $0.id == patch.id }) {
                devices[index].push = push
            }
            emit(.deviceList(V3DeviceList(devices: devices)))
        default:
            break
        }
        return true
    }

    // MARK: Replies

    /// The plugin's sequence for one message: relayed, delivered, the run with its tools, the reply in parts, a title.
    private func run(_ message: V3Message) async {
        let ref = V3MessageRef(convId: message.convId, messageId: message.messageId)
        let script = Self.reply(to: message.text)
        guard await pause(0.3) else { return }
        continuation?.yield(.accepted(messageId: message.messageId))
        guard await pause(0.4) else { return }
        emit(.delivered(ref))
        guard await pause(0.6) else { return }
        emit(.runStarted(ref))
        for (index, tool) in script.tools.enumerated() {
            let callId = "demo-\(message.messageId.prefix(8))-\(index)"
            emit(.tool(V3Tool(convId: ref.convId, messageId: ref.messageId, callId: callId, name: tool, status: .running)))
            guard await pause(0.9) else { return }
            emit(.tool(V3Tool(convId: ref.convId, messageId: ref.messageId, callId: callId, name: tool, status: .done)))
        }
        if !script.tools.isEmpty, let index = threads.firstIndex(where: { $0.id == ref.convId }) {
            let calls = script.tools.enumerated().map {
                V3HistoryItem.Call(callId: "demo-\(message.messageId.prefix(8))-\($0.offset)", name: $0.element, status: .done)
            }
            threads[index].items.append(item(.tools, id: ref.messageId, ts: Self.now, tools: calls))
        }
        for part in script.parts {
            guard await pause(1.2) else { return }
            let reply = V3Reply(convId: ref.convId, messageId: V3Event.newId(), text: part, ts: Self.now)
            if let index = threads.firstIndex(where: { $0.id == ref.convId }) {
                threads[index].items.append(item(.agent, id: reply.messageId, ts: reply.ts, text: reply.text))
            }
            emit(.reply(reply))
        }
        emit(.typing(V3Typing(convId: ref.convId, active: false)))
        // A new conversation gets its generated title after the first reply, as on a real host.
        if let index = threads.firstIndex(where: { $0.id == ref.convId }), threads[index].title == nil {
            let words = message.text.split(whereSeparator: \.isWhitespace).prefix(5).joined(separator: " ")
            threads[index].title = words.isEmpty ? "New conversation" : words
            emit(.convUpdate(V3ConvUpdate(convId: ref.convId, title: threads[index].title, archived: threads[index].archived)))
        }
    }

    /// False once the demo has ended.
    private func pause(_ seconds: Double) async -> Bool {
        try? await Task.sleep(for: .seconds(seconds))
        return !Task.isCancelled && continuation != nil
    }

    private func emit(_ event: V3Event) {
        continuation?.yield(.event(event))
    }

    private func item(_ kind: V3HistoryItem.Kind, id: String, ts: Int64, text: String? = nil,
        tools: [V3HistoryItem.Call]? = nil) -> V3HistoryItem {
        seq += 1
        return V3HistoryItem(kind: kind, id: id, seq: seq, ts: ts, text: text, tools: tools)
    }

    /// One seeded conversation, its items numbered on from `seq`. The last `unread` replies come after its read cursor.
    private static func seed(_ title: String, ago: Int64, unread: Int = 0, archived: Bool = false, _ turns: [Turn],
        seq: inout Int) -> Conv {
        var conv = Conv(id: V3Event.newId(), title: title, archived: archived ? true : nil)
        let end = now - ago
        var lastUser = V3Event.newId()
        for (index, turn) in turns.enumerated() {
            let ts = end - Int64(turns.count - 1 - index) * 90_000
            seq += 1
            switch turn {
            case .user(let text):
                lastUser = V3Event.newId()
                conv.items.append(V3HistoryItem(kind: .user, id: lastUser, seq: seq, ts: ts, text: text))
            case .agent(let text):
                conv.items.append(V3HistoryItem(kind: .agent, id: V3Event.newId(), seq: seq, ts: ts, text: text))
            case .tools(let names):
                let calls = names.enumerated().map { V3HistoryItem.Call(callId: "seed-\(seq)-\($0.offset)", name: $0.element, status: .done) }
                conv.items.append(V3HistoryItem(kind: .tools, id: lastUser, seq: seq, ts: ts, tools: calls))
            }
        }
        if let read = conv.items.filter({ $0.kind == .agent }).dropLast(unread).last {
            conv.read = V3ReadCursor(convId: conv.id, messageId: read.id, ts: read.ts, unread: false)
        }
        return conv
    }

    private static let day: TimeInterval = 86_400
    private static var now: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: Fixtures

extension DemoTransport {
    private struct Script {
        var tools: [String] = []
        let parts: [String]
    }

    /// The scripted reply: picked by a word in the message, else one that says what the demo is.
    private static func reply(to text: String) -> Script {
        let text = text.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("recipe", "cook", "bake", "dinner", "bread", "lunch") {
            return Script(tools: ["memory_search"], parts: [
                "Here’s a quick one that fits a weeknight: **lemon garlic pasta** for two, about 20 minutes.",
                """
                1. Boil 200 g of spaghetti in well-salted water.
                2. Meanwhile, warm 3 tbsp olive oil with 2 sliced garlic cloves over low heat.
                3. Add the zest and juice of one lemon, then a ladle of pasta water.
                4. Toss the drained pasta in the pan with a handful of grated parmesan.

                Finish with black pepper and parsley. Want a shopping list for it?
                """,
            ])
        }
        if has("trip", "travel", "weekend", "pack", "hike", "holiday") {
            return Script(tools: ["web_search", "weather"], parts: [
                "I checked the forecast: dry and mild on Saturday, showers likely Sunday afternoon.",
                """
                **Plan**
                - Saturday: the long ridge walk while it’s dry, picnic at the viewpoint.
                - Sunday: a short morning loop, then the café by the station before the rain.

                Pack a light rain jacket either way.
                """,
            ])
        }
        if has("code", "swift", "bug", "function", "review", "error") {
            return Script(tools: ["read_file"], parts: [
                "Happy to look. A small, testable shape usually reads best:",
                """
                ```swift
                func average(_ values: [Double]) -> Double? {
                    guard !values.isEmpty else { return nil }
                    return values.reduce(0, +) / Double(values.count)
                }
                ```

                Returning `nil` for an empty list keeps the caller honest instead of hiding a divide by zero.
                """,
            ])
        }
        if has("garden", "plant", "water", "tomato", "seed", "flower") {
            return Script(parts: [
                "Most garden trouble comes down to light, water or drainage.",
                """
                - **Light:** six hours of sun for vegetables, less for herbs like mint.
                - **Water:** deeply and less often, at the base, in the morning.
                - **Drainage:** a pot without a hole drowns roots; add one or use a liner.

                Tell me what you’re growing and I’ll be more specific.
                """,
            ])
        }
        if has("remind", "schedule", "every", "automation", "daily", "tomorrow") {
            return Script(tools: ["cron"], parts: [
                "Done: I scheduled it as an automation. You’ll find it under **Automations**, and its message will arrive in this conversation.",
            ])
        }
        return Script(parts: [
            "This is Yorozu’s demo, running entirely on this device.",
            """
            With a real setup, your message goes end-to-end encrypted to the OpenClaw agent on your own computer, and its \
            reply comes back here, in parts like this one.

            Try asking about a **recipe**, a **weekend trip**, some **code** or your **garden**.
            """,
        ])
    }

    private static let mountains: [Turn] = [
        .user("Help me plan a weekend in the mountains. Two of us, leaving Friday evening, moderate hiking."),
        .tools(["web_search", "weather", "web_search"]),
        .agent("""
            Here’s a relaxed plan with one big day and one easy day:

            **Friday**
            - Leave after work, about a 2½-hour drive.
            - Check in at the lodge near the trailhead; dinner there is good and simple.

            **Saturday**
            - 8:00 breakfast, 9:00 start the **Lake Loop** (14 km, 600 m climb, about 5 hours).
            - Picnic at the upper lake; the view is best before noon.

            **Sunday**
            - Short **Forest Trail** (5 km) in the morning, then lunch in the village and drive back.

            The forecast is dry Saturday, with showers possible Sunday afternoon.
            """),
        .user("Nice. What should we pack?"),
        .agent("""
            For day hikes in early autumn:

            1. Layers: a base layer, a fleece, and a waterproof shell
            2. Broken-in hiking shoes and spare socks
            3. 1.5 L of water each, plus snacks for the climb
            4. Map downloaded offline; signal is patchy past the first lake
            5. Sun cream and a hat, even if it’s cool
            6. A small first-aid kit and a head torch

            Leave room for a warm hat; mornings near the lakes are cold.
            """),
        .user("Is the lake trail still OK if it rains a bit?"),
        .agent("""
            Light rain is fine: the path is well kept and mostly forest until the upper lake. Skip the ridge shortcut \
            though, it gets slippery when wet. If it’s pouring at breakfast, swap the days and do the Forest Trail first.
            """),
    ]

    private static let briefing: [Turn] = [
        .agent("""
            Good morning! Yesterday’s summary:

            - ☀️ 17 °C, clear all day.
            - 📅 Nothing scheduled after 15:00.
            - ✅ All reminders done.
            """),
        .agent("""
            Good morning! Here’s your day:

            - 🌦️ 18 °C, clear until mid-afternoon, light rain after 16:00.
            - 📅 Dentist at 11:30, team call at 15:00.
            - ✅ Pay the electricity bill, water the seedlings, return the library books.

            Take an umbrella if you’re out late.
            """),
    ]

    private static let review: [Turn] = [
        .user("""
            Can you review this retry helper? It feels too clever.

            ```swift
            func retry<T>(_ times: Int, _ body: () async throws -> T) async throws -> T {
                do { return try await body() } catch {
                    if times <= 1 { throw error }
                    return try await retry(times - 1, body)
                }
            }
            ```
            """),
        .tools(["read_file"]),
        .agent("""
            It works, but three things are worth changing:

            1. **No delay between attempts.** A failing network call is retried at once, which rarely helps.
            2. **Cancellation is retried too.** A cancelled task should stop, not try again.
            3. **Recursion** hides the loop; a plain loop is easier to read and to step through.

            A loop with exponential backoff:

            ```swift
            func retry<T>(
                attempts: Int = 3,
                delay: Duration = .milliseconds(200),
                _ body: () async throws -> T
            ) async throws -> T {
                var wait = delay
                for _ in 1..<attempts {
                    do {
                        return try await body()
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try await Task.sleep(for: wait)
                        wait *= 2
                    }
                }
                return try await body()
            }
            ```
            """),
        .user("Should the delay have some jitter?"),
        .agent("""
            Yes, if many clients might retry together: it spreads them out. Add a little randomness to each wait, \
            for example `wait * 2 + .milliseconds(Int.random(in: 0...100))`. For a single app talking to its own \
            server, plain doubling is fine.
            """),
    ]

    private static let sourdough: [Turn] = [
        .user("I want fresh sourdough for Sunday lunch. When do I start?"),
        .agent("""
            Start on **Saturday morning**. A schedule that leaves your evening free:

            | When | Step |
            | --- | --- |
            | Sat 09:00 | Feed the starter |
            | Sat 13:00 | Mix flour and water, rest 1 hour |
            | Sat 14:00 | Add starter and salt |
            | Sat 14:30–17:00 | Four sets of stretch and folds |
            | Sat 20:00 | Shape, then into the fridge overnight |
            | Sun 10:00 | Bake 20 min lid on, 25 min lid off |

            Let it cool for an hour before slicing, or the crumb turns gummy.
            """),
        .user("My kitchen is cold, around 18 °C."),
        .agent("""
            Then give the bulk ferment longer: aim for the dough to grow by about **half**, not by time. At 18 °C \
            that’s often 6–7 hours. Putting the bowl in the oven with only the light on helps.
            """),
    ]

    private static let seedlings: [Turn] = [
        .user("My tomato seedlings are tall and floppy. What’s wrong?"),
        .agent("""
            That’s **legginess**: they’re stretching for light. Three fixes:

            1. Move the lamp to 5–10 cm above them, on for about 14 hours a day.
            2. A gentle fan or brushing them by hand each day thickens the stems.
            3. Repot them **deeper**: tomatoes grow roots along the buried stem.
            """),
        .user("Repotted them deeper today. Thanks!"),
        .agent("Great. Water at the base for the next few days and keep them out of strong sun until they perk up."),
    ]

    private static let commute: [Turn] = [
        .user("Is a 12 km bike commute realistic for a beginner?"),
        .agent("""
            Yes, with a gentle start. At an easy 18 km/h it’s about **40 minutes** each way.

            - Week 1–2: ride two days a week, take the train home if you’re tired.
            - Week 3–4: three days.
            - After that: most days, with a rest day mid-week.

            Plan a route with bike lanes even if it’s a little longer, and keep a spare shirt at work.
            """),
    ]

    private static let moving: [Turn] = [
        .user("Make me a checklist for moving flats next month."),
        .agent("""
            > Start early with what has a lead time.

            **Four weeks before**
            - Book the van or movers.
            - Give notice for internet and electricity, and book the new ones.

            **One week before**
            - Pack everything you won’t need, room by room, labelled.
            - Arrange a key handover with the landlord.

            **On the day**
            - Take meter photos in both flats.
            - Keep a box of essentials with you: chargers, kettle, towels.
            """),
    ]
}

import Foundation
import YorozuWire

/// Fictional examples, recreated for each demo session and never persisted.
enum V3DemoData {
    static let welcomeID = "d0000000-0000-4000-8000-000000000001"
    static let travelID = "d0000000-0000-4000-8000-000000000002"
    static let codeID = "d0000000-0000-4000-8000-000000000003"
    static let archiveID = "d0000000-0000-4000-8000-000000000004"
    private static var japanese: Bool { Locale.preferredLanguages.first?.hasPrefix("ja") == true }
    static var titles: [String: String] { japanese
        ? [welcomeID: "ゆとりのある一日の始め方", travelID: "週末の京都旅行",
            codeID: "小さな改善を届ける", archiveID: "週末の読書リスト"]
        : [welcomeID: "A calmer start to the day", travelID: "A weekend in Kyoto",
        codeID: "Ship a small improvement", archiveID: "The reading list"] }

    static var histories: [String: [V3HistoryItem]] {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        func thread(_ pairs: [(V3HistoryItem.Kind, String)], age: Int64, toolRow: Bool = false) -> [V3HistoryItem] {
            var items = pairs.enumerated().map { index, pair in
                V3HistoryItem(kind: pair.0, id: V3Event.newId(), seq: index + 1,
                    ts: now - age + Int64(index * 30_000), text: pair.1)
            }
            if toolRow, let user = items.first {
                let json = """
                [{"callId":"demo-review","name":"demo_sample","status":"done"}]
                """
                let calls = try? JSONDecoder().decode([V3HistoryItem.Call].self, from: Data(json.utf8))
                items.insert(V3HistoryItem(kind: .tools, id: user.id, seq: 2, ts: user.ts + 15_000, tools: calls), at: 1)
                for index in items.indices { items[index].seq = index + 1 }
            }
            return items
        }
        if japanese {
            return [
                welcomeID: thread([
                    (.user, "一日に少しゆとりを作りたい。"),
                    (.agent, "## 小さな余白を作る\n\n1. 今日できたらうれしいことを**一つ**選びます。\n2. 45分だけ集中する時間を確保します。\n3. 予定と予定の間に少し余裕を持たせます。\n\n> 計画は、一日を軽くするために。"),
                    (.user, "朝のチェックインにできる？"),
                    (.agent, "オートメーションの**朝のチェックイン**でスケジュールを確認できます。自分に合う時間を考えてみましょう。朝の何時ごろがよさそうですか？")
                ], age: 420_000),
                travelID: thread([
                    (.user, "コーヒーと散歩を楽しむ、ゆったりした京都の週末を考えて。"),
                    (.agent, "## 土曜日 · 東山\n\n- 朝は哲学の道を散歩。\n- コーヒーとゆっくりした昼食。\n- 午後は祇園を歩き、夜の予定は空けておきます。\n\n## 日曜日 · のんびりと\n\n川沿いを歩いて、本屋をのぞき、帰りの電車まで余裕を持たせます。\n\n**柔軟に：** 一日の中心を一つだけ決めましょう。"),
                    (.user, "持ち物は？"),
                    (.agent, "歩きやすい靴、羽織るもの、小さな傘、水、充電したスマートフォン。予約情報も保存しておきましょう。\n\n営業時間や交通情報は旅行前に確認してください。")
                ], age: 7_200_000),
                codeID: thread([
                    (.user, "アプリの小さな改善はどう進める？"),
                    (.agent, "目に見える動作を一つ選びます。\n\n```swift\nstruct SmallStep {\n    let outcome: String\n    let verification: String\n}\n```\n\n- 利用者にどう見えるかを書きます。\n- 関係するコードを読みます。\n- 小さく完結した変更を加えます。\n- コンパイルしてアプリで確認します。")
                ], age: 86_400_000, toolRow: true),
                archiveID: thread([
                    (.user, "静かな週末の読書リストを作って。"),
                    (.agent, "小説を一冊、エッセイを一本、読み返したいものを一つ。残りは次の週末に。\n\n気になった一節を短くメモしておくと、あとで読み返す楽しみも増えます。")
                ], age: 172_800_000)
            ]
        }
        return [
            welcomeID: thread([
                (.user, "Help me make some room in my day."),
                (.agent, "## A little space goes a long way\n\n1. Choose **one thing** that would make today feel worthwhile.\n2. Give it a quiet 45-minute block.\n3. Leave a little room between meetings.\n\n> A useful plan should make your day lighter."),
                (.user, "Can you turn that into a morning check-in?"),
                (.agent, "You can find **Morning check-in** in Automations and review its schedule. What time in the morning would work best for you?")
            ], age: 420_000),
            travelID: thread([
                (.user, "Plan a gentle two-day trip to Kyoto with time for coffee and walking."),
                (.agent, "## Saturday · East Kyoto\n\n- Start early with a walk along the Philosopher’s Path.\n- Stop for coffee and a slow lunch.\n- Spend the afternoon around Gion, leaving the evening open.\n\n## Sunday · A change of pace\n\nTake a morning walk by the river, browse a bookshop, and leave time for the train home.\n\n**Keep it flexible:** choose one main stop each day and let everything else be optional."),
                (.user, "What should I pack?"),
                (.agent, "Comfortable shoes, a light layer, a small umbrella, a water bottle, and a charged phone. Save your booking details before leaving.\n\nCheck opening times and travel details before you go.")
            ], age: 7_200_000),
            codeID: thread([
                (.user, "What’s a sensible way to break down a small app improvement?"),
                (.agent, "Start with one visible behavior:\n\n```swift\nstruct SmallStep {\n    let outcome: String\n    let verification: String\n}\n```\n\n- Describe what the person using the app should see.\n- Read the code that owns that behavior.\n- Make the smallest complete change.\n- Compile and check it in the app.\n\nKeep the scope small enough to review in one sitting.")
            ], age: 86_400_000, toolRow: true),
            archiveID: thread([
                (.user, "Make a short reading list for a quiet weekend."),
                (.agent, "Pick one novel, one essay, and one thing you’ve been meaning to reread. Leave the rest for another weekend.\n\nKeep a short note of a passage you enjoy so you can return to it later.")
            ], age: 172_800_000)
        ]
    }

    /// A fictional current-device row; its id is deliberately not a relay public key.
    static var devices: [V3DeviceInfo] {
        let json = """
        [{"id":"demo-device","pairedAt":1781827200000,"push":false,"current":true}]
        """
        var devices = (try? JSONDecoder().decode([V3DeviceInfo].self, from: Data(json.utf8))) ?? []
        if !devices.isEmpty { devices[0].name = String(localized: "Demo Device") }
        return devices
    }

    static var crons: [V3CronJob] {
        // Decode the public wire shape, just like a cron_list answer from the plugin.
        let json = """
        [{"id":"demo-morning","name":"Morning check-in","enabled":true,
          "schedule":{"kind":"cron","expr":"0 9 * * 1-5","tz":"Asia/Tokyo"},
          "scheduleText":"Weekdays at 09:00 (Asia/Tokyo)","lastStatus":"ok",
          "delivery":{"channel":"yorozu","threadId":"\(welcomeID)"}},
         {"id":"demo-weekend","name":"Weekend reading reminder","enabled":false,
          "schedule":{"kind":"cron","expr":"0 10 * * 6","tz":"Asia/Tokyo"},
          "scheduleText":"Saturdays at 10:00 (Asia/Tokyo)",
          "delivery":{"channel":"yorozu","threadId":"\(archiveID)"}}]
        """
        var jobs = (try? JSONDecoder().decode([V3CronJob].self, from: Data(json.utf8))) ?? []
        if japanese, jobs.count == 2 {
            jobs[0].name = "朝のチェックイン"
            jobs[0].scheduleText = "平日 09:00（Asia/Tokyo）"
            jobs[1].name = "週末の読書リマインダー"
            jobs[1].scheduleText = "毎週土曜日 10:00（Asia/Tokyo）"
        }
        return jobs

    }

    static var resetReply: String {
        japanese ? "新しいセッションを始めました。何から取り組みましょうか？"
            : "Fresh session started. What would you like to work on?"
    }

    static func reply(to text: String) -> String {
        if japanese {
            if text.contains("オートメーション") || text.contains("予定") || text.contains("チェックイン") {
                return "時間と曜日を決めると、無理なく続けやすくなります。\n\n例えば、**平日の朝8時半**はいかがですか？ 希望の時間を教えてください。"
            }
            if text.contains("計画") || text.contains("旅行") || text.contains("京都") {
                return "## ゆとりのある計画\n\n1. 楽しみにしていることを一つ選びます。\n2. ゆとりのある時間を確保します。\n3. 天気や気分が変わったときの代案を用意します。\n\nまずは、いちばん楽しみにしていることから決めましょう。"
            }
            if text.contains("要約") || text.contains("まとめ") {
                return "**ここまでのまとめ**\n\n- 今日の優先事項を一つ選びます。\n- 集中できる時間を確保します。\n- 予定と予定の間に余白を残します。\n\n次にできる小さな一歩は何でしょうか？"
            }
            return "何に取り組みましょうか？\n\n**計画を立てる**、**内容をまとめる**、**日々の習慣を考える**など、お手伝いできます。まずは今いちばん気になっていることを教えてください。"
        }

        let text = text.lowercased()
        if text.contains("automation") || text.contains("schedule") || text.contains("check-in") {
            return "Start with a time and the days that fit your routine.\n\nFor example, **8:30 on weekdays** leaves weekends free. What time would work best for you?"
        }
        if text.contains("plan") || text.contains("trip") || text.contains("kyoto") {
            return "## A simple plan\n\n1. Choose one thing you’re looking forward to.\n2. Leave a generous block of time for it.\n3. Keep a second option for a change in weather or energy.\n\nStart with the part you’re most looking forward to, then build around it."
        }
        if text.contains("summary") || text.contains("summarize") {
            return "**The main points**\n\n- Choose one priority for the day.\n- Give it a quiet block of time.\n- Leave a little room between commitments.\n\nWhat’s one small step you could take next?"
        }
        return "What would you like to work on?\n\nI can help with a **plan**, a **summary**, or ideas for a **daily routine**. Tell me what’s on your mind and we’ll start there."
    }
}

import Foundation
import YorozuWire

enum DemoData {
    static let welcomeID = "d0000000-0000-4000-8000-000000000001"
    static let travelID = "d0000000-0000-4000-8000-000000000002"
    static let codeID = "d0000000-0000-4000-8000-000000000003"
    static let archiveID = "d0000000-0000-4000-8000-000000000004"

    private static let content: Content = {
        let parts = (Locale.preferredLanguages.first ?? "en").split(separator: "-").map(String.init)
        switch parts.first ?? "" {
        case "ja": return .ja
        case "de": return .de
        case "es": return .es
        case "fr": return .fr
        case "ko": return .ko
        case "pt": return .ptBR
        case "zh":
            if parts.contains("Hant") { return .zhHant }
            if parts.contains("Hans") { return .zhHans }
            return parts.contains { ["TW", "HK", "MO"].contains($0) } ? .zhHant : .zhHans
        default: return .en
        }
    }()

    static var titles: [String: String] {
        [welcomeID: content.titles[0], travelID: content.titles[1],
            codeID: content.titles[2], archiveID: content.titles[3]]
    }

    static var histories: [String: [HistoryItem]] {
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        func thread(_ pairs: [(HistoryItem.Kind, String)], age: Int64, toolRow: Bool = false) -> [HistoryItem] {
            var items = pairs.enumerated().map { index, pair in
                HistoryItem(kind: pair.0, id: WireEvent.newId(), seq: index + 1,
                    ts: now - age + Int64(index * 30_000), text: pair.1)
            }
            if toolRow, let user = items.first {
                let json = """
                [{"callId":"demo-review","name":"demo_sample","status":"done"}]
                """
                let calls = try? JSONDecoder().decode([HistoryItem.Call].self, from: Data(json.utf8))
                items.insert(HistoryItem(kind: .tools, id: user.id, seq: 2, ts: user.ts + 15_000, tools: calls), at: 1)
                for index in items.indices { items[index].seq = index + 1 }
            }
            return items
        }
        return [
            welcomeID: thread(content.welcome, age: 420_000),
            travelID: thread(content.travel, age: 7_200_000),
            codeID: thread(content.code, age: 86_400_000, toolRow: true),
            archiveID: thread(content.archive, age: 172_800_000)
        ]
    }

    static var devices: [DeviceInfo] {
        let json = """
        [{"id":"demo-device","pairedAt":1781827200000,"push":false,"current":true}]
        """
        var devices = (try? JSONDecoder().decode([DeviceInfo].self, from: Data(json.utf8))) ?? []
        if !devices.isEmpty { devices[0].name = String(localized: "Demo Device") }
        return devices
    }

    static var crons: [CronJob] {
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
        var jobs = (try? JSONDecoder().decode([CronJob].self, from: Data(json.utf8))) ?? []
        for (index, cron) in content.crons.enumerated() where index < jobs.count {
            jobs[index].name = cron.name
            jobs[index].scheduleText = cron.scheduleText
        }
        return jobs
    }

    static var resetReply: String { content.resetReply }

    static func reply(to text: String) -> String {
        let text = text.lowercased()
        let reply = content.replies.first { reply in reply.keywords.contains { text.contains($0) } }
        return reply?.text ?? content.fallback
    }
}

private extension DemoData {
    struct Content: Sendable {
        let titles: [String]
        let welcome, travel, code, archive: [(HistoryItem.Kind, String)]
        let crons: [(name: String, scheduleText: String)]
        let resetReply: String
        let replies: [(keywords: [String], text: String)]
        let fallback: String
    }
}

private extension DemoData.Content {
    static let en = Self(
        titles: ["A calmer start to the day", "A weekend in Kyoto", "Ship a small improvement", "The reading list"],
        welcome: [
            (.user, "Help me make some room in my day."),
            (.agent, "## A little space goes a long way\n\n1. Choose **one thing** that would make today feel worthwhile.\n2. Give it a quiet 45-minute block.\n3. Leave a little room between meetings.\n\n> A useful plan should make your day lighter."),
            (.user, "Can you turn that into a morning check-in?"),
            (.agent, "You can find **Morning check-in** in Automations and review its schedule. What time in the morning would work best for you?")
        ],
        travel: [
            (.user, "Plan a gentle two-day trip to Kyoto with time for coffee and walking."),
            (.agent, "## Saturday · East Kyoto\n\n- Start early with a walk along the Philosopher’s Path.\n- Stop for coffee and a slow lunch.\n- Spend the afternoon around Gion, leaving the evening open.\n\n## Sunday · A change of pace\n\nTake a morning walk by the river, browse a bookshop, and leave time for the train home.\n\n**Keep it flexible:** choose one main stop each day and let everything else be optional."),
            (.user, "What should I pack?"),
            (.agent, "Comfortable shoes, a light layer, a small umbrella, a water bottle, and a charged phone. Save your booking details before leaving.\n\nCheck opening times and travel details before you go.")
        ],
        code: [
            (.user, "What’s a sensible way to break down a small app improvement?"),
            (.agent, "Start with one visible behavior:\n\n```swift\nstruct SmallStep {\n    let outcome: String\n    let verification: String\n}\n```\n\n- Describe what the person using the app should see.\n- Read the code that owns that behavior.\n- Make the smallest complete change.\n- Compile and check it in the app.\n\nKeep the scope small enough to review in one sitting.")
        ],
        archive: [
            (.user, "Make a short reading list for a quiet weekend."),
            (.agent, "Pick one novel, one essay, and one thing you’ve been meaning to reread. Leave the rest for another weekend.\n\nKeep a short note of a passage you enjoy so you can return to it later.")
        ],
        crons: [("Morning check-in", "Weekdays at 09:00 (Asia/Tokyo)"),
            ("Weekend reading reminder", "Saturdays at 10:00 (Asia/Tokyo)")],
        resetReply: "Fresh session started. What would you like to work on?",
        replies: [
            (["automation", "schedule", "check-in"], "Start with a time and the days that fit your routine.\n\nFor example, **8:30 on weekdays** leaves weekends free. What time would work best for you?"),
            (["plan", "trip", "kyoto"], "## A simple plan\n\n1. Choose one thing you’re looking forward to.\n2. Leave a generous block of time for it.\n3. Keep a second option for a change in weather or energy.\n\nStart with the part you’re most looking forward to, then build around it."),
            (["summary", "summarize"], "**The main points**\n\n- Choose one priority for the day.\n- Give it a quiet block of time.\n- Leave a little room between commitments.\n\nWhat’s one small step you could take next?")
        ],
        fallback: "What would you like to work on?\n\nI can help with a **plan**, a **summary**, or ideas for a **daily routine**. Tell me what’s on your mind and we’ll start there."
    )

    static let ja = Self(
        titles: ["ゆとりのある一日の始め方", "週末の京都旅行", "小さな改善を届ける", "週末の読書リスト"],
        welcome: [
            (.user, "一日に少しゆとりを作りたい。"),
            (.agent, "## 小さな余白を作る\n\n1. 今日できたらうれしいことを**一つ**選びます。\n2. 45分だけ集中する時間を確保します。\n3. 予定と予定の間に少し余裕を持たせます。\n\n> 計画は、一日を軽くするために。"),
            (.user, "朝のチェックインにできる？"),
            (.agent, "オートメーションの**朝のチェックイン**でスケジュールを確認できます。自分に合う時間を考えてみましょう。朝の何時ごろがよさそうですか？")
        ],
        travel: [
            (.user, "コーヒーと散歩を楽しむ、ゆったりした京都の週末を考えて。"),
            (.agent, "## 土曜日 · 東山\n\n- 朝は哲学の道を散歩。\n- コーヒーとゆっくりした昼食。\n- 午後は祇園を歩き、夜の予定は空けておきます。\n\n## 日曜日 · のんびりと\n\n川沿いを歩いて、本屋をのぞき、帰りの電車まで余裕を持たせます。\n\n**柔軟に：** 一日の中心を一つだけ決めましょう。"),
            (.user, "持ち物は？"),
            (.agent, "歩きやすい靴、羽織るもの、小さな傘、水、充電したスマートフォン。予約情報も保存しておきましょう。\n\n営業時間や交通情報は旅行前に確認してください。")
        ],
        code: [
            (.user, "アプリの小さな改善はどう進める？"),
            (.agent, "目に見える動作を一つ選びます。\n\n```swift\nstruct SmallStep {\n    let outcome: String\n    let verification: String\n}\n```\n\n- 利用者にどう見えるかを書きます。\n- 関係するコードを読みます。\n- 小さく完結した変更を加えます。\n- コンパイルしてアプリで確認します。")
        ],
        archive: [
            (.user, "静かな週末の読書リストを作って。"),
            (.agent, "小説を一冊、エッセイを一本、読み返したいものを一つ。残りは次の週末に。\n\n気になった一節を短くメモしておくと、あとで読み返す楽しみも増えます。")
        ],
        crons: [("朝のチェックイン", "平日 09:00（Asia/Tokyo）"),
            ("週末の読書リマインダー", "毎週土曜日 10:00（Asia/Tokyo）")],
        resetReply: "新しいセッションを始めました。何から取り組みましょうか？",
        replies: [
            (["オートメーション", "予定", "チェックイン"], "時間と曜日を決めると、無理なく続けやすくなります。\n\n例えば、**平日の朝8時半**はいかがですか？ 希望の時間を教えてください。"),
            (["計画", "旅行", "京都"], "## ゆとりのある計画\n\n1. 楽しみにしていることを一つ選びます。\n2. ゆとりのある時間を確保します。\n3. 天気や気分が変わったときの代案を用意します。\n\nまずは、いちばん楽しみにしていることから決めましょう。"),
            (["要約", "まとめ"], "**ここまでのまとめ**\n\n- 今日の優先事項を一つ選びます。\n- 集中できる時間を確保します。\n- 予定と予定の間に余白を残します。\n\n次にできる小さな一歩は何でしょうか？")
        ],
        fallback: "何に取り組みましょうか？\n\n**計画を立てる**、**内容をまとめる**、**日々の習慣を考える**など、お手伝いできます。まずは今いちばん気になっていることを教えてください。"
    )

    static let de = Self(
        titles: ["Ein ruhigerer Start in den Tag", "Ein Wochenende in Kyoto", "Eine kleine Verbesserung ausliefern", "Die Leseliste"],
        welcome: [
            (.user, "Hilf mir, in meinem Tag etwas Luft zu schaffen."),
            (.agent, "## Ein wenig Freiraum bewirkt viel\n\n1. Wähle **eine Sache**, die den heutigen Tag lohnenswert macht.\n2. Gib ihr einen ruhigen Block von 45 Minuten.\n3. Lass zwischen Terminen etwas Luft.\n\n> Ein guter Plan sollte deinen Tag leichter machen."),
            (.user, "Kannst du daraus einen Morgen-Check-in machen?"),
            (.agent, "Unter Automationen findest du **Morgen-Check-in** und kannst dort den Zeitplan prüfen. Welche Uhrzeit am Morgen passt dir am besten?")
        ],
        travel: [
            (.user, "Plane eine entspannte zweitägige Reise nach Kyoto mit Zeit für Kaffee und Spaziergänge."),
            (.agent, "## Samstag · Ost-Kyoto\n\n- Starte früh mit einem Spaziergang auf dem Philosophenweg.\n- Gönn dir einen Kaffee und ein gemütliches Mittagessen.\n- Verbring den Nachmittag rund um Gion und lass den Abend offen.\n\n## Sonntag · Ein anderes Tempo\n\nMach morgens einen Spaziergang am Fluss, stöbere in einer Buchhandlung und plane genug Zeit für den Zug nach Hause ein.\n\n**Bleib flexibel:** Wähle pro Tag einen Hauptpunkt und lass alles andere optional."),
            (.user, "Was sollte ich einpacken?"),
            (.agent, "Bequeme Schuhe, eine leichte Jacke, einen kleinen Regenschirm, eine Trinkflasche und ein aufgeladenes Handy. Speichere deine Buchungsdetails vor der Abreise.\n\nPrüfe Öffnungszeiten und Reisedetails, bevor du losfährst.")
        ],
        code: [
            (.user, "Wie zerlege ich eine kleine App-Verbesserung sinnvoll?"),
            (.agent, "Beginne mit einem sichtbaren Verhalten:\n\n```swift\nstruct SmallStep {\n    let outcome: String\n    let verification: String\n}\n```\n\n- Beschreibe, was die Person sehen soll, die die App nutzt.\n- Lies den Code, der für dieses Verhalten zuständig ist.\n- Nimm die kleinste vollständige Änderung vor.\n- Kompiliere und prüfe sie in der App.\n\nHalte den Umfang so klein, dass er sich in einem Durchgang prüfen lässt.")
        ],
        archive: [
            (.user, "Stell eine kurze Leseliste für ein ruhiges Wochenende zusammen."),
            (.agent, "Nimm einen Roman, einen Essay und etwas, das du schon lange wieder lesen wolltest. Den Rest hebst du dir für ein anderes Wochenende auf.\n\nNotiere dir kurz eine Passage, die dir gefällt, damit du später darauf zurückkommen kannst.")
        ],
        crons: [("Morgen-Check-in", "Werktags um 09:00 (Asia/Tokyo)"),
            ("Erinnerung an die Wochenendlektüre", "Samstags um 10:00 (Asia/Tokyo)")],
        resetReply: "Neue Sitzung gestartet. Woran möchtest du arbeiten?",
        replies: [
            (["automation", "zeitplan", "check-in", "erinnerung"], "Beginne mit einer Uhrzeit und den Tagen, die zu deinem Alltag passen.\n\nZum Beispiel **werktags um 8:30**, dann bleiben die Wochenenden frei. Welche Uhrzeit passt dir am besten?"),
            (["plan", "reise", "kyoto"], "## Ein einfacher Plan\n\n1. Wähle eine Sache, auf die du dich freust.\n2. Plane großzügig Zeit dafür ein.\n3. Halte eine zweite Option bereit, falls sich Wetter oder Energie ändern.\n\nBeginne mit dem Teil, auf den du dich am meisten freust, und plane den Rest drumherum."),
            (["zusammenfass", "fasse"], "**Die wichtigsten Punkte**\n\n- Wähle eine Priorität für den Tag.\n- Gib ihr einen ruhigen Zeitblock.\n- Lass zwischen deinen Verpflichtungen etwas Luft.\n\nWas wäre ein kleiner nächster Schritt?")
        ],
        fallback: "Woran möchtest du arbeiten?\n\nIch kann dir bei einem **Plan**, einer **Zusammenfassung** oder Ideen für eine **tägliche Routine** helfen. Erzähl mir, was dich beschäftigt, und wir fangen dort an."
    )

    static let es = Self(
        titles: ["Un comienzo del día más tranquilo", "Un fin de semana en Kioto", "Publicar una pequeña mejora", "La lista de lectura"],
        welcome: [
            (.user, "Ayúdame a hacer un poco de espacio en mi día."),
            (.agent, "## Un poco de espacio marca la diferencia\n\n1. Elige **una cosa** que haga que hoy valga la pena.\n2. Dale un bloque tranquilo de 45 minutos.\n3. Deja un poco de margen entre reuniones.\n\n> Un buen plan debería hacer tu día más ligero."),
            (.user, "¿Puedes convertirlo en un repaso matutino?"),
            (.agent, "Encontrarás **Repaso matutino** en Automatizaciones, donde puedes revisar su horario. ¿A qué hora de la mañana te vendría mejor?")
        ],
        travel: [
            (.user, "Planea un viaje tranquilo de dos días a Kioto, con tiempo para tomar café y pasear."),
            (.agent, "## Sábado · Este de Kioto\n\n- Empieza temprano con un paseo por el Camino del Filósofo.\n- Haz una pausa para tomar café y comer sin prisa.\n- Pasa la tarde por Gion y deja la noche libre.\n\n## Domingo · Otro ritmo\n\nDa un paseo matutino junto al río, curiosea en una librería y deja tiempo para el tren de vuelta.\n\n**Mantenlo flexible:** elige una parada principal cada día y deja todo lo demás como opcional."),
            (.user, "¿Qué debería llevar?"),
            (.agent, "Calzado cómodo, una prenda ligera de abrigo, un paraguas pequeño, una botella de agua y el móvil cargado. Guarda los datos de tus reservas antes de salir.\n\nConsulta los horarios de apertura y los detalles del viaje antes de ir.")
        ],
        code: [
            (.user, "¿Cuál es una forma sensata de dividir una pequeña mejora de una app?"),
            (.agent, "Empieza por un comportamiento visible:\n\n```swift\nstruct SmallStep {\n    let outcome: String\n    let verification: String\n}\n```\n\n- Describe lo que debería ver la persona que usa la app.\n- Lee el código responsable de ese comportamiento.\n- Haz el cambio completo más pequeño posible.\n- Compila y compruébalo en la app.\n\nMantén el alcance lo bastante pequeño como para revisarlo de una sola vez.")
        ],
        archive: [
            (.user, "Haz una lista de lectura corta para un fin de semana tranquilo."),
            (.agent, "Elige una novela, un ensayo y algo que llevas tiempo queriendo releer. Deja el resto para otro fin de semana.\n\nApunta brevemente un pasaje que te guste para poder volver a él más adelante.")
        ],
        crons: [("Repaso matutino", "De lunes a viernes a las 09:00 (Asia/Tokyo)"),
            ("Recordatorio de lectura del fin de semana", "Los sábados a las 10:00 (Asia/Tokyo)")],
        resetReply: "Nueva sesión iniciada. ¿En qué te gustaría trabajar?",
        replies: [
            (["automatiza", "horario", "repaso", "recordatorio"], "Empieza con una hora y los días que encajen con tu rutina.\n\nPor ejemplo, **a las 8:30 de lunes a viernes** te deja libres los fines de semana. ¿Qué hora te vendría mejor?"),
            (["plan", "viaje", "kioto", "kyoto"], "## Un plan sencillo\n\n1. Elige algo que te haga ilusión.\n2. Resérvale un buen bloque de tiempo.\n3. Ten una segunda opción por si cambian el tiempo o tus ganas.\n\nEmpieza por lo que más ilusión te haga y organiza el resto a su alrededor."),
            (["resum"], "**Los puntos principales**\n\n- Elige una prioridad para el día.\n- Dale un bloque de tiempo tranquilo.\n- Deja algo de margen entre compromisos.\n\n¿Cuál sería un pequeño paso que podrías dar a continuación?")
        ],
        fallback: "¿En qué te gustaría trabajar?\n\nPuedo ayudarte con un **plan**, un **resumen** o ideas para una **rutina diaria**. Cuéntame qué tienes en mente y empezamos por ahí."
    )

    static let fr = Self(
        titles: ["Un début de journée plus serein", "Un week-end à Kyoto", "Livrer une petite amélioration", "La liste de lecture"],
        welcome: [
            (.user, "Aide-moi à libérer un peu de temps dans ma journée."),
            (.agent, "## Un peu d’espace change tout\n\n1. Choisissez **une seule chose** qui donnerait du sens à votre journée.\n2. Réservez-lui un créneau calme de 45 minutes.\n3. Laissez un peu de marge entre vos réunions.\n\n> Un bon plan devrait alléger votre journée."),
            (.user, "Tu peux en faire un point du matin\u{202F}?"),
            (.agent, "Vous trouverez **Point du matin** dans Automatisations, où vous pourrez vérifier sa planification. À quelle heure du matin cela vous conviendrait-il le mieux\u{202F}?")
        ],
        travel: [
            (.user, "Prévois un voyage tranquille de deux jours à Kyoto, avec du temps pour le café et la marche."),
            (.agent, "## Samedi · Est de Kyoto\n\n- Commencez tôt par une promenade sur le chemin de la Philosophie.\n- Faites une pause café et prenez le temps de déjeuner.\n- Passez l’après-midi autour de Gion et gardez la soirée libre.\n\n## Dimanche · Changement de rythme\n\nPromenez-vous le matin au bord de la rivière, flânez dans une librairie et gardez du temps pour le train du retour.\n\n**Restez flexible\u{202F}:** choisissez une étape principale par jour et laissez le reste facultatif."),
            (.user, "Qu’est-ce que je devrais emporter\u{202F}?"),
            (.agent, "Des chaussures confortables, une couche légère, un petit parapluie, une gourde et un téléphone chargé. Enregistrez vos réservations avant de partir.\n\nVérifiez les horaires d’ouverture et les informations de transport avant le départ.")
        ],
        code: [
            (.user, "Comment découper intelligemment une petite amélioration d’app\u{202F}?"),
            (.agent, "Commencez par un comportement visible\u{202F}:\n\n```swift\nstruct SmallStep {\n    let outcome: String\n    let verification: String\n}\n```\n\n- Décrivez ce que la personne qui utilise l’app doit voir.\n- Lisez le code responsable de ce comportement.\n- Faites le plus petit changement complet possible.\n- Compilez et vérifiez le résultat dans l’app.\n\nGardez un périmètre assez réduit pour pouvoir le relire d’une traite.")
        ],
        archive: [
            (.user, "Fais une courte liste de lecture pour un week-end tranquille."),
            (.agent, "Choisissez un roman, un essai et un livre que vous vouliez relire depuis longtemps. Gardez le reste pour un autre week-end.\n\nNotez brièvement un passage qui vous plaît pour pouvoir y revenir plus tard.")
        ],
        crons: [("Point du matin", "En semaine à 09:00 (Asia/Tokyo)"),
            ("Rappel de lecture du week-end", "Le samedi à 10:00 (Asia/Tokyo)")],
        resetReply: "Nouvelle session ouverte. Sur quoi voulez-vous travailler\u{202F}?",
        replies: [
            (["automatisation", "planification", "horaire", "point du matin", "rappel"], "Commencez par choisir une heure et les jours qui correspondent à votre rythme.\n\nPar exemple, **8\u{00A0}h\u{00A0}30 en semaine** laisse vos week-ends libres. Quelle heure vous conviendrait le mieux\u{202F}?"),
            (["plan", "voyage", "kyoto", "prévoi"], "## Un plan simple\n\n1. Choisissez une chose qui vous fait envie.\n2. Réservez-lui un large créneau.\n3. Prévoyez une alternative si la météo ou votre énergie changent.\n\nCommencez par ce qui vous réjouit le plus, puis organisez le reste autour."),
            (["résum", "resum", "synthèse"], "**Les points essentiels**\n\n- Choisissez une priorité pour la journée.\n- Accordez-lui un créneau calme.\n- Laissez un peu de marge entre vos engagements.\n\nQuelle petite étape pourriez-vous franchir ensuite\u{202F}?")
        ],
        fallback: "Sur quoi voulez-vous travailler\u{202F}?\n\nJe peux vous aider avec un **plan**, un **résumé** ou des idées de **routine quotidienne**. Dites-moi ce qui vous occupe l’esprit, et partons de là."
    )

    static let ko = Self(
        titles: ["여유로운 하루의 시작", "교토에서 보내는 주말", "작은 개선 사항 배포하기", "독서 목록"],
        welcome: [
            (.user, "하루에 여유를 좀 만들고 싶어."),
            (.agent, "## 작은 여유가 큰 차이를 만듭니다\n\n1. 오늘을 보람 있게 만들어 줄 **한 가지**를 고르세요.\n2. 방해받지 않는 45분을 확보하세요.\n3. 일정과 일정 사이에 약간의 여유를 두세요.\n\n> 좋은 계획은 하루를 더 가볍게 만들어 줍니다."),
            (.user, "그걸 아침 체크인으로 만들어 줄 수 있어?"),
            (.agent, "자동화에서 **아침 체크인**을 찾아 일정을 확인할 수 있습니다. 아침 몇 시쯤이 가장 좋으세요?")
        ],
        travel: [
            (.user, "커피와 산책을 즐길 수 있는 여유로운 1박 2일 교토 여행을 계획해 줘."),
            (.agent, "## 토요일 · 교토 동부\n\n- 아침 일찍 철학의 길을 따라 산책하세요.\n- 커피를 마시고 여유롭게 점심을 드세요.\n- 오후에는 기온 일대를 둘러보고 저녁은 비워 두세요.\n\n## 일요일 · 느긋하게\n\n아침에 강변을 걷고, 서점을 구경하고, 돌아가는 기차 시간까지 넉넉히 여유를 두세요.\n\n**유연하게:** 하루에 중심 일정을 하나만 정하고 나머지는 선택 사항으로 남겨 두세요."),
            (.user, "뭘 챙겨 가야 할까?"),
            (.agent, "편한 신발, 가벼운 겉옷, 작은 우산, 물병, 충전된 휴대폰을 챙기세요. 떠나기 전에 예약 정보도 저장해 두세요.\n\n출발 전에 영업시간과 교통 정보를 확인하세요.")
        ],
        code: [
            (.user, "앱의 작은 개선을 어떻게 나누면 좋을까?"),
            (.agent, "눈에 보이는 동작 하나부터 시작하세요.\n\n```swift\nstruct SmallStep {\n    let outcome: String\n    let verification: String\n}\n```\n\n- 앱을 사용하는 사람에게 무엇이 보여야 하는지 적습니다.\n- 그 동작을 담당하는 코드를 읽습니다.\n- 가장 작으면서도 완결된 변경을 합니다.\n- 컴파일하고 앱에서 확인합니다.\n\n한 번에 검토할 수 있을 만큼 범위를 작게 유지하세요.")
        ],
        archive: [
            (.user, "조용한 주말을 위한 짧은 독서 목록을 만들어 줘."),
            (.agent, "소설 한 권, 에세이 한 편, 그리고 다시 읽고 싶었던 책 하나를 고르세요. 나머지는 다음 주말로 미뤄 두세요.\n\n마음에 드는 구절을 짧게 메모해 두면 나중에 다시 찾아볼 수 있습니다.")
        ],
        crons: [("아침 체크인", "평일 09:00 (Asia/Tokyo)"),
            ("주말 독서 알림", "매주 토요일 10:00 (Asia/Tokyo)")],
        resetReply: "새 세션을 시작했습니다. 무엇을 해 볼까요?",
        replies: [
            (["자동화", "스케줄", "체크인", "알림"], "생활 리듬에 맞는 시간과 요일부터 정해 보세요.\n\n예를 들어 **평일 오전 8시 30분**으로 하면 주말은 비워 둘 수 있습니다. 몇 시가 가장 좋으세요?"),
            (["계획", "여행", "교토"], "## 간단한 계획\n\n1. 기대되는 일을 하나 고르세요.\n2. 그 일에 넉넉한 시간을 확보하세요.\n3. 날씨나 컨디션이 바뀔 때를 대비해 대안을 하나 준비하세요.\n\n가장 기대되는 부분부터 정하고, 나머지는 그에 맞춰 짜 보세요."),
            (["요약", "정리"], "**핵심 정리**\n\n- 오늘의 우선순위를 하나 정하세요.\n- 집중할 수 있는 시간을 확보하세요.\n- 일정 사이에 약간의 여유를 남겨 두세요.\n\n다음으로 해 볼 수 있는 작은 한 걸음은 무엇일까요?")
        ],
        fallback: "무엇을 해 볼까요?\n\n**계획 세우기**, **내용 요약**, **일상 루틴** 아이디어 등을 도와드릴 수 있습니다. 지금 가장 신경 쓰이는 것을 말씀해 주세요."
    )

    static let ptBR = Self(
        titles: ["Um começo de dia mais tranquilo", "Um fim de semana em Quioto", "Entregar uma pequena melhoria", "A lista de leitura"],
        welcome: [
            (.user, "Me ajude a abrir um pouco de espaço no meu dia."),
            (.agent, "## Um pouco de espaço faz toda a diferença\n\n1. Escolha **uma coisa** que faria o dia de hoje valer a pena.\n2. Reserve para ela um bloco tranquilo de 45 minutos.\n3. Deixe um pouco de folga entre as reuniões.\n\n> Um bom plano deve deixar seu dia mais leve."),
            (.user, "Dá para transformar isso em um check-in matinal?"),
            (.agent, "Você encontra **Check-in matinal** em Automações e pode revisar o agendamento. Que horário de manhã funciona melhor para você?")
        ],
        travel: [
            (.user, "Planeje uma viagem tranquila de dois dias a Quioto, com tempo para café e caminhadas."),
            (.agent, "## Sábado · Leste de Quioto\n\n- Comece cedo com uma caminhada pelo Caminho do Filósofo.\n- Pare para um café e um almoço sem pressa.\n- Passe a tarde pelos arredores de Gion e deixe a noite livre.\n\n## Domingo · Outro ritmo\n\nCaminhe de manhã à beira do rio, dê uma olhada em uma livraria e deixe tempo para o trem de volta.\n\n**Mantenha a flexibilidade:** escolha uma parada principal por dia e deixe o resto como opcional."),
            (.user, "O que devo levar na mala?"),
            (.agent, "Sapatos confortáveis, um agasalho leve, um guarda-chuva pequeno, uma garrafa de água e o celular carregado. Salve os dados das reservas antes de sair.\n\nConfira os horários de funcionamento e as informações de transporte antes de ir.")
        ],
        code: [
            (.user, "Qual é um jeito sensato de dividir uma pequena melhoria no app?"),
            (.agent, "Comece por um comportamento visível:\n\n```swift\nstruct SmallStep {\n    let outcome: String\n    let verification: String\n}\n```\n\n- Descreva o que a pessoa que usa o app deve ver.\n- Leia o código responsável por esse comportamento.\n- Faça a menor mudança completa possível.\n- Compile e confira no app.\n\nMantenha o escopo pequeno o bastante para revisar de uma vez só.")
        ],
        archive: [
            (.user, "Monte uma lista de leitura curta para um fim de semana tranquilo."),
            (.agent, "Escolha um romance, um ensaio e algo que você queria reler há tempos. Deixe o resto para outro fim de semana.\n\nAnote rapidamente um trecho de que você gostar para poder voltar a ele depois.")
        ],
        crons: [("Check-in matinal", "Dias úteis às 09:00 (Asia/Tokyo)"),
            ("Lembrete de leitura do fim de semana", "Aos sábados às 10:00 (Asia/Tokyo)")],
        resetReply: "Nova sessão iniciada. No que você quer trabalhar?",
        replies: [
            (["automaç", "agend", "horário", "check-in", "lembrete"], "Comece com um horário e os dias que combinam com a sua rotina.\n\nPor exemplo, **8h30 nos dias úteis** deixa os fins de semana livres. Que horário funciona melhor para você?"),
            (["plan", "viagem", "quioto", "kyoto"], "## Um plano simples\n\n1. Escolha algo que você queira muito fazer.\n2. Reserve um bom bloco de tempo para isso.\n3. Tenha uma segunda opção caso o tempo ou a sua disposição mudem.\n\nComece pela parte que mais anima você e organize o resto em torno dela."),
            (["resum"], "**Os pontos principais**\n\n- Escolha uma prioridade para o dia.\n- Reserve para ela um bloco de tempo tranquilo.\n- Deixe um pouco de folga entre os compromissos.\n\nQual seria um pequeno próximo passo?")
        ],
        fallback: "No que você quer trabalhar?\n\nPosso ajudar com um **plano**, um **resumo** ou ideias para uma **rotina diária**. Conte o que está passando pela sua cabeça e começamos por aí."
    )

    static let zhHans = Self(
        titles: ["从容开启每一天", "京都周末之旅", "交付一个小改进", "阅读清单"],
        welcome: [
            (.user, "帮我在一天里腾出一点空间。"),
            (.agent, "## 一点余裕，大有不同\n\n1. 选出**一件**能让今天过得有意义的事。\n2. 为它留出 45 分钟不受打扰的时间。\n3. 在会议之间留一点缓冲。\n\n> 好的计划应该让一天更轻松。"),
            (.user, "能把它做成早间签到吗？"),
            (.agent, "你可以在“自动化”中找到**早间签到**并查看它的日程。早上几点最适合你？")
        ],
        travel: [
            (.user, "规划一趟轻松的京都两日游，留出喝咖啡和散步的时间。"),
            (.agent, "## 星期六 · 京都东部\n\n- 一早沿着哲学之道散步。\n- 停下来喝杯咖啡，慢慢吃顿午饭。\n- 下午在祇园一带走走，晚上不做安排。\n\n## 星期日 · 换个节奏\n\n早上沿河散步，逛逛书店，给回程的火车留足时间。\n\n**保持灵活**：每天只定一个主要目的地，其余都随意。"),
            (.user, "我该带些什么？"),
            (.agent, "舒适的鞋子、一件薄外套、一把小伞、一个水瓶和充好电的手机。出发前保存好预订信息。\n\n出行前请确认营业时间和交通信息。")
        ],
        code: [
            (.user, "怎样合理地拆分一个应用的小改进？"),
            (.agent, "从一个可见的行为开始：\n\n```swift\nstruct SmallStep {\n    let outcome: String\n    let verification: String\n}\n```\n\n- 描述使用应用的人应该看到什么。\n- 阅读负责这个行为的代码。\n- 做出最小且完整的改动。\n- 编译并在应用中确认。\n\n把范围控制在一次就能审查完的大小。")
        ],
        archive: [
            (.user, "为安静的周末列一份简短的阅读清单。"),
            (.agent, "选一本小说、一篇随笔，再加一本一直想重读的书。其余的留到下个周末。\n\n把喜欢的段落简单记下来，以后可以再回头读。")
        ],
        crons: [("早间签到", "工作日 09:00（Asia/Tokyo）"),
            ("周末阅读提醒", "每周六 10:00（Asia/Tokyo）")],
        resetReply: "已开始新会话。你想做些什么？",
        replies: [
            (["自动化", "日程", "签到", "提醒"], "先定下适合你作息的时间和日子。\n\n比如**工作日早上 8:30**，周末就能空出来。你觉得几点最合适？"),
            (["计划", "规划", "旅行", "京都"], "## 简单的计划\n\n1. 选一件你期待的事。\n2. 为它留出充裕的时间。\n3. 准备一个备选方案，以防天气或状态有变。\n\n先从你最期待的部分开始，再围绕它安排其他事。"),
            (["总结", "摘要", "概括"], "**要点**\n\n- 为今天选一个优先事项。\n- 为它留出一段安静的时间。\n- 在各项安排之间留一点余地。\n\n下一步可以迈出的一小步是什么？")
        ],
        fallback: "你想做些什么？\n\n我可以帮你**制定计划**、**做总结**，或者想想**日常习惯**。说说你现在最在意的事，我们就从那里开始。"
    )

    static let zhHant = Self(
        titles: ["從容展開每一天", "京都週末之旅", "交付一項小改進", "閱讀清單"],
        welcome: [
            (.user, "幫我在一天裡騰出一點空間。"),
            (.agent, "## 一點餘裕，大有不同\n\n1. 選出**一件**能讓今天過得有意義的事。\n2. 為它留出 45 分鐘不受打擾的時間。\n3. 在會議之間留一點緩衝。\n\n> 好的計畫應該讓一天更輕鬆。"),
            (.user, "能把它變成晨間簽到嗎？"),
            (.agent, "你可以在「自動化」中找到**晨間簽到**並查看它的排程。早上幾點最適合你？")
        ],
        travel: [
            (.user, "規劃一趟輕鬆的京都兩日遊，留些時間喝咖啡和散步。"),
            (.agent, "## 星期六 · 京都東部\n\n- 一早沿著哲學之道散步。\n- 停下來喝杯咖啡，慢慢吃頓午餐。\n- 下午在祇園一帶走走，晚上不排行程。\n\n## 星期日 · 換個步調\n\n早上沿著河邊散步，逛逛書店，替回程的火車留足時間。\n\n**保持彈性**：每天只排一個主要景點，其餘都隨興。"),
            (.user, "我該帶些什麼？"),
            (.agent, "好走的鞋子、一件薄外套、一把小傘、一個水壺和充飽電的手機。出發前先存好訂位資訊。\n\n出發前請確認營業時間和交通資訊。")
        ],
        code: [
            (.user, "怎麼合理拆解一個 App 的小改進？"),
            (.agent, "從一個看得見的行為開始：\n\n```swift\nstruct SmallStep {\n    let outcome: String\n    let verification: String\n}\n```\n\n- 描述使用 App 的人應該看到什麼。\n- 閱讀負責這個行為的程式碼。\n- 做出最小且完整的修改。\n- 編譯並在 App 中確認。\n\n把範圍控制在一次就能審查完的大小。")
        ],
        archive: [
            (.user, "幫安靜的週末列一份簡短的閱讀清單。"),
            (.agent, "選一本小說、一篇散文，再加一本一直想重讀的書。其餘的留到下個週末。\n\n把喜歡的段落簡單記下來，之後可以再回頭讀。")
        ],
        crons: [("晨間簽到", "平日 09:00（Asia/Tokyo）"),
            ("週末閱讀提醒", "每週六 10:00（Asia/Tokyo）")],
        resetReply: "已開始新的工作階段。你想做些什麼？",
        replies: [
            (["自動化", "排程", "簽到", "提醒"], "先訂出符合你作息的時間和日子。\n\n例如**平日早上 8:30**，週末就能空出來。你覺得幾點最合適？"),
            (["計畫", "計劃", "規劃", "旅行", "京都"], "## 簡單的計畫\n\n1. 選一件你期待的事。\n2. 為它留出充裕的時間。\n3. 準備一個備案，以防天氣或狀態有變。\n\n先從你最期待的部分開始，再圍繞它安排其他事。"),
            (["總結", "摘要", "整理"], "**重點整理**\n\n- 為今天選一個優先事項。\n- 為它留出一段安靜的時間。\n- 在各項安排之間留一點餘地。\n\n下一步可以踏出的一小步是什麼？")
        ],
        fallback: "你想做些什麼？\n\n我可以幫你**擬定計畫**、**整理重點**，或是想想**日常習慣**。說說你現在最在意的事，我們就從那裡開始。"
    )
}

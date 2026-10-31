// Deutsch (du, wie die App). Begriffe folgen Localizable.xcstrings und dem App-Store-Text der App.
export default {
  name: 'Yorozu',
  skip: 'Zum Inhalt springen',
  nav: { primary: 'Hauptnavigation', footer: 'Fußzeile', language: 'Sprache', home: 'Start', support: 'Support', privacy: 'Datenschutz', terms: 'Bedingungen', getApp: 'App laden' },
  footer: {
    copyright: '© 2026 Yumi Izumi',
    affiliation: '. Yorozu steht in keiner Verbindung zu OpenClaw, Nous Research (Hermes Agent), Cua (CuaDriver), Anthropic oder OpenAI.',
  },
  governs: 'Diese deutsche Fassung ist eine Übersetzung zur Information. Bei Abweichungen gilt die <a href="@en">englische Fassung</a>.',
  home: {
    title: 'Yorozu — Eine native Chat-App für deinen OpenClaw-Agenten',
    description: 'Yorozu ist eine native App für iPhone, iPad und Mac, mit der du mit deinem eigenen OpenClaw-Agenten chattest – Ende-zu-Ende-verschlüsselt über ein Relay, das deine Nachrichten nicht lesen kann.',
    og: {
      title: 'Yorozu',
      description: 'Eine native Chat-App für deinen eigenen OpenClaw-Agenten, auf iPhone, iPad und Mac. Ende-zu-Ende-verschlüsselt.',
      imageAlt: 'Das App-Symbol von Yorozu neben den englischen Worten „Your OpenClaw agent, anywhere.“ (Dein OpenClaw-Agent, überall).',
    },
    hero: 'Dein OpenClaw-Agent.<br><em>In deiner Tasche.</em>',
    appStore: 'Yorozu im App Store laden',
    downloadMac: 'Für Mac laden',
    fine: 'Mac: macOS 15 oder neuer · iPhone und iPad: im App Store, iOS 18 oder neuer · Benötigt dein eigenes OpenClaw-Gateway · <a href="https://github.com/izyuumi/yorozu">Open Source, MIT</a>',
    agent: {
      title: 'Mit deinem KI-Agenten einrichten',
      intro: 'Füge diesen Prompt in Claude Code, Codex, Cursor oder einen anderen KI-Agenten ein. Der Agent verbindet sich mit dem Hilfeserver von Yorozu, fragt, ob du einen Mac, ein iPhone oder ein iPad nutzt, und führt dich Schritt für Schritt durch die Einrichtung.',
      copy: 'Kopieren',
      copyLabel: 'Prompt kopieren',
      copied: 'Kopiert',
      status: 'Prompt kopiert.',
      failed: 'Automatisches Kopieren war nicht möglich. Der Prompt ist ausgewählt; nutze den Kopierbefehl deines Geräts.',
      note: 'Der Hilfeserver ist schreibgeschützt und braucht keine Anmeldung. Er liefert nur die Dokumentation von Yorozu und hat keinen Zugriff auf dein Gateway oder deine Chats. Der Prompt bleibt auf Englisch, dem Agenten am zuverlässigsten folgen, und bittet den Agenten, dir auf Deutsch zu antworten.',
      language: 'German',
    },
    setupTitle: 'Oder richte es selbst ein',
    stepsIntro: 'Du brauchst <a href="https://docs.openclaw.ai/install">OpenClaw</a> mit dem Yorozu-Plug-in. Halte den Computer des Gateways wach und online, damit du deinen Agenten erreichst.',
    steps: [
      ['Das Plug-in installieren', 'Installiere das Yorozu-Kanal-Plug-in in deinem OpenClaw-Gateway (OpenClaw 2026.9.8 oder neuer). Die <a href="https://github.com/izyuumi/yorozu/blob/main/docs/setup.md">Einrichtungsanleitung</a> (auf Englisch) enthält die Befehle und Einstellungen.'],
      ['Einen Kopplungscode erstellen', 'Führe auf dem Computer, auf dem dein Gateway läuft, <code>openclaw yorozu pair</code> aus. Der Befehl zeigt einen QR-Code und einen Link, die einmal funktionieren und nach 10 Minuten ablaufen.'],
      ['Dein Gerät koppeln', 'Scanne den QR-Code mit der Kamera oder in Yorozu, oder füge den Link ein. Prüfe, ob der Fingerabdruck mit dem übereinstimmt, den der Befehl angezeigt hat. Kein Yorozu-Konto nötig. Um später einen Mac hinzuzufügen, scanne den Code, den er anzeigt, mit einem gekoppelten iPhone oder iPad.'],
    ],
    docsTitle: 'Dokumentation und Support',
    docs: [
      ['Einrichtungsanleitung', 'Befehle, Einstellungen und Fehlerbehebung für das Plug-in und die Apps (auf Englisch).'],
      ['Hilfeserver für KI-Agenten', 'Verbinde einen beliebigen MCP-Client mit <code>yorozu.yumi.to/mcp</code>, um Hilfe bei Einrichtung und Fehlerbehebung zu bekommen (auf Englisch).'],
      ['Support', 'Melde ein Problem oder stelle eine Frage.'],
      ['Quellcode', 'Yorozu ist Open Source unter der MIT-Lizenz und liegt auf GitHub.'],
    ],
    riskTitle: 'Bevor du installierst',
    risk: [
      '<strong>Dein Agent handelt mit den Konten, die du OpenClaw gibst.</strong> Wenn OpenClaw Claude Code, Codex oder ein Modell über eine Abo-Anmeldung steuert, entscheiden Anthropic und OpenAI, welche Nutzung dieses Abos erlaubt ist, ändern diese Regeln ohne Ankündigung und haben Konten gesperrt, die mit Agent-Tools von Drittanbietern genutzt wurden. Für das geringste Risiko verwende einen API-Schlüssel statt einer Abo-Anmeldung.',
      'KI-Agenten führen echte Aktionen aus: Sie führen Befehle aus, bearbeiten und löschen Dateien und können Nachrichten senden. Prüfe, was dein Agent tun darf. Siehe die <a href="@/terms/">Nutzungsbedingungen</a>.',
    ],
  },
  pair: {
    title: 'Mit Yorozu koppeln',
    description: 'Öffne diesen Kopplungscode in Yorozu auf deinem iPhone oder iPad.',
    intro: 'Dies ist ein Yorozu-Kopplungscode. Lade Yorozu auf dieses iPhone oder iPad und scanne den Code dann erneut. Ist Yorozu installiert, öffnet die Kamera ihn in der App.',
    open: 'In Yorozu öffnen',
    private: 'Der Code bleibt auf diesem Gerät: Er steht in dem Teil des Links, den dein Browser nie an uns sendet. Halte ihn geheim; er funktioniert einmal und läuft ab.',
  },
  add: {
    title: 'Einen Mac zu Yorozu hinzufügen',
    description: 'Öffne diesen Code in Yorozu auf einem gekoppelten iPhone oder iPad.',
    intro: 'Dies ist der Code, den ein neuer Mac anzeigt, um sich mit deinem Host zu koppeln. Scanne ihn mit der Kamera oder in Yorozu unter Einstellungen › Gerät hinzufügen › Code eines Mac scannen, auf einem iPhone oder iPad, das Yorozu bereits nutzt.',
    private: 'Der Code bleibt auf diesem Gerät: Er steht in dem Teil des Links, den dein Browser nie an uns sendet. Er funktioniert einmal und läuft nach 10 Minuten ab.',
  },
  support: {
    title: 'Support — Yorozu',
    description: 'Hilfe bei Einrichtung, Kopplung und Problemen mit der App Yorozu.',
    heading: 'Yorozu-Support',
    body: `<p>Wenn du Hilfe beim Installieren, Koppeln, Verbinden oder Verwenden von Yorozu auf deinem Mac, iPhone oder iPad brauchst, schreib eine E-Mail an <a href="mailto:contact@yumi.to?subject=Yorozu%20support">contact@yumi.to</a>.</p>

  <h2>Was du angeben solltest</h2>
  <p>Sag uns, welche Yorozu-App und welche Version du nutzt, welches Gerät, was passiert ist und welche Schritte zu dem Problem geführt haben. Gib jede Fehlermeldung an, die du gesehen hast. Sende keine Passwörter, API-Schlüssel oder Kopplungslinks.</p>

  <h2>Diagnose kopieren</h2>
  <p>Öffne in Yorozu Einstellungen › Über, wähle „Diagnose kopieren“ und füge das Ergebnis in deine E-Mail ein. Es enthält die App-Version, dein Gerät, den Verbindungsstatus und das Protokoll seit diesem Start der App. Es enthält keine Schlüssel und keine Nachrichten, und nichts wird gesendet, bevor du es selbst einfügst.</p>`,
  },
  privacy: {
    title: 'Datenschutzerklärung — Yorozu',
    description: 'Was Yorozu erfasst, was sein Relay sehen kann und was nicht.',
    heading: 'Datenschutzerklärung',
    effective: 'Gültig ab 31. Oktober 2026',
    body: `<p>Yorozu ist eine App für iPhone, iPad und Mac und ein Plug-in für OpenClaw, entwickelt von Yumi Izumi („wir“). Diese Erklärung beschreibt, welche Daten Yorozu 0.9 und neuer verarbeitet. Kurz gesagt: <strong>Wir betreiben keine Konten, keine Analyse und keine Werbung, und wir können deine Unterhaltungen nicht lesen.</strong></p>

  <h2>Wo deine Daten liegen</h2>
  <p>Deine Unterhaltungen liegen in deinem eigenen OpenClaw-Gateway, auf einem Computer, den du kontrollierst. Das Yorozu-Plug-in läuft darin. Wir erhalten niemals deine Unterhaltungen, Dateien oder deine Anmeldedaten für Claude, OpenAI oder andere Anbieter; diese bleiben in OpenClaw.</p>
  <ul>
    <li><strong>In deinem Gateway</strong>: OpenClaw speichert die Sitzung und das Protokoll jeder Unterhaltung, erzeugte Titel und die Dateien, die du sendest, wie bei jedem Kanal. Das Plug-in speichert seine privaten Schlüssel im Anmeldedatenspeicher von OpenClaw sowie seine Liste gekoppelter Geräte und den Lesestatus im Statusspeicher von OpenClaw.</li>
    <li><strong>Auf deinem iPhone und iPad</strong>: ein Cache deiner Unterhaltungen, noch zu sendende Nachrichten und die Dateien, die du öffnest – von iOS im Ruhezustand verschlüsselt und von Backups ausgeschlossen. Kopplungsschlüssel liegen im iOS-Schlüsselbund, nur auf diesem Gerät.</li>
    <li><strong>Auf deinem Mac</strong>: derselbe Cache in <code>~/Library/Application Support/to.yumi.yorozu.ios/</code> und die Kopplungsschlüssel im macOS-Schlüsselbund.</li>
  </ul>
  <p>Das Entkoppeln eines Geräts löscht seinen Cache und seine Schlüssel.</p>

  <h2>Das Relay</h2>
  <p>Deine Geräte erreichen dein Gateway über ein Relay, das wir auf Cloudflare unter <code>relay.yumi.to</code> betreiben. Du kannst auch dein eigenes betreiben. Alles ist Ende-zu-Ende-verschlüsselt (ein Noise-IK-Handshake mit X25519 bei jeder Verbindung, dann ChaCha20-Poly1305), bevor es das Relay erreicht, und das Relay hat keinen Schlüssel, um es zu entschlüsseln. Das Relay verarbeitet jedoch:</p>
  <ul>
    <li><strong>Verschlüsselte Nachrichten</strong> deiner Geräte, die bis zu 24 Stunden (höchstens 5 MiB) gehalten werden, solange dein Gateway offline ist, und dann gelöscht werden. Nichts, was dein Gateway sendet, wird gehalten.</li>
    <li><strong>Verschlüsselte Anhänge</strong>, in Ende-zu-Ende-verschlüsselten Teilen. Das Relay sieht ihre Größe und ihren Zeitpunkt.</li>
    <li><strong>Öffentliche Schlüssel</strong> gekoppelter Geräte und eine Raumkennung, gespeichert, bis du das Gerät entkoppelst.</li>
    <li><strong>Einmalige Kopplungstoken</strong>, die nach 10 Minuten ablaufen.</li>
    <li><strong>Das Apple-Push-Token deines iPhone oder iPad</strong>, damit das Relay Mitteilungen senden kann, gespeichert, bis du das Gerät entkoppelst.</li>
    <li><strong>Metadaten</strong>: wann sich Geräte verbinden, sowie Größe und Zeitpunkt von Nachrichten. Verbindungsprotokolle enthalten niemals Nachrichteninhalte oder Schlüssel.</li>
    <li><strong>IP-Adressen</strong>, die Cloudflare verarbeitet, um den Datenverkehr zuzustellen, gemäß der <a href="https://www.cloudflare.com/privacypolicy/">Datenschutzerklärung von Cloudflare</a>.</li>
  </ul>

  <h2>Mitteilungen</h2>
  <p>Push-Mitteilungen werden von Apple zugestellt. Jede enthält eine Vorschau der Antwort (den Titel der Unterhaltung und ihre erste Zeile, höchstens 256 Byte), verschlüsselt allein für dein Gerät; dein Gerät öffnet sie. Das Relay und Apple sehen nur die verschlüsselte Box.</p>

  <h2>OpenClaw und Modellanbieter</h2>
  <p>Yorozu übergibt deine Nachrichten an deinen OpenClaw-Agenten. OpenClaw und die Tools, die es ausführt, senden Daten an ihre Modellanbieter (zum Beispiel Anthropic oder OpenAI) gemäß deren eigenen Datenschutzerklärungen und deinen Vereinbarungen mit diesen Anbietern. Wir sind daran nicht beteiligt und erhalten diese Daten nicht.</p>

  <h2>Updates und Downloads</h2>
  <p>Die App für iPhone und iPad wird über den App Store installiert und aktualisiert. Die Mac-App sucht unter <code>yorozu.yumi.to</code> nach Updates und lädt sie von GitHub herunter, wodurch Cloudflare und GitHub gemäß ihren Datenschutzerklärungen deine IP-Adresse und die App-Version erfahren. Es wird kein Systemprofil gesendet. Wenn du die Spracheingabe einschaltest, laden iPhone und iPad ihr Sprachmodell von Apple, wie die App selbst; die Mac-App lädt es von Hugging Face (<code>huggingface.co</code>), wodurch Hugging Face gemäß seiner Datenschutzerklärung deine IP-Adresse erfährt. Diese Website verwendet keine Analyse und keine Tracker. Ihr einziges Cookie, <code>yorozu_lang</code>, wird gesetzt, wenn du eine Sprache auswählst, und speichert nur diese Wahl, damit sich die Website beim nächsten Mal in dieser Sprache öffnet.</p>

  <h2>Berechtigungen</h2>
  <p>Yorozu fragt Berechtigungen nur für die Funktion an, die sie braucht: die Kamera, um einen Kopplungscode zu scannen oder ein Foto zum Senden aufzunehmen, das Mikrofon für die Spracheingabe, Fotos, um Bilder anzuhängen oder zu sichern, und Mitteilungen für Antworten. Die Spracheingabe wird auf deinem Gerät transkribiert; das Audio wird nirgendwohin gesendet. Daten, auf die über Berechtigungen zugegriffen wird, werden auf deinen Geräten verwendet und nur Ende-zu-Ende-verschlüsselt an dein eigenes Gateway gesendet.</p>

  <h2>Frühere Versionen</h2>
  <p>Frühere Versionen der Mac-App führten ihren eigenen Assistenten aus. Ihre Daten bleiben auf deinem Mac, in <code>~/Yorozu</code> und im Yorozu-Ordner in <code>~/Library/Application Support/</code>, bis du sie löschst.</p>

  <h2>Kinder</h2>
  <p>Yorozu richtet sich nicht an Kinder unter 13 Jahren, und wir erfassen ihre Daten nicht wissentlich.</p>

  <h2>Deine Möglichkeiten</h2>
  <p>Das Entkoppeln eines Geräts, in der App oder mit <code>openclaw yorozu devices remove</code>, löscht seine Schlüssel und sein Push-Token vom Relay. Das Löschen der App entfernt ihre Daten von diesem Gerät. Deine Unterhaltungen bleiben in OpenClaw, bis du sie dort oder in Yorozu löschst. Da wir kein Konto und keine lesbaren Inhalte haben, gibt es nichts weiter zu exportieren oder zu löschen. Bei Fragen schreib an <a href="mailto:contact@yumi.to">contact@yumi.to</a>.</p>

  <h2>Änderungen</h2>
  <p>Wir veröffentlichen Änderungen hier und aktualisieren das Datum oben.</p>`,
  },
  terms: {
    title: 'Nutzungsbedingungen — Yorozu',
    description: 'Die Bedingungen für die Nutzung von Yorozu, einschließlich des Risikos für Claude- und Codex-Konten, die von den damit gesteuerten Agenten genutzt werden.',
    heading: 'Nutzungsbedingungen',
    effective: 'Gültig ab 23. Oktober 2026',
    body: `<p>Diese Bedingungen gelten für die Yorozu-App für iPhone, iPad und Mac, das Yorozu-Plug-in für OpenClaw, das Relay unter <code>relay.yumi.to</code> und diese Website (zusammen „Yorozu“), bereitgestellt von Yumi Izumi („wir“, „uns“). Indem du Yorozu installierst oder nutzt, stimmst du ihnen zu. Wenn du nicht zustimmst, nutze Yorozu nicht. Wenn du die iPhone-App aus dem App Store beziehst, gilt außerdem Apples <a href="https://www.apple.com/legal/internet-services/itunes/dev/stdeula/">Standard-Endbenutzer-Lizenzvertrag</a>. Soweit er diesen Bedingungen widerspricht, hat er für die iPhone-App Vorrang.</p>

  <h2>1. Was Yorozu ist</h2>
  <p>Yorozu ist eine Chat-App für deinen eigenen OpenClaw-Agenten: Das Plug-in macht Yorozu zu einem Kanal deines OpenClaw-Gateways, und die App überbringt ihm deine Nachrichten und dir seine Antworten. Der Agent und alle Programmierwerkzeuge, die er ausführt, etwa Claude Code oder OpenAI Codex, sind Software, die du installierst und konfigurierst. Yorozu stellt keine KI-Modelle bereit, verkauft keine KI-Nutzung und erfasst keine Anmeldedaten von dir. Du installierst diese Werkzeuge selbst, meldest dich selbst an und bezahlst sie selbst.</p>

  <div class="warning" role="note">
    <h2 id="account-risk">2. Dein Claude- oder Codex-Konto kann gesperrt oder dauerhaft ausgeschlossen werden</h2>
    <p>Anthropic und OpenAI legen fest, wie ihre Abos und Konten genutzt werden dürfen, auch über automatisierte Werkzeuge oder Werkzeuge von Drittanbietern. Diese Regeln haben sich wiederholt geändert und können sich ohne Ankündigung ändern. Anthropic hat Konten gesperrt, die mit Agent-Tools von Drittanbietern genutzt wurden, und erklärt, seine Beschränkungen ohne vorherige Ankündigung durchsetzen zu können. Yorozu zu nutzen, um Claude Code oder Codex – über OpenClaw oder anderweitig – mit einer Abo-Anmeldung (etwa Claude Pro oder Max oder einem ChatGPT-Tarif) zu steuern, <strong>kann gegen diese Regeln verstoßen und dazu führen, dass dein Konto ohne Erstattung gedrosselt, gesperrt oder dauerhaft ausgeschlossen wird.</strong></p>
    <p>Du allein bist dafür verantwortlich, die Bedingungen jedes Anbieters, den du nutzt, zu lesen und einzuhalten, darunter die <a href="https://www.anthropic.com/legal/consumer-terms">Verbraucherbedingungen von Anthropic</a>, die <a href="https://code.claude.com/docs/en/legal-and-compliance">rechtlichen und Compliance-Bedingungen von Claude Code</a> und die <a href="https://openai.com/policies/terms-of-use/">Nutzungsbedingungen von OpenAI</a>. Ein API-Schlüssel, der dir in Rechnung gestellt wird, ist in der Regel die risikoärmere Wahl. <strong>Wir sind nicht verantwortlich für Maßnahmen, die ein Anbieter gegen dein Konto ergreift, oder für daraus entstehende Verluste.</strong></p>
  </div>

  <h2>3. Software von Drittanbietern</h2>
  <p>OpenClaw, Claude Code, Codex und die anderen Werkzeuge, die dein Agent nutzt, sind Software von Drittanbietern, die von ihren Eigentümern unter deren eigenen Lizenzen und Bedingungen bereitgestellt wird. OpenClaw ist Open-Source-Software der OpenClaw Foundation, lizenziert unter der MIT-Lizenz „wie besehen“, ohne Gewährleistung. Wir entwickeln, kontrollieren oder unterstützen diese Software oder die dahinterstehenden Modellanbieter nicht und sind nicht dafür verantwortlich, wie sie sich verhält, was sie ausgibt oder was sie auf deinem Computer tut. Dazu gehören Befehle, die sie ausführt, Dateien, die sie ändert oder löscht, Nachrichten, die sie sendet, Käufe, die sie tätigt, und alles, was mit Berechtigungen geschieht, die du ihr erteilst. Yorozu steht in keiner Verbindung zur OpenClaw Foundation, zu Anthropic oder zu OpenAI und wird von ihnen weder unterstützt noch gesponsert. Alle Produktnamen gehören ihren Eigentümern.</p>

  <h2>4. Du bist für deine Agenten verantwortlich</h2>
  <p>KI-Agenten können auf deinem Computer und in deinen Online-Konten handeln, und sie machen Fehler. Du bist verantwortlich für ihre Konfiguration, für die Berechtigungen und Freigaben, die du erteilst (einschließlich jedes Modus, der Freigaben überspringt), für die Prüfung ihrer Ergebnisse und für alles, was über deine Geräte geschieht. Lege Backups an. Nutze Yorozu nicht dort, wo ein Ausfall oder eine fehlerhafte Aktion Verletzungen, erhebliche finanzielle Verluste oder rechtlichen Schaden verursachen könnte.</p>

  <h2>5. Zulässige Nutzung</h2>
  <p>Nutze Yorozu nicht, um gegen Gesetze zu verstoßen, die Rechte anderer zu verletzen, gegen die Bedingungen eines Anbieters zu verstoßen, das Relay anzugreifen oder zu überlasten oder auf Geräte oder Konten zuzugreifen, die nicht dir gehören. Wir können den Zugang zum gehosteten Relay sperren, um es oder seine Nutzer zu schützen.</p>

  <h2>6. Das Relay</h2>
  <p>Das gehostete Relay wird kostenlos und nach bestem Bemühen bereitgestellt. Es kann jederzeit langsam, nicht verfügbar, geändert oder eingestellt werden. Du kannst stattdessen dein eigenes Relay betreiben.</p>

  <h2>7. Keine Gewährleistung</h2>
  <p>Soweit gesetzlich zulässig, wird Yorozu „wie besehen“ und „wie verfügbar“ bereitgestellt, ohne ausdrückliche oder stillschweigende Gewährleistungen jeglicher Art, einschließlich Marktgängigkeit, Eignung für einen bestimmten Zweck, Nichtverletzung von Rechten, Richtigkeit, Sicherheit sowie unterbrechungs- oder fehlerfreiem Betrieb.</p>

  <h2>8. Haftungsbeschränkung</h2>
  <p>Soweit gesetzlich zulässig, haften wir nicht für indirekte, beiläufige, besondere, Folge- oder Strafschäden oder für den Verlust von Daten, Gewinnen, Konten, Zugang zu Diensten oder Abos von Drittanbietern oder Geschäften, die sich aus Yorozu, aus Software oder Anbietern von Drittanbietern oder aus Aktionen von KI-Agenten ergeben, selbst wenn wir auf die Möglichkeit eines solchen Verlusts hingewiesen wurden. Unsere Gesamthaftung für Ansprüche im Zusammenhang mit Yorozu ist auf den Betrag beschränkt, den du uns in den 12 Monaten vor dem Anspruch für Yorozu gezahlt hast, oder auf 10 USD, wenn du nichts gezahlt hast. Manche Rechtsordnungen lassen bestimmte Ausschlüsse oder Beschränkungen nicht zu. In diesen Rechtsordnungen gelten sie nur, soweit das Gesetz es erlaubt. Nichts in diesen Bedingungen beschränkt eine Haftung, die gesetzlich nicht beschränkt werden kann, etwa die Haftung für Vorsatz oder grobe Fahrlässigkeit.</p>

  <h2>9. Freistellung</h2>
  <p>Soweit gesetzlich zulässig, erklärst du dich bereit, uns von Ansprüchen freizustellen, die sich aus deiner Nutzung von Yorozu, den Handlungen deiner Agenten oder deinem Verstoß gegen diese Bedingungen oder die Bedingungen eines Dritten ergeben.</p>

  <h2>10. Änderungen und Beendigung</h2>
  <p>Wir können diese Bedingungen aktualisieren, indem wir hier eine neue Fassung veröffentlichen. Wenn du Yorozu nach einer Aktualisierung weiter nutzt, akzeptierst du sie. Du kannst die Nutzung von Yorozu jederzeit beenden, indem du die Apps löschst.</p>

  <h2>11. Anwendbares Recht</h2>
  <p>Diese Bedingungen unterliegen japanischem Recht, und das Bezirksgericht Tokio ist als Gericht erster Instanz ausschließlich zuständig, sofern die Verbraucherschutzgesetze deines Wohnsitzlandes nichts anderes verlangen.</p>

  <h2>12. Kontakt</h2>
  <p><a href="mailto:contact@yumi.to">contact@yumi.to</a></p>`,
  },
};

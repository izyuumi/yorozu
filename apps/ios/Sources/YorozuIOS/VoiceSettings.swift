import SwiftUI
import VoiceText

/// Settings › Voice Input: the opt-in switch, the model, its download, the language and the dictionary.
struct VoiceInputSection: View {
    @AppStorage(VoiceModel.enabledKey) private var enabled = false
    @AppStorage(VoiceModel.languageKey) private var language = VoiceLanguage.automatic
    @AppStorage(VoiceModel.dictionaryKey) private var dictionary = ""
    @State private var deleting = false
    @State private var confirmingCellular = false
    private let setup = VoiceSetup.shared

    var body: some View {
        Section {
            Toggle(String(localized: "Voice Input"), isOn: $enabled)
                .disabled(!VoiceSetup.supported)
                .onChange(of: enabled) { _, on in on ? setup.prepare() : setup.pause() }
            if enabled, VoiceSetup.supported, let engine = setup.engine {
                VoiceSubpage(String(localized: "Model"), value: engine.name, action: String(localized: "Change…")) { VoiceModelList() }
                status(engine)
                Picker(String(localized: "Language"), selection: $language) {
                    Text("Automatic").tag(VoiceLanguage.automatic)
                    ForEach(languages(engine).filter { $0 != .automatic }) { Text(verbatim: $0.name).tag($0) }
                }
                .onChange(of: language) { setup.prepare() }
                VoiceSubpage(String(localized: "Dictionary"), value: VoiceDictionary(json: dictionary).entries.count.formatted(), action: String(localized: "Edit…")) {
                    VoiceDictionaryList()
                }
            }
            if let model = setup.model, model.hasFiles {
                Button(String(localized: "Delete Model"), role: .destructive) { deleting = true }
            }
        } header: {
            Text("Voice Input")
        } footer: {
            footer
        }
        .task { if enabled, VoiceSetup.supported { setup.prepare() } }
        .confirmationDialog(String(localized: "Delete the voice model?"), isPresented: $deleting, titleVisibility: .visible) {
            Button(String(localized: "Delete Model"), role: .destructive) {
                enabled = false
                setup.model?.delete()
            }
        } message: {
            Text("Voice input turns off. Turning it on again downloads the model again.")
        }
        .confirmationDialog(String(localized: "Download using cellular data?"), isPresented: $confirmingCellular, titleVisibility: .visible) {
            Button(String(localized: "Download Using Cellular")) { setup.prepare(cellular: true) }
        } message: {
            if let model = setup.model {
                Text("Up to \(voiceSize(model.totalBytes - model.received)) more will be downloaded over cellular or a personal hotspot. Charges may apply.")
            }
        }
    }

    private func languages(_ engine: VoiceEngineID) -> [VoiceLanguage] {
        if let languages = engine.languages { return languages }
        let codes = setup.apple.languages
        return codes.isEmpty ? VoiceLanguage.allCases : VoiceLanguage.allCases.filter { $0.code.map(codes.contains) ?? true }
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
            if !VoiceSetup.supported {
                if !VoiceModel.appleHosting {
                    Text("Voice input needs iOS 26 or later.")
                } else {
                    Text("This device needs more memory for voice input.")
                }
            } else if let engine = setup.engine, let model = setup.model {
                #if os(iOS)
                Text("Speak a message instead of typing it. Speech is transcribed on this device; turning this on downloads the \(voiceSize(model.totalBytes)) model from Apple.")
                #else
                Text("Speak a message instead of typing it. Speech is transcribed on this device; turning this on downloads the \(voiceSize(model.totalBytes)) model from Hugging Face.")
                #endif
                if let license = engine.license {
                    Text("The model is \(engine.name) by \(engine.maker), under the \(license.name) license.")
                }
            } else {
                Text("Speak a message instead of typing it. Speech is transcribed on this device by Apple Speech, which downloads each language the first time.")
            }
            if enabled, VoiceSetup.supported, language == .automatic {
                if setup.engine == .apple {
                    if !setup.apple.automaticName.isEmpty {
                        Text("Automatic uses this device’s language, \(setup.apple.automaticName). Apple Speech offers only the languages it supports on this device.")
                    }
                } else {
                    Text("Automatic detects the language you speak.")
                }
            }
        }
    }

    @ViewBuilder private func status(_ engine: VoiceEngineID) -> some View {
        if engine == .apple {
            switch setup.apple.state {
            case .unknown, .ready:
                EmptyView()
            case .absent:
                Button(String(localized: "Download the Language")) { setup.prepare() }
            case .downloading(let fraction):
                ProgressView(value: fraction) { Text("Downloading the language…") }
            case .unsupported:
                Text("Apple Speech can’t transcribe this language on this device. Pick another language or model.")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).foregroundStyle(YorozuPalette.warning)
                Button(String(localized: "Try Again")) { setup.prepare() }
            }
        } else if let model = setup.model {
            switch model.state {
            case .ready:
                LabeledContent(String(localized: "Size"), value: voiceSize(model.totalBytes))
            case .downloading:
                ProgressView(value: Double(model.received), total: Double(model.totalBytes)) {
                    Text("Downloading the model…")
                } currentValueLabel: {
                    Text("\(voiceSize(model.received)) of \(voiceSize(model.totalBytes))")
                }
                if model.waitingForWiFi {
                    Text("Waiting for Wi-Fi. The model downloads on Wi-Fi so it doesn’t use cellular data.")
                        .foregroundStyle(.secondary)
                    Button(String(localized: "Download Using Cellular…")) { confirmingCellular = true }
                }
            case .absent:
                Button(String(localized: "Download the Model")) { setup.prepare() }
            case .unavailable:
                Text("The voice model isn’t available for this version of Yorozu yet. Try again later.")
                    .foregroundStyle(.secondary)
                Button(String(localized: "Try Again")) { setup.prepare() }
            case .failed(let message):
                Text(message).foregroundStyle(YorozuPalette.warning)
                Button(String(localized: "Try Again")) { setup.prepare() }
            }
        }
    }
}

/// Settings › Voice Input › Model: every engine this build has, with what it costs and why one can't run.
struct VoiceModelList: View {
    @AppStorage(VoiceModel.enabledKey) private var enabled = false
    @AppStorage(VoiceModel.engineKey) private var chosen: VoiceEngineID?
    @State private var deleting: VoiceEngineID?
    private let setup = VoiceSetup.shared
    static let licenses = URL(string: "https://github.com/izyuumi/yorozu/blob/main/docs/voice-licenses/README.md")!

    var body: some View {
        Form {
            Section {
                ForEach(VoiceSetup.listed) { row($0) }
            } footer: {
                VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                    Text("Every model runs on this device; what you say isn’t sent anywhere to be transcribed. Streaming models are built to transcribe as you speak.")
                    Link(String(localized: "Licenses"), destination: Self.licenses)
                }
            }
        }
        .formStyle(.grouped)
        .task { for model in VoiceModel.all.values { await model.checkAvailability() } }
        .confirmationDialog(String(localized: "Delete the voice model?"), isPresented: Binding { deleting != nil } set: { if !$0 { deleting = nil } }, titleVisibility: .visible) {
            Button(String(localized: "Delete Model"), role: .destructive) {
                if let deleting { VoiceModel.all[deleting]?.delete() }
            }
        } message: {
            Text("Choosing it again downloads it again.")
        }
    }

    private func row(_ engine: VoiceEngineID) -> some View {
        let model = VoiceModel.all[engine]
        let reason = VoiceSetup.unsupportedReason(engine)
        let selected = setup.engine == engine
        return HStack {
            Button {
                chosen = engine
                setup.refresh()
                if enabled { setup.prepare() }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                        Text(verbatim: engine.name).foregroundStyle(reason == nil ? .primary : .secondary)
                        Text(details(engine)).textStyle(.caption).foregroundStyle(.secondary)
                        status(engine, model: model, reason: reason)
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark").foregroundStyle(.tint).accessibilityHidden(true)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(reason != nil || model?.state == .unavailable)
            .accessibilityAddTraits(selected ? .isSelected : [])
            if let model, model.hasFiles, !selected {
                Button(String(localized: "Delete"), role: .destructive) { deleting = engine }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func details(_ engine: VoiceEngineID) -> String {
        var parts: [String] = []
        if let model = VoiceModel.all[engine] {
            parts.append(voiceSize(model.totalBytes))
        } else {
            parts.append(String(localized: "Built in"))
        }
        if let count = engine.languageCount {
            parts.append(String(localized: "\(count) languages"))
        } else {
            parts.append(String(localized: "Languages vary by device"))
        }
        if let memory = engine.memoryGB { parts.append(String(localized: "\(memory) GB memory")) }
        if engine.streaming { parts.append(String(localized: "Streaming")) }
        if let license = engine.license { parts.append(license.name) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func status(_ engine: VoiceEngineID, model: VoiceModel?, reason: String?) -> some View {
        if let reason {
            Text(reason).textStyle(.caption).foregroundStyle(.secondary)
        } else if let model {
            switch model.state {
            case .ready:
                Text("Downloaded").textStyle(.caption).foregroundStyle(.secondary)
            case .downloading:
                ProgressView(value: Double(model.received), total: Double(model.totalBytes))
                    .accessibilityLabel(Text("Downloading the model…"))
            case .unavailable:
                Text("Not available yet").textStyle(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text(message).textStyle(.caption).foregroundStyle(YorozuPalette.warning)
            case .absent:
                if model.hasFiles {
                    Text("Paused at \(voiceSize(model.received)) of \(voiceSize(model.totalBytes))").textStyle(.caption).foregroundStyle(.secondary)
                }
            }
        } else if case .downloading(let fraction) = setup.apple.state {
            ProgressView(value: fraction).accessibilityLabel(Text("Downloading the language…"))
        }
    }
}

/// Settings › Voice Input › Dictionary: words voice input should know, each optionally with what it mishears.
struct VoiceDictionaryList: View {
    @AppStorage(VoiceModel.dictionaryKey) private var stored = ""
    @State private var editing: VoiceDictionary.Entry?

    private var dictionary: VoiceDictionary {
        get { VoiceDictionary(json: stored) }
        nonmutating set { stored = newValue.json }
    }

    var body: some View {
        Form {
            Section {
                if dictionary.entries.isEmpty {
                    Text("No words yet.").foregroundStyle(.secondary)
                }
                ForEach(dictionary.entries) { entry in
                    Button { editing = entry } label: {
                        VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                            Text(verbatim: entry.term)
                            if !entry.heardAs.isEmpty {
                                Text("Heard as “\(entry.heardAs)”").textStyle(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .swipeActions { Button(String(localized: "Delete"), role: .destructive) { remove(entry) } }
                    .contextMenu { Button(String(localized: "Delete"), role: .destructive) { remove(entry) } }
                }
            } footer: {
                Text("Add names and words voice input gets wrong. The model is told to expect them, and wherever a transcript has what you put under Heard As, the word replaces it. The dictionary stays on this device. Up to \(VoiceDictionary.maxEntries) words.")
            }
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(String(localized: "Add Word"), systemImage: "plus") { editing = VoiceDictionary.Entry(term: "") }
                    .disabled(dictionary.isFull)
            }
        }
        .sheet(item: $editing) { entry in
            VoiceDictionaryEditor(entry: entry, isNew: !dictionary.entries.contains { $0.id == entry.id }) { saved in
                var words = dictionary
                _ = words.save(saved)
                dictionary = words
            }
        }
    }

    private func remove(_ entry: VoiceDictionary.Entry) {
        var words = dictionary
        words.remove(entry.id)
        dictionary = words
    }
}

private struct VoiceDictionaryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entry: VoiceDictionary.Entry
    let isNew: Bool
    let save: (VoiceDictionary.Entry) -> Void

    init(entry: VoiceDictionary.Entry, isNew: Bool, save: @escaping (VoiceDictionary.Entry) -> Void) {
        _entry = State(initialValue: entry)
        self.isNew = isNew
        self.save = save
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(String(localized: "Word"), text: $entry.term)
                    TextField(String(localized: "Heard As (Optional)"), text: $entry.heardAs)
                } footer: {
                    Text("Leave Heard As empty to only tell the model to expect the word. Fill it in with what voice input writes instead, and every transcript gets the word in its place.")
                }
            }
            .formStyle(.grouped)
            .autocorrectionDisabled()
            .navigationTitle(isNew ? String(localized: "Add Word") : String(localized: "Edit Word"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save")) {
                        save(entry)
                        dismiss()
                    }
                    .disabled(VoiceDictionary.clean(entry) == nil)
                }
            }
        }
        #if os(macOS)
        .frame(width: LayoutMetrics.settingsWidth)
        #endif
    }
}

/// A row opening a page of its own: pushed on iPhone and iPad, a sheet in the Mac's settings window, which
/// has no navigation stack.
private struct VoiceSubpage<Destination: View>: View {
    let title: String
    let value: String
    let action: String
    @ViewBuilder let destination: () -> Destination
    #if os(macOS)
    @State private var open = false
    #endif

    init(_ title: String, value: String, action: String, @ViewBuilder destination: @escaping () -> Destination) {
        self.title = title
        self.value = value
        self.action = action
        self.destination = destination
    }

    var body: some View {
        #if os(iOS)
        NavigationLink {
            destination()
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
        } label: {
            LabeledContent(title, value: value)
        }
        #else
        LabeledContent(title) {
            HStack {
                Text(verbatim: value)
                Button(action) { open = true }
            }
        }
        .sheet(isPresented: $open) {
            NavigationStack {
                destination()
                    .navigationTitle(title)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(String(localized: "Done")) { open = false }
                        }
                    }
            }
            .frame(width: LayoutMetrics.settingsWidth, height: 480)
        }
        #endif
    }
}

func voiceSize(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }

extension VoiceDictionary {
    /// The owner's dictionary, kept as JSON in this device's settings only.
    static var stored: VoiceDictionary { VoiceDictionary(json: UserDefaults.standard.string(forKey: VoiceModel.dictionaryKey) ?? "") }

    init(json: String) {
        self = (try? JSONDecoder().decode(VoiceDictionary.self, from: Data(json.utf8))) ?? VoiceDictionary()
    }

    var json: String { (try? JSONEncoder().encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
}

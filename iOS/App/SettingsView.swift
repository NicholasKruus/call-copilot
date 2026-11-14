import SwiftUI

/// Edits the same settings.json the Mac app uses, plus the API key (kept in the Keychain, not in the file).
/// Changes apply from the next time you press Listen.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = Settings.load().0
    @State private var loadNote = Settings.load().1
    @State private var keyInput = ""
    @State private var keyNote: String?
    @State private var checkingKey = false
    @State private var hasKey = APIKeyStore.load() != nil
    @State private var newSite = ""
    @State private var confirmRestore = false
    @State private var saveError: String?

    private static let models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
    private static let efforts = ["low", "medium", "high"]

    var body: some View {
        NavigationStack {
            Form {
                if let loadNote { Section { Text(loadNote).foregroundStyle(K.red) } }
                keySection
                watcherSection
                Section {
                    TextField("For example: I run operations at a 12-person research nonprofit.",
                              text: optional(\.aboutMe), axis: .vertical)
                        .lineLimit(2...5)
                } header: { Text("About you") } footer: {
                    Text("Optional. Helps cards fit your context.")
                }
                modelSection
                sitesSection
                Section {
                    Button("Restore the example watchers and sites") { confirmRestore = true }
                }
                Section {
                    Text(Self.privacy).font(.footnote).foregroundStyle(.secondary)
                } header: { Text("Privacy") }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save", action: save).bold() }
            }
            .alert("Couldn't save", isPresented: .constant(saveError != nil)) {
                Button("OK") { saveError = nil }
            } message: { Text(saveError ?? "") }
            .confirmationDialog("Replace your watchers and trusted sites with the examples?", isPresented: $confirmRestore,
                                titleVisibility: .visible) {
                Button("Restore examples", role: .destructive, action: restoreExamples)
            }
        }
    }

    // MARK: sections

    private var keySection: some View {
        Section {
            if hasKey {
                LabeledContent("Anthropic API key", value: "Saved")
                Button("Remove key", role: .destructive) {
                    APIKeyStore.delete()
                    hasKey = false
                    keyNote = nil
                }
            } else {
                SecureField("sk-ant-…", text: $keyInput)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                Button(checkingKey ? "Checking…" : "Check and save key", action: saveKey)
                    .disabled(keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checkingKey)
            }
            if let keyNote { Text(keyNote).font(.footnote).foregroundStyle(hasKey ? .secondary : K.red) }
        } header: { Text("API key") } footer: {
            Text("Create one at platform.claude.com → API keys. It's kept in this iPhone's Keychain only and isn't shown again. You pay Anthropic per use; the running cost shows while you listen.")
        }
    }

    private var watcherSection: some View {
        Section {
            ForEach(Array((settings.watchers ?? []).enumerated()), id: \.offset) { i, w in
                NavigationLink {
                    WatcherEditor(watcher: watcherBinding(i))
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Rectangle().fill(w.isOn ? Palette.watcher(activeIndex(i)) : Color.secondary.opacity(0.4))
                                .frame(width: 6, height: 6)
                            Text(w.name.isEmpty ? "Untitled" : w.name).font(.body.weight(.semibold))
                            if !w.isOn { Text("off").font(.caption).foregroundStyle(.secondary) }
                            if w.usesWeb { Image(systemName: "globe").font(.caption).foregroundStyle(.secondary) }
                            if w.reference != nil { Image(systemName: "list.bullet").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text(w.instruction).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            .onDelete { settings.watchers?.remove(atOffsets: $0) }
            .onMove { settings.watchers?.move(fromOffsets: $0, toOffset: $1) }
            Button("Add a watcher") {
                settings.watchers = (settings.watchers ?? []) + [Watcher(name: "", instruction: "")]
            }
        } header: { Text("Watchers") } footer: {
            Text("Each watcher says, in plain language, what to surface without being asked. Example: “When someone describes a task they do by hand, suggest a tool that could do it, with a link.”")
        }
    }

    private var modelSection: some View {
        Section {
            Picker("Model", selection: optional(\.model, default: "claude-opus-5-5")) {
                ForEach(Self.models + ((settings.model).map { Self.models.contains($0) ? [] : [$0] } ?? []), id: \.self) {
                    Text(Self.modelName($0)).tag($0)
                }
            }
            Picker("Effort", selection: optional(\.effort, default: "low")) {
                ForEach(Self.efforts, id: \.self) { Text($0.capitalized).tag($0) }
            }
        } header: { Text("Claude") } footer: {
            Text("Opus is the most careful. Sonnet costs about half as much and Haiku far less, but they may miss more. Higher effort thinks longer and costs more.")
        }
    }

    private var sitesSection: some View {
        Section {
            ForEach(settings.trustedSites ?? [], id: \.self) { site in
                Text(site).font(.callout.monospaced())
            }
            .onDelete { settings.trustedSites?.remove(atOffsets: $0) }
            HStack {
                TextField("example.org", text: $newSite)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .onSubmit(addSite)
                Button("Add", action: addSite).disabled(newSite.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: { Text("Trusted sites") } footer: {
            Text("Watchers that use the web can search anywhere but open pages only on these sites (and their subdomains). A page address can carry words from the meeting to that site, so list only sites you trust.")
        }
    }

    // MARK: actions

    private func saveKey() {
        let key = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        checkingKey = true
        keyNote = nil
        Task {
            let problem = await APIKeyStore.check(key)
            checkingKey = false
            if let problem { keyNote = problem; return }
            if APIKeyStore.save(key) {
                keyInput = ""
                hasKey = true
                keyNote = "Anthropic accepted the key."
            } else {
                keyNote = "Couldn't save the key in the Keychain."
            }
        }
    }

    private func addSite() {
        var s = newSite.trimmingCharacters(in: .whitespaces).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        s = String(s.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        guard !s.isEmpty else { return }
        if !(settings.trustedSites ?? []).contains(s) { settings.trustedSites = (settings.trustedSites ?? []) + [s] }
        newSite = ""
    }

    private func save() {
        settings.watchers = settings.watchers?.filter {
            !$0.name.trimmingCharacters(in: .whitespaces).isEmpty || !$0.instruction.trimmingCharacters(in: .whitespaces).isEmpty
        }
        if let about = settings.aboutMe, about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { settings.aboutMe = "" }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(settings)
            try FileManager.default.createDirectory(at: Config.settingsURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: Config.settingsURL, options: .atomic)
            log("settings: saved")
            dismiss()
        } catch {
            saveError = "\(error.localizedDescription)"
        }
    }

    private func restoreExamples() {
        guard let url = Bundle.main.url(forResource: "default-settings", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let defaults = try? JSONDecoder().decode(Settings.self, from: data) else { return }
        settings.watchers = defaults.watchers
        settings.trustedSites = defaults.trustedSites
    }

    // MARK: bindings

    /// A watcher's colour follows its position among the watchers that are on, as on its cards.
    private func activeIndex(_ i: Int) -> Int {
        (settings.watchers ?? []).prefix(i).filter(\.isOn).count
    }

    private func watcherBinding(_ i: Int) -> Binding<Watcher> {
        Binding(get: { (settings.watchers ?? [])[safe: i] ?? Watcher(name: "", instruction: "") },
                set: { if settings.watchers?.indices.contains(i) == true { settings.watchers?[i] = $0 } })
    }

    private func optional(_ path: WritableKeyPath<Settings, String?>, default value: String = "") -> Binding<String> {
        Binding(get: { settings[keyPath: path] ?? value }, set: { settings[keyPath: path] = $0 })
    }

    private static func modelName(_ id: String) -> String {
        switch id {
        case "claude-opus-5-5": return "Opus 5.5"
        case "claude-sonnet-5-5": return "Sonnet 5.5"
        case "claude-haiku-5-5": return "Haiku 5.5"
        default: return id
        }
    }

    static let privacy = """
    Audio stays on this iPhone: it's transcribed here by Apple's speech recognition. The transcript text, your \
    questions, your settings and your reference lists go to Anthropic with your API key, under your API account's \
    data settings. Watchers that use the web send searches through Anthropic, and the trusted sites see page requests. \
    Nothing from a meeting is saved: the transcript is dropped when listening stops. While listening, the newest card \
    shows on the Lock Screen, where others can see it.
    """
}

struct WatcherEditor: View {
    @Binding var watcher: Watcher

    var body: some View {
        Form {
            Section("Name") {
                TextField("Evidence", text: $watcher.name)
            }
            Section {
                TextField("When anyone states or speculates about an empirical question, surface the best evidence…",
                          text: $watcher.instruction, axis: .vertical)
                    .lineLimit(4...14)
            } header: { Text("What to surface") } footer: {
                Text("Say when it should speak up and what a card should contain. It stays quiet otherwise.")
            }
            Section {
                Toggle("On", isOn: Binding(get: { watcher.isOn }, set: { watcher.enabled = $0 }))
                Toggle("Can search the web", isOn: Binding(get: { watcher.usesWeb }, set: { watcher.web = $0 }))
            } footer: {
                Text("Searching costs about a cent each, plus reading the results.")
            }
            Section {
                TextField("https://…", text: Binding(get: { watcher.reference ?? "" },
                                                     set: { watcher.reference = $0.isEmpty ? nil : $0 }))
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: { Text("Reference list (optional)") } footer: {
                Text("An https address loaded when listening starts, such as a JSON list of items with id and name. Cards about an item then link to the real item.")
            }
        }
        .navigationTitle(watcher.name.isEmpty ? "New watcher" : watcher.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

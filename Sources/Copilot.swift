import AVFoundation
import Foundation

struct Card: Identifiable {
    let id = UUID()
    let watcher: String
    /// Position of the watcher in the settings, for its colour.
    let watcherIndex: Int
    let title: String
    let body: String
    let quote: String
    /// Only links that came from a reference list or this call's search and page results.
    let links: [URL]
}

/// Runs one call: capture -> on-device transcript -> Claude -> cards. All state changes happen on the main queue.
/// The transcript lives only in memory and is dropped when the call ends. Every call starts fresh, so back-to-back
/// calls never share context.
final class Copilot: ObservableObject {
    enum Phase: Equatable { case idle, starting, listening, ended, failed(String) }

    @Published var phase: Phase = .idle
    @Published var callApp: String?
    /// Watchers and reference lists, e.g. "Evidence · Automations (31)".
    @Published var watchStatus = ""
    @Published var referencesReady = false
    /// Settings or reference problems that don't stop the call.
    @Published var setupNote: String?
    @Published var cards: [Card] = []
    @Published var answer: String?
    @Published var asking = false
    @Published var lastLine: String?
    /// The last few transcript lines (the demo's stage shows them as captions).
    @Published var recentLines: [String] = []
    /// Demo only: text being "typed" into the ask bar.
    @Published var demoTyping: String?
    @Published var meActive = false
    @Published var themActive = false
    /// "Them" covers everything the Mac plays (a start by hand with no call app), not just the call.
    @Published var themIsAllAudio = false
    @Published var turnError: String?
    /// A capture side that isn't working.
    @Published var captureNote: String?

    var isListening: Bool { phase == .starting || phase == .listening }
    /// The detector's latest view of the call apps, for starts by hand.
    var currentSnapshot: CallSnapshot { snapshot }
    var onCardsAdded: (() -> Void)?
    /// Test mode prints each line and reply to stdout.
    var echo = false

    // Call state
    private var generation = 0
    private var skippedCall = false
    private var stopWhenCallEnds = false
    private var lastCallSeen = Date.distantPast
    private var lastSpeech = Date()
    private var snapshot = CallSnapshot()
    private var startedAt = Date()

    // Capture
    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var transcribers: [SourceTranscriber] = []
    private var deadTapRebuiltAt: Date?

    // Claude
    private var settings = Settings()
    private var watchers: [Watcher] = []
    private var references: [String: Reference] = [:]
    private var referenceMessage: String? // the REFERENCE message, once every list has loaded (nil if there are none)
    private var allowedLinks = Set<String>() // URLs a card may link to
    private var toolInputs: [String: (name: String, input: [String: Any])] = [:]
    private var session: ClaudeSession?
    private var sessionReady = false
    private var databaseSent = false
    private var recap: [String] = [] // answered lines to replay after the database when the session restarts
    private var sessionLines: [String] = [] // every line Claude has answered this call, for a recap after a restart
    private var inFlightLines: [String] = [] // lines in the turn awaiting an answer; resent as new if it never comes
    private var pending: [String] = []
    private var busy = false
    private var queuedAsk: String?
    private var inFlightAsk: String?
    private var turnDeadline = Date.distantFuture
    private var restarts = 0
    private var lastSend = Date.distantPast
    private var shownCards = Set<String>()
    private var timer: Timer?

    // MARK: call detection

    func callUpdate(_ snap: CallSnapshot) {
        snapshot = snap
        if let app = snap.primary {
            lastCallSeen = Date()
            if isListening {
                callApp = app
                stopWhenCallEnds = true
                if !snap.processes.isEmpty {
                    system?.retarget(snap.processes)
                    themIsAllAudio = false
                }
            } else if !skippedCall && phase != .starting {
                start(app: app, auto: true, processes: snap.processes)
            }
        } else if Date().timeIntervalSince(lastCallSeen) > Config.callEndGrace {
            skippedCall = false
            if isListening && stopWhenCallEnds { stop(reason: "call ended") }
        }
    }

    func toggleManual(snapshot snap: CallSnapshot) {
        if isListening {
            skippedCall = true // don't auto-restart during this call
            stop(reason: "stopped by hand")
        } else {
            skippedCall = false
            start(app: snap.primary, auto: snap.primary != nil, processes: snap.processes)
        }
    }

    func skipCall() {
        skippedCall = true
        stop(reason: "skipped")
    }

    // MARK: lifecycle

    /// `testFiles`: transcribe these files (label, file) instead of capturing; `realtime` feeds them at their own
    /// pace (the demo) rather than as fast as possible (tests).
    func start(app: String?, auto: Bool, processes: [AudioObjectID], testFiles: [(String, URL)] = [], realtime: Bool = false) {
        generation += 1
        let gen = generation
        log("start: \(app ?? "by hand")\(auto ? " (auto)" : "")")
        phase = .starting
        callApp = app
        stopWhenCallEnds = app != nil // a start by hand stops once a call it saw has ended
        startedAt = Date()
        lastSpeech = Date()
        recap = []
        cards = []; answer = nil
        shownCards = []
        lastLine = nil; recentLines = []; turnError = nil; captureNote = nil; setupNote = nil
        sessionLines = []
        inFlightLines = []
        pending = []; queuedAsk = nil; inFlightAsk = nil; busy = false; asking = false
        restarts = 0; deadTapRebuiltAt = nil
        let (loaded, settingsError) = Settings.load()
        settings = loaded
        watchers = loaded.activeWatchers
        setupNote = settingsError
        references = [:]; referenceMessage = nil; referencesReady = false
        allowedLinks = []; toolInputs = [:]
        themIsAllAudio = testFiles.isEmpty && processes.isEmpty
        lastSend = Date()
        updateWatchStatus()
        loadReferences(gen: gen)
        startSession(gen: gen)

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.startCapture(testFiles: testFiles, realtime: realtime, processes: processes, gen: gen)
                DispatchQueue.main.async { if self.generation == gen, self.phase == .starting { self.phase = .listening } }
            } catch {
                log("capture: failed: \(error)")
                DispatchQueue.main.async {
                    guard self.generation == gen else { return }
                    self.skippedCall = true // don't retry every 2 s during this call
                    self.teardown()
                    self.phase = .failed("\(error)")
                }
            }
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop(reason: String) {
        guard phase != .idle else { return }
        log("stop: \(reason)")
        generation += 1
        teardown() // drops the transcript
        phase = .ended
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        mic?.stop(); mic = nil
        system?.stop(); system = nil
        let ts = transcribers
        transcribers = []
        Task { for t in ts { await t.finish() } }
        session?.stop(); session = nil
        sessionReady = false
        sessionLines = []
        inFlightLines = []
        recap = []
        pending = []
        queuedAsk = nil
        inFlightAsk = nil
        busy = false
        asking = false
        meActive = false; themActive = false
        lastLine = nil
        recentLines = []
    }

    private func startCapture(testFiles: [(String, URL)], realtime: Bool, processes: [AudioObjectID], gen: Int) async throws {
        let locale = await SourceTranscriber.locale()
        if !testFiles.isEmpty {
            var sources: [(SourceTranscriber, URL)] = []
            for (label, file) in testFiles {
                let t = SourceTranscriber(label: label)
                try await t.start(locale: locale)
                wire(t, gen: gen)
                sources.append((t, file))
            }
            let ts = sources.map(\.0)
            await MainActor.run {
                self.transcribers = ts
                if realtime, self.generation == gen { self.phase = .listening } // fed like a live call
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (t, file) in sources {
                    group.addTask {
                        try await Self.feed(file: file, into: t, realtime: realtime)
                        await t.finish()
                    }
                }
                try await group.waitForAll()
            }
            return
        }
        let micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        let me = SourceTranscriber(label: "Me"), them = SourceTranscriber(label: "Them")
        do {
            try await me.start(locale: locale)
            try await them.start(locale: locale)
        } catch {
            await me.finish(); await them.finish()
            throw error
        }
        wire(me, gen: gen); wire(them, gen: gen)
        let mic = MicCapture(), system = SystemAudioCapture(targets: processes.isEmpty ? nil : processes)
        mic.onBuffer = { [weak me] in me?.append($0) }
        system.onBuffer = { [weak them] in them?.append($0) }
        mic.onFailure = { [weak self] e in self?.noteCapture("Mic stopped working (\(e)).") }
        system.onFailure = { [weak self] e in self?.noteCapture("Call audio stopped working (\(e)).") }
        let started: Bool = await MainActor.run {
            guard self.generation == gen else { return false }
            var notes: [String] = []
            var anyRunning = false
            if micAllowed {
                do { try mic.start(); self.mic = mic; anyRunning = true }
                catch { notes.append("Mic unavailable (\(error)).") }
            } else {
                notes.append("Microphone access is off: System Settings → Privacy & Security → Microphone.")
            }
            do { try system.start(); self.system = system; anyRunning = true }
            catch { notes.append("Call audio unavailable (\(error)).") }
            self.captureNote = notes.isEmpty ? nil : notes.joined(separator: " ")
            guard anyRunning else { return false }
            self.transcribers = [me, them]
            return true
        }
        if !started { // nothing captured, or a newer start or a stop came in meanwhile
            await me.finish(); await them.finish()
            let note = await MainActor.run { self.generation == gen ? self.captureNote : nil }
            if let note { throw CaptureError(note) }
        }
    }

    private func noteCapture(_ note: String) {
        captureNote = [captureNote, note].compactMap { $0 }.joined(separator: " ")
    }

    private func wire(_ t: SourceTranscriber, gen: Int) {
        let label = t.label
        t.onFinal = { [weak self] text in
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                let line = "[\(label)] \(text)"
                if self.echo { print("HEARD " + line) }
                self.pending.append(line)
                self.lastLine = line
                self.recentLines = Array((self.recentLines + [line]).suffix(6))
                self.lastSpeech = Date()
            }
        }
        t.onEnded = { [weak self] label in
            DispatchQueue.main.async {
                guard let self, self.generation == gen, self.isListening else { return }
                self.noteCapture("Transcription of \(label) stopped.")
            }
        }
    }

    private static func feed(file: URL, into t: SourceTranscriber, realtime: Bool) async throws {
        let f = try AVAudioFile(forReading: file)
        let chunk: AVAudioFrameCount = 4800
        let start = Date()
        var fed: Double = 0
        while f.framePosition < f.length, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: chunk) {
            try f.read(into: buf, frameCount: min(chunk, AVAudioFrameCount(f.length - f.framePosition)))
            if buf.frameLength == 0 { break }
            t.append(buf)
            if realtime {
                fed += Double(buf.frameLength) / f.processingFormat.sampleRate
                let ahead = fed - Date().timeIntervalSince(start)
                if ahead > 0 { try await Task.sleep(nanoseconds: UInt64(ahead * 1e9)) }
            }
        }
    }

    // MARK: watchers and references

    private func updateWatchStatus() {
        watchStatus = watchers.map { w -> String in
            guard w.reference != nil else { return w.name }
            if let r = references[w.name] { return r.items.isEmpty ? w.name : "\(w.name) (\(r.items.count))" }
            return referencesReady ? "\(w.name) (no list)" : "\(w.name) (loading)"
        }.joined(separator: " · ")
        if watchers.isEmpty { watchStatus = "No watchers: asks only" }
    }

    /// Loads every watcher's reference list in the app (Claude never fetches them), then builds the first message.
    /// Lists not loaded within 20 s are skipped, so one slow list can't hold up the call.
    private func loadReferences(gen: Int) {
        let wanted = watchers.filter { $0.reference != nil }
        Task { [weak self] in
            var loaded: [Reference] = []
            var notes: [String] = []
            await withTaskGroup(of: (String, Result<(Reference, String?), Error>)?.self) { group in
                for w in wanted {
                    group.addTask {
                        do { return (w.name, .success(try await Reference.load(for: w))) }
                        catch { return (w.name, .failure(error)) }
                    }
                }
                group.addTask { try? await Task.sleep(nanoseconds: 20_000_000_000); return nil } // the deadline
                var pendingNames = Set(wanted.map(\.name))
                for await result in group {
                    guard let (name, outcome) = result else { break } // deadline reached
                    pendingNames.remove(name)
                    switch outcome {
                    case .success(let (ref, note)):
                        loaded.append(ref)
                        if let note { notes.append("\(name)'s reference list: \(note).") }
                    case .failure(let e):
                        notes.append("\(name)'s reference list didn't load (\(e)), so it runs without it.")
                    }
                    if pendingNames.isEmpty { break }
                }
                for name in pendingNames { notes.append("\(name)'s reference list took too long, so it runs without it.") }
                group.cancelAll()
            }
            let refs = loaded, messages = notes
            await MainActor.run {
                guard let self, self.generation == gen else { return }
                for r in refs {
                    self.references[r.watcher] = r
                    self.allowedLinks.formUnion(r.links)
                    log("reference: \(r.watcher): \(r.items.count) items, \(r.text.count) chars")
                }
                if !messages.isEmpty {
                    messages.forEach { log("reference: \($0)") }
                    self.setupNote = ([self.setupNote].compactMap { $0 } + messages).joined(separator: " ")
                }
                self.referenceMessage = refs.isEmpty ? nil : refs.map { r in
                    "REFERENCE for the \(r.watcher) watcher (from \(r.source))"
                        + (r.items.isEmpty ? ", without ids, so give ref null for it" : "") + ":\n\(r.text)"
                }.joined(separator: "\n\n") + "\n\nThat is all the reference material for this call. Reply with an empty card list."
                self.referencesReady = true
                self.updateWatchStatus()
                self.tick()
            }
        }
    }

    private func systemPrompt() -> String? {
        guard let url = Bundle.main.url(forResource: "prompt", withExtension: "txt"),
              let template = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let about = (settings.aboutMe ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return template
            .replacingOccurrences(of: "{{ABOUT}}", with: about.isEmpty ? "" : "About the user: \(about)\n")
            .replacingOccurrences(of: "{{WATCHERS}}", with: watchers.isEmpty ? "(none: answer asks only)" : settings.watcherText)
    }

    /// Links a card may use from this call's web results: the addresses in a search result's link list (chosen by the
    /// search engine, not the model), and pages on the trusted sites that were actually opened. Nothing is taken from
    /// page text or error messages, which the model or a page could steer.
    private func noteToolResult(_ id: String, _ content: Any?, _ isError: Bool) {
        guard let use = toolInputs.removeValue(forKey: id), !isError else { return }
        var text = ""
        if let s = content as? String { text = s }
        if let parts = content as? [[String: Any]] { text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        switch use.name {
        case "WebSearch":
            allowedLinks.formUnion(Self.searchResultLinks(text))
        case "WebFetch":
            guard let s = use.input["url"] as? String, let url = URL(string: s), settings.isTrusted(url),
                  !text.hasPrefix("The server returned HTTP"), !text.contains("REDIRECT DETECTED") else { return }
            allowedLinks.insert(s)
        default:
            break
        }
    }

    /// The `url` fields of the JSON list after "Links:" in a WebSearch result.
    static func searchResultLinks(_ text: String) -> [String] {
        guard let start = text.range(of: "Links: [")?.upperBound else { return [] }
        let open = text.index(before: start)
        var depth = 0, inString = false, escaped = false
        var end: String.Index?
        var i = open
        while i < text.endIndex {
            let c = text[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" { inString = true }
            else if c == "[" { depth += 1 }
            else if c == "]" { depth -= 1; if depth == 0 { end = i; break } }
            i = text.index(after: i)
        }
        guard let end, let data = String(text[open...end]).data(using: .utf8),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap { $0["url"] as? String }
    }

    private func allowedLink(_ s: String) -> URL? {
        func norm(_ x: String) -> String {
            var y = x.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
            while y.hasSuffix("/") { y.removeLast() }
            return y
        }
        let n = norm(s)
        guard n.hasPrefix("https://") || n.hasPrefix("http://"),
              allowedLinks.contains(where: { norm($0) == n }) else { return nil }
        return URL(string: n)
    }

    // MARK: Claude session

    private func startSession(gen: Int) {
        guard let prompt = systemPrompt() else { turnError = "prompt.txt is missing from the app"; return }
        let s = ClaudeSession(settings: settings)
        s.onToolUse = { [weak self] id, name, input in self?.toolInputs[id] = (name, input) }
        s.onToolResult = { [weak self] id, content, isError in self?.noteToolResult(id, content, isError) }
        s.onReady = { [weak self] in
            guard let self, self.generation == gen else { return }
            self.sessionReady = true
            self.tick()
        }
        s.onResult = { [weak self] text, err in self?.handleResult(text, err) }
        s.onExit = { [weak self] reason, restartable in
            guard let self, self.generation == gen else { return }
            self.sessionDied(reason, restartable: restartable, gen: gen)
        }
        databaseSent = false
        sessionReady = false
        busy = false
        turnDeadline = .distantFuture
        do {
            try s.start(systemPrompt: prompt)
            session = s
        } catch {
            session = nil
            turnError = "Couldn't start Claude: \(error)"
            log("claude: start failed: \(error)")
        }
    }

    /// The session exited or got stuck. Restart it with the database and a recap of the call so far; cards stay.
    private func sessionDied(_ reason: String, restartable: Bool, gen: Int) {
        log("claude: session \(reason)")
        session?.stop()
        session = nil
        sessionReady = false
        busy = false
        if let ask = inFlightAsk { queuedAsk = queuedAsk ?? ask; inFlightAsk = nil }
        pending = inFlightLines + pending // never answered, so they go again as new speech
        inFlightLines = []
        guard restartable, restarts < Config.maxSessionRestarts else {
            turnError = "Claude stopped: \(reason). Press ⌃⌥C twice to restart."
            asking = false
            return
        }
        restarts += 1
        recap = sessionLines
        startSession(gen: gen)
    }

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard isListening, session != nil else { answer = "Not listening. Press Listen or ⌃⌥C first."; return }
        queuedAsk = q
        asking = true
        answer = nil
        tick()
    }

    /// Every second: meters, stop rules, the stuck-turn watchdog, the dead-tap check, then send what's due.
    func tick(force: Bool = false) {
        let now = Date()
        if let me = transcribers.first(where: { $0.label == "Me" }) {
            let a = now.timeIntervalSince(me.lastAudio) < 1.5
            if a != meActive { meActive = a }
        }
        if let them = transcribers.first(where: { $0.label == "Them" }) {
            let a = now.timeIntervalSince(them.lastAudio) < 1.5
            if a != themActive { themActive = a }
            checkDeadTap(them, now: now)
        }
        if phase == .listening, now.timeIntervalSince(lastSpeech) > Config.silenceStop {
            skippedCall = true // the call app still holds the mic; don't restart until the call ends
            stop(reason: "no speech for \(Int(Config.silenceStop / 60)) min")
            return
        }
        if busy, now > turnDeadline {
            sessionDied("didn't answer in time", restartable: true, gen: generation)
            return
        }
        guard sessionReady, !busy, let session else { return }
        if !databaseSent {
            guard referencesReady else { return } // everything waits for the reference lists
            databaseSent = true
            if let msg = referenceMessage {
                send(msg, ask: false, via: session)
                return
            }
        }
        if !recap.isEmpty {
            let msg = "TRANSCRIPT (earlier in this call, already answered; don't repeat cards from it)\n"
                + recap.joined(separator: "\n")
            recap = []
            send(msg, ask: false, via: session)
            return
        }
        let due = !pending.isEmpty && (force || now.timeIntervalSince(lastSend) >= Config.sendInterval)
        guard queuedAsk != nil || due else { return }
        var msg = pending.isEmpty ? "" : "TRANSCRIPT\n" + pending.joined(separator: "\n")
        if let q = queuedAsk { msg += (msg.isEmpty ? "" : "\n\n") + "ASK: " + q }
        let me = pending.filter { $0.hasPrefix("[Me]") }.count
        log("claude: sending \(pending.count) lines (Me \(me), Them \(pending.count - me))\(queuedAsk != nil ? " + ask" : "")")
        inFlightLines = pending
        pending = []
        inFlightAsk = queuedAsk
        queuedAsk = nil
        send(msg, ask: inFlightAsk != nil, via: session)
    }

    private func send(_ msg: String, ask: Bool, via session: ClaudeSession) {
        busy = true
        lastSend = Date()
        turnDeadline = Date().addingTimeInterval(ask ? Config.askTimeout : Config.turnTimeout)
        session.send(msg)
    }

    /// The tap delivers exact zeros when System Audio Recording is off or the tap has stalled. If the call app is
    /// playing and "Them" has been all zeros for a while, rebuild once; if that doesn't help, say so.
    private func checkDeadTap(_ them: SourceTranscriber, now: Date) {
        let silentFor = now.timeIntervalSince(them.lastNonZero)
        if silentFor < 2 {
            deadTapRebuiltAt = nil
            if let note = captureNote, note.contains(Self.deadTapNote) { // audio is back
                let rest = note.replacingOccurrences(of: Self.deadTapNote, with: "").trimmingCharacters(in: .whitespaces)
                captureNote = rest.isEmpty ? nil : rest
            }
        }
        guard phase == .listening, let system, !themIsAllAudio, snapshot.playing,
              now.timeIntervalSince(startedAt) > Config.deadTapAfter, silentFor > Config.deadTapAfter else { return }
        if let at = deadTapRebuiltAt {
            if now.timeIntervalSince(at) > Config.deadTapAfter, captureNote?.contains(Self.deadTapNote) != true {
                log("system audio: still silent after a rebuild")
                noteCapture(Self.deadTapNote)
            }
        } else {
            log("system audio: silent while the call app plays; rebuilding")
            deadTapRebuiltAt = now
            system.rebuild()
        }
    }

    static let deadTapNote = "No call audio for a while. If the other side has been talking, check System Settings → "
        + "Privacy & Security → Screen & System Audio Recording → Call Copilot."

    /// Nothing waiting to go to Claude and nothing in flight (test mode uses this).
    var idle: Bool { !busy && pending.isEmpty && queuedAsk == nil && recap.isEmpty && databaseSent }

    private func handleResult(_ text: String?, _ err: String?) {
        busy = false
        turnDeadline = .distantFuture
        let hadAsk = inFlightAsk != nil
        guard let text else {
            // Not answered: the lines (and any question) go again with the next turn.
            pending = inFlightLines + pending
            inFlightLines = []
            if let ask = inFlightAsk { queuedAsk = queuedAsk ?? ask }
            inFlightAsk = nil
            turnError = "Claude error: \(err?.prefix(120) ?? "unknown")"
            return
        }
        sessionLines += inFlightLines
        inFlightLines = []
        inFlightAsk = nil
        if hadAsk && queuedAsk == nil { asking = false }
        turnError = nil
        if echo { print("REPLY " + text.replacingOccurrences(of: "\n", with: " ")) }
        guard let reply = Self.firstJSONObject(in: text) else {
            log("claude: reply had no JSON object")
            if hadAsk { answer = text } // a plain-text answer is still an answer
            tick(); return
        }
        var added: [Card] = []
        for case let c as [String: Any] in reply["cards"] as? [Any] ?? [] {
            guard let name = c["watcher"] as? String,
                  let wi = watchers.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            var title = (c["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var links = (c["links"] as? [Any] ?? []).compactMap { $0 as? String }
            let key: String
            var ref = (c["ref"] as? String) ?? (c["ref"] as? NSNumber)?.stringValue
            if let r = ref, r.isEmpty || r.lowercased() == "null" { ref = nil }
            if let ref {
                // A card about a reference item must name a real one in its own watcher's list; its name and link
                // come from the list itself.
                guard let item = references[watchers[wi].name]?.items[ref] else {
                    log("claude: dropped a card with an unknown ref"); continue
                }
                title = item.name
                if let u = item.url { links.insert(u, at: 0) }
                key = "\(wi):ref:" + ref
            } else {
                key = watchers[wi].name.lowercased() + ":" + title.lowercased().filter { $0.isLetter || $0.isNumber }
            }
            guard !title.isEmpty, shownCards.insert(key).inserted else { continue }
            var unique: [String] = []
            for l in links where !unique.contains(l) { unique.append(l) }
            var urls: [URL] = []
            for l in unique { if let u = allowedLink(l), !urls.contains(u) { urls.append(u) } }
            let dropped = unique.count - urls.count
            if dropped > 0 { log("claude: dropped \(dropped) link(s) not from a reference list or this call's results") }
            added.append(Card(watcher: watchers[wi].name, watcherIndex: wi, title: title,
                              body: (c["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                              quote: c["quote"] as? String ?? "", links: Array(urls.prefix(3))))
            log("card: \(watchers[wi].name)\(ref != nil ? " (reference item)" : "")")
        }
        if !added.isEmpty {
            cards.insert(contentsOf: added.reversed(), at: 0)
            onCardsAdded?()
        }
        if hadAsk {
            switch reply["answer"] {
            case let s as String: answer = s
            case nil, is NSNull: answer = "(No answer came back.)"
            case let other?:
                answer = (try? JSONSerialization.data(withJSONObject: other, options: [.prettyPrinted]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "\(other)"
            }
        }
        tick()
    }

    /// The first balanced `{…}` in the text that parses as a JSON object; braces inside strings don't count.
    static func firstJSONObject(in text: String) -> [String: Any]? {
        let chars = Array(text.utf8)
        var start = chars.firstIndex(of: UInt8(ascii: "{"))
        while let s = start {
            var depth = 0, inString = false, escaped = false
            var i = s
            scan: while i < chars.count {
                let c = chars[i]
                if inString {
                    if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true }
                    else if c == UInt8(ascii: "\"") { inString = false }
                } else if c == UInt8(ascii: "\"") { inString = true }
                else if c == UInt8(ascii: "{") { depth += 1 }
                else if c == UInt8(ascii: "}") {
                    depth -= 1
                    if depth == 0 {
                        if let obj = try? JSONSerialization.jsonObject(with: Data(chars[s...i])) as? [String: Any] {
                            return obj
                        }
                        break scan
                    }
                }
                i += 1
            }
            start = s + 1 < chars.count ? chars[(s + 1)...].firstIndex(of: UInt8(ascii: "{")) : nil
        }
        return nil
    }
}

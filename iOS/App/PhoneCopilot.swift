import AVFoundation
import Foundation
import SwiftUI
import UIKit

/// One listening session at a time: iPhone mic -> on-device transcript -> Claude (CallBrain) -> cards, shown in the
/// app and on the Lock Screen. Main actor only. Nothing from the conversation is kept after the session ends except
/// the cards and last answer on screen, until the next session or until the app quits.
@MainActor
final class PhoneCopilot: ObservableObject {
    static let shared = PhoneCopilot()

    enum Phase: Equatable {
        case idle, starting, listening
        case paused(String)
        case ended(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var cards: [Card] = []
    @Published var answer: String?
    @Published private(set) var asking = false
    @Published private(set) var lastLine: String?
    @Published private(set) var micActive = false
    /// Watchers and reference lists, e.g. "Evidence · Automations (31)".
    @Published private(set) var watchStatus = ""
    /// Problems that don't stop listening: settings, reference lists, the microphone.
    @Published private(set) var notes: [String] = []
    /// The latest problem talking to Claude (cleared by the next good turn).
    @Published private(set) var turnNote: String?
    /// Estimated cost of this session at list prices; nil for a model without known prices.
    @Published private(set) var cost: Double?
    @Published private(set) var startedAt: Date?
    @Published private(set) var hasKey = false

    var isListening: Bool {
        switch phase {
        case .starting, .listening, .paused: return true
        default: return false
        }
    }

    private var brain: CallBrain?
    private var mic: PhoneMic?
    private var transcriber: SourceTranscriber?
    private let activity = LiveActivityController()
    private var timer: Timer?
    private var generation = 0
    private var lastSpeech = Date()
    private var watchers: [Watcher] = []

    init() { refreshKey() }

    func refreshKey() { hasKey = apiKey() != nil }

    func toggle() { isListening ? stop("Stopped") : start() }

    // MARK: lifecycle

    func start(testFile: URL? = nil) {
        guard !isListening else { return }
        generation += 1
        let gen = generation
        log("start")
        cards = []; answer = nil; asking = false; lastLine = nil; notes = []; turnNote = nil; cost = nil
        startedAt = Date()
        lastSpeech = Date()
        phase = .starting

        let (settings, settingsNote) = Settings.load()
        if let settingsNote { notes.append(settingsNote) }
        guard let key = apiKey() else { return fail("Add your Anthropic API key in Settings first.") }
        guard let template = SystemPrompt.bundledTemplate() else { return fail("The app is missing its prompt. Rebuild it.") }
        watchers = settings.activeWatchers
        let brain = CallBrain(settings: settings, apiKey: key, template: template, setting: Config.promptSetting)
        wire(brain, gen: gen)
        self.brain = brain
        updateWatchStatus(nil)
        brain.start()
        activity.start(startedAt: startedAt!, state: activityState())

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        Task { await self.startAudio(gen: gen, testFile: testFile) }
    }

    func stop(_ reason: String) {
        guard isListening else { return }
        log("stop: \(reason)")
        generation += 1
        teardown()
        phase = .ended(reason)
    }

    private func fail(_ message: String) {
        log("failed: \(message)")
        generation += 1
        teardown()
        phase = .failed(message)
    }

    private func teardown() {
        timer?.invalidate(); timer = nil
        mic?.stop(); mic = nil
        if let t = transcriber { Task { await t.finish() } }
        transcriber = nil
        brain?.stop(); brain = nil // drops the transcript
        asking = false
        micActive = false
        lastLine = nil
        activity.end()
    }

    private func startAudio(gen: Int, testFile: URL?) async {
        do {
            let locale = await SourceTranscriber.locale()
            let t = SourceTranscriber(label: "Room")
            try await t.start(locale: locale)
            guard generation == gen else { await t.finish(); return }
            Self.wire(t, to: self, gen: gen)
            transcriber = t
            if let testFile {
                resumeListening()
                Task.detached { try? await t.feed(file: testFile, realtime: true) }
                return
            }
            guard await AVAudioApplication.requestRecordPermission() else {
                return fail("Microphone access is off. Turn it on in Settings → Apps → Call Copilot.")
            }
            guard generation == gen else { return }
            let mic = PhoneMic()
            mic.onBuffer = Self.sink(into: t)
            mic.onInterruption = { [weak self] began in
                guard let self, self.generation == gen else { return }
                if began {
                    self.phase = .paused("Paused: another app is using the microphone")
                    self.updateActivity()
                } else {
                    self.resumeListening()
                }
            }
            mic.onFailure = { [weak self] message in
                guard let self, self.generation == gen else { return }
                self.phase = .paused(message)
                self.updateActivity()
            }
            try mic.start()
            self.mic = mic
            resumeListening()
        } catch {
            guard generation == gen else { return }
            fail("Couldn't start listening: \(error)")
        }
    }

    /// Back in the app: if the microphone was left paused (iOS won't always allow a restart from the background),
    /// try again now.
    func appBecameActive() {
        refreshKey()
        guard case .paused = phase, let mic else { return }
        if mic.restart() { resumeListening() }
    }

    /// Listening (again). The silence clock restarts, so time spent starting up or paused by a phone call doesn't
    /// count as silence.
    private func resumeListening() {
        phase = .listening
        lastSpeech = Date()
        updateActivity()
    }

    // These closures run on audio and analyzer threads, so they're made outside the main actor and only hop to it.
    nonisolated private static func sink(into t: SourceTranscriber) -> (AVAudioPCMBuffer) -> Void {
        { [weak t] buffer in t?.append(buffer) }
    }

    nonisolated private static func wire(_ t: SourceTranscriber, to copilot: PhoneCopilot, gen: Int) {
        t.onFinal = { [weak copilot] text in Task { @MainActor in copilot?.heard(text, gen: gen) } }
        t.onEnded = { [weak copilot] _ in Task { @MainActor in copilot?.transcriptionEnded(gen: gen) } }
    }

    private func transcriptionEnded(gen: Int) {
        guard generation == gen, isListening else { return }
        notes.append("Transcription stopped. Stop and start listening again.")
    }

    // MARK: conversation

    private func heard(_ text: String, gen: Int) {
        guard gen == generation, let brain else { return }
        brain.hear(text)
        lastLine = text
        lastSpeech = Date()
    }

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        guard isListening, let brain else { answer = "Start listening first."; return }
        answer = nil
        brain.ask(q)
    }

    private func wire(_ brain: CallBrain, gen: Int) {
        brain.onCards = { [weak self] new in
            guard let self, self.generation == gen else { return }
            self.cards.insert(contentsOf: new.reversed(), at: 0)
            self.updateActivity()
            if Config.isTestRun {
                for c in new { print("CARD [\(c.watcher)] \(c.title) | \(c.body) | links: \(c.links.map(\.absoluteString))") }
            }
        }
        brain.onAnswer = { [weak self] a in
            guard let self, self.generation == gen else { return }
            self.answer = a
            if Config.isTestRun { print("ANSWER " + a.replacingOccurrences(of: "\n", with: " ")) }
        }
        brain.onAsking = { [weak self] on in
            guard let self, self.generation == gen else { return }
            self.asking = on
        }
        brain.onNote = { [weak self] note in
            guard let self, self.generation == gen else { return }
            self.turnNote = note
        }
        brain.onFatal = { [weak self] message in
            guard let self, self.generation == gen else { return }
            self.fail(message)
        }
        brain.onUsage = { [weak self] c in
            guard let self, self.generation == gen else { return }
            self.cost = c
        }
        brain.onReferences = { [weak self] refs, notes in
            guard let self, self.generation == gen else { return }
            self.notes += notes
            self.updateWatchStatus(refs)
        }
    }

    /// Every second: the mic meter, the stop rules, then whatever is due to go to Claude.
    private func tick() {
        guard isListening else { return }
        let now = Date()
        if let t = transcriber {
            let active = now.timeIntervalSince(t.lastAudio) < 1.5
            if active != micActive { micActive = active }
        }
        if phase == .listening, now.timeIntervalSince(lastSpeech) > Config.silenceStop {
            return stop("Stopped after \(Int(Config.silenceStop / 60)) minutes without speech")
        }
        if let s = startedAt, now.timeIntervalSince(s) > Config.maxSession {
            return stop("Stopped after \(Int(Config.maxSession / 3600)) hours")
        }
        brain?.tick()
    }

    private func updateWatchStatus(_ refs: [String: Reference]?) {
        watchStatus = watchers.map { w -> String in
            guard w.reference != nil else { return w.name }
            guard let refs else { return "\(w.name) (loading)" }
            if let r = refs[w.name] { return r.items.isEmpty ? w.name : "\(w.name) (\(r.items.count))" }
            return "\(w.name) (no list)"
        }.joined(separator: " · ")
        if watchers.isEmpty { watchStatus = "No watchers: questions only" }
    }

    // MARK: Lock Screen

    var statusText: String {
        switch phase {
        case .idle: return "Not listening"
        case .starting: return "Starting…"
        case .listening: return "Listening"
        case .paused(let why): return why
        case .ended(let why): return why
        case .failed: return "Stopped"
        }
    }

    private func activityState() -> CopilotActivityAttributes.ContentState {
        let top = cards.first
        return .init(status: phase == .starting ? "Starting" : statusText, listening: phase == .listening,
                     cardCount: cards.count, watcher: top?.watcher, colorIndex: top?.watcherIndex ?? 0,
                     title: top?.title, body: top?.body)
    }

    private func updateActivity() { activity.update(activityState()) }

    // MARK: keys and tests

    private func apiKey() -> String? {
        if Config.isTestRun, let k = ProcessInfo.processInfo.environment["CALLCOPILOT_TEST_API_KEY"], !k.isEmpty { return k }
        return APIKeyStore.load()
    }

    /// Launch arguments for checks without a phone call (each needs its --test-* argument):
    ///   --test-file <audio> [--test-ask-at <seconds> <question>]   transcribe a file instead of the mic, at its own pace
    ///   --test-listen                                              start listening with the real microphone
    ///   --test-probe                                               check the request shape with two tiny requests
    ///   --test-preview                                             sample cards, for screenshots
    func runTestIfAsked() {
        if Config.isTestRun { UIApplication.shared.isIdleTimerDisabled = true } // a test mustn't stop at auto-lock
        if let path = Config.testValue("--test-file") {
            // A relative path is in the app's Documents folder (where `devicectl device copy to` puts test files).
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            start(testFile: path.hasPrefix("/") ? URL(fileURLWithPath: path) : docs.appendingPathComponent(path))
            if let at = Config.testValue("--test-ask-at").flatMap(Double.init),
               let q = Config.testValue("--test-ask-at", offset: 2) {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { [weak self] in self?.ask(q) }
            }
        } else if Config.isTestRun && ProcessInfo.processInfo.arguments.contains("--test-listen") {
            UIApplication.shared.isIdleTimerDisabled = false // this one is about listening with the screen locked
            start()
        } else if Config.isTestRun && ProcessInfo.processInfo.arguments.contains("--test-probe") {
            Task { await probe() }
        } else if Config.isTestRun && ProcessInfo.processInfo.arguments.contains("--test-preview") {
            phase = .listening
            startedAt = Date().addingTimeInterval(-754)
            watchStatus = "Evidence · Automations (31)"
            micActive = true
            cost = 0.214
            lastLine = "I don't think anyone has actually surveyed that."
            cards = PreviewData.cards
            answer = nil
        }
    }
}

extension PhoneCopilot {
    /// --test-probe: two tiny requests. The first has exactly the app's request shape (tools, caching, fallbacks,
    /// effort), so a rejected field shows up before a real session; the second asks whether the API takes a trusted
    /// site without a dot ("gov"). Prints only status and error text.
    func probe() async {
        guard let key = apiKey() else { print("PROBE no API key"); return }
        let (settings, _) = Settings.load()
        let s = MessagesSession(apiKey: key, settings: settings, system: "Reply with exactly: {\"cards\":[],\"answer\":null}")
        do {
            let t = try await s.send("TRANSCRIPT\nHello.", timeout: 60)
            print("PROBE app request: OK, reply \(t.text.prefix(60))")
        } catch { print("PROBE app request: \(error)") }
        var body: [String: Any] = [
            "model": settings.modelName, "max_tokens": 64, "messages": [["role": "user", "content": "Say OK."]],
            "tools": [["type": "web_fetch_20250910", "name": "web_fetch", "allowed_domains": ["gov"]]],
        ]
        body["output_config"] = ["effort": "low"]
        var r = URLRequest(url: MessagesSession.endpoint, timeoutInterval: 60)
        r.httpMethod = "POST"
        r.setValue(key, forHTTPHeaderField: "x-api-key")
        r.setValue(MessagesSession.apiVersion, forHTTPHeaderField: "anthropic-version")
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        if let (data, resp) = try? await URLSession.shared.data(for: r) {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])
                .flatMap { $0["error"] as? [String: Any] }?["message"] as? String ?? ""
            print("PROBE allowed_domains [gov]: HTTP \(status) \(msg)")
        } else { print("PROBE allowed_domains [gov]: no response") }
    }
}

enum PreviewData {
    static let cards: [Card] = [
        Card(watcher: "Evidence", watcherIndex: 0, title: "Public views on AI sentience have been surveyed",
             body: "Sentience Institute's AIMS survey (US, 2023): about 1 in 5 adults think some current AI systems are sentient; most support protections if they were.",
             quote: "I don't think anyone has actually surveyed that",
             links: [URL(string: "https://www.sentienceinstitute.org/aims-survey-2023")!]),
        Card(watcher: "Automations", watcherIndex: 1, title: "Find and Chase Missing Payment Receipts",
             body: "Matches card payments to receipts and tells each person which ones still need one.",
             quote: "we spend hours every month chasing receipts", links: [URL(string: "https://ai-automations-db.vercel.app/")!]),
    ]
}

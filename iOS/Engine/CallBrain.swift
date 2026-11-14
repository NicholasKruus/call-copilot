import Foundation

/// The Claude side of one listening session on iPhone: takes transcript lines and typed questions, sends them to
/// Claude every few seconds, and hands back cards and answers. Knows nothing about audio or screens, so the same code
/// runs in the app and in the Mac test harness. Main actor only.
///
/// The transcript lives only in memory and is dropped when the session ends.
@MainActor
final class CallBrain {
    enum Timing {
        /// Seconds between transcript chunks sent to Claude. A typed question goes at once.
        static let sendInterval: TimeInterval = 12
        /// A reply that searches and opens pages can take a while, and a request that times out on the phone may
        /// still finish (and be billed) on the server, so these are generous.
        static let turnTimeout: TimeInterval = 180
        static let askTimeout: TimeInterval = 240
        /// Tries for the same lines when Claude is unreachable or busy, before they're dropped.
        static let maxRetries = 3
        /// Once a request's prompt is this large, the next turn starts a fresh conversation with a recap of what was
        /// said. Old search results and pages drop out, and each turn costs less to re-read.
        static let freshConversationAt = 300_000
    }

    var onCards: (@MainActor ([Card]) -> Void)?
    var onAnswer: (@MainActor (String) -> Void)?
    var onAsking: (@MainActor (Bool) -> Void)?
    /// A problem worth showing that doesn't stop listening (nil clears it).
    var onNote: (@MainActor (String?) -> Void)?
    /// A problem that ends the session (a refused key, a request the API keeps rejecting).
    var onFatal: (@MainActor (String) -> Void)?
    var onUsage: (@MainActor (Double?) -> Void)?
    var onReferences: (@MainActor ([String: Reference], [String]) -> Void)?

    let settings: Settings
    let watchers: [Watcher]
    let rules: CardRules
    private let apiKey: String
    private let system: String

    private var session: MessagesSession?
    private var referenceText: String?
    private(set) var referencesReady = false
    private var stopped = false
    private var pending: [String] = []
    /// Lines Claude has answered, for a recap when a fresh conversation starts.
    private var answered: [String] = []
    private var needsRecap = false
    private var queuedAsk: String?
    private(set) var busy = false
    private var inFlight: Task<Void, Never>?
    private var lastSend = Date.distantPast
    private var retryAt = Date.distantPast
    private var retries = 0
    private var freshStarts = 0
    private var rejectedInARow = 0
    /// Cost of the conversations before the current one.
    private var earlierCost: Double? = 0

    init(settings: Settings, apiKey: String, template: String, setting: String) {
        self.settings = settings
        self.watchers = settings.activeWatchers
        self.rules = CardRules(watchers: settings.activeWatchers)
        self.apiKey = apiKey
        self.system = SystemPrompt.make(template: template, settings: settings, watchers: settings.activeWatchers,
                                        setting: setting)
        if Pricing.rate(for: settings.modelName) == nil { earlierCost = nil }
    }

    /// Loads the reference lists. Nothing goes to Claude until they're in (at most 20 s).
    func start() {
        Task { [weak self] in
            guard let self else { return }
            let (refs, notes) = await ReferenceLoader.loadAll(self.watchers)
            guard !self.stopped else { return }
            for r in refs {
                self.rules.add(r)
                log("reference: \(r.watcher): \(r.items.count) items, \(r.text.count) chars")
            }
            notes.forEach { log("reference: \($0)") }
            self.referenceText = ReferenceLoader.message(refs)
            self.referencesReady = true
            self.onReferences?(self.rules.references, notes)
            self.tick()
        }
    }

    /// Ends the session: cancels a request in flight (so it isn't billed for longer than needed and the transcript it
    /// carries is let go) and drops everything heard.
    func stop() {
        stopped = true
        inFlight?.cancel(); inFlight = nil
        pending = []; answered = []; queuedAsk = nil
        session = nil
    }

    func hear(_ line: String) { pending.append(line) }

    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        queuedAsk = q
        onAsking?(true)
        tick()
    }

    /// Nothing waiting and nothing in flight (tests use this).
    var idle: Bool { referencesReady && !busy && pending.isEmpty && queuedAsk == nil }

    /// Called every second, and after each event: sends what's due.
    func tick(force: Bool = false) {
        let now = Date()
        guard !stopped, referencesReady, !busy, now >= retryAt else { return }
        let due = !pending.isEmpty && (force || now.timeIntervalSince(lastSend) >= Timing.sendInterval)
        guard due || queuedAsk != nil else { return }

        if session == nil { session = MessagesSession(apiKey: apiKey, settings: settings, system: system) }
        guard let session else { return }
        // The conversation's first message carries the reference lists (and a recap after a fresh start), also when
        // an earlier attempt at that first message failed.
        let fresh = session.messages.isEmpty
        var parts: [String] = []
        if fresh, let referenceText {
            parts.append(referenceText + "\n\nThat is all the reference material for this call.")
        }
        if fresh, needsRecap, !answered.isEmpty {
            parts.append("TRANSCRIPT (earlier in this call, already answered; don't repeat cards from it)\n"
                + answered.joined(separator: "\n"))
        }
        let lines = pending
        let ask = queuedAsk
        pending = []
        queuedAsk = nil
        if !lines.isEmpty { parts.append("TRANSCRIPT\n" + lines.joined(separator: "\n")) }
        if let ask { parts.append("ASK: " + ask) }
        busy = true
        lastSend = now
        log("claude: sending \(lines.count) lines\(ask != nil ? " + ask" : "")\(fresh ? " (new conversation)" : "")")
        inFlight = Task { [weak self] in
            do {
                let turn = try await session.send(parts.joined(separator: "\n\n"),
                                                  timeout: ask != nil ? Timing.askTimeout : Timing.turnTimeout)
                self?.finished(turn, lines: lines, ask: ask, session: session)
            } catch {
                self?.failed(error, lines: lines, ask: ask, session: session)
            }
        }
    }

    private func finished(_ turn: MessagesSession.Turn, lines: [String], ask: String?, session: MessagesSession) {
        busy = false
        inFlight = nil
        guard !stopped else { return }
        retries = 0; rejectedInARow = 0; freshStarts = 0
        needsRecap = false
        answered += lines
        onNote?(nil)
        report()
        if turn.truncated { log("claude: reply was cut off") }
        rules.allowLinks(turn.links) // before reading the cards, which cite this turn's results
        if let reply = rules.read(turn.text) {
            if !reply.cards.isEmpty { onCards?(reply.cards) }
            if ask != nil { onAnswer?(reply.answer ?? "(No answer came back.)") }
        } else {
            log("claude: reply had no JSON object")
            if ask != nil { onAnswer?(turn.text.isEmpty ? "(No answer came back.)" : turn.text) }
        }
        if ask != nil && queuedAsk == nil { onAsking?(false) }
        if session.lastPromptTokens > Timing.freshConversationAt { startFresh("the conversation got long") }
        tick()
    }

    private func failed(_ error: Error, lines: [String], ask: String?, session: MessagesSession) {
        busy = false
        inFlight = nil
        guard !stopped else { return }
        report()
        let failure = error as? MessagesSession.Failure ?? .retry("\(error)")
        log("claude: turn failed: \(failure)")
        func requeue() {
            pending = lines + pending
            if let ask { queuedAsk = queuedAsk ?? ask }
        }
        switch failure {
        case .auth:
            onFatal?(failure.description + " Check it in Settings.")
        case .retry:
            retries += 1
            let delays: [TimeInterval] = [5, 15, 45, 60]
            retryAt = Date().addingTimeInterval(delays[min(retries - 1, delays.count - 1)])
            if retries <= Timing.maxRetries {
                requeue()
                onNote?(failure.description)
            } else {
                // A timed-out request may have been billed, so the same lines aren't sent forever: newer speech
                // goes next.
                retries = 0
                if ask != nil { onAnswer?("Couldn't reach Claude to answer that."); if queuedAsk == nil { onAsking?(false) } }
                onNote?("Couldn't reach Claude for a while, so \(lines.count) earlier lines were skipped.")
            }
        case .conversation:
            requeue()
            freshStarts += 1
            guard freshStarts <= 3 else { onFatal?(failure.description); return }
            startFresh("\(failure)")
        case .refused, .gaveUp:
            // Sending these lines again would be declined again or cost the same again, so they're dropped rather
            // than resent or recapped.
            if ask != nil { onAnswer?("No answer came back for that."); if queuedAsk == nil { onAsking?(false) } }
            onNote?(failure.description)
        case .rejected:
            requeue()
            rejectedInARow += 1
            guard rejectedInARow < 2 else { onFatal?(failure.description); return }
            startFresh("\(failure)")
        }
        tick()
    }

    private func startFresh(_ reason: String) {
        log("claude: starting a fresh conversation: \(reason)")
        if let s = session { earlierCost = earlierCost.flatMap { e in s.usage.cost.map { e + $0 } } }
        session = nil
        needsRecap = true
    }

    /// The session's running cost: earlier conversations plus the current one.
    private func report() {
        let current = session.map { $0.usage.cost } ?? 0
        onUsage?(earlierCost.flatMap { e in current.map { e + $0 } })
    }
}

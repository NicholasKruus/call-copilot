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

/// What one call's cards may contain: its watchers, their reference lists, and the links the call has earned. Both
/// apps turn Claude's replies into cards here, so they apply the same checks:
/// - a card must name one of the user's watchers;
/// - a card about a reference item must name a real item in that watcher's own list, and takes its name and link
///   from the list, not from Claude;
/// - a link must have come from a reference list or from this call's search and page results, never from text
///   Claude wrote, so a planted instruction can't put an address of its choosing on a card;
/// - a card already shown this call isn't shown again.
final class CardRules {
    let watchers: [Watcher]
    private(set) var references: [String: Reference] = [:]
    private var allowed = Set<String>() // normalized
    private var shown = Set<String>()

    init(watchers: [Watcher]) { self.watchers = watchers }

    func add(_ reference: Reference) {
        references[reference.watcher] = reference
        allowLinks(reference.links)
    }

    func allowLinks<S: Sequence>(_ links: S) where S.Element == String {
        for l in links { allowed.insert(Self.normalize(l)) }
    }

    static func normalize(_ s: String) -> String {
        var y = s.trimmingCharacters(in: CharacterSet(charactersIn: " .,;:"))
        while y.hasSuffix("/") { y.removeLast() }
        return y
    }

    func allowedLink(_ s: String) -> URL? {
        let n = Self.normalize(s)
        guard n.hasPrefix("https://") || n.hasPrefix("http://"), allowed.contains(n) else { return nil }
        return URL(string: n)
    }

    struct Reply {
        var cards: [Card] = []
        /// The answer to a typed question; nil when none came back.
        var answer: String?
    }

    /// Reads one reply: `{"cards":[...],"answer":...}`. Nil when the text holds no JSON object.
    func read(_ text: String) -> Reply? {
        guard let reply = JSONText.firstObject(in: text) else { return nil }
        var out = Reply()
        for case let c as [String: Any] in reply["cards"] as? [Any] ?? [] {
            guard let name = c["watcher"] as? String,
                  let wi = watchers.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            var title = (c["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var links = (c["links"] as? [Any] ?? []).compactMap { $0 as? String }
            let key: String
            var ref = (c["ref"] as? String) ?? (c["ref"] as? NSNumber)?.stringValue
            if let r = ref, r.isEmpty || r.lowercased() == "null" { ref = nil }
            if let ref {
                guard let item = references[watchers[wi].name]?.items[ref] else {
                    log("claude: dropped a card with an unknown ref"); continue
                }
                title = item.name
                if let u = item.url { links.insert(u, at: 0) }
                key = "\(wi):ref:" + ref
            } else {
                key = watchers[wi].name.lowercased() + ":" + title.lowercased().filter { $0.isLetter || $0.isNumber }
            }
            guard !title.isEmpty, shown.insert(key).inserted else { continue }
            var unique: [String] = []
            for l in links where !unique.contains(l) { unique.append(l) }
            var urls: [URL] = []
            for l in unique { if let u = allowedLink(l), !urls.contains(u) { urls.append(u) } }
            let dropped = unique.count - urls.count
            if dropped > 0 { log("claude: dropped \(dropped) link(s) not from a reference list or this call's results") }
            out.cards.append(Card(watcher: watchers[wi].name, watcherIndex: wi, title: title,
                                  body: (c["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                  quote: c["quote"] as? String ?? "", links: Array(urls.prefix(3))))
            log("card: \(watchers[wi].name)\(ref != nil ? " (reference item)" : "")")
        }
        switch reply["answer"] {
        case let s as String: out.answer = s
        case nil, is NSNull: out.answer = nil
        case let other?:
            out.answer = (try? JSONSerialization.data(withJSONObject: other, options: [.prettyPrinted]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "\(other)"
        }
        return out
    }
}

enum JSONText {
    /// The first balanced `{…}` in the text that parses as a JSON object; braces inside strings don't count.
    static func firstObject(in text: String) -> [String: Any]? {
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

/// The system prompt: Shared/prompt.txt with the user's details filled in. `setting` describes where the transcript
/// comes from, which differs between the Mac (two labelled sides of a call) and iPhone (one microphone).
enum SystemPrompt {
    static func make(template: String, settings: Settings, watchers: [Watcher], setting: String) -> String {
        let about = (settings.aboutMe ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return template
            .replacingOccurrences(of: "{{SETTING}}", with: setting)
            .replacingOccurrences(of: "{{ABOUT}}", with: about.isEmpty ? "" : "About the user: \(about)\n")
            .replacingOccurrences(of: "{{WATCHERS}}", with: watchers.isEmpty ? "(none: answer asks only)" : settings.watcherText)
    }

    static func bundledTemplate() -> String? {
        guard let url = Bundle.main.url(forResource: "prompt", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}

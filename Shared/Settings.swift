import Foundation

/// An error with a plain-language description, shown to the user as is.
struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Something to surface during calls without being asked, in plain language.
struct Watcher: Codable {
    var name: String
    /// What to watch for and what to show, in plain language.
    var instruction: String
    /// Optional reference material loaded when a call starts: an https URL or a file path. A JSON list of items with
    /// `id` and `name` (and optionally `url`) lets cards point at exact items.
    var reference: String?
    /// Let this watcher search the web and open pages on the trusted sites.
    var web: Bool?
    var enabled: Bool?

    var isOn: Bool { enabled ?? true }
    var usesWeb: Bool { web ?? false }
}

/// The user's watchers and options, in settings.json (Config.settingsURL). Read at the start of every call, so edits
/// apply from the next call without a rebuild. The Mac and iPhone apps share this format.
struct Settings: Codable {
    var model: String?
    var effort: String?
    /// A sentence about you and your calls, so cards fit your context.
    var aboutMe: String?
    var watchers: [Watcher]?
    /// Sites a web-enabled watcher may open pages on. Each entry covers the site and its subdomains; "gov.uk" covers
    /// every UK government site. Searching isn't limited by this list; opening pages is.
    var trustedSites: [String]?
    /// iPhone only (the Mac uses your Claude plan): stop listening once a session's estimated cost reaches this many
    /// US dollars. Default 10.
    var sessionBudget: Double?

    var activeWatchers: [Watcher] { (watchers ?? []).filter(\.isOn) }
    var usesWeb: Bool { activeWatchers.contains(where: \.usesWeb) }
    var modelName: String { model ?? "claude-opus-5-5" }
    var effortLevel: String { effort ?? "low" }
    var budget: Double { max(sessionBudget ?? 10, 0.5) }

    /// Loads the settings, creating the file from the bundled defaults the first time. A file that can't be read
    /// runs no watchers (asks only), never the defaults, so a typo can't switch on watchers or web access the user
    /// turned off; the error is returned so the panel can say so.
    static func load() -> (Settings, String?) {
        let fm = FileManager.default
        let url = Config.settingsURL
        if !fm.fileExists(atPath: url.path) {
            guard let defaults = Bundle.main.url(forResource: "default-settings", withExtension: "json") else {
                return (Settings(), "The app is missing its default settings, so no watchers are running. Rebuild it with build.sh.")
            }
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: defaults, to: url)
            log("settings: created \(url.path)")
        }
        guard let data = try? Data(contentsOf: url) else {
            return (Settings(), "settings.json couldn't be opened, so no watchers are running; questions still work.")
        }
        if let s = try? JSONDecoder().decode(Settings.self, from: data) { return (s, nil) }
        // Text editors often turn typed " into curly quotes; accept that if it's the only problem.
        let straightened = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        if let s = try? JSONDecoder().decode(Settings.self, from: Data(straightened.utf8)) {
            log("settings: read after straightening curly quotes")
            return (s, nil)
        }
        do { _ = try JSONDecoder().decode(Settings.self, from: data) } catch {
            log("settings: unreadable: \(error)")
            return (Settings(), "settings.json has a mistake, so no watchers are running; questions still work. "
                + "(\(Self.describe(error)))")
        }
        return (Settings(), nil)
    }

    private static func describe(_ error: Error) -> String {
        if case DecodingError.dataCorrupted(let c) = error { return c.underlyingError?.localizedDescription ?? c.debugDescription }
        if case DecodingError.typeMismatch(_, let c) = error { return c.debugDescription }
        return error.localizedDescription
    }

    /// The watcher list as the prompt shows it.
    var watcherText: String {
        activeWatchers.map { w in
            var tags: [String] = []
            if w.usesWeb { tags.append("can search the web") }
            if w.reference != nil { tags.append("has a reference list") }
            return "- \(w.name)\(tags.isEmpty ? "" : " (\(tags.joined(separator: ", ")))"): \(w.instruction)"
        }.joined(separator: "\n")
    }

    /// Trusted sites as bare host names ("https://www.pewresearch.org/x" becomes "www.pewresearch.org"; a path is
    /// dropped, so an entry covers the whole site). Entries that would trust far more than one site, or that aren't a
    /// plain host name, are left out: see `rejectedSites`.
    var trustedHosts: [String] { (trustedSites ?? []).compactMap { Self.host(fromSite: $0) }.filter { Self.problem(with: $0) == nil } }

    /// Entries left out of the trusted list, with the reason, for a note when listening starts.
    var rejectedSites: [String] {
        (trustedSites ?? []).compactMap { site in
            guard let h = Self.host(fromSite: site) else { return nil }
            return Self.problem(with: h).map { "“\(site)” (\($0))" }
        }
    }

    private static func host(fromSite site: String) -> String? {
        var s = site.trimmingCharacters(in: .whitespaces).lowercased()
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        s = String(s.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ".*"))
        return s.isEmpty ? nil : s
    }

    /// Endings anyone can register a site under. "gov", "gov.uk" and similar are fine: only governments get those.
    static let tooBroad: Set<String> = ["com", "org", "net", "info", "biz", "io", "co", "ai", "app", "dev", "me", "xyz",
                                        "edu", "uk", "co.uk", "org.uk", "ac.uk", "us", "eu", "de", "fr", "ca", "au",
                                        "com.au", "github.io", "substack.com", "medium.com", "blogspot.com"]

    private static func problem(with host: String) -> String? {
        if !host.allSatisfy({ $0.isASCII }) || host.contains("xn--") { return "not a plain ASCII name" }
        if host.contains("@") || host.contains(":") || host.contains(" ") { return "not a plain site name" }
        if tooBroad.contains(host) { return "too broad: it covers sites anyone can publish" }
        return nil
    }

    /// --allowedTools entries for opening pages: each trusted site and its subdomains (a bare entry doesn't cover www).
    var fetchRules: [String] { trustedHosts.flatMap { ["WebFetch(domain:\($0))", "WebFetch(domain:*.\($0))"] } }

    /// The Messages API's allowed_domains for opening pages. Each covers its subdomains, so "gov" covers every .gov
    /// site (the API accepts it; checked 14 Nov 2026).
    var fetchDomains: [String] { trustedHosts }

    func isTrusted(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return trustedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// Reference material for one watcher, loaded by the app (not by Claude) at the start of a call.
struct Reference {
    struct Item { let id: String; let name: String; let url: String? }
    let watcher: String
    let source: String
    let text: String // what Claude sees
    let items: [String: Item] // id -> item, when the reference is a JSON list
    let links: Set<String> // every URL in the material

    static let maxChars = 150_000
    static let maxBytes = 5_000_000
    /// A web list is fetched at most once a day, so its server learns when you use the app on a given day, not when
    /// each call starts.
    static let cacheFor: TimeInterval = 24 * 3600

    static func load(for watcher: Watcher) async throws -> (Reference, String?) {
        guard let source = watcher.reference?.trimmingCharacters(in: .whitespaces), !source.isEmpty else {
            throw CaptureError("no reference")
        }
        var note: String?
        let data: Data
        if source.hasPrefix("https://") {
            (data, note) = try await fetch(source)
        } else if source.hasPrefix("http://") {
            throw CaptureError("use an https:// address")
        } else {
            let path = NSString(string: source).expandingTildeInPath
            let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int ?? 0
            guard size <= maxBytes else { throw CaptureError("the file is over 5 MB") }
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        }
        let raw = String(decoding: data, as: UTF8.self)
        var items: [String: Item] = [:]
        var text = raw
        if let json = try? JSONSerialization.jsonObject(with: data) {
            let list = (json as? [[String: Any]]) ?? ((json as? [String: Any])?["items"] as? [[String: Any]])
            if let list {
                var lines: [String] = []
                for entry in list {
                    let id = (entry["id"] as? String) ?? (entry["id"] as? NSNumber)?.stringValue
                    let name = entry["name"] as? String ?? entry["title"] as? String
                    if let id, let name { items[id] = Item(id: id, name: name, url: entry["url"] as? String) }
                    let rest = entry.filter { $0.key != "id" && $0.key != "name" }.sorted { $0.key < $1.key }.map { k, v -> String in
                        let value = (v as? [Any])?.map { "\($0)" }.joined(separator: ", ") ?? "\(v)"
                        return "\(k): \(value.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(600))"
                    }
                    lines.append("- " + ([id.map { "id \($0)" }, name].compactMap { $0 } + rest).joined(separator: " | "))
                }
                text = lines.joined(separator: "\n")
            }
        }
        if text.count > maxChars { text = String(text.prefix(maxChars)) + "\n(cut off at \(maxChars) characters)" }
        text = PromptText.neutral(text)
        var links = Set(Self.urls(in: text)) // only addresses Claude was actually shown
        items.values.compactMap(\.url).forEach { links.insert($0) }
        return (Reference(watcher: watcher.name, source: source, text: text, items: items, links: links), note)
    }

    private static func fetch(_ source: String) async throws -> (Data, String?) {
        guard let url = URL(string: source) else { throw CaptureError("bad address") }
        // ~/Library/Caches/Call Copilot on the Mac; the app's own caches folder on iPhone.
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Call Copilot")
        let key = source.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 } // FNV-1a
        let cached = dir.appendingPathComponent(String(key, radix: 16) + ".ref")
        let age = ((try? FileManager.default.attributesOfItem(atPath: cached.path))?[.modificationDate] as? Date)
            .map { Date().timeIntervalSince($0) }
        if let age, age < cacheFor, let d = try? Data(contentsOf: cached) { return (d, nil) }
        do {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.setValue("CallCopilot", forHTTPHeaderField: "User-Agent")
            let (d, resp) = try await URLSession.shared.data(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw CaptureError("HTTP \(http.statusCode)")
            }
            guard d.count <= maxBytes else { throw CaptureError("it's over 5 MB") }
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? d.write(to: cached)
            return (d, nil)
        } catch {
            // Labelled, not silent: an older copy is used and the panel says so.
            if let d = try? Data(contentsOf: cached), let age {
                return (d, "couldn't refresh (\(Self.describe(error))); using the copy from \(Int(age / 3600)) h ago")
            }
            throw CaptureError(Self.describe(error))
        }
    }

    /// An error without the address it came from (a reference list's address can contain a private token).
    private static func describe(_ error: Error) -> String {
        if let e = error as? URLError { return "network error \(e.code.rawValue)" }
        return "\(error)"
    }

    static func urls(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"https?://[^\s"'<>\)\]\\]+"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        }
    }
}

/// Loads every watcher's reference list (in the app; Claude never fetches them). Lists not loaded within 20 s are
/// skipped, so one slow list can't hold up the call. Returns the lists that loaded and a note for each problem.
enum ReferenceLoader {
    static func loadAll(_ watchers: [Watcher], deadline: TimeInterval = 20) async -> ([Reference], [String]) {
        let wanted = watchers.filter { $0.reference != nil }
        guard !wanted.isEmpty else { return ([], []) }
        var loaded: [Reference] = []
        var notes: [String] = []
        await withTaskGroup(of: (String, Result<(Reference, String?), Error>)?.self) { group in
            for w in wanted {
                group.addTask {
                    do { return (w.name, .success(try await Reference.load(for: w))) }
                    catch { return (w.name, .failure(error)) }
                }
            }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000)); return nil }
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
        return (loaded, notes)
    }

    /// The REFERENCE part of a call's first message.
    static func message(_ refs: [Reference]) -> String? {
        guard !refs.isEmpty else { return nil }
        return refs.map { r in
            "REFERENCE for the \(r.watcher) watcher (from \(r.source))"
                + (r.items.isEmpty ? ", without ids, so give ref null for it" : "") + ":\n\(r.text)"
        }.joined(separator: "\n\n")
    }
}

import Foundation

/// One Claude conversation for a call, over the Messages API with the user's own API key. Every method runs on the
/// main actor; the network waits don't block it.
///
/// It reads other people's speech, so it gets no tools of its own: it can't run anything, change anything or send
/// anything. With web on, it gets only Anthropic's server-run web search and page fetch. The API opens pages only on
/// the trusted sites (`allowed_domains`, subdomains included) and only at addresses that already appeared in the
/// conversation, so Claude can't make up an address to carry words from the call somewhere.
@MainActor
final class MessagesSession {
    enum Failure: Error, CustomStringConvertible {
        /// The key was refused, or has no access. Stop.
        case auth(String)
        /// Busy, overloaded, rate limited or offline. Send the same lines again later.
        case retry(String)
        /// This conversation can't go on (too long, or its history was rejected). Start a fresh one.
        case conversation(String)
        /// Claude declined this turn, after any fallback model. Don't send these lines again.
        case refused
        /// Anything else the API rejected.
        case rejected(String)
        /// The turn may have been billed but gave nothing usable (it kept pausing, or the reply was unreadable).
        /// Sending the same lines again would likely cost the same again, so they're dropped.
        case gaveUp(String)

        var description: String {
            switch self {
            case .auth(let m): return "Your API key was refused (\(m))."
            case .retry(let m): return "Claude is unavailable right now (\(m)); retrying."
            case .conversation(let m): return "Starting a fresh conversation (\(m))."
            case .refused: return "Claude declined part of the conversation."
            case .rejected(let m): return "Claude rejected the request (\(m))."
            case .gaveUp(let m): return "Skipped part of the conversation (\(m))."
            }
        }
    }

    struct Turn {
        /// The reply's text (the JSON object the prompt asks for).
        let text: String
        /// Addresses this turn's search results and opened pages came from (set by the search engine and the
        /// fetcher, not written by Claude), for the card link check.
        let links: [String]
        /// Cut off at max_tokens.
        let truncated: Bool
    }

    struct Usage {
        var input = 0, cacheWrite = 0, cacheRead = 0, output = 0, searches = 0
        var cost: Double? // estimate at list prices; nil for a model Pricing doesn't know
    }

    nonisolated static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    nonisolated static let apiVersion = "2026-10-21"
    /// Models that accept `fallbacks: "default"` (a declined turn is re-run on Anthropic's recommended model).
    static let fallbackModels: Set<String> = ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5",
                                              "claude-sonnet-5-5"]
    /// Model families whose web tools can filter results in a sandbox before they reach the context (fewer tokens).
    static let filteringPrefixes = ["claude-fable-5", "claude-mythos-5", "claude-opus-5", "claude-opus-4-6",
                                    "claude-opus-4-7", "claude-opus-4-8", "claude-sonnet-5", "claude-sonnet-4-6"]

    let model: String
    private let apiKey: String
    private let effort: String
    private let system: String
    private let tools: [[String: Any]]
    private let settings: Settings
    private(set) var messages: [[String: Any]] = []
    private(set) var usage = Usage()
    /// Prompt size of the last request (input, cache reads and cache writes), to know when to start afresh.
    private(set) var lastPromptTokens = 0

    init(apiKey: String, settings: Settings, system: String) {
        self.apiKey = apiKey
        self.settings = settings
        self.model = settings.modelName
        self.effort = settings.effortLevel
        self.system = system
        self.tools = Self.webTools(settings: settings)
        usage.cost = Pricing.rate(for: model) == nil ? nil : 0
    }

    /// The web tools, or none. Opening pages is offered only with a non-empty trusted list: without allowed_domains
    /// the API would open pages anywhere.
    static func webTools(settings: Settings) -> [[String: Any]] {
        guard settings.usesWeb else { return [] }
        let filtering = filteringPrefixes.contains { settings.modelName.hasPrefix($0) }
        var tools: [[String: Any]] = [[
            "type": filtering ? "web_search_20260318" : "web_search_20250305",
            "name": "web_search",
            "max_uses": 2,
        ]]
        let domains = settings.fetchDomains
        if !domains.isEmpty {
            tools.append([
                "type": filtering ? "web_fetch_20260318" : "web_fetch_20250910",
                "name": "web_fetch",
                "max_uses": 2,
                "allowed_domains": domains,
                "max_content_tokens": 20_000, // a page stays in the conversation, so keep each one bounded
            ])
        }
        return tools
    }

    var opensPages: Bool { tools.contains { $0["name"] as? String == "web_fetch" } }

    /// Sends one user message and returns Claude's reply. On failure nothing is added to the conversation, so the
    /// same text (or more) can be sent again.
    func send(_ text: String, timeout: TimeInterval) async throws -> Turn {
        var convo = messages + [["role": "user", "content": [["type": "text", "text": text]]]]
        var texts: [String] = []
        var links: [String] = []
        var container: String? // the sandbox the web tools filter results in, kept for a paused turn
        for _ in 0..<4 { // a turn the server paused is continued, at most 3 times
            let response = try await post(convo, container: container, timeout: timeout)
            container = (response["container"] as? [String: Any])?["id"] as? String ?? container
            let content = Self.forHistory(response["content"] as? [[String: Any]] ?? [])
            add(usage: response["usage"] as? [String: Any], servedBy: response["model"] as? String)
            let stop = response["stop_reason"] as? String ?? ""
            if stop == "refusal" {
                log("claude: turn declined (\((response["stop_details"] as? [String: Any])?["category"] as? String ?? "no category"))")
                throw Failure.refused
            }
            convo.append(["role": "assistant", "content": content])
            texts.append(contentsOf: content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil })
            links.append(contentsOf: Self.resultLinks(in: content, trusted: settings.isTrusted))
            if stop == "pause_turn" { continue }
            messages = convo
            return Turn(text: texts.joined(), links: links, truncated: stop == "max_tokens")
        }
        throw Failure.gaveUp("the turn kept pausing")
    }

    private func post(_ convo: [[String: Any]], container: String?, timeout: TimeInterval) async throws -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "max_tokens": 16_000,
            "system": system,
            "messages": convo,
            "output_config": ["effort": effort],
            "cache_control": ["type": "ephemeral"], // caches the whole conversation so far, each turn
        ]
        if !tools.isEmpty { body["tools"] = tools }
        if let container { body["container"] = container }
        var request = URLRequest(url: Self.endpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        if Self.fallbackModels.contains(model) {
            body["fallbacks"] = "default"
            request.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw Failure.retry((error as? URLError).map { Self.describe($0) } ?? "\(error)") }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = ((json?["error"] as? [String: Any])?["message"] as? String).map { String($0.prefix(200)) }
            ?? "HTTP \(status)"
        switch status {
        case 200:
            guard let json else { throw Failure.gaveUp("unreadable reply") }
            return json
        case 401, 403: throw Failure.auth(message)
        case 413: throw Failure.conversation("too long")
        case 400 where message.localizedCaseInsensitiveContains("too long")
            || message.localizedCaseInsensitiveContains("context")
            || message.localizedCaseInsensitiveContains("thinking"):
            throw Failure.conversation(message)
        case 408, 429, 500...599: throw Failure.retry(message)
        default: throw Failure.rejected(message)
        }
    }

    /// Adds a reply's tokens to the running totals. After a server-side fallback (or on a later turn routed straight
    /// to the fallback model), `usage.iterations` lists every attempt with the model that ran it, so each is priced
    /// at its own model's rates; without it, the reply is priced at the model that served it.
    private func add(usage u: [String: Any]?, servedBy: String?) {
        guard let u else { return }
        let input = u["input_tokens"] as? Int ?? 0
        let write = u["cache_creation_input_tokens"] as? Int ?? 0
        let read = u["cache_read_input_tokens"] as? Int ?? 0
        let output = u["output_tokens"] as? Int ?? 0
        let searches = (u["server_tool_use"] as? [String: Any])?["web_search_requests"] as? Int ?? 0
        usage.input += input; usage.cacheWrite += write; usage.cacheRead += read; usage.output += output
        usage.searches += searches
        lastPromptTokens = input + write + read
        var cost: Double? = Double(searches) * Pricing.perSearch
        if let iterations = u["iterations"] as? [[String: Any]], !iterations.isEmpty {
            for it in iterations {
                let c = Pricing.cost(model: it["model"] as? String ?? "", input: it["input_tokens"] as? Int ?? 0,
                                     cacheWrite: it["cache_creation_input_tokens"] as? Int ?? 0,
                                     cacheRead: it["cache_read_input_tokens"] as? Int ?? 0,
                                     output: it["output_tokens"] as? Int ?? 0, searches: 0)
                cost = cost.flatMap { a in c.map { a + $0 } }
            }
            if iterations.contains(where: { $0["type"] as? String == "fallback_message" }) {
                log("claude: served by a fallback model (\(servedBy ?? "unknown"))")
            }
        } else {
            let c = Pricing.cost(model: servedBy ?? model, input: input, cacheWrite: write, cacheRead: read,
                                 output: output, searches: 0)
            cost = cost.flatMap { a in c.map { a + $0 } }
        }
        // Once any part can't be priced, the estimate is withheld rather than shown too low.
        usage.cost = usage.cost.flatMap { a in cost.map { a + $0 } }
        log("claude: \(input + write + read) prompt tokens (\(read) cached), \(output) out, \(searches) searches"
            + (usage.cost.map { String(format: ", ≈$%.3f so far", $0) } ?? ""))
    }

    /// A reply as it goes back into the conversation. Claude's content is sent back as received, except:
    /// - before the last `fallback` block (a declined model's output, which the docs say to drop on the next turn):
    ///   thinking, connector text, client tool calls, and server tool calls without a result;
    /// - an empty reply (Claude occasionally ends a turn with nothing) becomes an empty card list, because an empty
    ///   assistant message isn't valid in the middle of a conversation.
    static func forHistory(_ content: [[String: Any]]) -> [[String: Any]] {
        var out = content
        if let lastFallback = content.lastIndex(where: { $0["type"] as? String == "fallback" }) {
            let resultIDs = Set(content.compactMap { $0["tool_use_id"] as? String })
            out = content.enumerated().compactMap { i, block in
                guard i < lastFallback else { return block }
                switch block["type"] as? String {
                case "thinking", "redacted_thinking", "connector_text", "tool_use": return nil
                case "server_tool_use": return resultIDs.contains(block["id"] as? String ?? "") ? block : nil
                default: return block
                }
            }
        }
        if out.isEmpty { out = [["type": "text", "text": #"{"cards":[],"answer":null}"#]] }
        return out
    }

    /// Addresses a card may link to from this turn: the `url` of each search result and of each citation of one
    /// (both set by the search engine), and pages on the trusted sites that were actually opened. Error results and
    /// text Claude wrote are never used.
    static func resultLinks(in content: [[String: Any]], trusted: (URL) -> Bool) -> [String] {
        var out: [String] = []
        for block in content {
            switch block["type"] as? String {
            case "web_search_tool_result":
                for r in block["content"] as? [[String: Any]] ?? [] where r["type"] as? String == "web_search_result" {
                    if let u = r["url"] as? String { out.append(u) }
                }
            case "web_fetch_tool_result":
                if let r = block["content"] as? [String: Any], r["type"] as? String == "web_fetch_result",
                   let s = r["url"] as? String, let u = URL(string: s), trusted(u) {
                    out.append(s)
                }
            case "text":
                for c in block["citations"] as? [[String: Any]] ?? []
                where c["type"] as? String == "web_search_result_location" {
                    if let u = c["url"] as? String { out.append(u) }
                }
            default:
                break
            }
        }
        return out
    }

    private static func describe(_ e: URLError) -> String {
        switch e.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed: return "no internet connection"
        case .timedOut: return "no reply in time"
        default: return e.localizedDescription
        }
    }
}

/// List prices, for the running estimate shown during a call. Per million tokens; a search is $10 per 1,000.
/// Checked against platform.claude.com/docs/en/about-claude/pricing on 13 Nov 2026.
enum Pricing {
    struct Rate { let input, cacheWrite, cacheRead, output: Double }
    static let perSearch = 0.01

    static func rate(for model: String, promptTokens: Int = 0) -> Rate? {
        switch model {
        case "claude-opus-5-5": return Rate(input: 4, cacheWrite: 5, cacheRead: 0.20, output: 20)
        case "claude-sonnet-5-5": return Rate(input: 2, cacheWrite: 2.5, cacheRead: 0.10, output: 10)
        // Models a declined turn can fall back to.
        case "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6":
            return Rate(input: 5, cacheWrite: 6.25, cacheRead: 0.50, output: 25)
        case "claude-sonnet-5": return Rate(input: 2, cacheWrite: 2.5, cacheRead: 0.20, output: 10)
        case "claude-haiku-5-5": // priced by prompt length
            return promptTokens > 100_000 ? Rate(input: 0.50, cacheWrite: 0.625, cacheRead: 0.05, output: 2.50)
                                          : Rate(input: 0.10, cacheWrite: 0.125, cacheRead: 0.01, output: 0.50)
        default: return nil
        }
    }

    static func cost(model: String, input: Int, cacheWrite: Int, cacheRead: Int, output: Int, searches: Int) -> Double? {
        guard let r = rate(for: model, promptTokens: input + cacheWrite + cacheRead) else { return nil }
        let tokens = Double(input) * r.input + Double(cacheWrite) * r.cacheWrite + Double(cacheRead) * r.cacheRead
            + Double(output) * r.output
        return tokens / 1_000_000 + Double(searches) * perSearch
    }
}

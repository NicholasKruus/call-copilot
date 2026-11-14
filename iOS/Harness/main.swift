import Foundation

// Mac command-line harness for the iPhone app's Claude side (Shared/ and iOS/Engine/), so it can be tested without
// a phone. Build and run with iOS/Harness/run.sh.
//
//   run.sh --selftest                          offline checks of the link and card rules
//   run.sh --dry                               print the system prompt and the tools a request would carry
//   run.sh transcript.txt [--ask-at N "q"]     send a transcript (one line per utterance) to Claude, print the cards
//
// The live mode reads the API key from CALLCOPILOT_TEST_API_KEY and never prints it.

enum Config {
    static let isTestRun = true
    static let settingsURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cc-harness-settings.json")
}

func log(_ message: String) { FileHandle.standardError.write(("LOG " + message + "\n").data(using: .utf8)!) }

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let args = Array(CommandLine.arguments.dropFirst())

func loadSettings() -> Settings {
    let path = args.firstIndex(of: "--settings").map { args[$0 + 1] } ?? repo.appendingPathComponent("Shared/default-settings.json").path
    let data = try! Data(contentsOf: URL(fileURLWithPath: path))
    return try! JSONDecoder().decode(Settings.self, from: data)
}
let template = try! String(contentsOf: repo.appendingPathComponent("Shared/prompt.txt"), encoding: .utf8)
let setting = "You assist the user during a live meeting or call. You receive its transcript in chunks as it happens, "
    + "from the user's iPhone microphone: everyone in the room (or a call on a nearby speaker), with no speaker labels."

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "PASS " : "FAIL ") + what)
    if !ok { failures += 1 }
}

@MainActor func selftest() {
    let settings = loadSettings()
    // The web tools: opening pages only with allowed_domains, never without.
    let tools = MessagesSession.webTools(settings: settings)
    let fetch = tools.first { $0["name"] as? String == "web_fetch" }
    check(fetch != nil, "web fetch offered with a trusted list")
    check((fetch?["allowed_domains"] as? [String])?.contains("pewresearch.org") == true, "trusted sites passed as allowed_domains")
    check((fetch?["allowed_domains"] as? [String])?.contains("gov") == true, "a top-level entry such as gov is passed on")
    var noSites = settings
    noSites.trustedSites = []
    check(!MessagesSession.webTools(settings: noSites).contains { $0["name"] as? String == "web_fetch" },
          "no web fetch at all when the trusted list is empty")
    var noWeb = settings
    noWeb.watchers = settings.watchers?.map { var w = $0; w.web = false; return w }
    check(MessagesSession.webTools(settings: noWeb).isEmpty, "no tools when no watcher uses the web")

    // Links come from result blocks, not from text Claude wrote or from errors or untrusted pages.
    let content: [[String: Any]] = [
        ["type": "text", "text": "See https://evil.example/steal?q=secret"],
        ["type": "server_tool_use", "id": "srvtoolu_1", "name": "web_search", "input": ["query": "https://evil.example/q"]],
        ["type": "web_search_tool_result", "tool_use_id": "srvtoolu_1", "content": [
            ["type": "web_search_result", "url": "https://www.pewresearch.org/a", "title": "A", "encrypted_content": "x"]]],
        ["type": "web_fetch_tool_result", "tool_use_id": "srvtoolu_2", "content": [
            "type": "web_fetch_result", "url": "https://ourworldindata.org/b", "content": [:]]],
        ["type": "web_fetch_tool_result", "tool_use_id": "srvtoolu_3", "content": [
            "type": "web_fetch_result", "url": "https://untrusted.example/c", "content": [:]]],
        ["type": "web_fetch_tool_result", "tool_use_id": "srvtoolu_4", "content": [
            "type": "web_fetch_tool_result_error", "error_code": "url_not_accessible"]],
        ["type": "text", "text": "x", "citations": [
            ["type": "web_search_result_location", "url": "https://www.gallup.com/d", "cited_text": "y"]]],
    ]
    let links = MessagesSession.resultLinks(in: content, trusted: settings.isTrusted)
    check(Set(links) == ["https://www.pewresearch.org/a", "https://ourworldindata.org/b", "https://www.gallup.com/d"],
          "links only from search results, citations and opened trusted pages (got \(links))")

    // Cards: watcher must exist; links must be earned; unknown refs dropped; no repeats.
    let rules = CardRules(watchers: settings.activeWatchers)
    rules.allowLinks(links)
    let reply = #"""
    Here you go: {"cards":[
      {"watcher":"Evidence","ref":null,"title":"Pew on AI views","body":"b","quote":"","links":["https://www.pewresearch.org/a/","https://evil.example/steal"]},
      {"watcher":"Nonexistent","ref":null,"title":"t","body":"b","quote":"","links":[]},
      {"watcher":"Automations","ref":"999","title":"Fake item","body":"b","quote":"","links":[]},
      {"watcher":"evidence","ref":"null","title":"Pew on AI views","body":"dup","quote":"","links":[]}
    ],"answer":"42"}
    """#
    let r = rules.read(reply)
    check(r?.cards.count == 1, "only the valid card kept (got \(r?.cards.count ?? -1))")
    check(r?.cards.first?.links.map(\.absoluteString) == ["https://www.pewresearch.org/a"], "planted link dropped, earned link kept")
    check(r?.answer == "42", "answer read")
    check(rules.read("no json here") == nil, "text without JSON gives nil")
    check(Pricing.cost(model: "claude-opus-5-5", input: 1_000_000, cacheWrite: 0, cacheRead: 0, output: 0, searches: 1) == 4.01,
          "pricing: 1M input tokens and a search on Opus 5.5 is $4.01")
    print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
    exit(failures == 0 ? 0 : 1)
}

@MainActor func dry() {
    let settings = loadSettings()
    print(SystemPrompt.make(template: template, settings: settings, watchers: settings.activeWatchers, setting: setting))
    let tools = MessagesSession.webTools(settings: settings)
    print(String(data: try! JSONSerialization.data(withJSONObject: tools, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
    exit(0)
}

@MainActor func live(_ file: String) async {
    guard let key = ProcessInfo.processInfo.environment["CALLCOPILOT_TEST_API_KEY"], !key.isEmpty else {
        print("set CALLCOPILOT_TEST_API_KEY"); exit(2)
    }
    let settings = loadSettings()
    let lines = try! String(contentsOfFile: file, encoding: .utf8).split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    var askAt: Int?, question: String?
    if let i = args.firstIndex(of: "--ask-at") { askAt = Int(args[i + 1]); question = args[i + 2] }
    let brain = CallBrain(settings: settings, apiKey: key, template: template, setting: setting)
    brain.onCards = { cards in
        for c in cards {
            print("CARD [\(c.watcher)] \(c.title) | \(c.body) | quote: \(c.quote) | links: \(c.links.map(\.absoluteString))")
        }
    }
    brain.onAnswer = { print("ANSWER \($0)") }
    brain.onNote = { if let n = $0 { print("NOTE \(n)") } }
    brain.onFatal = { print("FATAL \($0)"); exit(1) }
    brain.onUsage = { if let c = $0 { print(String(format: "COST ≈$%.4f", c)) } }
    brain.onReferences = { refs, notes in print("REFERENCES \(refs.mapValues(\.items.count)) \(notes)") }
    brain.start()
    // Feed the transcript in chunks of 4 lines, as if 12 s apart.
    var asked = false
    var i = 0
    while i < lines.count {
        for l in lines[i..<min(i + 4, lines.count)] { brain.hear(l) }
        i += 4
        if let askAt, let question, !asked, i >= askAt { brain.ask(question); asked = true }
        while !brain.referencesReady { try? await Task.sleep(nanoseconds: 200_000_000) }
        brain.tick(force: true)
        while !brain.idle { try? await Task.sleep(nanoseconds: 300_000_000); brain.tick(force: true) }
    }
    exit(0)
}

Task { @MainActor in
    if args.contains("--selftest") { selftest() }
    else if args.contains("--dry") { dry() }
    else if let file = args.first(where: { !$0.hasPrefix("--") }) { await live(file) }
    else { print("usage: run.sh --selftest | --dry | transcript.txt [--ask-at N \"question\"]"); exit(2) }
}
RunLoop.main.run()

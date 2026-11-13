import Foundation

enum Config {
    /// Where Claude Code's native installer and Homebrew put `claude`. The first that resolves to a binary signed by
    /// Anthropic is used (ClaudeBinary), because anything the app spawns inherits its microphone and system-audio
    /// permissions.
    static let claudeCandidates = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        .map { NSString(string: $0).expandingTildeInPath }
    /// Anthropic's Developer ID team. A `claude` signed by anyone else is refused.
    static let claudeRequirement = #"anchor apple generic and certificate leaf[subject.OU] = "Q6L2SF6YDW""#

    /// The user's watchers and options (Settings.swift). Created from Resources/default-settings.json on first launch.
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Call Copilot/settings.json")

    /// Seconds between transcript chunks sent to Claude. A typed ask goes at once.
    static let sendInterval: TimeInterval = 12
    /// A Claude turn that hasn't answered by then is treated as stuck, and the session is restarted.
    static let turnTimeout: TimeInterval = 90
    static let askTimeout: TimeInterval = 150
    /// Restarts allowed per call before giving up and showing an error.
    static let maxSessionRestarts = 3
    /// A session stops once no call app has used the mic for this long (generous, because a call app may
    /// briefly release the mic on a device switch or reconnect).
    static let callEndGrace: TimeInterval = 60
    /// A session stops after this long with no speech from either side.
    static let silenceStop: TimeInterval = 10 * 60
    /// "Them" delivering only exact zeros this long while the call app plays audio suggests the tap is dead (or the
    /// other side is silent, which is why the note is worded as a question and clears itself).
    static let deadTapAfter: TimeInterval = 60

    /// Apps whose microphone use means "on a call". Matched as bundle-ID prefixes, so helper processes count.
    /// "Them" is tapped from the processes of whichever of these are using the mic.
    static let callApps: [(prefix: String, name: String)] = [
        ("us.zoom", "Zoom"),
        ("com.google.Chrome", "Chrome"),
        ("app.zen-browser", "Zen"),
        ("org.mozilla.firefox", "Firefox"),
        ("org.mozilla.plugincontainer", "Firefox"),
        ("com.microsoft.teams", "Teams"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.apple.avconferenced", "FaceTime"),
        ("com.granola.app", "Granola"),
        ("com.apple.WebKit.GPU", "Safari"),
        ("com.apple.Safari", "Safari"),
        ("company.thebrowser", "Arc"),
        ("com.hnc.Discord", "Discord"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("org.whispersystems.signal-desktop", "Signal"),
        ("com.webex", "Webex"),
        ("com.cisco.webex", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
    ]

    static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/CallCopilot.log")

    /// Test switches work only alongside a --test-* argument, so an environment variable alone can't change
    /// what the installed app does.
    static let isTestRun = CommandLine.arguments.contains { $0.hasPrefix("--test-") }
    static let showInCapture = isTestRun && ProcessInfo.processInfo.environment["CALLCOPILOT_TEST_SHOW_IN_CAPTURE"] != nil
}

private let logQueue = DispatchQueue(label: "call-copilot.log")

/// Event log. Never pass transcript text or Claude's replies here: the log outlives the call.
func log(_ message: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if Config.isTestRun { FileHandle.standardError.write(line.data(using: .utf8)!) }
    logQueue.async {
        guard let f = fopen(Config.logURL.path, "a") else { return }
        fputs(line, f)
        fclose(f)
    }
}

/// Keeps the log to its last ~512 KB. Called at launch.
func trimLog() {
    let url = Config.logURL
    guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int,
          size > 1_000_000, let data = try? Data(contentsOf: url) else { return }
    var tail = data.suffix(512_000)
    if let nl = tail.firstIndex(of: 0x0A) { tail = tail.suffix(from: tail.index(after: nl)) }
    try? Data(tail).write(to: url)
}

/// Environment for child `claude` processes: an allowlist, so nothing set in launchd's environment (a proxy, a
/// different API endpoint) reaches them.
func childEnvironment(extra: [String: String] = [:]) -> [String: String] {
    let src = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var env: [String: String] = [
        "HOME": home,
        "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
    ]
    for k in ["USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"] {
        if let v = src[k] { env[k] = v }
    }
    env.merge(extra) { _, new in new }
    return env
}

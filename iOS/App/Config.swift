import Foundation
import os

enum Config {
    /// The same settings format as the Mac app (Shared/Settings.swift), edited in the app's Settings screen.
    static let settingsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("settings.json")
    /// Listening stops after this long without speech, so a forgotten session doesn't keep costing money...
    static let silenceStop: TimeInterval = 10 * 60
    /// ...and after this long in any case.
    static let maxSession: TimeInterval = 4 * 3600

    /// Where the transcript comes from, for the prompt.
    static let promptSetting = "You assist the user during a live meeting or call. You receive its transcript in chunks "
        + "as it happens, from the user's iPhone microphone: everyone in the room (or a call on a nearby speaker), with "
        + "no speaker labels."

    /// Test switches work only alongside a --test-* launch argument, and only in development (Debug) builds:
    /// `iOS/build.sh phone` installs a Release build, in which they don't exist.
    #if DEBUG
    static let isTestRun = ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--test-") }
    #else
    static let isTestRun = false
    #endif

    static func testValue(_ flag: String, offset: Int = 1) -> String? {
        let a = ProcessInfo.processInfo.arguments
        guard isTestRun, let i = a.firstIndex(of: flag), i + offset < a.count else { return nil }
        return a[i + offset]
    }
}

private let logger = Logger(subsystem: "Call Copilot", category: "events")

/// Event log (Console.app, or stdout in test runs). Never pass transcript text or Claude's replies here.
func log(_ message: String) {
    logger.info("\(message, privacy: .public)")
    if Config.isTestRun { print("LOG " + message) }
}
